// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One evaluated assertion: green/red plus the evidence line that decided it
/// (embedded in report.json so a red is diagnosable without re-running).
struct AssertionOutcome: Sendable {
    let index: Int
    /// Human-readable restatement of the predicate ("file_exists answer.txt").
    let description: String
    let passed: Bool
    /// What was actually observed, when the assertion is red (nil on green —
    /// no noise in passing evidence).
    let detail: String?

    static func green(_ index: Int, _ description: String) -> AssertionOutcome {
        AssertionOutcome(index: index, description: description, passed: true, detail: nil)
    }
    static func red(_ index: Int, _ description: String, _ detail: String) -> AssertionOutcome {
        AssertionOutcome(index: index, description: description, passed: false, detail: detail)
    }
}

/// The grading engine: exactly the five kinds of TASKS.md §3, evaluated
/// against the workspace **after** the run ends (SCORING.md §2: assertions
/// never influence the agent's context).
///
/// Everything except `command_ok`/`grep_count` is a pure function of the
/// workspace bytes; those two run processes by definition — `command_ok`
/// through `/bin/sh -c`, `grep_count` through `/usr/bin/grep -E -c` so the
/// count is POSIX-ERE by the same binary the spec names, under the fixed
/// sandbox environment.
enum AssertionEngine {
    static let commandTimeout: TimeInterval = 10

    /// Evaluates every assertion of `task` against `workspace` in order.
    static func evaluate(task: TaskSpec, workspace: EvalWorkspace) -> [AssertionOutcome] {
        task.assertions.enumerated().map { index, spec in
            evaluateOne(spec, index: index, workspace: workspace)
        }
    }

    static func describe(_ spec: AssertionSpec) -> String {
        switch spec {
        case .fileExists(let path, let negated):
            return negated ? "file_exists \(path) (negated: must be absent)" : "file_exists \(path)"
        case .fileContains(let path, let values, let inOrder, let ci):
            let list = values.map { "\($0.debugDescription)" }.joined(separator: ", ")
            var text = "file_contains \(path) values[\(list)]"
            if inOrder { text += " in_order" }
            if ci { text += " ci" }
            return text
        case .commandOK(let command):
            return "command_ok \(command.debugDescription)"
        case .jsonField(let path, let field, let expected, _):
            return "json_field \(path) \(field) == \(expected.serialized())"
        case .grepCount(let path, let pattern, let gte, let lte):
            return "grep_count \(path) /\(pattern)/ [\(gte.map(String.init) ?? "0"), \(lte.map(String.init) ?? "∞")]"
        }
    }

    private static func evaluateOne(_ spec: AssertionSpec, index: Int, workspace: EvalWorkspace) -> AssertionOutcome {
        switch spec {
        case .fileExists(let path, let negated):
            return fileExists(path: path, negated: negated, index: index, workspace: workspace)
        case .fileContains(let path, let values, let inOrder, let ci):
            return fileContains(path: path, values: values, inOrder: inOrder,
                                caseInsensitive: ci, index: index, workspace: workspace)
        case .commandOK(let command):
            return commandOK(command: command, index: index, workspace: workspace)
        case .jsonField(let path, let field, let expected, let tolerance):
            return jsonField(path: path, field: field, expected: expected,
                             tolerance: tolerance, index: index, workspace: workspace)
        case .grepCount(let path, let pattern, let gte, let lte):
            return grepCount(path: path, pattern: pattern, countGte: gte, countLte: lte,
                             index: index, workspace: workspace)
        }
    }

    // MARK: - file_exists

