// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A harness run that cannot continue: the suite data is unusable. Per the
/// slice contract the loader fails loudly — a malformed `tasks.json` is
/// schema drift, never a silently-degraded run.
struct EvalFatalError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Assertion vocabulary (TASKS.md §3 — the complete grading language)

/// One grading predicate. The five kinds below are the *entire* vocabulary;
/// anything else in `tasks.json` is schema drift.
enum AssertionSpec: Sendable, Equatable {
    /// `path`, `negated?` — file present; `negated` inverts (must be absent).
    case fileExists(path: String, negated: Bool)
    /// `path` + `value` or `values`, `in_order?`, `ci?` — substring present
    /// (case-insensitive if `ci`); with `in_order` every value appears in
    /// first-occurrence order.
    case fileContains(path: String, values: [String], inOrder: Bool, caseInsensitive: Bool)
    /// `command` — via `/bin/sh -c` from workspace root, exit 0, timeout 10 s.
    case commandOK(command: String)
    /// `path`, `field`, `equals`, `tolerance?` — strict JSON dot-path lookup,
    /// numeric tolerance (default 1e-9), no string↔number coercion.
    case jsonField(path: String, field: String, expected: JSONValue, tolerance: Double)
    /// `path`, `pattern` (POSIX ERE), `count_gte?`, `count_lte?` — matching
    /// *line* count within both bounds.
    case grepCount(path: String, pattern: String, countGte: Int?, countLte: Int?)

    static func decode(_ object: [String: JSONValue], taskID: String, index: Int) throws -> AssertionSpec {
        let where_ = "\(taskID) assertion[\(index)]"
        guard case .string(let kind) = object["kind"] else {
            throw EvalFatalError(message: "\(where_): missing or non-string \"kind\"")
        }
        func stringField(_ name: String) throws -> String {
            guard case .string(let value) = object[name] else {
                throw EvalFatalError(message: "\(where_) (\(kind)): missing or non-string \"\(name)\"")
            }
            return value
        }
        func intField(_ name: String) throws -> Int? {
            guard let raw = object[name] else { return nil }
            guard case .number(let value) = raw, let integer = JSONValue.number(value).intValue else {
                throw EvalFatalError(message: "\(where_) (\(kind)): \"\(name)\" must be an integer")
            }
            return integer
        }
        func boolField(_ name: String) -> Bool {
            if case .bool(true) = object[name] { return true }
            return false
        }
        switch kind {
        case "file_exists":
            return .fileExists(path: try stringField("path"), negated: boolField("negated"))
        case "file_contains":
            let path = try stringField("path")
            let inOrder = boolField("in_order")
            let ci = boolField("ci")
            let values: [String]
            switch object["value"] {
            case .string(let value)?: values = [value]
            default:
                guard case .array(let list) = object["values"], !list.isEmpty else {
                    throw EvalFatalError(message: "\(where_) (file_contains): needs a string \"value\" or a non-empty \"values\" array")
                }
                var decoded: [String] = []
                for item in list {
                    guard case .string(let text) = item else {
                        throw EvalFatalError(message: "\(where_) (file_contains): \"values\" entries must be strings")
                    }
                    decoded.append(text)
                }
                values = decoded
            }
            return .fileContains(path: path, values: values, inOrder: inOrder, caseInsensitive: ci)
        case "command_ok":
            return .commandOK(command: try stringField("command"))
        case "json_field":
            guard case .string(let field) = object["field"] else {
                throw EvalFatalError(message: "\(where_) (json_field): missing \"field\"")
            }
            guard let expected = object["equals"] else {
                throw EvalFatalError(message: "\(where_) (json_field): missing \"equals\"")
            }
            var numericTolerance = 1e-9
            if case .number(let value) = object["tolerance"] {
                numericTolerance = abs(value)
            }
            return .jsonField(path: try stringField("path"), field: field, expected: expected, tolerance: numericTolerance)
        case "grep_count":
            let gte = try intField("count_gte")
            let lte = try intField("count_lte")
            guard gte != nil || lte != nil else {
                throw EvalFatalError(message: "\(where_) (grep_count): at least one of \"count_gte\"/\"count_lte\" is required")
            }
            return .grepCount(path: try stringField("path"), pattern: try stringField("pattern"), countGte: gte, countLte: lte)
        default:
            throw EvalFatalError(message: "\(where_): unknown assertion kind \"\(kind)\" — the grading vocabulary is exactly the five kinds in TASKS.md §3")
        }
    }
}

// MARK: - Seed files and tasks

/// One file laid down in the fresh task workspace before turn 1.
struct SeedFile: Sendable, Equatable {
    /// Workspace-relative path.
    let path: String
    /// Exact literal bytes (UTF-8 text; the suite guarantees static content).
    let content: String
}

