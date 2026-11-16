// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The task spine (M0): the deterministic part of every turn's context.
///
/// Small models lose the plot mid-task; the spine counters that by
/// rebuilding the fixed frame on every turn — goal, plan sketch, the state
/// digest, and the tool contract — so no turn ever starts from amnesia.
/// This type is pure Swift with no I/O: the kernel owns the turn counter and
/// the ledger, and asks the spine for the prompt pieces.
public struct MerlinTaskSpine: Sendable {
    public let goal: String
    /// Short plan sketch, one bullet per line, written once at run start.
    /// The spine re-injects it verbatim; the model may revise it through
    /// `note_add`, and the kernel swaps in the revised sketch.
    public var planSketch: [String]
    /// Hard ceiling on tool turns for this run.
    public let maxTurns: Int
    /// Tool calls the actor may pack into one turn (eval protocol: a turn is
    /// one model completion with 1...4 calls).
    public let maxCallsPerTurn: Int

    public init(goal: String, planSketch: [String] = [], maxTurns: Int, maxCallsPerTurn: Int = 4) {
        self.goal = goal
        self.planSketch = planSketch
        self.maxTurns = maxTurns
        self.maxCallsPerTurn = maxCallsPerTurn
    }

    public enum StopReason: String, Sendable {
        /// The model filed the completion contract (`task_done`).
        case taskDone
        /// The turn budget ran out before the model finished.
        case budgetExhausted
        /// An unrecoverable kernel error ended the run.
        case kernelError
    }

    /// The per-turn system prompt spine: fixed frame, then state, then the
    /// contract reminder. Order matters — identity, plan, state, rules — so
    /// the model reads the frame before the state and the rules last.
    public func systemPrompt(turn: Int, digest: String) -> String {
        let maxTurn = max(0, maxTurns - turn)
        var lines: [String] = []
        lines.append("You are Merlin, a task agent. Work only inside your task workspace.")
        lines.append("")
        lines.append("GOAL: \(goal)")
        if !planSketch.isEmpty {
            lines.append("PLAN:")
            for step in planSketch {
                lines.append("- \(step)")
            }
        }
        lines.append("")
        lines.append("STATE (re-injected every turn; trust this over your memory):")
        lines.append(digest)
        lines.append("")
        lines.append("TOOL CONTRACT:")
        lines.append("- Up to \(maxCallsPerTurn) tool calls per turn, executed in order; one batch per turn.")
        let remain = maxTurn == 1 ? "1 turn remains" : "\(maxTurn) turns remain"
        lines.append("- Turn \(turn) of \(maxTurns); \(remain).")
        lines.append("- Keep results out of your replies; the ledger remembers for you.")
        lines.append("- Record finished work as an artifact, then call task_done with a summary citing the artifact paths.")
        if maxTurn == 0 {
            lines.append("- This is your final turn: call task_done now with what you have.")
        }
        return lines.joined(separator: "\n")
    }
}
