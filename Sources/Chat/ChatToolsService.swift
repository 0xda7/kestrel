// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

struct BuiltinToolInfo: Identifiable, Sendable {
    let displayName: String
    let name: String
    let writesData: Bool
    /// Server tools work relative to the working directory carried in `x-tool-cwd`.
    let usesCwd: Bool
    let definitionData: Data
    let mcpServerID: UUID?
    let remoteName: String?

    var id: String { name }

    /// BUG-SHIELD naming comment (census W8 ChatToolsService:21): registration
    /// already validates every definition — `init?(json:)` checks
    /// `isValidJSONObject` before serializing, the throwing init propagates
    /// the serialize error, and the literal init traps — so `definitionData`
    /// is exactly valid JSON and this decode cannot fail for a registered
    /// tool. A nil here would mean a registration bug, not bad input.
    var openAIDefinition: [String: Any]? {
        try? JSONSerialization.jsonObject(with: definitionData) as? [String: Any]
    }

    init?(json: [String: Any]) {
        guard let displayName = json["display_name"] as? String,
              let name = json["tool"] as? String,
              let permissions = json["permissions"] as? [String: Any],
              let writesData = permissions["write"] as? Bool,
              let definition = json["definition"] as? [String: Any],
              JSONSerialization.isValidJSONObject(definition),
              let definitionData = try? JSONSerialization.data(withJSONObject: definition)
        else { return nil }
        self.displayName = displayName
        self.name = name
        self.writesData = writesData
        self.usesCwd = json["uses_cwd"] as? Bool ?? false
        self.definitionData = definitionData
        mcpServerID = nil
        remoteName = nil
    }

    init(displayName: String, name: String, definition: [String: Any],
         mcpServerID: UUID, remoteName: String) throws {
        self.displayName = displayName
        self.name = name
        writesData = true
        usesCwd = false
        definitionData = try JSONSerialization.data(withJSONObject: definition)
        self.mcpServerID = mcpServerID
        self.remoteName = remoteName
    }

    /// For definitions written as compile-time literals (the builtin tools):
    /// string keys with string/bool/array/dictionary values, so the schema is
    /// valid JSON by construction and serialization cannot fail — every
    /// definition passed here was verified to serialize as written. A static
    /// initializer has no caller that could receive an error, and a tool whose
    /// schema cannot be serialized cannot be advertised, so a violated
    /// invariant traps with the tool's name instead of failing silently.
    /// Definitions built at runtime (MCP tools, server tool lists) must use the
    /// throwing `init(displayName:name:definition:mcpServerID:remoteName:)`
    /// or `init?(json:)` instead, which surface the error to their caller.
    init(displayName: String, name: String, writesData: Bool,
         definition: [String: Any]) {
        guard let definitionData = try? JSONSerialization.data(withJSONObject: definition) else {
            preconditionFailure("\(name): builtin tool definition literal is not valid JSON")
        }
        self.displayName = displayName
        self.name = name
        self.writesData = writesData
        usesCwd = false
        self.definitionData = definitionData
        mcpServerID = nil
        remoteName = nil
    }
}

struct ToolExecutionResult: Sendable, Equatable {
    let content: String
    let isError: Bool
}

enum ChatToolsError: LocalizedError {
    case invalidResponse
    /// A `data:` line of the tool-exec stream that failed to decode (census
    /// W8 ChatToolsService:237): a dropped event is lost stream content, so
    /// it surfaces as a typed error carrying the offending fragment.
    case invalidStreamEvent(payload: String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "llama.cpp returned an invalid tools response."
        case let .invalidStreamEvent(payload):
            return "llama.cpp sent a malformed tool-stream event: \(payload)"
        case let .server(status, message):
            return "HTTP \(status): \(message)"
        }
    }
}

