// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Per-task run outcome: everything SCORING.md §1-§3 requires, in one
/// struct. Field names in report.json use the snake_case spellings of §3.
struct TaskScore: Sendable {
    let taskID: String
    let axis: String
    let tier: Int
    let passed: Bool
    let budgetExhausted: Bool
    let seedDrift: Bool
    let voluntaryStop: Bool
    let turnsUsed: Int
    let turnsBudget: Int
    let wallClockS: Double
    let toolCalls: Int
    let toolErrors: Int
    let recoveryEvents: Int
    let repeatFailures: Int
    let repairCount: Int
    let assertionOutcomes: [AssertionOutcome]
    let seedVerdicts: [EvalWorkspace.SeedVerdict]
    /// Immutable-seed SHA-256 hashes captured at workspace boot — the
    /// provenance evidence report.json embeds (SCORING.md §8). Read at boot,
    /// never re-read at report time, so a drifted file cannot masquerade as
    /// its own boot hash.
    let bootHashes: [String: String]
    /// nil when the run completed via `task_done`; otherwise why it ended.
    let endReason: String?
    /// Human-readable failure chain, ordered drift > budget > assertions.
    let failReasons: [String]
    /// Workspace path, for report provenance.
    let workspacePath: String
}

/// The mechanical scorer (SCORING.md §1-§3).
///
/// Pass gate (§1): all assertions green AND the run finished within budget
/// AND no seed drift. Two overriding rules: immutable-seed drift fails the
/// task outright regardless of assertions, and the completion contract
/// requires the run to end via `task_done` (budget-forced wrap-up is
/// recorded and, under a `stop_authority_rule`, hard-fails).
enum ScoringEngine {
    /// A "different approach" window (§3): a tool error at turn T counts as
    /// recovered when a differently-signatured call occurs at T+1 or T+2.
    static let recoveryWindow = 2

    /// Scores one finished run.
    static func score(task: TaskSpec,
                      workspace: EvalWorkspace,
                      transcript: EvalTranscript,
                      turnsUsed: Int,
                      budgetExhausted: Bool,
                      voluntaryStop: Bool,
                      repairCount: Int,
                      wallClockS: Double) -> TaskScore {
        let events = transcript.allEvents

        // 1. Immutable seeds re-verified at scoring (§1 overriding rule 1).
        let seedVerdicts = workspace.verifySeeds()
        let seedDrift = seedVerdicts.contains { $0 != .intact }

        // 2. Mechanical assertions, evaluated after the run (§2).
        let assertionOutcomes = AssertionEngine.evaluate(task: task, workspace: workspace)
        let redAssertions = assertionOutcomes.filter { !$0.passed }
        let assertionsGreen = redAssertions.isEmpty

        // 3. Metrics from the tool trace (§3).
        let toolErrorEvents = events.filter(\.isError)
        let recoveryEvents = Self.recoveryEvents(events: events, window: Self.recoveryWindow)
        let repeatFailures = Self.repeatFailures(events: events)

        // 4. Failure synthesis, drift > budget > assertions.
        var failReasons: [String] = []
        if seedDrift {
            let detail = seedVerdicts.compactMap(\.failureText).joined(separator: "; ")
            failReasons.append("seed_drift (auto-fail per SCORING.md §1): \(detail)")
        }
        if budgetExhausted {
            failReasons.append("budget_exhausted: turn budget (\(task.maxTurns)) reached without task_done — completion contract unmet")
            if task.hasStopAuthorityRule {
                failReasons.append("stop_authority_rule: \(task.stopAuthorityRule ?? "")")
            }
        }
        if !assertionsGreen {
            let detail = redAssertions
                .map { "\($0.description) — \($0.detail ?? "predicate false")" }
                .joined(separator: "; ")
            failReasons.append("assertions \(assertionOutcomes.count - redAssertions.count)/\(assertionOutcomes.count) green: \(detail)")
        }

        return TaskScore(taskID: task.id,
                         axis: task.axis,
                         tier: task.tier,
                         passed: failReasons.isEmpty,
                         budgetExhausted: budgetExhausted,
                         seedDrift: seedDrift,
                         voluntaryStop: voluntaryStop && !budgetExhausted,
                         turnsUsed: turnsUsed,
                         turnsBudget: task.maxTurns,
                         wallClockS: wallClockS,
                         toolCalls: events.count,
                         toolErrors: toolErrorEvents.count,
                         recoveryEvents: recoveryEvents,
                         repeatFailures: repeatFailures,
                         repairCount: repairCount,
                         assertionOutcomes: assertionOutcomes,
                         seedVerdicts: seedVerdicts,
                         bootHashes: workspace.bootHashes,
                         endReason: budgetExhausted ? "budget_exhausted" : (voluntaryStop ? "task_done" : nil),
                         failReasons: failReasons,
                         workspacePath: workspace.rootPath)
    }

    // MARK: - Trace-derived metrics

