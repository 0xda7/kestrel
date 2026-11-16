// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The ten-tool surface Merlin advertises to the model, plus the handlers
/// that execute them.
///
/// Each tool carries the three things the runtime needs: a JSON schema (the
/// constrained-actor grammar in slice 2 compiles per-tool schemas from
/// these), a one-line description injected into the tool contract, and a
/// handler closure taking the decoded JSON arguments as a string and
/// returning the model-facing result text. Handlers do their own argument
/// decoding so the registry stays decoding-agnostic.
///
/// Filesystem tools resolve every path through the run's `MerlinWorkspace`
/// and refuse the ledger file directly — the run's memory is only mutated
/// through the ledger-backed tools. `shell_run` and `js_eval` execute
/// kernel-side through `MerlinShell` / `MerlinJS` (slice 3, workspace-cwd
/// process runner with an environment allowlist, and a host-free
/// JavaScriptCore sandbox respectively).
public final class MerlinToolRegistry: @unchecked Sendable {
    /// One registered tool.
    ///
    /// `@unchecked Sendable`: a tool is immutable after construction — the
    /// schema and description are only read, and the handler is already
    /// `@Sendable` — so sharing it across the loop is safe.
    public struct Tool: @unchecked Sendable {
        public let name: String
        /// JSON Schema for the `parameters` object (M1 compiles the grammar
        /// from this).
        public let schema: [String: Any]
        public let description: String
        /// Executes the tool. `argumentsJSON` is the raw arguments object as
        /// a JSON string; `turn` is the current spine turn (for ledger
        /// entries). Throws `MerlinRetry.ToolError` or a system error.
        public let handler: @Sendable (String, Int) async throws -> String
    }

    /// Thrown by `execute` when the model names a tool that does not exist.
    public struct UnknownToolError: Error, CustomStringConvertible {
        public let name: String
        public var description: String { "unknown tool: \(name)" }
    }

    /// Typed stub error for tools owned by later slices. Classification is
    /// permanent: retrying a not-yet-wired tool can never succeed, and the
    /// message tells the model to route around it.
    public struct NotWiredError: Error, CustomStringConvertible {
        public let tool: String
        public var description: String {
            "\(tool) is not yet wired (slice 3); use the fs_* tools and the ledger tools"
        }
    }

    /// Thrown by the `task_done` handler to end the run. The kernel catches
    /// it and turns the summary into the outcome; direct registry callers
    /// (the CLI probe) may catch it too.
    ///
    /// Slice 3 (M5): `claimedArtifacts` carries the artifact paths the
    /// completion claim names — from the JSON `artifacts` array when the
    /// model sends it, plus any inline `- <path>` summary lines. The
    /// verifier checks each against the workspace before the run may end as
    /// completed (see `CompletionClaim` for the documented contract).
    /// `summary`-only construction keeps the pre-verifier call shape valid.
    public struct TaskDoneSignal: Error {
        public let summary: String
        public let claimedArtifacts: [String]

        public init(summary: String, claimedArtifacts: [String] = []) {
            self.summary = summary
            self.claimedArtifacts = claimedArtifacts
        }
    }

    /// The canonical tool names, in contract order.
    public static let reservedNames: [String] = [
        "fs_read", "fs_write", "fs_list", "fs_grep",
        "shell_run", "js_eval",
        "todo_write", "todo_read", "note_add", "task_done",
    ]

    public let workspace: MerlinWorkspace
    public let ledger: MerlinLedger
    private var tools: [String: Tool]

    /// Builds the registry with all ten tools bound to `workspace` and
    /// `ledger`.
    public init(workspace: MerlinWorkspace, ledger: MerlinLedger) {
        self.workspace = workspace
        self.ledger = ledger
        self.tools = [:]
        for tool in Self.makeTools(workspace: workspace, ledger: ledger) {
            self.tools[tool.name] = tool
        }
    }

    /// All tools in the canonical order (the order of `reservedNames`).
    public var orderedTools: [Tool] {
        Self.reservedNames.compactMap { tools[$0] }
    }