enum ChatToolsService {
    /// KES-05: "always" consent is session-scoped and never covers the shell.
    /// A persisted, global grant for `exec_shell_command` is full
    /// user-account code execution for the life of the install — one
    /// misclick away. Grants live in memory, so restarting the app clears
    /// them; grants persisted by pre-KES-05 versions are swept away.
    static let execShellToolName = "exec_shell_command"
    private static let sessionAllowed = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func isAlwaysAllowed(_ name: String) -> Bool {
        sweepLegacyPermissionsIfNeeded()
        guard name != execShellToolName else { return false }
        return sessionAllowed.withLock { $0.contains(name) }
    }

    static func allowAlways(_ name: String) {
        sweepLegacyPermissionsIfNeeded()
        guard name != execShellToolName else { return }
        sessionAllowed.withLock { $0.insert(name) }
    }

    static func revokeAllPermissions() {
        sessionAllowed.withLock { $0.removeAll() }
        sweepLegacyPermissionsIfNeeded(force: true)
    }

    /// Versions before KES-05 persisted "always" grants in UserDefaults;
    /// sweep them once per install — not per launch (census W6-2, T4-3 H4)
    /// — so permanent grants from old installs die with this version
    /// instead of surviving as invisible standing consent, and later
    /// launches never pay the dictionaryRepresentation() enumeration
    /// again. The persisted record replaces the old in-process flag; a
    /// concurrent first sweep is two idempotent removals of the same keys,
    /// so no lock is needed. `force` (the explicit revoke path) always
    /// sweeps, record or not: standing consent must die on the operator's
    /// command. Injectable so the one-shot record is checked against a
    /// suite, not the operator's real defaults.
    static func sweepLegacyPermissionsIfNeeded(force: Bool = false, in defaults: UserDefaults = .standard) {
        if !force, defaults.bool(forKey: SettingsKeys.toolPermissionsLegacySwept) { return }
        defaults.set(true, forKey: SettingsKeys.toolPermissionsLegacySwept)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("toolPermission.always.") {
            defaults.removeObject(forKey: key)
        }
    }

