// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "llama.cpp returned an invalid tools response."
        case let .server(status, message):
            return "HTTP \(status): \(message)"
        }
    }
}

enum ChatToolsService {
    static let builtInNames = [
        "read_file", "edit_file", "write_file", "get_datetime",
        "file_glob_search", "grep_search", "exec_shell_command", "run_javascript"
    ]

    static func isAlwaysAllowed(_ name: String) -> Bool {
        UserDefaults.standard.bool(forKey: permissionKey(name))
    }

    static func allowAlways(_ name: String) {
        UserDefaults.standard.set(true, forKey: permissionKey(name))
    }

    static func revokeAllPermissions() {
        let defaults = UserDefaults.standard
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
        return rows.compactMap(BuiltinToolInfo.init(json:))
    }

    static func execute(name: String, arguments: [String: Any], port: Int,
                        workingDirectory: String? = nil) async throws -> ToolExecutionResult {
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
            guard line.hasPrefix("data: "),
                  let data = String(line.dropFirst(6)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
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

    /// Small models emit tool arguments with BOMs, ```json fences, trailing
    /// commas, or single quotes. Tolerate all of it before giving up: an
    /// unusable arguments blob costs the whole turn.
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
        // An arguments blob that is only whitespace (or only a comment) means
        // "no arguments" for every builtin tool; throwing here would kill the
        // turn for tools like get_datetime.
        if strippedOfStrings(text).allSatisfy({ $0.isWhitespace }) { return [:] }
        throw ChatToolsError.invalidResponse
    }

    /// Removes trailing commas outside string literals and normalizes
    /// single-quoted keys/values to double quotes. Returns nil when no repair
    /// produces parseable JSON, so the caller falls through to its error path.
    static func repairedJSONObject(from text: String) -> String? {
        // No `?? [:]` here: coalescing an unrepairable blob into an empty
        // object would turn every invalid arguments payload into "no
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
    /// blow the KV budget. The marker tells the model more existed.
    static let toolResultContextLimit = 12_000

    static func clampedToolResult(_ result: String) -> String {
        guard result.count > toolResultContextLimit else { return result }
        let head = String(result.prefix(toolResultContextLimit))
        return head + "\n\n[truncated — output exceeded \(toolResultContextLimit) characters; narrow the query or read the file in sections]"
    }
    private static func authorize(_ request: inout URLRequest) {
        if let key = ServerSettings.activeAPIKey() {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }

    private static func permissionKey(_ name: String) -> String {
        "toolPermission.always.builtin.\(name)"
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

/// Small distilled models frequently emit tool calls as plain text — a fenced
/// `{"name": ..., "arguments": ...}` blob or a `<tool_call>{...}</tool_call>`
/// tag — instead of using the engine's function-calling channel. The engine
/// then answers "I used the tool" while nothing ran. This rescues that text
/// into real pending tool calls, capped low so a rambling model cannot fire a
/// dozen of them in one turn.

enum ToolCallRescue {
    static let maxPerTurn = 3

    static func rescuedCalls(text: String, toolNames: Set<String>) -> [ChatToolCall] {
        guard !text.isEmpty else { return [] }
        var calls: [ChatToolCall] = []
        for blob in candidateBlobs(in: text) {
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
            guard let argumentsData = try? JSONSerialization.data(withJSONObject: arguments)
            else { continue }
            calls.append(ChatToolCall(serverID: nil, name: rawName,
                                      arguments: String(decoding: argumentsData, as: UTF8.self)))
        }
        return calls
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