    private static func fileExists(path: String, negated: Bool, index: Int, workspace: EvalWorkspace) -> AssertionOutcome {
        let url: URL
        do {
            url = try workspace.resolve(path)
        } catch {
            // An unresolvable path cannot hold a file: green only when the
            // assertion demands absence.
            return negated ? .green(index, describe(.fileExists(path: path, negated: true)))
                           : .red(index, describe(.fileExists(path: path, negated: false)),
                                  "path is not usable inside the workspace (\(error))")
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        // A directory at the path does not count as "file present".
        let present = exists && !isDirectory.boolValue
        if negated {
            return present
                ? .red(index, describe(.fileExists(path: path, negated: true)), "file exists but must be absent")
                : .green(index, describe(.fileExists(path: path, negated: true)))
        }
        return present
            ? .green(index, describe(.fileExists(path: path, negated: false)))
            : .red(index, describe(.fileExists(path: path, negated: false)),
                   exists ? "a directory exists at this path, not a file" : "no file at \(path)")
    }

    // MARK: - file_contains

    private static func fileContains(path: String, values: [String], inOrder: Bool,
                                     caseInsensitive: Bool, index: Int, workspace: EvalWorkspace) -> AssertionOutcome {
        let description = describe(.fileContains(path: path, values: values, inOrder: inOrder, caseInsensitive: caseInsensitive))
        guard let content = readWorkspaceFile(path: path, workspace: workspace) else {
            return .red(index, description, "file missing or unreadable: \(path)")
        }
        let haystack = caseInsensitive ? content.lowercased() : content

        if !inOrder {
            for value in values {
                let needle = caseInsensitive ? value.lowercased() : value
                if !haystack.contains(needle) {
                    return .red(index, description, "missing substring \(value.debugDescription) in \(path)")
                }
            }
            return .green(index, description)
        }

        // in_order: every value present, first occurrence strictly ascending.
        var firstOccurrences: [(value: String, offset: Int)] = []
        for value in values {
            let needle = caseInsensitive ? value.lowercased() : value
            guard let range = haystack.range(of: needle) else {
                return .red(index, description, "missing substring \(value.debugDescription) in \(path)")
            }
            firstOccurrences.append((value, haystack.distance(from: haystack.startIndex, to: range.lowerBound)))
        }
        for (previous, next) in zip(firstOccurrences, firstOccurrences.dropFirst()) where previous.offset >= next.offset {
            let order = firstOccurrences.map { "\($0.value)@\($0.offset)" }.joined(separator: " < ")
            return .red(index, description, "first-occurrence order violated (\(order))")
        }
        return .green(index, description)
    }

    // MARK: - command_ok

    private static func commandOK(command: String, index: Int, workspace: EvalWorkspace) -> AssertionOutcome {
        let description = describe(.commandOK(command: command))
        let outcome = EvalShell.run(command: command, cwd: workspace.rootPath,
                                    timeout: commandTimeout)
        if outcome.timedOut {
            return .red(index, description, "timed out after \(Int(commandTimeout))s")
        }
        guard outcome.exitCode == 0 else {
            let tail = EvalShell.modelFacingText(outcome, limit: 400)
            return .red(index, description, "exit \(outcome.exitCode.map(String.init) ?? "signal"): \(tail)")
        }
        return .green(index, description)
    }

    // MARK: - json_field

    private static func jsonField(path: String, field: String, expected: JSONValue,
                                  tolerance: Double, index: Int, workspace: EvalWorkspace) -> AssertionOutcome {
        let description = describe(.jsonField(path: path, field: field, expected: expected, tolerance: tolerance))
        guard let text = readWorkspaceFile(path: path, workspace: workspace) else {
            return .red(index, description, "file missing or unreadable: \(path)")
        }
        let root: JSONValue
        do {
            root = try JSONParser.parse(text)
        } catch {
            return .red(index, description, "not strict JSON: \(error)")
        }
        guard let actual = root.value(atPath: field) else {
            return .red(index, description, "dot-path \"\(field)\" not found in \(path)")
        }
        if actual.matches(expected, tolerance: tolerance) {
            return .green(index, description)
        }
        return .red(index, description,
                    "field \(field) is \(actual.serialized()), expected \(expected.serialized()) (tolerance \(tolerance))")
    }

    // MARK: - grep_count

    private static func grepCount(path: String, pattern: String, countGte: Int?, countLte: Int?,
                                  index: Int, workspace: EvalWorkspace) -> AssertionOutcome {
        let description = describe(.grepCount(path: path, pattern: pattern, countGte: countGte, countLte: countLte))
        let url: URL
        do {
            url = try workspace.resolve(path)
        } catch {
            return .red(index, description, "bad path: \(error)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .red(index, description, "no file at \(path)")
        }
        // grep exit codes: 0 = matches found, 1 = none (count 0), 2 = error.
        // `-c` counts matching LINES, per the spec's `grep -E` semantics.
        let outcome = EvalShell.run(command: "/usr/bin/grep -E -c -- \(Self.shellQuoted(pattern)) \(Self.shellQuoted(url.path))",
                                    cwd: workspace.rootPath, timeout: commandTimeout)
        if outcome.timedOut {
            return .red(index, description, "grep timed out")
        }
        guard outcome.exitCode == 0 || outcome.exitCode == 1 else {
            return .red(index, description,
                        "grep failed (exit \(outcome.exitCode.map(String.init) ?? "?")): \(outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let count = outcome.exitCode == 1 ? 0 : (Int(outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        if let gte = countGte, count < gte {
            return .red(index, description, "matched \(count) line(s), required ≥ \(gte)")
        }
        if let lte = countLte, count > lte {
            return .red(index, description, "matched \(count) line(s), allowed ≤ \(lte)")
        }
        return .green(index, description)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Shared

    /// Reads a UTF-8 text file confined to the workspace; nil when missing,
    /// unreadable, or not valid UTF-8 (the suite is text-only by contract).
    private static func readWorkspaceFile(path: String, workspace: EvalWorkspace) -> String? {
        guard let url = try? workspace.resolve(path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