    /// A call's identity for comparison: tool name + normalized arguments.
    private typealias CallSignature = String

    private static func signature(tool: String, argumentsJSON: String) -> CallSignature {
        "\(tool)|\(normalizedArgumentsJSON(argumentsJSON))"
    }

    /// recovery_events (§3): "a tool error followed, within 2 turns, by a
    /// *different* approach that does not repeat the identical failing call
    /// — counted mechanically from the tool trace."
    ///
    /// Mechanically: for every error event at turn T, a recovery is credited
    /// when some later call at turn ≤ T+2 has a different (tool, args)
    /// signature. The different call need not succeed — the metric observes
    /// adaptation, not correctness; correctness is the assertions' job.
    /// One credit per qualifying error event.
    static func recoveryEvents(events: [ToolEvent], window: Int) -> Int {
        var count = 0
        for (index, error) in events.enumerated() where error.isError {
            let failedSignature = signature(tool: error.call.name, argumentsJSON: error.call.argumentsJSON)
            for follower in events[(index + 1)...] {
                guard follower.turn - error.turn <= window else { break }
                let followerSignature = signature(tool: follower.call.name, argumentsJSON: follower.call.argumentsJSON)
                if followerSignature != failedSignature {
                    count += 1
                    break
                }
            }
        }
        return count
    }

    /// repeat_failures (§3): "identical failing tool call (same tool, same
    /// normalized args, same error class) issued ≥2 times — the loop
    /// signature." Counts DISTINCT signatures exhibiting the pattern, so the
    /// scorecard's `repeat_failures` reads as the number of distinct loops,
    /// not raw repetitions.
    static func repeatFailures(events: [ToolEvent]) -> Int {
        var counts: [CallSignature: Int] = [:]
        for event in events where event.isError {
            let key = signature(tool: event.call.name, argumentsJSON: event.call.argumentsJSON)
                + "|class=\(event.errorClass ?? "?")"
            counts[key, default: 0] += 1
        }
        return counts.values.filter { $0 >= 2 }.count
    }
}

// MARK: - Reporting conveniences

extension TaskScore {
    /// Compact per-task scorecard token: `T01 ✔(2t)` / `T14 ✘(8t,budget)`.
    var scorecardToken: String {
        let mark = passed ? "✔" : "✘"
        var suffix = "\(turnsUsed)t"
        if budgetExhausted { suffix += ",budget" }
        if seedDrift { suffix += ",drift" }
        return "\(taskID) \(mark)(\(suffix))"
    }

    var assertionSummaryJSON: JSONValue {
        .array(assertionOutcomes.map { outcome in
            var object: [String: JSONValue] = [
                "index": .number(Double(outcome.index)),
                "description": .string(outcome.description),
                "passed": .bool(outcome.passed),
            ]
            if let detail = outcome.detail {
                object["detail"] = .string(detail)
            }
            return .object(object)
        })
    }

    var seedVerdictsJSON: JSONValue {
        .array(seedVerdicts.map { verdict in
            switch verdict {
            case .intact:
                return .object(["status": .string("intact")])
            case .drifted(let path, let bootHash, let currentHash):
                return .object(["status": .string("drifted"), "path": .string(path),
                                "boot_sha256": .string(bootHash), "current_sha256": .string(currentHash)])
            case .missing(let path, let bootHash):
                return .object(["status": .string("missing"), "path": .string(path),
                                "boot_sha256": .string(bootHash)])
            }
        })
    }

    var taskJSON: JSONValue {
        .object([
            "id": .string(taskID),
            "axis": .string(axis),
            "tier": .number(Double(tier)),
            "pass": .bool(passed),
            "budget_exhausted": .bool(budgetExhausted),
            "seed_drift": .bool(seedDrift),
            "voluntary_stop": .bool(voluntaryStop),
            "turns_used": .number(Double(turnsUsed)),
            "turns_budget": .number(Double(turnsBudget)),
            "wall_clock_s": .number((wallClockS * 1000).rounded() / 1000),
            "tool_calls": .number(Double(toolCalls)),
            "tool_errors": .number(Double(toolErrors)),
            "recovery_events": .number(Double(recoveryEvents)),
            "repeat_failures": .number(Double(repeatFailures)),
            "repair_count": .number(Double(repairCount)),
            "end_reason": endReason.map { .string($0) } ?? .null,
            "assertions": assertionSummaryJSON,
            "immutable_seeds": seedVerdictsJSON,
            "immutable_seed_boot_hashes": .object(bootHashes.mapValues { .string($0) }),
            "workspace": .string(workspacePath),
            "fail_reasons": .array(failReasons.map { .string($0) }),
        ])
    }
}

extension EvalWorkspace.SeedVerdict {
    /// Human-readable drift/missing description; nil when intact.
    var failureText: String? {
        switch self {
        case .intact:
            return nil
        case .drifted(let path, _, _):
            return "\(path) changed after boot"
        case .missing(let path, _):
            return "\(path) was deleted after boot"
        }
    }
}
