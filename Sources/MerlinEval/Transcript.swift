// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One tool call as the driver emits it. Mirrors the kernel's
/// `MerlinToolCall` (name + raw JSON arguments object) so a later
/// llama-server driver can adapt to the real MerlinActor unchanged.
struct EvalToolCall: Sendable, Equatable {
    let name: String
    /// The arguments object serialized (canonical key order, compact).
    let argumentsJSON: String

    init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// Convenience for script authors: build from a decoded dictionary and
    /// canonicalize immediately, so `Equatable` compares semantics.
    init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.argumentsJSON = JSONValue.object(arguments).serialized()
    }

    /// Decoded arguments; nil when the call was malformed (a parse error is
    /// itself recorded as a tool error by the executor).
    var decodedArguments: [String: JSONValue]? {
        (try? JSONParser.parse(argumentsJSON)).flatMap { value in
            guard case .object(let object) = value else { return nil }
            return object
        }
    }
}

/// One executed call and what came back — the unit the metrics read from.
struct ToolEvent: Sendable {
    let turn: Int
    let call: EvalToolCall
    /// "ok" or the error class ("not_found", "timeout", …).
    let errorClass: String?
    /// The model-facing text (full — the baseline echoes everything).
    let resultText: String

    var isError: Bool { errorClass != nil }
}

/// Error classifier for tool outcomes: the coarse bucket repeat-failure
/// detection compares on (SCORING.md §3 — same tool, same normalized args,
/// same error class, ≥2 times).
enum ToolErrorClass {
    static func classify(tool: String, message: String) -> String {
        let lowered = message.lowercased()
        switch tool {
        case "fs_read", "fs_list", "fs_grep":
            if lowered.contains("no such") || lowered.contains("missing") || lowered.contains("not found") || lowered.contains("no file") {
                return "not_found"
            }
        case "shell_run", "command_ok":
            if lowered.contains("timed out") || lowered.contains("timeout") { return "timeout" }
            return "nonzero_exit"
        case "js_eval":
            if lowered.contains("not supported") { return "unsupported" }
        case "task_done":
            return "contract"
        default:
            break
        }
        if lowered.contains("escape") || lowered.contains("confine") || lowered.contains("workspace-relative") {
            return "sandbox"
        }
        if lowered.contains("missing") || lowered.contains("invalid") || lowered.contains("must be") {
            return "bad_args"
        }
        return "other"
    }
}

/// Canonicalizes a decoded arguments object for repeat-failure comparison:
/// parsed JSON, keys sorted, compact — so `{"path":"a.txt"}` and
/// `{ "path": "a.txt" }` (whitespace) compare identical while genuinely
/// different arguments do not. Falls back to the raw string when the
/// arguments were never valid JSON.
func normalizedArgumentsJSON(_ argumentsJSON: String) -> String {
    if let parsed = try? JSONParser.parse(argumentsJSON) {
        return parsed.serialized()
    }
    return argumentsJSON
}

func normalizedArguments(_ call: EvalToolCall) -> String {
    normalizedArgumentsJSON(call.argumentsJSON)
}

/// Append-only run transcript, the harness's record of everything the
/// driver said and everything the sandbox answered.
struct EvalTranscript {
    /// The task prompt as delivered to the driver (turn 1).
    let taskPrompt: String
    private(set) var turns: [TranscriptTurn] = []

    mutating func beginTurn(_ turn: Int) {
        turns.append(TranscriptTurn(turn: turn, events: [], driverNote: nil))
    }

    mutating func record(_ event: ToolEvent) {
        turns[turns.count - 1].events.append(event)
    }

    mutating func annotateDriver(_ note: String) {
        turns[turns.count - 1].driverNote = note
    }

    /// The last `limit` events, in order — the context a stateful driver
    /// (like NaiveBaselineDriver's transcript-stuffing loop) re-reads.
    func recentEvents(limit: Int = 20) -> [ToolEvent] {
        Array(turns.flatMap(\.events).suffix(limit))
    }

    var allEvents: [ToolEvent] { turns.flatMap(\.events) }
}

/// One driver completion (a "turn" per TASKS.md §2) and its calls.
struct TranscriptTurn: Sendable {
    let turn: Int
    var events: [ToolEvent]
    /// Driver-side annotation ("returned 5 calls; executor kept the first 4").
    var driverNote: String?
}