    static func list(port: Int) async throws -> [BuiltinToolInfo] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tools")!)
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ChatToolsError.invalidResponse
        }
        return decodeToolRows(rows)
    }

    /// Decodes /tools rows, surfacing rows that fail registration instead of
    /// dropping them silently (census W8 ChatToolsService:31): a tool absent
    /// from the engine's tool list is a silent capability loss — the model
    /// cannot call what it was never offered. Healthy rows still load; each
    /// dropped row is reported with its best-available identifier.
    /// (The listing's network failures are surfaced by the caller.)
    static func decodeToolRows(
        _ rows: [[String: Any]],
        reportDrop: (String) -> Void = { AppLog.chat.warning("tool listing dropped a malformed tool row: \($0)") }
    ) -> [BuiltinToolInfo] {
        var tools: [BuiltinToolInfo] = []
        for row in rows {
            if let tool = BuiltinToolInfo(json: row) {
                tools.append(tool)
            } else {
                let identifier = (row["tool"] as? String) ?? (row["display_name"] as? String) ?? "unknown"
                reportDrop(identifier)
            }
        }
        return tools
    }

    /// Transient-failure retry, read-only tools only. A write/exec tool whose
    /// request timed out may already have taken effect — replaying side
    /// effects is the model's decision on the next turn, never the harness's.
    /// Read-only tools (writesData false) retry twice with backoff on the
    /// transient classes below.
    static func execute(name: String, arguments: [String: Any], port: Int,
                        workingDirectory: String? = nil, writesData: Bool = true,
                        attempt: Int = 0) async throws -> ToolExecutionResult {
        do {
            return try await executeOnce(name: name, arguments: arguments, port: port,
                                         workingDirectory: workingDirectory)
        } catch {
            guard writesData == false, attempt < 2, isTransient(error) else { throw error }
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 1_200))
            return try await execute(name: name, arguments: arguments, port: port,
                                     workingDirectory: workingDirectory, writesData: writesData,
                                     attempt: attempt + 1)
        }
    }

    /// Whether a tool failure is worth retrying: transport-level hiccups and
    /// server-side 5xx. Anything else (4xx refusals, invalid payloads, a tool
    /// that ran and reported an error) is deterministic.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                return false
            }
        }
        if let server = error as? ChatToolsError, case let .server(status, _) = server {
            return status >= 500
        }
        return false
    }

    private static func executeOnce(name: String, arguments: [String: Any], port: Int,
                                    workingDirectory: String?) async throws -> ToolExecutionResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tools")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // the model can't override this one: the server takes the directory from the header
        if let workingDirectory, !workingDirectory.isEmpty {
            request.setValue(workingDirectory, forHTTPHeaderField: "x-tool-cwd")
        }
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tool": name, "params": arguments])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatToolsError.invalidResponse
        }
        if let error = object["error"] { return ToolExecutionResult(content: String(describing: error), isError: true) }
        if let text = object["plain_text_response"] { return ToolExecutionResult(content: String(describing: text), isError: false) }
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ToolExecutionResult(content: String(decoding: normalized, as: UTF8.self), isError: false)
    }

    static func executeStreaming(name: String, arguments: [String: Any], port: Int,
                                 workingDirectory: String? = nil,
                                 onUpdate: @escaping @Sendable (String) async -> Void) async throws -> ToolExecutionResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tools")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let workingDirectory, !workingDirectory.isEmpty {
            request.setValue(workingDirectory, forHTTPHeaderField: "x-tool-cwd")
        }
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "tool": name, "params": arguments, "stream": true
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 1_000 { break }
            }
            throw ChatToolsError.server(status: status, message: detail)
        }
        var output = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            // Census W8 ChatToolsService:237 (DEBT → typed): this endpoint
            // has NO non-JSON sentinel — the loop terminates on the JSON
            // "done" event ([DONE] belongs to the /v1/chat protocol, not
            // here) — so a `data:` payload that fails to decode is lost
            // stream content, not a skippable line, and surfaces as a
            // typed invalidStreamEvent. Prefix-less lines (SSE comments,
            // keepalives) are the protocol skipping itself, not lost
            // content, and still continue.
            guard let event = try Self.toolStreamEvent(from: line) else { continue }
            if let chunk = event["chunk"] as? String {
                output += chunk
                await onUpdate(output)
            }
            if (event["done"] as? Bool) == true {
                if let error = event["error"] as? String, !error.isEmpty {
                    if !output.isEmpty { output += "\n" }
                    output += "Error: \(error)"
                    await onUpdate(output)
                    return ToolExecutionResult(content: output, isError: true)
                }
                return ToolExecutionResult(content: output, isError: false)
            }
        }
        throw ChatToolsError.invalidResponse
    }

    /// Parses one SSE line of the tool-exec stream. Returns nil for lines
    /// without the `data: ` prefix (comments/keepalives — skipping them is
    /// the protocol), the decoded event object for a `data:` payload, and
    /// throws `.invalidStreamEvent` (fragment truncated to 120 characters)
    /// for a `data:` payload that fails UTF-8/JSON/object decode.
    static func toolStreamEvent(from line: String) throws -> [String: Any]? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard let data = payload.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ChatToolsError.invalidStreamEvent(payload: String(payload.prefix(120)))
        }
        return event
    }

    /// Doctrine (mission C1, W1-2): small models emit tool arguments with
    /// BOMs, ```json fences, trailing commas, or single quotes — but only on
    /// UNCONSTRAINED paths (remote providers, custom engine binaries), where
    /// nothing forces the arguments into valid JSON before they arrive. On
    /// the grammar-constrained local path (`ToolTurnEnvelope`) the engine's
    /// schema grammar has already rejected everything this ladder repairs,
    /// so these tiers are unreachable there by construction. Tolerate the
    /// unconstrained shapes before giving up: an unusable arguments blob
    /// costs the whole turn.
    static func parseArguments(_ source: String) throws -> [String: Any] {
        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ```json ... ``` fence: cut to the JSON object itself.
        if text.hasPrefix("```") {
            if let brace = text.firstIndex(of: "{") {
                text = String(text[brace...])
            }
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Census W8 :272 — BUG-SHIELD, interim doctrine. The strict pass is
        // where models that emit well-formed arguments succeed. The repair
        // tiers after it exist for a real UPSTREAM producer failure — small
        // models emit BOM-prefixed, fenced, trailing-comma, or single-quoted
        // JSON — never for a Kestrel defect; they stay until W9
        // grammar-constrained tool calls retire them on the last
        // unconstrained paths (the constrained local path never reaches
        // them). Every tier is pinned in ToolArgumentsRepairTests.
        if let data = text.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return value
        }
        // Trailing commas and single-quoted keys/values: repair with a
        // string-aware scan, not blind search-and-replace.
        if let repaired = repairedJSONObject(from: text),
           let data = repaired.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return value
        }
        // An arguments blob that is only whitespace means "no arguments" for
        // every builtin tool; throwing here would kill the turn for tools
        // like get_datetime. A comment-only blob is NOT whitespace and does
        // throw (pinned in ToolArgumentsRepairTests).
        if strippedOfStrings(text).allSatisfy({ $0.isWhitespace }) { return [:] }
        throw ChatToolsError.invalidResponse
    }

    /// Removes trailing commas outside string literals and normalizes
    /// single-quoted keys/values to double quotes. Returns nil when no repair
    /// produces parseable JSON, so the caller falls through to its error path.
    static func repairedJSONObject(from text: String) -> String? {
        // No `?? [:]` here: coalescing an unrepairable blob into an empty
        // object would turn every invalid arguments payload into "no
        // Census W8 :297 — BUG-SHIELD, interim doctrine (same upstream
        // producer failure as the ladder above): re-serializing the relaxed
        // parse hands the repaired text back in exactly valid JSON. The
        // try? cannot fail for JSONSerialization output; the genuine
        // failure mode (nothing repairable) is the nil return below.
        // arguments" and the invalidResponse throw below would be dead code.
        guard let relaxed = relaxedParse(text),
              let trimmed = try? JSONSerialization.data(withJSONObject: relaxed) else { return nil }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private static func relaxedParse(_ text: String) -> [String: Any]? {
        // First: strip trailing commas with a string-aware, index-based scan.
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                i = text.index(after: i)
                continue
            }
            if ch == "\"" {
                inString = true
                out.append(ch)
                i = text.index(after: i)
                continue
            }
            if ch == "," {
                var peek = text.index(after: i)
                while peek < text.endIndex, text[peek] == " " || text[peek] == "\n"
                        || text[peek] == "\r" || text[peek] == "\t" {
                    peek = text.index(after: peek)
                }
                if peek < text.endIndex, text[peek] == "}" || text[peek] == "]" {
                    i = peek
                    continue
                }
            }
            out.append(ch)
            i = text.index(after: i)
        }
        // Census W8 :337 — BUG-SHIELD, interim doctrine: blobs with
        // trailing commas (a common small-model emission) only parse after
        // this string-aware strip; the re-parse fails for genuinely
        // unrepairable text and falls through to the quote tier below.
        if let data = out.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return value
        }
        // Second: single-quote normalization (keys and values), still
        // string-aware: quotes inside double-quoted strings are untouched.
        var fixed = ""
        fixed.reserveCapacity(out.count)
        inString = false
        escaped = false
        for ch in out {
            if inString {
                fixed.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "'" { fixed.removeLast(); fixed.append("\""); inString = false }
                continue
            }
            if ch == "\"" {
                inString = true
                fixed.append(ch)
                continue
            }
            if ch == "'" {
                fixed.append("\"")
                inString = true
                escaped = false
                continue
            }
            fixed.append(ch)
        }
        // Census W8 :366 — BUG-SHIELD, interim doctrine: single-quoted
        // keys/values (another small-model emission shape) survive only
        // after this normalization; a nil here ends the ladder and the
        // caller throws the typed invalidResponse.
        if let data = fixed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return value
        }
        return nil
    }

    /// Strips double-quoted string contents so whitespace checks ignore what is
    /// inside strings (a result that is `"   "` still counts as empty).
    private static func strippedOfStrings(_ text: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for ch in text {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true; continue }
            out.append(ch)
        }
        return out
    }

    /// Cap on how much of a tool result re-enters the model's context: giant
    /// outputs (a full-file grep, a verbose shell dump) starve small models and
    /// blow the KV budget. The marker tells the model more existed. The
    /// declared default is the operator's `chatToolResultMaxTokens` (T3-1,
    /// census W3-11).
    static let toolResultContextLimit = ChatDefaults.toolResultMaxTokens

    static func clampedToolResult(_ result: String, cap: Int = toolResultContextLimit) -> String {
        guard result.count > cap else { return result }
        let head = String(result.prefix(cap))
        return head + "\n\n[truncated — output exceeded \(cap) characters; narrow the query or read the file in sections]"
    }

    /// Dynamic cap for a tool result entering the context: a quarter of the
    /// window's remaining headroom (≈4 chars/token), floored at the
    /// operator's `chatToolResultMinTokens` and never above the
    /// `chatToolResultMaxTokens` ceiling. Near a full window, tool dumps
    /// shrink instead of evicting the conversation itself.
    nonisolated static func dynamicToolResultCap(windowTokens: Int, usedTokens: Int,
                                                 in defaults: UserDefaults = .standard) -> Int {
        let maxTokens = SettingsNumericCoercion.int(SettingsKeys.chatToolResultMaxTokens,
                                                    default: ChatDefaults.toolResultMaxTokens, in: defaults)
        let minTokens = SettingsNumericCoercion.int(SettingsKeys.chatToolResultMinTokens,
                                                    default: ChatDefaults.toolResultMinTokens, in: defaults)
        let remaining = max(windowTokens - max(usedTokens, 0), 0)
        return min(max(remaining / 4 * 4, minTokens), maxTokens)
    }

    /// Structural validation of a tool's JSON Schema before it is offered to
    /// the engine. A malformed schema (empty name or description, a
    /// `required` entry with no property behind it) surfaces later as cryptic
    /// engine-side tool-call failures; registration drops the tool with a
    /// logged reason instead of shipping a broken definition.
    nonisolated static func schemaProblems(for info: BuiltinToolInfo) -> [String] {
        var problems: [String] = []
        if info.name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("name is empty")
        }
        guard let object = info.openAIDefinition else {
            return problems + ["definition is not valid JSON"]
        }
        let function = object["function"] as? [String: Any] ?? object
        if (function["description"] as? String ?? "").isEmpty {
            problems.append("description is empty")
        }
        if let parameters = function["parameters"] as? [String: Any] {
            if (parameters["type"] as? String) != "object" {
                problems.append("parameters.type is not \"object\"")
            }
            let properties = parameters["properties"] as? [String: Any] ?? [:]
            for required in (parameters["required"] as? [String]) ?? []
            where properties[required] == nil {
                problems.append("required property \"\(required)\" has no schema")
            }
        }
        return problems
    }
    private static func authorize(_ request: inout URLRequest) {
        if let key = ServerSettings.activeAPIKey() {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = object["error"] ?? object["message"] {
                message = String(describing: detail)
            } else {
                message = String(decoding: data.prefix(1_000), as: UTF8.self)
            }
            throw ChatToolsError.server(status: status, message: message)
        }
    }
}