/// One eval task, decoded strictly from `tasks.json`.
struct TaskSpec: Sendable {
    let id: String
    let axis: String
    let tier: Int
    let title: String
    /// The verbatim prompt handed to the driver in turn 1.
    let prompt: String
    let seedFiles: [SeedFile]
    /// Files SHA-256-hashed at boot and re-verified at scoring; any drift
    /// fails the task outright (SCORING.md §1).
    let immutableSeeds: [String]
    let assertions: [AssertionSpec]
    let maxTurns: Int
    /// M-systems the task stresses (reporting only).
    let stresses: [String]
    /// Present only on T14: a voluntary `task_done` within budget is part of
    /// the pass condition.
    let stopAuthorityRule: String?

    var hasStopAuthorityRule: Bool { stopAuthorityRule != nil }
}

// MARK: - Suite

/// The decoded `tasks.json` suite.
struct EvalSuite: Sendable {
    static let expectedSuiteName = "merlin-eval-v1"
    /// The exact ten-tool surface (plan.md §3, TASKS.md §2).
    static let toolSurface = [
        "fs_read", "fs_write", "fs_list", "fs_grep", "shell_run",
        "js_eval", "todo_write", "todo_read", "note_add", "task_done",
    ]
    static let axes = ["A", "B", "C", "D", "E"]

    let suite: String
    let mission: String
    let tasks: [TaskSpec]
    /// Raw suite JSON, embedded in report.json provenance.
    let sourcePath: String

    func task(named id: String) -> TaskSpec? {
        tasks.first { $0.id == id }
    }

    /// Tasks filtered to `ids` in suite order; unknown ids are loud errors.
    func tasks(named ids: [String]) throws -> [TaskSpec] {
        try ids.map { id in
            guard let task = task(named: id) else {
                throw EvalFatalError(message: "--task \(id): no such task in \(sourcePath) (known: \(tasks.map(\.id).joined(separator: ", ")))")
            }
            return task
        }
    }
}

// MARK: - Loader

enum TaskSpecLoader {
    /// Static schema contract for the suite envelope. Decoding is strict:
    /// unknown top-level envelope keys fail the load, so a spec change that
    /// matters can never pass unnoticed.
    static let envelopeKeys: Set<String> = [
        "suite", "mission", "spec", "turn_definition",
        "assertion_kinds", "immutable_seeds_rule", "completion_contract", "tasks",
    ]
    static let taskKeys: Set<String> = [
        "id", "axis", "tier", "title", "prompt", "seed_files",
        "immutable_seeds", "assertions", "max_turns", "stresses", "stop_authority_rule",
    ]
    static let seedFileKeys: Set<String> = ["path", "content"]