    public func tool(named name: String) -> Tool? {
        tools[name]
    }

    /// Executes one tool call: decode arguments, run the handler under the
    /// tool's retry policy (M7), and return the model-facing text. The
    /// caller (kernel loop) owns ledger writes for results.
    public func execute(name: String, argumentsJSON: String, turn: Int) async throws -> String {
        guard let tool = tools[name] else { throw UnknownToolError(name: name) }
        return try await MerlinRetry.runAsync(tool: name) {
            try await tool.handler(argumentsJSON, turn)
        }
    }

    // MARK: - Tool construction

    /// The JSON Schema shapes. Kept static and pure so M1 can compile
    /// grammars from the same definitions checks pin.
    public static func schema(for name: String) -> [String: Any] {
        switch name {
        case "fs_read":
            return object(required: ["path"], properties: [
                "path": string("Workspace-relative file path to read"),
            ])
        case "fs_write":
            return object(required: ["path", "content"], properties: [
                "path": string("Workspace-relative file path to write"),
                "content": string("Full text content to write (replaces the file)"),
            ])
        case "fs_list":
            return object(required: ["path"], properties: [
                "path": string("Workspace-relative directory path ('.' for the root)"),
            ])
        case "fs_grep":
            return object(required: ["pattern"], properties: [
                "pattern": string("Literal text to search for"),
                "path": string("Optional workspace-relative file or directory to search (default: whole workspace)"),
            ])
        case "shell_run":
            return object(required: ["command"], properties: [
                "command": string("Shell command to run inside the workspace"),
                "timeout": [
                    "type": "number",
                    "description": "Optional wall-clock cap in seconds (1-30; default 30)",
                ],
            ])
        case "js_eval":
            return object(required: ["code"], properties: [
                "code": string("JavaScript source to evaluate in the sandbox"),
            ])
        case "todo_write":
            return object(required: ["todos"], properties: [
                "todos": [
                    "type": "array",
                    "description": "The complete todo list, replacing any previous list",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string", "description": "What to do"],
                            "done": ["type": "boolean", "description": "True when finished"],
                        ],
                        "required": ["text", "done"],
                    ],
                ],
            ])
        case "todo_read":
            return object(required: [], properties: [:])
        case "note_add":
            return object(required: ["kind", "text"], properties: [
                "kind": [
                    "type": "string",
                    "description": "Entry kind: fact, decision, blocker, or artifact",
                    "enum": ["fact", "decision", "blocker", "artifact"],
                ],
                "key": ["type": "string", "description": "Optional short key for grouping"],
                "text": ["type": "string", "description": "The note itself"],
            ])
        case "task_done":
            // `artifacts` is OPTIONAL (M5 mechanical completion contract):
            // either shape names the files the claim cites — the JSON array
            // here, or inline `- <path>` lines inside the summary. Required
            // stays ["summary"], so the M1 envelope grammar (which compiles
            // per-tool schemas from this same map) stays byte-compatible.
            return ["type": "object",
                    "properties": [
                        "summary": string("Final answer: what was accomplished, citing artifact paths"),
                        "artifacts": [
                            "type": "array",
                            "description": "Workspace-relative paths of the files this completion claims as evidence",
                            "items": ["type": "string"],
                        ],
                    ],
                    "required": ["summary"]]
        default:
            return object(required: [], properties: [:])
        }
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func object(required: [String], properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    /// Decodes a JSON object payload into a dictionary of untyped values.
    public static func decodeArguments(_ argumentsJSON: String) throws -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw MerlinRetry.ToolError(classification: .toolArg, message: "arguments are not UTF-8 text")
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MerlinRetry.ToolError(classification: .toolArg, message: "arguments must be a JSON object")
            }
            return object
        } catch let error as MerlinRetry.ToolError {
            throw error
        } catch {
            throw MerlinRetry.ToolError(classification: .toolArg,
                                        message: "arguments are not valid JSON: \(error.localizedDescription)")
        }
    }

    public static func requireString(_ args: [String: Any], _ field: String) throws -> String {
        guard let value = args[field] as? String, !value.isEmpty else {
            throw MerlinRetry.ToolError(classification: .toolArg,
                                        message: "missing or empty string field: \(field)")
        }
        return value
    }

    /// The ledger lives at the workspace root under a reserved name; this is
    /// its resolved path in `workspace`.
    private static func ledgerPath(in workspace: MerlinWorkspace) -> String {
        workspace.rootURL.appendingPathComponent(MerlinLedger.fileName).path
    }

    /// Refuses direct tool access to the run's ledger file: the run's memory
    /// is only mutated through the ledger-backed tools, never through `fs_*`.
    ///
    /// SECURITY wave 2 (§1.1 case-fold hole): the comparison is
    /// CASE-INSENSITIVE on both sides. On case-insensitive APFS the
    /// byte-different spelling (`MERLIN-LEDGER.JSONL`) resolves onto the
    /// SAME file, so the old byte-wise `!=` let the write through and the
    /// case-folded name overwrote the run's memory. Folded on both sides
    /// (not `localizedCaseInsensitiveCompare`, which is locale-dependent) —
    /// the reservation is a byte-folding property, not a localization one.
    private static func rejectLedgerAccess(_ url: URL, workspace: MerlinWorkspace, path: String) throws {
        guard url.path.lowercased() != ledgerPath(in: workspace).lowercased() else {
            throw MerlinRetry.ToolError(classification: .toolArg,
                                        message: "\(path) is the run ledger, managed by the kernel; use note_add, todo_write, and todo_read")
        }
    }

    /// Builds all ten tools.
    private static func makeTools(workspace: MerlinWorkspace, ledger: MerlinLedger) -> [Tool] {
        [
            fileRead(workspace: workspace),
            fileWrite(workspace: workspace, ledger: ledger),
            fileList(workspace: workspace),
            fileGrep(workspace: workspace),
            shellRun(workspace: workspace),
            jsEval(),
            todoWrite(ledger: ledger),
            todoRead(ledger: ledger),
            noteAdd(ledger: ledger),
            taskDone(ledger: ledger),
        ]
    }

    // MARK: - fs_* (fully wired in this slice)

    private static func fileRead(workspace: MerlinWorkspace) -> Tool {
        Tool(name: "fs_read", schema: schema(for: "fs_read"),
             description: "Read a text file from the workspace.") { argsJSON, _ in
            let args = try decodeArguments(argsJSON)
            let path = try requireString(args, "path")
            let url = try workspace.resolve(path)
            try rejectLedgerAccess(url, workspace: workspace, path: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MerlinRetry.ToolError(classification: .toolArg, message: "no such file: \(path)")
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                throw MerlinRetry.ToolError(classification: .toolArg, message: "path is a directory: \(path)")
            }
            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw MerlinRetry.ToolError(classification: .permanent,
                                            message: "file is not readable text: \(path)")
            }
        }
    }

    private static func fileWrite(workspace: MerlinWorkspace, ledger: MerlinLedger) -> Tool {
        Tool(name: "fs_write", schema: schema(for: "fs_write"),
             description: "Create or replace a text file in the workspace; intermediate folders are created for you.") { argsJSON, turn in
            let args = try decodeArguments(argsJSON)
            let path = try requireString(args, "path")
            let content = try requireString(args, "content")
            let url = try workspace.resolveForWriting(path)
            try rejectLedgerAccess(url, workspace: workspace, path: path)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try ledger.append(turn: turn, kind: .artifact, key: path,
                              text: "wrote \(content.count) chars to \(path)")
            return "wrote \(path) (\(content.count) chars)"
        }
    }

    private static func fileList(workspace: MerlinWorkspace) -> Tool {
        Tool(name: "fs_list", schema: schema(for: "fs_list"),
             description: "List a directory in the workspace, one entry per line.") { argsJSON, _ in
            let args = try decodeArguments(argsJSON)
            let rawPath = (args["path"] as? String) ?? "."
            let url = try workspace.resolve(rawPath)
            try rejectLedgerAccess(url, workspace: workspace, path: rawPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MerlinRetry.ToolError(classification: .toolArg,
                                            message: "not a directory in the workspace: \(rawPath)")
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            if names.isEmpty { return "(empty directory)" }
            return names.joined(separator: "\n")
        }
    }

    private static func fileGrep(workspace: MerlinWorkspace) -> Tool {
        Tool(name: "fs_grep", schema: schema(for: "fs_grep"),
             description: "Find lines containing literal text, reported as path:line: matches.") { argsJSON, _ in
            let args = try decodeArguments(argsJSON)
            let pattern = try requireString(args, "pattern")
            let rawPath = (args["path"] as? String) ?? "."
            let url = try workspace.resolve(rawPath)
            try rejectLedgerAccess(url, workspace: workspace, path: rawPath)

            let reservedLedgerPath = ledgerPath(in: workspace)
            var files: [URL] = []
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
                while let next = enumerator?.nextObject() as? URL {
                    guard next.path != reservedLedgerPath else { continue }
                    if (try? next.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        files.append(next)
                    }
                }
            } else {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw MerlinRetry.ToolError(classification: .toolArg,
                                                message: "no such path in the workspace: \(rawPath)")
                }
                files = [url]
            }

            var matches: [String] = []
            for file in files.sorted(by: { $0.path < $1.path }) {
                let relative = file.path.hasPrefix(workspace.rootPath + "/")
                    ? String(file.path.dropFirst(workspace.rootPath.count + 1))
                    : file.path
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    if line.contains(pattern) {
                        matches.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                        if matches.count >= 200 {
                            matches.append("(truncated at 200 matches)")
                            return matches.joined(separator: "\n")
                        }
                    }
                }
            }
            return matches.isEmpty ? "no matches" : matches.joined(separator: "\n")
        }
    }

    // MARK: - Ledger tools (fully wired in this slice)

    private static func todoWrite(ledger: MerlinLedger) -> Tool {
        Tool(name: "todo_write", schema: schema(for: "todo_write"),
             description: "Replace the task todo list; the digest shows open items every turn.") { argsJSON, turn in
            let args = try decodeArguments(argsJSON)
            guard let todos = args["todos"] as? [[String: Any]], !todos.isEmpty else {
                throw MerlinRetry.ToolError(classification: .toolArg,
                                            message: "todos must be a non-empty array of {text, done}")
            }
            var lines: [String] = []
            for (index, todo) in todos.enumerated() {
                guard let text = todo["text"] as? String, !text.isEmpty else {
                    throw MerlinRetry.ToolError(classification: .toolArg,
                                                message: "todo \(index) is missing its text")
                }
                let done = (todo["done"] as? Bool) ?? false
                lines.append("\(done ? "[x]" : "[ ]") \(text)")
            }
            try ledger.append(turn: turn, kind: .decision, key: "todos",
                              text: "todo list now:\n" + lines.joined(separator: "\n"))
            return "todo list replaced (\(todos.count) items); open items show in the digest"
        }
    }

    private static func todoRead(ledger: MerlinLedger) -> Tool {
        Tool(name: "todo_read", schema: schema(for: "todo_read"),
             description: "Read the current todo list (the latest todo_write).") { _, _ in
            let todos = ledger.allEntries.last { $0.kind == .decision && $0.key == "todos" }
            guard let todos else { return "(no todo list yet; call todo_write to set one)" }
            let body = todos.text.split(separator: "\n").dropFirst().joined(separator: "\n")
            return body.isEmpty ? "(empty todo list)" : body
        }
    }

    private static func noteAdd(ledger: MerlinLedger) -> Tool {
        Tool(name: "note_add", schema: schema(for: "note_add"),
             description: "Record a fact, decision, blocker, or artifact in the structured memory.") { argsJSON, turn in
            let args = try decodeArguments(argsJSON)
            let kindName = try requireString(args, "kind")
            let text = try requireString(args, "text")
            let key = args["key"] as? String
            guard let kind = MerlinLedger.Kind(rawValue: kindName),
                  kind != .result else {
                throw MerlinRetry.ToolError(classification: .toolArg,
                                            message: "kind must be fact, decision, blocker, or artifact (results are written by the kernel)")
            }
            try ledger.append(turn: turn, kind: kind, key: key, text: text)
            return "noted (\(kind.rawValue)\(key.map { ", key \($0)" } ?? ""))"
        }
    }

    private static func taskDone(ledger: MerlinLedger) -> Tool {
        Tool(name: "task_done", schema: schema(for: "task_done"),
             description: "File the completion contract: end the task with a final summary that cites artifact paths.") { argsJSON, turn in
            let args = try decodeArguments(argsJSON)
            let summary = try requireString(args, "summary")
            // M5 completion contract: both artifact shapes fold into one
            // list on the signal — the JSON `artifacts` array (optional) and
            // any inline `- <path>` summary lines. The union (JSON entries
            // first, deduplicated) is authoritative: JSON paths may contain
            // spaces, which the inline line parser intentionally refuses.
            // The kernel's verifier checks every named path against the
            // workspace before the run ends as completed; a missing
            // artifact rejects the task_done with an actionable blocker.
            let jsonArtifacts = CompletionClaim.artifacts(fromArguments: args)
            let folded = CompletionClaim.folded(summary: summary, artifacts: jsonArtifacts)
            var claimed = jsonArtifacts
            for path in CompletionClaim.parse(summary: summary).artifactPaths
            where !claimed.contains(path) {
                claimed.append(path)
            }
            try ledger.append(turn: turn, kind: .result, key: "task_done", text: folded)
            throw TaskDoneSignal(summary: folded, claimedArtifacts: claimed)
        }
    }

    // MARK: - Compute tools (wired in slice 3)

    /// `shell_run`: kernel-side process runner (`MerlinShell`), cwd pinned
    /// to the workspace root, fixed environment allowlist, ledger screen on
    /// every command, and — when the host allows it — the generated
    /// seatbelt profile (no network, workspace-confined writes, hidden
    /// HOME), with a process-group SIGTERM→SIGKILL timeout ladder. The
    /// description is the HONEST boundary text from `MerlinShell` (never a
    /// hardcoded claim: the screening fallback says so). Result text
    /// carries the `exit <code>` contract line the M4 guardian checks.
    private static func shellRun(workspace: MerlinWorkspace) -> Tool {
        Tool(name: "shell_run", schema: schema(for: "shell_run"),
             description: MerlinShell.modelFacingDescription()) { argsJSON, _ in
            let args = try decodeArguments(argsJSON)
            let command = try requireString(args, "command")
            var configuration = MerlinShell.Configuration()
            if let seconds = args["timeout"] as? NSNumber {
                // Clamp to the tool's contract: never below 1 s, never
                // above the 30 s ceiling (the tool cap is not model-stretchable).
                let clamped = min(max(seconds.doubleValue, 1), configuration.timeout)
                configuration.timeout = clamped
            }
            let outcome = try await MerlinShell.run(command: command,
                                                    workspaceRoot: workspace.rootPath,
                                                    ledgerFileName: MerlinLedger.fileName,
                                                    configuration: configuration)
            return MerlinShell.outcomeText(outcome, cap: configuration.outputCharacterCap)
        }
    }

    /// `js_eval`: fresh host-free JavaScriptCore context per evaluation
    /// (`MerlinJS`), 100 KB script cap, 10 s watchdog wall clock — a script
    /// exceeding it is abandoned and reported as a timeout error (the
    /// pre-hardening version blocked the run forever; see `MerlinJS`'s
    /// documented residual limitation).
    private static func jsEval() -> Tool {
        Tool(name: "js_eval", schema: schema(for: "js_eval"),
             description: MerlinJS.modelFacingDescription()) { argsJSON, _ in
            let args = try decodeArguments(argsJSON)
            let code = try requireString(args, "code")
            return try await MerlinJS.evaluate(code: code)
        }
    }
}