/// Doctrine (mission C1, W1-1): small distilled models frequently emit tool
/// calls as plain text — a fenced `{"name": ..., "arguments": ...}` blob or
/// a `<tool_call>{...}</tool_call>` tag — instead of using the engine's
/// function-calling channel, then answer "I used the tool" while nothing
/// ran. RETIRED on the grammar-constrained local path: `ToolTurnEnvelope`'s
/// schema makes those prose shapes unemittable, so `constrained: true`
/// rescues nothing. Deliberately retained (`constrained: false`, the
/// default) for unconstrained paths — remote providers and custom engine
/// binaries — where prose emission is still possible and this remains the
/// only salvage into real pending tool calls, capped low so a rambling
/// model cannot fire a dozen of them in one turn.

enum ToolCallRescue {
    static let maxPerTurn = 3

    static func rescuedCalls(text: String, toolNames: Set<String>,
                             constrained: Bool = false) -> [ChatToolCall] {
        // Grammar-constrained turns never see prose blobs: the envelope
        // grammar admits only the JSON envelope, so there is nothing to
        // rescue. Returning [] here is the C1 census drill.
        if constrained { return [] }
        guard !text.isEmpty else { return [] }
        var calls: [ChatToolCall] = []
        for blob in candidateBlobs(in: text) {
            // Census W8 :475 — BUG-SHIELD, interim doctrine: candidate
            // blobs fail to parse when the model emitted prose around a
            // broken object — the upstream producer failure documented
            // above (models emitting tool calls outside the wire format on
            // unconstrained paths), not a Kestrel defect. The blob is
            // skipped and the scan continues; W9 grammar enforcement
            // retires this on the constrained path, which already returns
            // [] before reaching here.
            guard calls.count < maxPerTurn else { break }
            guard let data = blob.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rawName = (object["name"] ?? object["tool"] ?? object["tool_name"]) as? String,
                  toolNames.contains(rawName)
            else { continue }
            let arguments: [String: Any]
            if let value = object["arguments"] ?? object["parameters"] ?? object["params"],
               let dict = value as? [String: Any] {
                arguments = dict
            } else {
                arguments = [:]
            }
            // Census W8 :486 — BUG-SHIELD, interim doctrine: this
            // re-serialize cannot fail for arguments taken from a
            // successfully parsed JSON object (JSONSerialization output is
            // exactly valid JSON, and the non-dict case degrades to [:]
            // above, pinned in ToolCallRescueTests) — the skip guards a
            // future non-JSON-producing arguments source, never today's.
            guard let argumentsData = try? JSONSerialization.data(withJSONObject: arguments)
            else { continue }
            calls.append(ChatToolCall(serverID: nil, name: rawName,
                                      arguments: String(decoding: argumentsData, as: UTF8.self)))
        }
        return calls
    }

