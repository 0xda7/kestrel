// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Harness-side executor for the same 10-tool surface the kernel advertises
/// (plan.md §3, TASKS.md §2): fs_read/fs_write/fs_list/fs_grep/shell_run/
/// js_eval/todo_write/todo_read/note_add/task_done.
///
/// Deliberately NOT the kernel's `MerlinToolRegistry`: this is the harness's
/// own executor, path-confined to the task workspace by `EvalWorkspace`,
/// with the baseline contract from SCORING.md §7 — raw results, no
/// guardian, no ledger, no retry classification beyond the error class tag.
/// `task_done` does not throw through here: it records the completion and
/// the executor reports `finished`, ending the run.
final class EvalToolExecutor: @unchecked Sendable {
    /// Timeout for `shell_run` per the slice contract (the command_ok
    /// *assertion* path uses the tighter 10 s limit in AssertionEngine).
    static let shellTimeout: TimeInterval = 30
    /// Maximum size of any single model-facing tool result.
    static let maxResultLength = 6000

    struct State: Sendable {
        /// The latest todo list (todo_write replaces, todo_read returns).
        var todos: [String] = []
        /// Notes recorded via note_add.
        var notes: [String] = []
        /// Completion record when `task_done` executed (voluntary by
        /// construction: the only way to reach it is a driver-emitted call).
        var completionSummary: String?
        /// For js_eval: carries the explicit not-supported note once.
        var jsNotSupportedReported = false
    }

    private let workspace: EvalWorkspace
    /// Executor state mutated by todo/note tools; guarded because the harness
    /// loop is single-threaded, the lock keeps the class Sendable-honest.
    private let stateLock = NSLock()
    private var _state = State()

    init(workspace: EvalWorkspace) {
        self.workspace = workspace
    }

    var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    /// True when a `task_done` call completed the run.
    var isCompleted: Bool {
        state.completionSummary != nil
    }
    var completionSummary: String? {
        state.completionSummary
    }

    /// Executes one call and returns its event. Never throws: every failure
    /// becomes a recorded tool error with a class tag (the transcript is the
    /// fault signal, not the control flow).
    func execute(_ call: EvalToolCall, turn: Int) -> ToolEvent {
        stateLock.lock()
        defer { stateLock.unlock() }
        let (text, errorClass) = executeLocked(call)
        _state = stateAfterExecutionLocked(call, text: text, errorClass: errorClass)
        return ToolEvent(turn: turn, call: call, errorClass: errorClass, resultText: text)
    }

    // MARK: - Dispatch

    /// Returns (resultText, errorClass: nil = success).
    private func executeLocked(_ call: EvalToolCall) -> (String, String?) {
        guard let args = call.decodedArguments else {
            return ("error: tool arguments are not a valid JSON object: \(call.argumentsJSON.prefix(200))", "bad_args")
        }
        switch call.name {
        case "fs_read": return fileRead(args)
        case "fs_write": return fileWrite(args)
        case "fs_list": return fileList(args)
        case "fs_grep": return fileGrep(args)
        case "shell_run": return shellRun(args)
        case "js_eval": return jsEval(args)
        case "todo_write": return todoWrite(args)
        case "todo_read": return todoRead()
        case "note_add": return noteAdd(args)
        case "task_done": return taskDone(args)
        default:
            return ("error: unknown tool \"\(call.name)\" — surface is exactly: \(EvalSuite.toolSurface.joined(separator: ", "))", "unknown_tool")
        }
    }

    // MARK: - fs_*

    private func fileRead(_ args: [String: JSONValue]) -> (String, String?) {
        guard let path = args.string("path") else {
            return (toolError("fs_read requires a string \"path\""), "bad_args")
        }
        do {
            let url = try workspace.resolve(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return (toolError("no such file: \(path)"), "not_found")
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return (toolError("file is not readable UTF-8 text: \(path)"), "not_text")
            }
            return (cap(text), nil)
        } catch {
            return (toolError("\(error)"), "sandbox")
        }
    }