    /// Loads and validates the whole suite. Every failure names the offending
    /// task/field — schema drift is a loud harness error, not a degraded run.
    static func load(path: String) throws -> EvalSuite {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw EvalFatalError(message: "tasks file not found: \(path)")
        }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw EvalFatalError(message: "cannot read \(path): \(error)")
        }
        let root: [String: JSONValue]
        do {
            root = try JSONParser.parseObject(text)
        } catch let error as JSONParseError {
            throw EvalFatalError(message: "\(path): \(error)")
        }

        for key in root.keys where !envelopeKeys.contains(key) {
            throw EvalFatalError(message: "\(path): unknown top-level key \"\(key)\" — suite schema drift; expected keys: \(envelopeKeys.sorted().joined(separator: ", "))")
        }

        guard case .string(let suiteName) = root["suite"] else {
            throw EvalFatalError(message: "\(path): missing \"suite\"")
        }
        guard suiteName == EvalSuite.expectedSuiteName else {
            throw EvalFatalError(message: "\(path): suite is \"\(suiteName)\", expected \"\(EvalSuite.expectedSuiteName)\" (SCORING.md §8: in-place edits create a new suite version)")
        }
        guard case .string(let mission) = root["mission"] else {
            throw EvalFatalError(message: "\(path): missing \"mission\"")
        }
        guard case .array(let rawTasks) = root["tasks"], !rawTasks.isEmpty else {
            throw EvalFatalError(message: "\(path): \"tasks\" must be a non-empty array")
        }

        var tasks: [TaskSpec] = []
        var seenIDs: Set<String> = []
        for (index, rawTask) in rawTasks.enumerated() {
            guard case .object(let taskObject) = rawTask else {
                throw EvalFatalError(message: "\(path): tasks[\(index)] is not an object")
            }
            tasks.append(try decodeTask(taskObject, file: path, index: index))
            let id = tasks[tasks.count - 1].id
            if !seenIDs.insert(id).inserted {
                throw EvalFatalError(message: "\(path): duplicate task id \"\(id)\"")
            }
        }

        // Suite-level invariants from TASKS.md §6/§7: five axes, every axis
        // populated, ids dense T01…TNN.
        for task in tasks {
            guard EvalSuite.axes.contains(task.axis) else {
                throw EvalFatalError(message: "\(path): task \(task.id) has unknown axis \"\(task.axis)\"")
            }
        }
        let present = Set(tasks.map(\.axis))
        for axis in EvalSuite.axes where !present.contains(axis) {
            throw EvalFatalError(message: "\(path): axis \(axis) has no tasks (suite contract: A=2, B=3, C=3, D=3, E=3)")
        }
        for (index, task) in tasks.enumerated() {
            let expected = String(format: "T%02d", index + 1)
            guard task.id == expected else {
                throw EvalFatalError(message: "\(path): task at position \(index) has id \"\(task.id)\", expected \"\(expected)\" (suite ids must be dense)")
            }
        }

        return EvalSuite(suite: suiteName, mission: mission, tasks: tasks, sourcePath: path)
    }

    private static func decodeTask(_ object: [String: JSONValue], file: String, index: Int) throws -> TaskSpec {
        let where_ = "\(file): tasks[\(index)]"
        for key in object.keys where !taskKeys.contains(key) {
            throw EvalFatalError(message: "\(where_): unknown task key \"\(key)\" — expected keys: \(taskKeys.sorted().joined(separator: ", "))")
        }
        func string(_ name: String) throws -> String {
            guard case .string(let value) = object[name] else {
                throw EvalFatalError(message: "\(where_): missing or non-string \"\(name)\"")
            }
            return value
        }
        func integer(_ name: String) throws -> Int {
            guard case .number(let raw) = object[name], let value = JSONValue.number(raw).intValue else {
                throw EvalFatalError(message: "\(where_): \"\(name)\" must be an integer")
            }
            return value
        }

        let id = try string("id")
        let tier = try integer("tier")
        let maxTurns = try integer("max_turns")
        guard (1...3).contains(tier) else {
            throw EvalFatalError(message: "\(where_) (\(id)): tier \(tier) outside 1...3")
        }
        guard maxTurns >= 1 else {
            throw EvalFatalError(message: "\(where_) (\(id)): max_turns must be ≥ 1")
        }

        guard case .array(let rawSeeds) = object["seed_files"], !rawSeeds.isEmpty else {
            throw EvalFatalError(message: "\(where_) (\(id)): \"seed_files\" must be a non-empty array")
        }
        var seedFiles: [SeedFile] = []
        var seenPaths: Set<String> = []
        for (seedIndex, rawSeed) in rawSeeds.enumerated() {
            guard case .object(let seedObject) = rawSeed else {
                throw EvalFatalError(message: "\(where_) (\(id)): seed_files[\(seedIndex)] is not an object")
            }
            for key in seedObject.keys where !seedFileKeys.contains(key) {
                throw EvalFatalError(message: "\(where_) (\(id)): seed_files[\(seedIndex)] has unknown key \"\(key)\"")
            }
            guard case .string(let path) = seedObject["path"], !path.isEmpty else {
                throw EvalFatalError(message: "\(where_) (\(id)): seed_files[\(seedIndex)] missing \"path\"")
            }
            guard case .string(let content) = seedObject["content"] else {
                throw EvalFatalError(message: "\(where_) (\(id)): seed_files[\(seedIndex)] (\(path)) missing \"content\"")
            }
            if !seenPaths.insert(path).inserted {
                throw EvalFatalError(message: "\(where_) (\(id)): duplicate seed path \"\(path)\"")
            }
            seedFiles.append(SeedFile(path: path, content: content))
        }

        var immutableSeeds: [String] = []
        if case .array(let rawImmutable) = object["immutable_seeds"] {
            for item in rawImmutable {
                guard case .string(let path) = item else {
                    throw EvalFatalError(message: "\(where_) (\(id)): \"immutable_seeds\" entries must be strings")
                }
                guard seenPaths.contains(path) else {
                    throw EvalFatalError(message: "\(where_) (\(id)): immutable seed \"\(path)\" is not in seed_files")
                }
                immutableSeeds.append(path)
            }
        }

        guard case .array(let rawAssertions) = object["assertions"], !rawAssertions.isEmpty else {
            throw EvalFatalError(message: "\(where_) (\(id)): \"assertions\" must be a non-empty array")
        }
        var assertions: [AssertionSpec] = []
        for (assertionIndex, rawAssertion) in rawAssertions.enumerated() {
            guard case .object(let assertionObject) = rawAssertion else {
                throw EvalFatalError(message: "\(where_) (\(id)): assertions[\(assertionIndex)] is not an object")
            }
            assertions.append(try AssertionSpec.decode(assertionObject, taskID: id, index: assertionIndex))
        }

        var stresses: [String] = []
        if case .array(let rawStresses) = object["stresses"] {
            for item in rawStresses {
                guard case .string(let name) = item else {
                    throw EvalFatalError(message: "\(where_) (\(id)): \"stresses\" entries must be strings")
                }
                stresses.append(name)
            }
        }

        var stopAuthorityRule: String?
        if case .string(let rule) = object["stop_authority_rule"] {
            stopAuthorityRule = rule
        }

        return TaskSpec(id: id,
                        axis: try string("axis"),
                        tier: tier,
                        title: try string("title"),
                        prompt: try string("prompt"),
                        seedFiles: seedFiles,
                        immutableSeeds: immutableSeeds,
                        assertions: assertions,
                        maxTurns: maxTurns,
                        stresses: stresses,
                        stopAuthorityRule: stopAuthorityRule)
    }
}