    /// The call-site gate (ChatNative): rescue only when the engine's own
    /// function-calling channel delivered nothing usable, the turn was not
    /// cancelled, and no error was reported. Extracted verbatim from the
    /// inline condition so the gate itself can be pinned (Mission C1 Phase B).
    static func shouldRescue(channelToolCalls: [ChatToolCall], cancelled: Bool, reportedError: Bool) -> Bool {
        channelToolCalls.filter { !$0.name.isEmpty }.isEmpty && !cancelled && !reportedError
    }

    /// Extracts balanced `{...}` spans that look like tool-call objects:
    /// bare, fenced, or wrapped in `<tool_call>` tags. A naive brace-count is
    /// string-aware so braces inside quoted values do not break balancing.
    private static func candidateBlobs(in text: String) -> [String] {
        var spans: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "<tool_call>", range: searchStart..<text.endIndex) {
            if let close = text.range(of: "</tool_call>", range: open.upperBound..<text.endIndex) {
                spans.append(open.upperBound..<close.lowerBound)
                searchStart = close.upperBound
            } else {
                break
            }
        }
        if spans.isEmpty { spans = [text.startIndex..<text.endIndex] }
        let chunks = spans.map { String(text[$0]) }
        var blobs: [String] = []
        for chunk in chunks {
            var depth = 0
            var start: String.Index?
            var inString = false
            var escaped = false
            for index in chunk.indices {
                let ch = chunk[index]
                if inString {
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                    continue
                }
                if ch == "\"" { inString = true; continue }
                if ch == "{" {
                    if depth == 0 { start = index }
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0, let begin = start {
                        blobs.append(String(chunk[begin...index]))
                        start = nil
                        if blobs.count >= maxPerTurn { return blobs }
                    }
                }
            }
        }
        return blobs
    }
}