    private func fileWrite(_ args: [String: JSONValue]) -> (String, String?) {
        guard let path = args.string("path") else {
            return (toolError("fs_write requires a string \"path\""), "bad_args")
        }
        guard let content = args.string("content") else {
            return (toolError("fs_write requires a string \"content\""), "bad_args")
        }
        do {
            let url = try workspace.resolve(path, forWriting: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return (cap("wrote \(path) (\(content.count) chars)"), nil)
        } catch {
            return (toolError("\(error)"), ToolErrorClass.classify(tool: "fs_write", message: "\(error)"))
        }
    }

    private func fileList(_ args: [String: JSONValue]) -> (String, String?) {
        let rawPath = args.string("path") ?? "."
        do {
            let url = try workspace.resolve(rawPath == "." ? "" : rawPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return (toolError("not a directory in the workspace: \(rawPath)"), "not_found")
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            return (cap(names.isEmpty ? "(empty directory)" : names.joined(separator: "\n")), nil)
        } catch {
            return (toolError("\(error)"), ToolErrorClass.classify(tool: "fs_list", message: "\(error)"))
        }
    }

    /// Literal-substring search across regular files under the given path
    /// (whole workspace when omitted), reported as path:line: line — the
    /// kernel registry's format, kept identical so drivers see one surface.
    private func fileGrep(_ args: [String: JSONValue]) -> (String, String?) {
        guard let pattern = args.string("pattern") else {
            return (toolError("fs_grep requires a string \"pattern\""), "bad_args")
        }
        let rawPath = args.string("path") ?? "."
        do {
            let url = try workspace.resolve(rawPath == "." ? "" : rawPath)
            var isDirectory: ObjCBool = false
            var files: [URL] = []
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
                while let next = enumerator?.nextObject() as? URL {
                    if (try? next.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        files.append(next)
                    }
                }
            } else if FileManager.default.fileExists(atPath: url.path) {
                files = [url]
            } else {
                return (toolError("no such path in the workspace: \(rawPath)"), "not_found")
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
                            return (cap(matches.joined(separator: "\n") + "\n(truncated at 200 matches)"), nil)
                        }
                    }
                }
            }
            return (cap(matches.isEmpty ? "no matches" : matches.joined(separator: "\n")), nil)
        } catch {
            return (toolError("\(error)"), ToolErrorClass.classify(tool: "fs_grep", message: "\(error)"))
        }
    }

    // MARK: - shell_run / js_eval

    private func shellRun(_ args: [String: JSONValue]) -> (String, String?) {
        guard let command = args.string("command") else {
            return (toolError("shell_run requires a string \"command\""), "bad_args")
        }
        let outcome = EvalShell.run(command: command, cwd: workspace.rootPath, timeout: Self.shellTimeout)
        let text = EvalShell.modelFacingText(outcome)
        if outcome.timedOut { return (toolError("shell_run timed out after \(Int(Self.shellTimeout))s: \(text)"), "timeout") }
        if outcome.exitCode != 0 { return (toolError("shell_run exited \(outcome.exitCode.map(String.init) ?? "?"): \(text)"), "nonzero_exit") }
        return (cap(text), nil)
    }

    /// JS engine wiring is a later dispatch: refuse loudly and honestly
    /// instead of pretending. Drivers get a stable, classified error and the
    /// transcript records that the capability was declined.
    private func jsEval(_ args: [String: JSONValue]) -> (String, String?) {
        guard args.string("code") != nil else {
            return (toolError("js_eval requires a string \"code\""), "bad_args")
        }
        return ("error: js_eval is not supported in baseline yet (JS engine wiring is a later dispatch); use shell_run with python3 for computation",
                "unsupported")
    }

    // MARK: - Ledger tools (harness-side, in-memory)

    private func todoWrite(_ args: [String: JSONValue]) -> (String, String?) {
        guard case .array(let items) = args["todos"], !items.isEmpty else {
            return (toolError("todo_write requires a non-empty \"todos\" array of {text, done}"), "bad_args")
        }
        var lines: [String] = []
        for (index, item) in items.enumerated() {
            guard case .object(let object) = item, let text = object.string("text") else {
                return (toolError("todo \(index) must be an object with a string \"text\""), "bad_args")
            }
            let done: Bool
            if case .bool(let flag) = object["done"] { done = flag } else { done = false }
            lines.append("\(done ? "[x]" : "[ ]") \(text)")
        }
        // Called with stateLock already held by execute(); mutate _state
        // directly — NSLock is not re-entrant.
        _state.todos = lines
        return ("todo list replaced (\(lines.count) items)", nil)
    }

    private func todoRead() -> (String, String?) {
        // Called with stateLock already held by execute(); read _state directly.
        let todos = _state.todos
        guard !todos.isEmpty else {
            return ("(no todo list yet; call todo_write to set one)", nil)
        }
        return (todos.joined(separator: "\n"), nil)
    }

    private func noteAdd(_ args: [String: JSONValue]) -> (String, String?) {
        guard let kind = args.string("kind"), ["fact", "decision", "blocker", "artifact"].contains(kind) else {
            return (toolError("note_add requires \"kind\" ∈ {fact, decision, blocker, artifact}"), "bad_args")
        }
        guard let text = args.string("text") else {
            return (toolError("note_add requires a string \"text\""), "bad_args")
        }
        let key = args.string("key")
        let line = "[\(kind)\(key.map { ":\($0)" } ?? "")] \(text)"
        // Called with stateLock already held by execute(); mutate directly.
        _state.notes.append(line)
        return ("noted (\(kind)\(key.map { ", key \($0)" } ?? ""))", nil)
    }

    /// Completion contract: records the summary and reports `finished`. The
    /// harness turn-loop checks this after every call and ends the run —
    /// mid-batch, dropping the rest of the batch, exactly like the kernel.
    private func taskDone(_ args: [String: JSONValue]) -> (String, String?) {
        guard let summary = args.string("summary"), !summary.isEmpty else {
            return (toolError("task_done requires a non-empty string \"summary\" (cite artifact paths)"), "bad_args")
        }
        // Called with stateLock already held by execute(); mutate directly.
        _state.completionSummary = summary
        return ("task accepted: \(cap(summary, limit: 500))", nil)
    }

    // MARK: - Helpers

    private func stateAfterExecutionLocked(_ call: EvalToolCall, text: String, errorClass: String?) -> State {
        // The todo/note tools already mutated _state inline under the lock
        // (their handlers own the mutation); nothing further is needed here.
        // This hook exists so a later dispatch can add trace hooks without
        // re-working the dispatch switch.
        return _state
    }

    private func toolError(_ message: String) -> String {
        "error: \(message)"
    }

    private func cap(_ text: String, limit: Int = EvalToolExecutor.maxResultLength) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 20)) + "… [truncated]"
    }
}

// MARK: - JSONValue argument helpers

private extension Dictionary where Key == String, Value == JSONValue {
    /// String field accessor used by every handler ("path", "content", …).
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }
}
