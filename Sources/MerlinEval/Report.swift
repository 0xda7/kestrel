// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Report generation per SCORING.md §4-§5: the fixed-width MODEL SCORECARD
/// block plus the suite-level delta skeleton (merlin vs baseline columns).
/// The same content always exists as JSON (`report.json`) so numbers are
/// diffable across models and machinery modes.
enum ReportGenerator {
    /// One run's identity for the scorecard header.
    struct RunIdentity {
        var modelID: String = "scripted-reference"
        var date: String = Self.today()
        var machinery: MachineryMode = .merlin

        static func today() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: Date())
        }
    }

    // MARK: - MODEL SCORECARD (§4)

    /// Renders the scorecard for one (model × machinery) run.
    static func scorecard(scores: [TaskScore], suite: EvalSuite, identity: RunIdentity) -> String {
        let total = scores.count
        let passes = scores.filter(\.passed).count
        let passRate = Double(passes) / Double(max(1, total)) * 100

        // Axis gates: all tasks on the axis pass (§1); axis pass rate is
        // informational only.
        var axisSegments: [String] = []
        for axis in EvalSuite.axes {
            let axisTasks = scores.filter { $0.axis == axis }
            guard !axisTasks.isEmpty else { continue }
            let allPass = axisTasks.allSatisfy(\.passed)
            axisSegments.append("\(axis) \(allPass ? "✔" : "✘")")
        }

        let sortedTurns = scores.map(\.turnsUsed).sorted()
        let medianTurns = Self.median(sortedTurns) ?? 0
        let sortedWall = scores.map(\.wallClockS).sorted()
        let medianWall = Self.median(sortedWall) ?? 0

        // tool_errors grouped per task (§4 shows "T07:6, T13:9, …").
        let errorGroups = scores
            .filter { $0.toolErrors > 0 }
            .sorted { $0.taskID < $1.taskID }
            .map { "\($0.taskID):\($0.toolErrors)" }
        let totalErrors = scores.reduce(0) { $0 + $1.toolErrors }

        let totalRecovery = scores.reduce(0) { $0 + $1.recoveryEvents }
        let totalRepeats = scores.reduce(0) { $0 + $1.repeatFailures }
        let totalRepairs = scores.reduce(0) { $0 + $1.repairCount }
        let voluntaryStops = scores.filter(\.voluntaryStop).count
        let drifted = scores.filter(\.seedDrift).map(\.taskID)

        var lines: [String] = []
        let rule = String(repeating: "─", count: 76)
        lines.append("MODEL SCORECARD — \(identity.modelID) · suite \(suite.suite) · \(identity.date) · machinery: \(identity.machinery.label)")
        lines.append(rule)
        lines.append("pass_rate        : \(passes)/\(total) (\(String(format: "%.1f", passRate))%)")
        lines.append("axis_gates       : \(axisSegments.joined(separator: "  "))")
        lines.append(String(format: "median_turns     : %.1f   (of budget; per-task turns_used median over all %d runs)", medianTurns, total))
        lines.append("median_wallclock : \(Self.durationText(medianWall))")
        lines.append("tool_errors      : \(totalErrors) total\(errorGroups.isEmpty ? "" : " (" + errorGroups.joined(separator: ", ") + ")")")
        lines.append("recovery_events  : \(totalRecovery)   ·  repeat_failures: \(totalRepeats)")
        lines.append("repair_count     : \(totalRepairs)                    # expected 0 on M1 grammar path")
        lines.append("voluntary_stops  : \(voluntaryStops)/\(total)")
        lines.append("seed_drift       : \(drifted.isEmpty ? "none" : drifted.joined(separator: ", "))")
        lines.append("per-task         : \(scores.map(\.scorecardToken).joined(separator: " "))")
        lines.append(rule)

        // Suite gate (§5): 14/14 tasks pass; ≥1 failing axis = gate red.
        let gateVerdict = (passes == total && passes > 0)
            ? "MERLIN GATE: \(identity.modelID) PASS (suite gate = \(total)/\(total) tasks; all axis gates green)"
            : "MERLIN GATE: \(identity.modelID) FAIL (suite gate = \(total)/\(total) tasks; got \(passes)/\(total); failing axes: \(failingAxes(scores: scores).joined(separator: ", ").isEmpty ? "-" : failingAxes(scores: scores).joined(separator: ", ")))"
        lines.append("verdict          : \(gateVerdict)")
        return lines.joined(separator: "\n")
    }

    private static func failingAxes(scores: [TaskScore]) -> [String] {
        EvalSuite.axes.filter { axis in
            let axisTasks = scores.filter { $0.axis == axis }
            guard !axisTasks.isEmpty else { return false }
            return !axisTasks.allSatisfy(\.passed)
        }
    }

    // MARK: - Delta report skeleton (§5)

    /// One row of the delta table: a (model × machinery) pair's summary.
    struct RunSummary {
        let modelID: String
        let machinery: MachineryMode
        let scores: [TaskScore]

        var passCount: Int { scores.filter(\.passed).count }
        var total: Int { scores.count }
        var passRatePercent: Double { Double(passCount) / Double(max(1, total)) * 100 }
        var axisGateText: String {
            EvalSuite.axes.compactMap { axis -> String? in
                let axisTasks = scores.filter { $0.axis == axis }
                guard !axisTasks.isEmpty else { return nil }
                return "\(axis)\(axisTasks.allSatisfy(\.passed) ? "✔" : "✘")"
            }.joined()
        }
        var medianTurns: Double { ReportGenerator.median(scores.map(\.turnsUsed).sorted()) ?? 0 }
        var medianWallClock: Double { ReportGenerator.median(scores.map(\.wallClockS).sorted()) ?? 0 }
        var recoveries: Int { scores.reduce(0) { $0 + $1.recoveryEvents } }
        var loops: Int { scores.reduce(0) { $0 + $1.repeatFailures } }
    }

    /// The overall report skeleton: per-model rows and the DELTA line that
    /// is the mission claim. Model rows appear once per machinery mode, so
    /// the delta is read straight off adjacent rows.
    static func overallReport(rows: [RunSummary], date: String = RunIdentity.today()) -> String {
        var lines: [String] = []
        lines.append("MERLIN-EVAL REPORT — \(date)")
        let models = orderedUniqueModels(rows: rows)
        lines.append("models: \(models.isEmpty ? "(none)" : models.joined(separator: ", "))")
        lines.append("")
        lines.append("model                 machinery   pass_rate    axes    med_turns  med_time  recoveries  loops")
        for row in rows {
            lines.append(rowLine(row))
        }
        lines.append("")
        lines.append(deltaLine(rows: rows, models: models))
        lines.append("known flaws: (recorded per run in report.json fail_reasons)")
        return lines.joined(separator: "\n")
    }

    private static func orderedUniqueModels(rows: [RunSummary]) -> [String] {
        var seen: Set<String> = []
        var models: [String] = []
        for row in rows where !seen.contains(row.modelID) {
            seen.insert(row.modelID)
            models.append(row.modelID)
        }
        return models
    }

    static func rowLine(_ row: RunSummary) -> String {
        let model = row.modelID.count > 21 ? String(row.modelID.prefix(21)) : row.modelID.padding(toLength: 21, withPad: " ", startingAt: 0)
        let machinery = row.machinery.label.padding(toLength: 9, withPad: " ", startingAt: 0)
        let rate = "\(row.passCount)/\(row.total) (\(Int(row.passRatePercent.rounded()))%)".padding(toLength: 10, withPad: " ", startingAt: 0)
        let axes = row.axisGateText.padding(toLength: 6, withPad: " ", startingAt: 0)
        let turns = String(format: "%.1f", row.medianTurns).padding(toLength: 9, withPad: " ", startingAt: 0)
        let time = Self.durationText(row.medianWallClock).padding(toLength: 9, withPad: " ", startingAt: 0)
        return "\(model) \(machinery)  \(rate)  \(axes)  \(turns)  \(time)  \(String(row.recoveries).padding(toLength: 10, withPad: " ", startingAt: 0))  \(row.loops)"
    }

    /// DELTA (merlin − baseline, per model) — the claim (§5).
    static func deltaLine(rows: [RunSummary], models: [String]) -> String {
        var deltas: [String] = []
        for model in models {
            let merlin = rows.first { $0.modelID == model && $0.machinery == .merlin }
            let baseline = rows.first { $0.modelID == model && $0.machinery == .baseline }
            guard let merlin, let baseline else {
                deltas.append("\(model): (run both machinery modes to compute the delta — anti-rationalization clause, SCORING.md §7)")
                continue
            }
            let rateDelta = merlin.passRatePercent - baseline.passRatePercent
            let turnDelta = merlin.medianTurns - baseline.medianTurns
            let loopDelta = merlin.loops - baseline.loops
            deltas.append("\(model): \(rateDelta >= 0 ? "+" : "")\(String(format: "%.0f", rateDelta))% pass rate, \(turnDelta >= 0 ? "+" : "")\(String(format: "%.1f", turnDelta)) median turns, \(loopDelta >= 0 ? "+" : "")\(loopDelta) loops")
        }
        return "DELTA (merlin − baseline, per model): " + deltas.joined(separator: " · ")
    }

    // MARK: - report.json

    /// Full run record (SCORING.md §8: tasks, assertions, metrics, seed
    /// hashes, model meta). Written into the run root.
    static func reportJSON(suite: EvalSuite, scores: [TaskScore],
                           identity: RunIdentity, runRoot: URL,
                           seedHashes: [String: [String: String]]) -> JSONValue {
        .object([
            "suite": .string(suite.suite),
            "mission": .string(suite.mission),
            "tasks_source": .string(suite.sourcePath),
            "date": .string(identity.date),
            "model": .string(identity.modelID),
            "machinery": .string(identity.machinery.label),
            "run_root": .string(runRoot.path),
            "summary": .object([
                "tasks": .number(Double(scores.count)),
                "passed": .number(Double(scores.filter(\.passed).count)),
                "voluntary_stops": .number(Double(scores.filter(\.voluntaryStop).count)),
                "tool_errors": .number(Double(scores.reduce(0) { $0 + $1.toolErrors })),
                "recovery_events": .number(Double(scores.reduce(0) { $0 + $1.recoveryEvents })),
                "repeat_failures": .number(Double(scores.reduce(0) { $0 + $1.repeatFailures })),
                "seed_drift": .array(scores.filter(\.seedDrift).map { .string($0.taskID) }),
            ]),
            "immutable_seed_boot_hashes": .object(seedHashes.mapValues { hashes in
                .object(hashes.mapValues { .string($0) })
            }),
            "tasks": .array(scores.map(\.taskJSON)),
        ])
    }

    // MARK: - Shared formatting

    /// Median of an already-sorted numeric list; even counts average the
    /// two middle values. (Values arrive as Int turns or Double seconds;
    /// both convert through Double losslessly for eval-scale magnitudes.)
    static func median<T: BinaryInteger>(_ sorted: [T]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let doubles = sorted.map { Double($0) }
        let middle = doubles.count / 2
        if doubles.count % 2 == 1 {
            return doubles[middle]
        }
        return (doubles[middle - 1] + doubles[middle]) / 2
    }

    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return "\(minutes)m\(String(remainder).padding(toLength: 2, withPad: "0", startingAt: 0))s"
    }
}