/// Mission C1: the grammar-constrained tool-call channel for the local
/// bundled engine. Every tools-carrying request also carries
/// `response_format json_schema` over an envelope that admits exactly one
/// of: a tool call `{"name": <offered name>, "arguments": <that tool's
/// schema>}` or a free-text reply `{"reply": "…"}`. The engine's
/// per-family precedence makes the SAME request shape correct everywhere:
/// generic-path templates (GLM-class prose emitters) enforce the envelope
/// grammar — malformed, fenced, or tagged blobs become unemittable, and the
/// generic tools branch that produced the peg-native 500 is never
/// synthesized — while named families (LFM2/LFM2.5, Kimi, Qwen) keep their
/// own specialized tool grammar and carry calls through the channel. One
/// call per turn by construction; the agent loop iterates for multi-tool
/// flows.
enum ToolTurnEnvelope {
    enum Outcome: Equatable {
        case calls([ChatToolCall])
        case reply(String)
    }

    /// When the constraint binds: a local request, the bundled engine (a
    /// custom binary may predate json_schema support and keeps the legacy
    /// unconstrained path), and tools actually offered after every gate —
    /// a blocklisted model offers no tools, sends no schema, and cannot
    /// 500 (ToolSupport clears `availableTools` before this point).
    static func shouldConstrain(remote: Bool, engineKind: String, toolCount: Int) -> Bool {
        !remote && engineKind == "bundled" && toolCount > 0
    }

