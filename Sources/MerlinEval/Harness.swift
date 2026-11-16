// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The harness loop: seed → run → score. One task, one fresh workspace, one
/// driver, the protocol of TASKS.md §2:
///
/// • a turn is ONE driver completion yielding up to 4 tool calls;
/// • the executor runs the batch in order, `task_done` mid-batch ends the
///   run immediately and drops the rest of the batch (AMENDMENT 2);
/// • the budget counts completions; the run ends on `task_done` (voluntary)
///   or when the budget is consumed without it;
/// • a driver that returns fewer turns than the budget simply ends its
///   side of the conversation — recorded as budget-exhausted (the
///   completion contract was never filed).
enum EvalHarness {
    /// Maximum calls per turn (TASKS.md §2: "up to 4").
    static let maxCallsPerTurn = 4

    /// Runs `task` end-to-end and returns its score.
    static func run(task: TaskSpec, runRoot: URL,
                    driver: any EvalTurnDriver,
                    machinery: MachineryMode) async throws -> TaskScore {
        // Seed a fresh sandbox; hashes captured at boot.
        let workspace = try EvalWorkspace.seed(task: task, runRoot: runRoot)
        let executor = EvalToolExecutor(workspace: workspace)
        var transcript = EvalTranscript(taskPrompt: task.prompt)

        let wallClock = WallClock(start: Date())
        var turn = 0
        var completedVoluntarily = false

        while turn < task.maxTurns {
            turn += 1
            transcript.beginTurn(turn)

            let batch: [EvalToolCall]
            do {
                batch = try await driver.toolCalls(prompt: task.prompt, turn: turn,
                                                   events: transcript.recentEvents(limit: 20))
            } catch {
                transcript.annotateDriver("driver failed: \(error)")
                break
            }

            if batch.isEmpty {
                transcript.annotateDriver("driver returned an empty batch; turn consumed")
                // A quiet driver is a stalled conversation: end the run.
                break
            }

            // Out-of-contract batches are clamped, never trusted.
            let calls = Array(batch.prefix(maxCallsPerTurn))
            if batch.count > calls.count {
                transcript.annotateDriver("driver returned \(batch.count) calls; kept the first \(calls.count) (protocol max 4 per turn)")
            }

            for call in calls {
                let event = executor.execute(call, turn: turn)
                transcript.record(event)
                if executor.isCompleted {
                    break // task_done ends the run now; remaining calls dropped
                }
            }
            if executor.isCompleted {
                completedVoluntarily = true
                break
            }
        }

        let budgetExhausted = !completedVoluntarily
        return ScoringEngine.score(task: task,
                                   workspace: workspace,
                                   transcript: transcript,
                                   turnsUsed: turn,
                                   budgetExhausted: budgetExhausted,
                                   voluntaryStop: completedVoluntarily,
                                   repairCount: 0,
                                   wallClockS: wallClock.elapsed)
    }

    /// Monotonic wall-clock helper: first completion start → run end.
    struct WallClock {
        let start: Date
        var elapsed: Double { Date().timeIntervalSince(start) }
    }
}

// MARK: - Machinery mode (SCORING.md §7)

/// The one variable the suite is run twice per model: machinery on (the
/// Merlin kernel) or off (the naive baseline). Everything else — sandbox,
/// seeds, assertions, scoring — is byte-identical between the two modes.
enum MachineryMode: String, Sendable {
    case merlin
    case baseline

    var label: String { rawValue }
}
