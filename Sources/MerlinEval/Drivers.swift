// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The turn-driver seam (harness twin of the kernel's `MerlinActor`).
///
/// TASKS.md §2 defines a turn as ONE model completion yielding up to 4 tool
/// calls. The kernel's landed seam already has this shape:
/// `MerlinActor.toolCalls(prompt:turn:) async throws -> [MerlinToolCall]`
/// (Sources/Merlin/MerlinKernel.swift, AMENDMENT 2 landed). This protocol
/// mirrors it with harness-owned types so the eval CLI does not import the
/// kernel module into its driver contract; a later dispatch wires a
/// LlamaServerDriver onto the real `MerlinActor` behind this seam.
protocol EvalTurnDriver: Sendable {
    /// Produce the tool-call batch for `turn` (a "model completion").
    /// `prompt` is the task prompt (turn 1) or a follow-up prompt built from
    /// the transcript so far; `events` is the transcript-so-far (raw tool
    /// results included, per the baseline contract). Throwing ends the run
    /// as a driver failure.
    func toolCalls(prompt: String, turn: Int, events: [ToolEvent]) async throws -> [EvalToolCall]
}

// MARK: - ScriptedDriver

/// Replays a JSON file of predetermined tool calls (deterministic harness
/// self-tests). Script format (see eval/scripts/*.json):
///
///     {
///       "task": "T01",
///       "turns": [ [ {call}, {call} ], [ {call} ] ],
///       "notes": [ "why the script looks like this", ... ]
///     }
///
/// A call is `{"tool": "fs_read", "args": {...}}`. A turn is an array of
/// 1–4 calls. When the script's turns run out before `task_done` or the
/// budget, the script is a budget-thrash by construction — the harness
/// records budget exhaustion and the task fails per the completion
/// contract. `turn` counts model completions, so script turn N is batch N.
struct ScriptedDriver: EvalTurnDriver {
    struct Script {
        let taskID: String?
        let turns: [[EvalToolCall]]
        let notes: [String]
    }

    let script: Script

    static func load(path: String) throws -> Script {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw EvalFatalError(message: "cannot read script \(path): \(error)")
        }
        let root: [String: JSONValue]
        do {
            root = try JSONParser.parseObject(text)
        } catch {
            throw EvalFatalError(message: "script \(path): \(error)")
        }
        guard case .array(let rawTurns) = root["turns"], !rawTurns.isEmpty else {
            throw EvalFatalError(message: "script \(path): \"turns\" must be a non-empty array of turns")
        }
        var turns: [[EvalToolCall]] = []
        for (turnIndex, rawTurn) in rawTurns.enumerated() {
            guard case .object(let turnObject) = rawTurn, case .array(let rawCalls) = turnObject["calls"], !rawCalls.isEmpty else {
                throw EvalFatalError(message: "script \(path): turns[\(turnIndex)] must be an object with a non-empty \"calls\" array")
            }
            var calls: [EvalToolCall] = []
            for (callIndex, rawCall) in rawCalls.enumerated() {
                guard case .object(let callObject) = rawCall,
                      case .string(let tool) = callObject["tool"], !tool.isEmpty else {
                    throw EvalFatalError(message: "script \(path): turns[\(turnIndex)].calls[\(callIndex)] must be an object with a string \"tool\"")
                }
                let args = callObject["args"] ?? .object([:])
                guard case .object(let argObject) = args else {
                    throw EvalFatalError(message: "script \(path): turns[\(turnIndex)].calls[\(callIndex)].args must be an object")
                }
                calls.append(EvalToolCall(name: tool, arguments: argObject))
            }
            if calls.count > 4 {
                throw EvalFatalError(message: "script \(path): turns[\(turnIndex)] has \(calls.count) calls; the protocol allows at most 4 per turn (TASKS.md §2)")
            }
            turns.append(calls)
        }
        var notes: [String] = []
        if case .array(let rawNotes) = root["notes"] {
            for note in rawNotes {
                if case .string(let text) = note { notes.append(text) }
            }
        }
        let taskID: String?
        if case .string(let declared) = root["task"] { taskID = declared }
        else { taskID = nil }
        return Script(taskID: taskID, turns: turns, notes: notes)
    }

    func toolCalls(prompt: String, turn: Int, events: [ToolEvent]) async throws -> [EvalToolCall] {
        // Turn numbers are 1-based; a script shorter than the budget simply
        // ends the conversation (the harness treats that as budget-end).
        guard (1...script.turns.count).contains(turn) else { return [] }
        return script.turns[turn - 1]
    }
}

// MARK: - NaiveBaselineDriver (skeleton)

/// Single-prompt naive-loop behavior, per SCORING.md §7's baseline table:
/// all Merlin machinery off — no spine, no digest, no ledger, no guardian,
/// no retry budgets. This skeleton owns the *shape* (one stock prompt, raw
/// transcript stuffing, stop only on an explicit DONE marker or the turn
/// budget); the actual completion call is the extension point.
///
/// EXTENSION POINT (later dispatch): wire `completion` to a llama-server
/// completion with the stock chat template and lenient tool-JSON parsing.
/// The harness scores it identically to the Merlin path; there is no second
/// scoring code path to drift (SCORING.md §7).
struct NaiveBaselineDriver: EvalTurnDriver {
    struct NaiveLoopContext: Sendable {
        let turn: Int
        /// The task prompt, verbatim, on every turn — a naive loop has no
        /// spine to re-state anything beyond what it stuffed itself.
        let prompt: String
        /// The full raw tool-result transcript so far (no summaries).
        let events: [ToolEvent]
        /// Turn budget from the task spec (the hard stop).
        let maxTurns: Int
        /// The stock system prompt (chat template + tools block only).
        let systemPrompt: String
        /// Set by the completion hook when it had to spend its one parse
        /// repair retry (SCORING.md §7 fairness rule 2).
        var usedParseRepairRetry = false
    }

    /// Performs one model completion from the context and returns the batch
    /// (1...4 calls). The llama-server wiring replaces this closure.
    typealias Completion = @Sendable (NaiveLoopContext) async throws -> [EvalToolCall]

    let maxTurns: Int
    let completion: Completion?

    init(maxTurns: Int, completion: Completion?) {
        self.maxTurns = maxTurns
        self.completion = completion
    }

    /// The stock one-shot system prompt (chat template + tools block only —
    /// no spine, no digest, per SCORING.md §7 M8-off row).
    static func stockSystemPrompt(for prompt: String, maxTurns: Int) -> String {
        let tools = EvalSuite.toolSurface.map { "- \($0)" }.joined(separator: "\n")
        return """
        You are an agent working in a sandboxed workspace. Complete the task using the tools.
        Task:
        \(prompt)

        Tools:
        \(tools)

        Rules: up to 4 tool calls per reply. When the task is complete, call task_done.
        If you cannot finish, call task_done with a BLOCKED summary. Budget: \(maxTurns) turns.
        """
    }

    func toolCalls(prompt: String, turn: Int, events: [ToolEvent]) async throws -> [EvalToolCall] {
        guard let completion else {
            throw EvalFatalError(message: "NaiveBaselineDriver has no completion hook wired; the llama-server driver is a later dispatch (SCORING.md §7 defines the behavior this skeleton implements)")
        }
        let context = NaiveLoopContext(turn: turn, prompt: prompt, events: events,
                                       maxTurns: maxTurns,
                                       systemPrompt: Self.stockSystemPrompt(for: prompt, maxTurns: maxTurns))
        return try await completion(context)
    }
}
