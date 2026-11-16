// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission Merlin kernel-skeleton slice: workspace sandbox containment, the
/// deterministic ledger digest, the task spine, the tool registry surface,
/// retry classification, and the kernel loop's stop conditions (task_done,
/// turn budget, batch clamping, guardian hook).
final class MerlinChecks: CheckCase {
    /// Async twin of `XCTAssertThrowsError`: the harness's assert functions
    /// take autoclosures, which cannot carry `await`, so async throwing calls
    /// assert through this helper instead. MainActor-isolated end to end so
    /// the closures stay in the caller's isolation domain.
    @MainActor private func assertThrowsAsync<T>(_ expression: @MainActor () async throws -> T,
                                                 _ message: @autoclosure () -> String = "",
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line,
                                                 _ errorHandler: @MainActor (any Error) -> Void = { _ in }) async {
        do {
            _ = try await expression()
            XCTFail("XCTAssertThrowsError failed: did not throw an error \(message())")
        } catch {
            errorHandler(error)
        }
    }

    // MARK: - Workspace containment

    private func makeWorkspace() throws -> MerlinWorkspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("merlin-checks-\(UUID().uuidString)", isDirectory: true)
        return try MerlinWorkspace(root: root, taskID: "check-\(UUID().uuidString.prefix(8))")
    }

    func testWorkspaceRejectsTraversal() throws {
        let workspace = try makeWorkspace()
        XCTAssertThrowsError(try workspace.resolve("../outside")) { error in
            XCTAssertTrue("\(error)".contains("escapes"), "unexpected error: \(error)")
        }
        XCTAssertThrowsError(try workspace.resolve("a/../../b"))
        // '..' is refused even when the walk would stay inside the sandbox.
        XCTAssertThrowsError(try workspace.resolve("dir/../file.txt"))
        XCTAssertThrowsError(try workspace.resolve(""),
                             "empty path must be rejected")
        XCTAssertThrowsError(try workspace.resolve("   "))
    }

    func testWorkspaceRejectsAbsolutePathsOutsideRoot() throws {
        let workspace = try makeWorkspace()
        XCTAssertThrowsError(try workspace.resolve("/etc/passwd"))
        XCTAssertThrowsError(try workspace.resolve("/usr/bin"))
        // An absolute path that restates a seeded file IS allowed.
        try workspace.seed(["known.txt": "hello"])
        let url = try workspace.resolve(workspace.rootPath + "/known.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testWorkspaceRejectsSymlinkEscape() throws {
        let workspace = try makeWorkspace()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("merlin-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspace.rootURL.appendingPathComponent("laundered"),
            withDestinationURL: outside)

        // The symlink is inside the workspace; the target is not. Resolution
        // must catch the laundering at read time...
        XCTAssertThrowsError(try workspace.resolve("laundered"))
        // ...and at write time, including under a nested innocent path.
        XCTAssertThrowsError(try workspace.resolveForWriting("laundered/secret.txt"))
    }

    func testWorkspaceDotResolvesToRootAndWritesNest() throws {
        let workspace = try makeWorkspace()
        XCTAssertEqual(try workspace.resolve(".").path, workspace.rootPath)
        XCTAssertEqual(try workspace.resolve("a/./b.txt").path,
                       workspace.rootURL.appendingPathComponent("a/b.txt").path,
                       "'.' segments are dropped, never walked")
        let url = try workspace.resolveForWriting("deep/nested/file.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
                      "intermediate directories are created for writes")
        XCTAssertEqual(url.path, workspace.rootURL.appendingPathComponent("deep/nested/file.txt").path)
    }

    func testWorkspaceSeedWritesSortedAndReturnsOrder() throws {
        let workspace = try makeWorkspace()
        let written = try workspace.seed(["b.txt": "2", "a.txt": "1", "d/c.txt": "3"])
        XCTAssertEqual(written, ["a.txt", "b.txt", "d/c.txt"], "seed order is sorted, hence deterministic")
        XCTAssertEqual(try String(contentsOf: workspace.rootURL.appendingPathComponent("a.txt"),
                                  encoding: .utf8), "1")
    }

    func testWorkspaceLockRejectsForeignTask() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("merlin-lockcheck-\(UUID().uuidString)", isDirectory: true)
        _ = try MerlinWorkspace(root: root, taskID: "task-one")
        // Same task may re-adopt its own workspace.
        _ = try MerlinWorkspace(root: root, taskID: "task-one")
        XCTAssertThrowsError(try MerlinWorkspace(root: root, taskID: "task-two")) { error in
            XCTAssertTrue("\(error)".contains("locked by task task-one"), "unexpected error: \(error)")
        }
    }

    // MARK: - Ledger and digest determinism

    private func sampleEntries() -> [MerlinLedger.Entry] {
        [
            MerlinLedger.Entry(turn: 1, kind: .decision, key: "todos", text: "todo list now:\n[ ] read\n[ ] write"),
            MerlinLedger.Entry(turn: 1, kind: .result, key: "fs_read", text: "read notes.md (1400 chars)"),
            MerlinLedger.Entry(turn: 2, kind: .blocker, key: "fs_grep", text: "pattern too broad"),
            MerlinLedger.Entry(turn: 2, kind: .result, key: "fs_grep", text: "error: no such file: missing.txt"),
            MerlinLedger.Entry(turn: 3, kind: .result, key: "fs_write", text: "wrote report.md (320 chars)"),
            MerlinLedger.Entry(turn: 3, kind: .artifact, key: "report.md", text: "wrote 320 chars to report.md"),
            MerlinLedger.Entry(turn: 3, kind: .result, key: "todo_write", text: "todo list replaced (2 items)"),
        ]
    }

    func testDigestIsDeterministicAndSectioned() {
        let first = MerlinLedger.digest(goal: "write the report", entries: sampleEntries())
        let second = MerlinLedger.digest(goal: "write the report", entries: sampleEntries())
        XCTAssertEqual(first, second, "same entries must render byte-identical digests")

        let lines = first.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "GOAL: write the report")
        XCTAssertTrue(lines.contains("BLOCKERS:"))
        XCTAssertTrue(lines.contains { $0.contains("pattern too broad") }, "open blockers appear verbatim")
        XCTAssertTrue(lines.contains("RECENT RESULTS:"))
        // Last 3 results only: fs_read is the oldest and must be dropped.
        XCTAssertFalse(lines.contains { $0.contains("fs_read") }, "only the last 3 results are shown")
        XCTAssertTrue(lines.contains { $0.contains("fs_write") })
        XCTAssertTrue(lines.contains("ARTIFACTS:"))
        XCTAssertTrue(lines.contains { $0.contains("report.md") })
    }

    func testDigestLineBudgetIsHonored() {
        let blockers = (1...30).map {
            MerlinLedger.Entry(turn: $0, kind: .blocker, key: "k\($0)", text: "blocker \($0)")
        }
        let digest = MerlinLedger.digest(goal: "g", entries: blockers, maxLines: 8)
        let lineCount = digest.split(separator: "\n").count
        XCTAssertLessThanOrEqual(lineCount, 8, "digest never exceeds its line budget")
        XCTAssertTrue(digest.hasPrefix("GOAL: g\nBLOCKERS:"), "the goal and the blockers header survive the clamp")
    }

    func testDigestLineCollapsesWhitespaceAndTruncates() {
        let bloated = MerlinLedger.Entry(turn: 1, kind: .result, key: "fs_read",
                                         text: String(repeating: "word \n\t", count: 80))
        let rendered = MerlinLedger.digestLine(bloated)
        XCTAssertFalse(rendered.contains("\n"), "newlines are collapsed: one entry is one digest line")
        XCTAssertLessThanOrEqual(rendered.count, 160, "digest lines are truncated")
        XCTAssertTrue(rendered.hasSuffix("…"))
        XCTAssertTrue(rendered.hasPrefix("fs_read: "), "the key prefixes the rendered text")

        let short = MerlinLedger.digestLine(MerlinLedger.Entry(turn: 1, kind: .fact, key: nil, text: "clean fact"))
        XCTAssertEqual(short, "clean fact", "no key, no truncation, no padding")
    }

    func testLedgerJSONLRoundTripAndDeterministicEncoding() throws {
        for entry in sampleEntries() {
            let line = try MerlinLedger.encodeLine(entry)
            XCTAssertTrue(line.hasSuffix("\n"), "each entry is one newline-terminated line")
            let parsed = try MerlinLedger.parse(data: Data(line.utf8))
            XCTAssertEqual(parsed, [entry], "encode → parse restores the entry exactly")
        }
        // Sorted keys make the encoding deterministic across runs.
        XCTAssertEqual(try MerlinLedger.encodeLine(sampleEntries()[0]),
                       try MerlinLedger.encodeLine(sampleEntries()[0]))
    }

    func testLedgerParseRejectsTornLines() {
        let torn = Data("{\"turn\":1,\"kind\":\"fact\",\"text\":\"ok\"\n".utf8)
        XCTAssertThrowsError(try MerlinLedger.parse(data: torn)) { error in
            XCTAssertTrue("\(error)".contains("line 1"), "the error names the offending line: \(error)")
        }
        // Blank lines are skipped, not fatal.
        let padded = Data("\n{\"turn\":1,\"kind\":\"fact\",\"text\":\"ok\"}\n\n".utf8)
        XCTAssertEqual(try MerlinLedger.parse(data: padded).count, 1)
    }

    func testLedgerPersistsAcrossReopen() throws {
        let workspace = try makeWorkspace()
        let url = workspace.rootURL.appendingPathComponent(MerlinLedger.fileName)
        let ledger = try MerlinLedger(url: url)
        try ledger.append(turn: 1, kind: .fact, key: "k", text: "persisted fact")
        try ledger.append(turn: 2, kind: .artifact, key: "out.txt", text: "wrote out.txt")
        let reopened = try MerlinLedger(url: url)
        XCTAssertEqual(reopened.allEntries, ledger.allEntries,
                       "the JSONL file is the durable record; a reopened ledger restores it")
    }

    // MARK: - Task spine

    func testSpineInjectsGoalPlanDigestAndContract() {
        let spine = MerlinTaskSpine(goal: "fix the flaky check",
                                    planSketch: ["reproduce", "patch", "verify"],
                                    maxTurns: 5)
        let digest = MerlinLedger.digest(goal: "fix the flaky check", entries: [])
        let prompt = spine.systemPrompt(turn: 2, digest: digest)
        XCTAssertTrue(prompt.contains("GOAL: fix the flaky check"))
        XCTAssertTrue(prompt.contains("PLAN:\n- reproduce\n- patch\n- verify"))
        XCTAssertTrue(prompt.contains("STATE (re-injected every turn"))
        XCTAssertTrue(prompt.contains(digest), "the digest is embedded verbatim")
        XCTAssertTrue(prompt.contains("Turn 2 of 5; 3 turns remain."))
        XCTAssertTrue(prompt.contains("Up to 4 tool calls per turn"))
        XCTAssertTrue(prompt.contains("task_done"), "the completion contract is always present")
        XCTAssertFalse(prompt.contains("This is your final turn"))
    }

    func testSpineMarksFinalTurn() {
        let spine = MerlinTaskSpine(goal: "g", maxTurns: 3)
        let final = spine.systemPrompt(turn: 3, digest: "GOAL: g")
        XCTAssertTrue(final.contains("0 turns remain"))
        XCTAssertTrue(final.contains("This is your final turn: call task_done now"),
                      "the wrap-up instruction only appears on the final turn")
        let early = spine.systemPrompt(turn: 1, digest: "GOAL: g")
        XCTAssertFalse(early.contains("This is your final turn"))
    }

    // MARK: - Tool registry

    func testToolSurfaceIsExactlyTheTenContractTools() throws {
        let workspace = try makeWorkspace()
        let ledger = try MerlinLedger(url: workspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let registry = MerlinToolRegistry(workspace: workspace, ledger: ledger)
        XCTAssertEqual(registry.orderedTools.map(\.name), MerlinToolRegistry.reservedNames)
        XCTAssertEqual(registry.orderedTools.count, 10)
        for tool in registry.orderedTools {
            let schema = tool.schema
            XCTAssertEqual(schema["type"] as? String, "object", "\(tool.name): schema root is an object")
            XCTAssertNotNil(schema["properties"], "\(tool.name): schema declares properties")
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name): description is non-empty")
        }
    }

    @MainActor func testFileToolsRoundTrip() async throws {
        let workspace = try makeWorkspace()
        let ledger = try MerlinLedger(url: workspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let registry = MerlinToolRegistry(workspace: workspace, ledger: ledger)

        let write = try await registry.execute(name: "fs_write",
                                               argumentsJSON: #"{"path": "notes/todo.md", "content": "hello\nworld"}"#,
                                               turn: 1)
        XCTAssertTrue(write.contains("notes/todo.md"))
        let read = try await registry.execute(name: "fs_read",
                                              argumentsJSON: #"{"path": "notes/todo.md"}"#,
                                              turn: 1)
        XCTAssertEqual(read, "hello\nworld")
        let list = try await registry.execute(name: "fs_list",
                                              argumentsJSON: #"{"path": "notes"}"#,
                                              turn: 1)
        XCTAssertEqual(list, "todo.md")
        let grep = try await registry.execute(name: "fs_grep",
                                              argumentsJSON: #"{"pattern": "world"}"#,
                                              turn: 1)
        XCTAssertEqual(grep, "notes/todo.md:2: world")
        let rootList = try await registry.execute(name: "fs_list",
                                                  argumentsJSON: #"{"path": "."}"#,
                                                  turn: 1)
        XCTAssertTrue(rootList.contains("notes"), "the seeded directory shows in the root listing")
    }

    @MainActor func testFileToolsRefuseLedgerAccessAndBadArgs() async throws {
        let workspace = try makeWorkspace()
        let ledger = try MerlinLedger(url: workspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let registry = MerlinToolRegistry(workspace: workspace, ledger: ledger)

        // fs_read must refuse the ledger file even though the file does not
        // exist yet: the reserved name is refused before existence is
        // checked, so probing for the ledger's existence is impossible.
        await assertThrowsAsync({
            try await registry.execute(name: "fs_read",
                                       argumentsJSON: "{\"path\": \"\(MerlinLedger.fileName)\"}",
                                       turn: 1)
        }) { error in
            XCTAssertTrue("\(error)".contains("managed by the kernel"),
                          "fs_read must refuse the ledger file, got: \(error)")
        }
        // fs_write to the ledger path is refused the same way.
        await assertThrowsAsync {
            try await registry.execute(name: "fs_write",
                                       argumentsJSON: "{\"path\": \"\(MerlinLedger.fileName)\", \"content\": \"x\"}",
                                       turn: 1)
        }

        await assertThrowsAsync {
            try await registry.execute(name: "fs_read",
                                       argumentsJSON: #"{"path": "no/such/file.txt"}"#,
                                       turn: 1)
        }
        await assertThrowsAsync({
            try await registry.execute(name: "fs_write",
                                       argumentsJSON: #"{"path": "x.txt"}"#,
                                       turn: 1)
        }, "missing content field is a tool-arg error")
        await assertThrowsAsync({
            try await registry.execute(name: "fs_read",
                                       argumentsJSON: "{not json",
                                       turn: 1)
        }, "malformed JSON is a tool-arg error")
        await assertThrowsAsync({
            try await registry.execute(name: "fs_grep",
                                       argumentsJSON: #"{"pattern": "x", "path": "gone.txt"}"#,
                                       turn: 1)
        }, "an explicit missing path is a tool-arg error")
        let noMatches = try await registry.execute(name: "fs_grep",
                                                   argumentsJSON: #"{"pattern": "zzz-not-there"}"#,
                                                   turn: 1)
        XCTAssertEqual(noMatches, "no matches")
    }

    @MainActor func testLedgerToolsWriteAndRead() async throws {
        let workspace = try makeWorkspace()
        let ledger = try MerlinLedger(url: workspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let registry = MerlinToolRegistry(workspace: workspace, ledger: ledger)

        let todoReply = try await registry.execute(name: "todo_write",
                                                   argumentsJSON: #"""
        {"todos": [{"text": "read the docs", "done": true}, {"text": "write the summary", "done": false}]}
        """#,
                                                   turn: 1)
        XCTAssertTrue(todoReply.contains("2 items"))
        let todoState = try await registry.execute(name: "todo_read", argumentsJSON: "{}", turn: 1)
        XCTAssertEqual(todoState, "[x] read the docs\n[ ] write the summary")

        let noteReply = try await registry.execute(name: "note_add",
                                                   argumentsJSON: #"{"kind": "blocker", "text": "compiler out of memory", "key": "build"}"#,
                                                   turn: 2)
        XCTAssertTrue(noteReply.contains("blocker"))
        XCTAssertTrue(ledger.allEntries.contains { $0.kind == .blocker && $0.text.contains("out of memory") })

        await assertThrowsAsync({
            try await registry.execute(name: "note_add",
                                       argumentsJSON: #"{"kind": "result", "text": "sneaky"}"#,
                                       turn: 2)
        }, "the model may not forge kernel-written result entries")
    }

    @MainActor func testStubToolsFailTypedAndUnknownToolsAreRefused() async throws {
        let workspace = try makeWorkspace()
        let ledger = try MerlinLedger(url: workspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let registry = MerlinToolRegistry(workspace: workspace, ledger: ledger)

        // Slice 3 wired shell_run and js_eval (MerlinShell / MerlinJS), so
        // the former stub assertions became happy-path checks there. What
        // remains here from that check is the argument contract: both
        // compute tools refuse malformed or missing arguments, and unknown
        // tools are still refused.
        await assertThrowsAsync({
            try await registry.execute(name: "shell_run", argumentsJSON: "{not json", turn: 1)
        }, "shell_run refuses malformed JSON arguments")
        await assertThrowsAsync({
            try await registry.execute(name: "shell_run", argumentsJSON: "{}", turn: 1)
        }, "shell_run refuses a missing command field")
        await assertThrowsAsync({
            try await registry.execute(name: "js_eval", argumentsJSON: #"{"code": ""}"#, turn: 1)
        }, "js_eval refuses an empty code field")
        // The typed not-wired error classifies permanent: retrying it is
        // pointless. (Asserted here because the handler throws through the
        // registry, which does not re-classify.)
        let notWired = MerlinToolRegistry.NotWiredError(tool: "shell_run")
        XCTAssertEqual(MerlinRetry.classify(notWired), .permanent)
        await assertThrowsAsync({
            try await registry.execute(name: "no_such_tool", argumentsJSON: "{}", turn: 1)
        }) { error in
            XCTAssertTrue("\(error)".contains("unknown tool"))
        }
    }

    // MARK: - Retry classification (M7)

    func testRetryClassificationMapsFaultKinds() {
        // Handler-declared classifications pass through.
        XCTAssertEqual(MerlinRetry.classify(MerlinRetry.ToolError(classification: .transient, message: "x")), .transient)
        XCTAssertEqual(MerlinRetry.classify(MerlinRetry.ToolError(classification: .toolArg, message: "x")), .toolArg)
        XCTAssertEqual(MerlinRetry.classify(MerlinRetry.ToolError(classification: .permanent, message: "x")), .permanent)
        // Malformed model JSON is the model's problem.
        XCTAssertEqual(MerlinRetry.classify(makeDecodingError()), .toolArg)
        // POSIX faults: hiccups heal, argument mistakes do not.
        XCTAssertEqual(MerlinRetry.classify(posixError(ECONNRESET)), .transient)
        XCTAssertEqual(MerlinRetry.classify(posixError(EAGAIN)), .transient)
        XCTAssertEqual(MerlinRetry.classify(posixError(ENOENT)), .toolArg)
        XCTAssertEqual(MerlinRetry.classify(posixError(EACCES)), .toolArg)
        XCTAssertEqual(MerlinRetry.classify(posixError(EPERM)), .toolArg)
        // Cocoa file faults: unknown/read faults may heal; missing and
        // permission-denied files are argument errors.
        XCTAssertEqual(MerlinRetry.classify(cocoaError(NSFileReadUnknownError)), .transient)
        XCTAssertEqual(MerlinRetry.classify(cocoaError(NSFileNoSuchFileError)), .toolArg)
        XCTAssertEqual(MerlinRetry.classify(cocoaError(NSFileReadNoPermissionError)), .toolArg)
        // Anything unrecognized is permanent.
        XCTAssertEqual(MerlinRetry.classify(cocoaError(999, domain: "com.example.whatever")), .permanent)
    }

    private func makeDecodingError() -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "test"))
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
    }

    private func cocoaError(_ code: Int, domain: String = NSCocoaErrorDomain) -> NSError {
        NSError(domain: domain, code: code, userInfo: nil)
    }

    func testBackoffScheduleDoublesAndNeverDelaysFirstAttempt() {
        let policy = MerlinRetry.Policy(maxAttempts: 5, baseDelay: 0.25)
        XCTAssertEqual(MerlinRetry.backoff(policy: policy, attempt: 1), 0)
        XCTAssertEqual(MerlinRetry.backoff(policy: policy, attempt: 2), 0.25)
        XCTAssertEqual(MerlinRetry.backoff(policy: policy, attempt: 3), 0.5)
        XCTAssertEqual(MerlinRetry.backoff(policy: policy, attempt: 4), 1.0)
    }

    @MainActor func testTransientRetriesWithBackoffWithoutRealSleep() async throws {
        let sleeps = SleepRecorder()
        let attempts = Counter()
        let result: String = try await MerlinRetry.runAsync(tool: "fs_read",
                                                            operation: {
            attempts.increment()
            if attempts.current < 3 {
                throw MerlinRetry.ToolError(classification: .transient, message: "hiccup")
            }
            return "recovered"
        }, sleep: { sleeps.record($0) })
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(attempts.current, 3)
        XCTAssertEqual(sleeps.intervals, [0.25, 0.5], "backoff doubles between attempts")
    }

    @MainActor func testRetryGivesUpAtPolicyCap() async throws {
        let sleeps = SleepRecorder()
        let attempts = Counter()
        do {
            _ = try await MerlinRetry.runAsync(tool: "fs_list", operation: {
                attempts.increment()
                throw MerlinRetry.ToolError(classification: .transient, message: "still down")
            }, sleep: { sleeps.record($0) })
            XCTFail("exhausted retries must throw")
        } catch {
            XCTAssertTrue("\(error)".contains("still down"))
        }
        XCTAssertEqual(attempts.current, MerlinRetry.Policy.forTool("fs_list").maxAttempts)
        XCTAssertEqual(sleeps.intervals.count, attempts.current - 1)
    }

    @MainActor func testToolArgAndPermanentNeverRetry() async throws {
        let sleeps = SleepRecorder()
        let argAttempts = Counter()
        await assertThrowsAsync({
            try await MerlinRetry.runAsync(tool: "fs_read", operation: {
                argAttempts.increment()
                throw MerlinRetry.ToolError(classification: .toolArg, message: "bad path")
            }, sleep: { sleeps.record($0) })
        })
        let permAttempts = Counter()
        await assertThrowsAsync({
            try await MerlinRetry.runAsync(tool: "note_add", operation: {
                permAttempts.increment()
                throw MerlinRetry.ToolError(classification: .permanent, message: "broken")
            }, sleep: { sleeps.record($0) })
        })
        XCTAssertEqual(argAttempts.current, 1, "tool-arg failures surface immediately")
        XCTAssertEqual(permAttempts.current, 1, "permanent failures surface immediately")
        XCTAssertEqual(sleeps.intervals, [], "no sleeps when nothing retries")
    }

    /// Thread-safe integer box: closures crossing an isolation boundary
    /// mutate attempt counters through this instead of captured local vars,
    /// which Swift 6 correctly refuses to send.
    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Collects the injected backoff intervals; stands in for a real clock.
    private final class SleepRecorder: @unchecked Sendable {
        private var stored: [TimeInterval] = []
        private let lock = NSLock()
        func record(_ interval: TimeInterval) {
            lock.lock()
            stored.append(interval)
            lock.unlock()
        }
        var intervals: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    // MARK: - Kernel loop (scripted actor)

    /// A scripted actor: plays back one call batch per turn, recording the
    /// prompts it received. MainActor-isolated because the check bodies run
    /// there; the kernel's calls arrive through the same domain. This is the
    /// seam slice 2's real actor plugs into.
    @MainActor private final class ScriptedActor: MerlinActor {
        private let batches: [[MerlinToolCall]]
        private var index = 0
        private var prompts: [String] = []

        init(_ batches: [[MerlinToolCall]]) {
            self.batches = batches
        }

        func toolCalls(prompt: String, turn: Int) async throws -> [MerlinToolCall] {
            prompts.append(prompt)
            defer { index += 1 }
            guard index < batches.count else { return [] }
            return batches[index]
        }

        var recordedPrompts: [String] { prompts }
    }

    private func makeKernel(maxTurns: Int = 6) throws -> (MerlinKernel, MerlinWorkspace) {
        let workspace = try makeWorkspace()
        let ledger = try MerlinLedger(url: workspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let spine = MerlinTaskSpine(goal: "produce the artifact", maxTurns: maxTurns)
        let kernel = MerlinKernel(workspace: workspace, ledger: ledger, spine: spine,
                                  configuration: MerlinKernel.Configuration(maxTurns: maxTurns))
        return (kernel, workspace)
    }

    @MainActor func testTaskDoneTerminatesAndDropsRemainingBatchCalls() async throws {
        let (kernel, workspace) = try makeKernel(maxTurns: 6)
        let actor = ScriptedActor([
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "final.txt", "content": "done"}"#),
             MerlinToolCall(name: "task_done",
                            argumentsJSON: #"{"summary": "wrote final.txt as required"}"#),
             MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "dropped.txt", "content": "never"}"#),
            ],
        ])

        let outcome = await kernel.run(actor: actor)
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.summary, "wrote final.txt as required")
        XCTAssertEqual(outcome.turnsUsed, 1, "a mid-batch task_done ends the run in that turn")

        // The call before task_done executed; the call after it was dropped.
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.rootURL.appendingPathComponent("final.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.rootURL.appendingPathComponent("dropped.txt").path))
        XCTAssertTrue(kernel.ledger.allEntries.contains { $0.kind == .artifact && $0.key == "final.txt" })
        XCTAssertTrue(kernel.ledger.allEntries.contains { $0.kind == .result && $0.key == "task_done" })
    }

    @MainActor func testBudgetStopEndsWithoutCompletion() async throws {
        let (kernel, _) = try makeKernel(maxTurns: 2)
        // A failing read every turn: the loop must never end the run on a
        // tool error, only on the budget.
        let actor = ScriptedActor([
            [MerlinToolCall(name: "fs_read", argumentsJSON: #"{"path": "missing.txt"}"#)],
            [MerlinToolCall(name: "fs_read", argumentsJSON: #"{"path": "missing.txt"}"#)],
        ])
        let outcome = await kernel.run(actor: actor)
        XCTAssertEqual(outcome.status, .budgetExhausted)
        XCTAssertEqual(outcome.turnsUsed, 2)
        XCTAssertEqual(outcome.maxTurns, 2)
        // Errors became state, not termination: both failures are ledgered.
        let errors = kernel.ledger.allEntries.filter { $0.kind == .result && $0.text.contains("error:") }
        XCTAssertEqual(errors.count, 2)
        // The actor saw the digest grow: the second prompt differs from the
        // first (M0 re-injection is live).
        XCTAssertNotEqual(actor.recordedPrompts.first, actor.recordedPrompts.last)
    }

    @MainActor func testEmptyBatchConsumesTurnAndLoopContinues() async throws {
        let (kernel, _) = try makeKernel(maxTurns: 3)
        let actor = ScriptedActor([
            [],  // an empty completion still burns the turn
            [MerlinToolCall(name: "task_done", argumentsJSON: #"{"summary": "finished late"}"#)],
        ])
        let outcome = await kernel.run(actor: actor)
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.turnsUsed, 2, "the empty turn was consumed, then task_done landed")
    }

    @MainActor func testOversizedBatchIsClampedToTheContract() async throws {
        let (kernel, workspace) = try makeKernel(maxTurns: 6)
        // Six calls in one completion, with the completion contract sitting
        // beyond the clamp: only the first four (the contract maximum) may
        // execute, and the dropped task_done must never run.
        let batch = (1...4).map { index -> MerlinToolCall in
            MerlinToolCall(name: "fs_write",
                           argumentsJSON: "{\"path\": \"f\(index).txt\", \"content\": \"\(index)\"}")
        } + [
            MerlinToolCall(name: "task_done", argumentsJSON: #"{"summary": "must be dropped"}"#),
            MerlinToolCall(name: "fs_write", argumentsJSON: #"{"path": "f6.txt", "content": "6"}"#),
        ]
        let actor = ScriptedActor([batch])
        let outcome = await kernel.run(actor: actor)
        XCTAssertEqual(outcome.status, .budgetExhausted,
                       "the clamped-away task_done never ran, so the budget ends the run")
        XCTAssertEqual(outcome.turnsUsed, 6,
                       "after the clamped batch the actor's empty completions burn the remaining turns")
        for index in 1...4 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.rootURL.appendingPathComponent("f\(index).txt").path),
                "call \(index) of the clamped batch executed")
        }
        for path in ["f6.txt"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.rootURL.appendingPathComponent(path).path),
                "\(path) exceeds the 4-call contract and was dropped")
        }
        XCTAssertFalse(kernel.ledger.allEntries.contains { $0.key == "task_done" },
                       "a task_done beyond the clamp is dropped, never honored")
        XCTAssertTrue(kernel.ledger.allEntries.contains { $0.kind == .blocker && $0.text.contains("6 calls") },
                      "the clamp is recorded as state for the model")
    }

    @MainActor func testGuardianRejectionBecomesBlockerState() async throws {
        let (kernel, workspace) = try makeKernel(maxTurns: 6)
        // Reject every fs_write result: the run continues, but the next
        // digest must carry the retry instruction.
        kernel.guardian = SelectiveGuardian(rejectTool: "fs_write")
        let actor = ScriptedActor([
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "draft.txt", "content": "v1"}"#)],
            [MerlinToolCall(name: "task_done", argumentsJSON: #"{"summary": "done after retry"}"#)],
        ])
        let outcome = await kernel.run(actor: actor)
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertTrue(kernel.ledger.allEntries.contains { $0.kind == .result && $0.text.contains("rejected by guardian") })
        XCTAssertTrue(kernel.ledger.allEntries.contains { $0.kind == .blocker && $0.text.contains("rewrite") },
                      "the guardian's instruction is ledgered as a blocker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.rootURL.appendingPathComponent("draft.txt").path))
    }

    /// Guardian double used to prove the hook point is wired into the loop.
    private struct SelectiveGuardian: MerlinGuardian {
        let rejectTool: String

        func review(tool: String, argumentsJSON: String, result: String) async -> MerlinGuardianVerdict {
            guard tool == rejectTool else { return .accept }
            return .reject(instruction: "rewrite the file with verified content")
        }
    }

    @MainActor func testActorFailureEndsRunAsFailed() async throws {
        let (kernel, _) = try makeKernel(maxTurns: 6)
        struct Boom: Error {}
        let outcome = await kernel.run(actor: ThrowingActor(error: Boom()))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(kernel.ledger.allEntries.contains { $0.kind == .blocker && $0.text.contains("actor failed") })
    }

    /// An actor that always throws: the kernel's terminal failure path.
    private struct ThrowingActor: MerlinActor {
        let error: Error
        func toolCalls(prompt: String, turn: Int) async throws -> [MerlinToolCall] {
            throw error
        }
    }

    // MARK: - Kernel progress seam (slice 6, app-1's documented follow-up)

    /// Sendable-safe event collector for the `onEvent` seam checks: the
    /// callback is `@Sendable`, so captured mutable state must be
    /// lock-guarded (the ScriptedActor pattern from MerlinChecks4).
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [MerlinKernelEvent] = []
        func append(_ event: MerlinKernelEvent) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }
        var all: [MerlinKernelEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    /// Turn/call labels for the sequence assertions below (the enum has no
    /// Equatable conformance because MerlinToolCall is Equatable but the
    /// closures make synthesis awkward; cases are matched structurally).
    private static func labels(_ events: [MerlinKernelEvent]) -> [String] {
        events.map { event in
            switch event {
            case .turnStarted(let turn): return "turn\(turn)"
            case .callExecuted(let call, _): return "call:\(call.name)"
            case .blocker: return "blocker"
            case .completed: return "completed"
            }
        }
    }

    @MainActor func testOnEventSurfacesTurnsCallsAndTerminalOutcomeOnce() async throws {
        let workspace = try makeWorkspace()
        let ledger = try MerlinLedger(url: workspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let log = EventLog()
        let spine = MerlinTaskSpine(goal: "produce the artifact", maxTurns: 4)
        var configuration = MerlinKernel.Configuration(maxTurns: 4)
        configuration.onEvent = { log.append($0) }
        let kernel = MerlinKernel(workspace: workspace, ledger: ledger, spine: spine,
                                  configuration: configuration)
        let actor = ScriptedActor([
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "out.txt", "content": "v1"}"#)],
            [MerlinToolCall(name: "task_done",
                            argumentsJSON: #"{"summary": "wrote out.txt as required"}"#)],
        ])
        let outcome = await kernel.run(actor: actor)
        XCTAssertEqual(outcome.status, .completed)

        let labels = Self.labels(log.all)
        XCTAssertEqual(labels, ["turn1", "call:fs_write", "turn2", "call:task_done", "completed"],
                       "events fire at the natural points, in order: \(labels)")
        // completed arrives exactly once and carries the run's outcome.
        let completions = log.all.compactMap { event -> MerlinOutcome? in
            if case .completed(let finished) = event { return finished }
            return nil
        }
        XCTAssertEqual(completions.count, 1, "completed must fire exactly once")
        XCTAssertEqual(completions.first?.status, .completed)
        XCTAssertEqual(completions.first?.summary, "wrote out.txt as required")
        // callExecuted carries the ledger-faithful summary text.
        if case .callExecuted(let call, let summary) = log.all[1] {
            XCTAssertEqual(call.name, "fs_write")
            XCTAssertTrue(summary.contains("wrote out.txt"), "summary text: \(summary)")
        } else {
            XCTFail("second event must be callExecuted, got \(log.all[1])")
        }
    }

    @MainActor func testOnEventDeliversBlockersAndThrowingObserverCannotStallLoop() async throws {
        let workspace = try makeWorkspace()
        let ledger = try MerlinLedger(url: workspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let log = EventLog()
        let spine = MerlinTaskSpine(goal: "produce the artifact", maxTurns: 6)
        // The seam is non-throwing BY TYPE (@Sendable (Event) -> Void): an
        // observer that could throw or be awaited is not even expressible —
        // fire-and-forget is enforced at compile time, not by convention.
        let configuration = MerlinKernel.Configuration(
            maxTurns: 6,
            maxCallsPerTurn: 4,
            digestMaxLines: 24,
            onEvent: { event in
                log.append(event)
                Thread.sleep(forTimeInterval: 0.001) // busy observer: still cannot reshape the loop
            })
        let kernel = MerlinKernel(workspace: workspace, ledger: ledger, spine: spine,
                                  configuration: configuration)
        kernel.guardian = SelectiveGuardian(rejectTool: "fs_write")
        let actor = ScriptedActor([
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "draft.txt", "content": "v1"}"#)],
            [MerlinToolCall(name: "task_done",
                            argumentsJSON: #"{"summary": "done after retry"}"#)],
        ])
        let outcome = await kernel.run(actor: actor)
        // The run completed with the busy observer attached — the seam is
        // strictly observational.
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.rootURL.appendingPathComponent("draft.txt").path))
        let labels = Self.labels(log.all)
        XCTAssertTrue(labels.contains("blocker"), "guardian rejection must surface as a blocker event: \(labels)")
        XCTAssertTrue(labels.contains("call:fs_write"), "the guardian-rejected call is still executed+surfaced: \(labels)")
        XCTAssertEqual(labels.last, "completed", "terminal event lands last")
        // The default (nil onEvent) keeps the pre-slice-6 behavior: a
        // kernel built through makeKernel ran every earlier check without
        // the seam, so nil is proven by this suite's green state.
    }
}

// MARK: - Generated registration (port from XCTest)
extension MerlinChecks {
    @MainActor static let __checkSet = CheckSet(
        suite: "MerlinChecks",
        instance: { MerlinChecks() },
        checks: [
            .init(name: "testWorkspaceRejectsTraversal") { try $0.testWorkspaceRejectsTraversal() },
            .init(name: "testWorkspaceRejectsAbsolutePathsOutsideRoot") { try $0.testWorkspaceRejectsAbsolutePathsOutsideRoot() },
            .init(name: "testWorkspaceRejectsSymlinkEscape") { try $0.testWorkspaceRejectsSymlinkEscape() },
            .init(name: "testWorkspaceDotResolvesToRootAndWritesNest") { try $0.testWorkspaceDotResolvesToRootAndWritesNest() },
            .init(name: "testWorkspaceSeedWritesSortedAndReturnsOrder") { try $0.testWorkspaceSeedWritesSortedAndReturnsOrder() },
            .init(name: "testWorkspaceLockRejectsForeignTask") { try $0.testWorkspaceLockRejectsForeignTask() },
            .init(name: "testDigestIsDeterministicAndSectioned") { $0.testDigestIsDeterministicAndSectioned() },
            .init(name: "testDigestLineBudgetIsHonored") { $0.testDigestLineBudgetIsHonored() },
            .init(name: "testDigestLineCollapsesWhitespaceAndTruncates") { $0.testDigestLineCollapsesWhitespaceAndTruncates() },
            .init(name: "testLedgerJSONLRoundTripAndDeterministicEncoding") { try $0.testLedgerJSONLRoundTripAndDeterministicEncoding() },
            .init(name: "testLedgerParseRejectsTornLines") { try $0.testLedgerParseRejectsTornLines() },
            .init(name: "testLedgerPersistsAcrossReopen") { try $0.testLedgerPersistsAcrossReopen() },
            .init(name: "testSpineInjectsGoalPlanDigestAndContract") { $0.testSpineInjectsGoalPlanDigestAndContract() },
            .init(name: "testSpineMarksFinalTurn") { $0.testSpineMarksFinalTurn() },
            .init(name: "testToolSurfaceIsExactlyTheTenContractTools") { try $0.testToolSurfaceIsExactlyTheTenContractTools() },
            .init(name: "testFileToolsRoundTrip") { try await $0.testFileToolsRoundTrip() },
            .init(name: "testFileToolsRefuseLedgerAccessAndBadArgs") { try await $0.testFileToolsRefuseLedgerAccessAndBadArgs() },
            .init(name: "testLedgerToolsWriteAndRead") { try await $0.testLedgerToolsWriteAndRead() },
            .init(name: "testStubToolsFailTypedAndUnknownToolsAreRefused") { try await $0.testStubToolsFailTypedAndUnknownToolsAreRefused() },
            .init(name: "testRetryClassificationMapsFaultKinds") { $0.testRetryClassificationMapsFaultKinds() },
            .init(name: "testBackoffScheduleDoublesAndNeverDelaysFirstAttempt") { $0.testBackoffScheduleDoublesAndNeverDelaysFirstAttempt() },
            .init(name: "testTransientRetriesWithBackoffWithoutRealSleep") { try await $0.testTransientRetriesWithBackoffWithoutRealSleep() },
            .init(name: "testRetryGivesUpAtPolicyCap") { try await $0.testRetryGivesUpAtPolicyCap() },
            .init(name: "testToolArgAndPermanentNeverRetry") { try await $0.testToolArgAndPermanentNeverRetry() },
            .init(name: "testTaskDoneTerminatesAndDropsRemainingBatchCalls") { try await $0.testTaskDoneTerminatesAndDropsRemainingBatchCalls() },
            .init(name: "testBudgetStopEndsWithoutCompletion") { try await $0.testBudgetStopEndsWithoutCompletion() },
            .init(name: "testEmptyBatchConsumesTurnAndLoopContinues") { try await $0.testEmptyBatchConsumesTurnAndLoopContinues() },
            .init(name: "testOversizedBatchIsClampedToTheContract") { try await $0.testOversizedBatchIsClampedToTheContract() },
            .init(name: "testGuardianRejectionBecomesBlockerState") { try await $0.testGuardianRejectionBecomesBlockerState() },
            .init(name: "testActorFailureEndsRunAsFailed") { try await $0.testActorFailureEndsRunAsFailed() },
            .init(name: "testOnEventSurfacesTurnsCallsAndTerminalOutcomeOnce") { try await $0.testOnEventSurfacesTurnsCallsAndTerminalOutcomeOnce() },
            .init(name: "testOnEventDeliversBlockersAndThrowingObserverCannotStallLoop") { try await $0.testOnEventDeliversBlockersAndThrowingObserverCannotStallLoop() },
        ])
}