    /// The `response_format` value for a tools-carrying turn, built from the
    /// SAME OpenAI definitions the engine receives (nil when none survive).
    /// Per-tool branches carry each tool's own parameters schema verbatim,
    /// so the grammar enforces argument shapes, not just JSON syntax; a
    /// tool with no (or an empty) parameters schema gets a bare object.
    static func responseFormat(definitions: [[String: Any]]) -> [String: Any]? {
        var branches: [[String: Any]] = []
        for definition in definitions {
            let function = definition["function"] as? [String: Any] ?? definition
            guard let name = function["name"] as? String, !name.isEmpty else { continue }
            let arguments = (function["parameters"] as? [String: Any])
                .flatMap { $0.isEmpty ? nil : $0 } ?? ["type": "object"]
            branches.append([
                "type": "object",
                "properties": [
                    "name": ["const": name],
                    "arguments": arguments,
                ],
                "required": ["name", "arguments"],
            ])
        }
        guard !branches.isEmpty else { return nil }
        branches.append([
            "type": "object",
            "properties": ["reply": ["type": "string"]],
            "required": ["reply"],
        ])
        return [
            "type": "json_schema",
            "json_schema": [
                "name": "kestrelToolTurn",
                "strict": false,
                "schema": ["oneOf": branches],
            ],
        ]
    }

    /// Unwraps a completed turn's visible text. Under the bound grammar the
    /// whole visible answer is one envelope object: a `name` naming an
    /// offered tool becomes a pending call (arguments re-serialized); a
    /// `reply` becomes the displayed answer. Returns nil for anything
    /// else — plain prose is the EXPECTED shape for named-family templates
    /// whose own grammar wins over the schema, and the caller displays it
    /// untouched rather than inventing a call.
    static func unwrap(text: String, toolNames: Set<String>) -> Outcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let name = object["name"] as? String, toolNames.contains(name) {
            let arguments = (object["arguments"] as? [String: Any]) ?? [:]
            guard let argumentsData = try? JSONSerialization.data(withJSONObject: arguments)
            else { return nil }
            return .calls([ChatToolCall(serverID: nil, name: name,
                                        arguments: String(decoding: argumentsData, as: UTF8.self))])
        }
        if let reply = object["reply"] as? String {
            return .reply(reply)
        }
        return nil
    }
}
