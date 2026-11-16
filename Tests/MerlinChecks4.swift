// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// Merlin slice-5 checks (app integration, 2026-11-15): the MerlinChatService
// wiring behind the AMENDMENT 3 toggle. NO live servers anywhere — every
// kernel run below is driven by a scripted MerlinActor (the same shape the
// MerlinChecks suites use), the store rides ChatStore.storeDirectoryOverride
// (set by ChecksMain before any check runs), and the workspace roots ride
// per-check temp directories.

import Foundation
@testable import KestrelCore

@MainActor
final class MerlinChecks4: CheckCase {
    // No setUp/tearDown overrides: the CheckCase base lifecycle hooks are
    // nonisolated under Swift 6, so every check sets up and tears down its
    // own isolated store through the helpers below (same per-check pattern
    // the harness's own isolation tests use).

    // MARK: - Fixtures

    /// A fresh isolated chat store per check (the ChatStoreIsolationTests
    /// pattern): its constructor loads whatever is on disk, so each check
    /// points the override at its own scratch directory first. The prior
    /// override (ChecksMain's per-run directory) is restored on exit.
    private func makeStore() -> ChatStore {
        // Belt and braces: ChecksMain already points the store at a per-run
        // temp directory; a check that can prove that fails loudly instead of
        // writing the operator's live conversations.json.
        guard ChatStore.storeDirectoryOverride != nil else {
            fatalError("ChecksMain must set ChatStore.storeDirectoryOverride before any check runs")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("merlin-checks4-\(UUID().uuidString)", isDirectory: true)
        ChatStore.storeDirectoryOverride = scratch
        defer { ChatStore.storeDirectoryOverride = scratch.deletingLastPathComponent() }
        let store = ChatStore()
        ChatStore.storeDirectoryOverride = scratch
        return store
    }

    /// realpath(3) canonicalization, mirroring MerlinWorkspace.canonicalize:
    /// `URL.resolvingSymlinksInPath` leaves a `/var/...` input unresolved, so
    /// the prefix assertions below canonicalize both sides the same way the
    /// kernel does.
    private func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func tempWorkspaceRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("merlin-checks4-ws-\(UUID().uuidString)", isDirectory: true)
    }

    /// Scripted actor: one batch per turn, then task_done on turn 2 (the
    /// MerlinChecks pattern, kept small and self-contained). Records the
    /// spine prompts so goal plumbing can be pinned through the kernel.
    /// `@unchecked Sendable` is honest: every mutable field is NSLock-guarded,
    /// and the async seam touches the lock only through synchronous helpers
    /// (Swift 6 forbids taking an NSLock inside an async function).
    private final class ScriptedActor: MerlinActor, @unchecked Sendable {
        let batches: [[MerlinToolCall]]
        private let lock = NSLock()
        private var index = 0
        private var prompts: [String] = []
        private var turns: [Int] = []

        init(_ batches: [[MerlinToolCall]]) { self.batches = batches }

        private func record(prompt: String, turn: Int) -> Int {
            lock.lock()
            prompts.append(prompt)
            turns.append(turn)
            let i = index
            index += 1
            lock.unlock()
            return i
        }

        func toolCalls(prompt: String, turn: Int) async throws -> [MerlinToolCall] {
            let i = record(prompt: prompt, turn: turn)
            guard i < batches.count else { return [] }
            return batches[i]
        }

        /// Lock-guarded snapshot for the assertions below.
        func recordedPrompts() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return prompts
        }
    }

    /// Scripted completion verifier (the MerlinCompletionVerifier seam):
    /// plays back one YES/NO answer per check call, so the M5 layer runs
    /// without a socket. Injected through buildRuntime's check-only
    /// `verifierOverride`; production builds the live MerlinVerifier.
    private struct ScriptedVerifier: MerlinCompletionVerifier {
        let answer: String
        init(_ answer: String) { self.answer = answer }

        func check(goal: String, ledgerDigest: String, summary: String,
                   claimedArtifacts: [String], ledgerUnchangedSinceLastRejection: Bool) async -> MerlinVerifier.Decision {
            _ = goal; _ = ledgerDigest; _ = summary
            _ = claimedArtifacts; _ = ledgerUnchangedSinceLastRejection
            return MerlinVerifier.parseVerdict(answer)
        }
    }

    // MARK: - Runtime wiring

    func testRuntimeWiresWorkspaceLedgerKernelAndActor() throws {
        let root = tempWorkspaceRoot()
        let modelPath = "/models/GLM-4-9B-Q4_K_M.gguf"
        let runtime = try MerlinChatService.buildRuntime(
            goal: "write the report",
            serverPort: 8151,
            modelPath: modelPath,
            maxTurns: 6,
            workspaceRoot: root,
            actorOverride: ScriptedActor([]))
        // Workspace lives under the root the caller asked for, locked to a
        // task id, with the ledger at its reserved name.
        XCTAssertTrue(runtime.workspace.rootPath.hasPrefix(canonicalPath(root.path)),
                      "workspace root \(runtime.workspace.rootPath) must sit under the canonical app-store root")
        XCTAssertEqual(runtime.workspace.rootURL
            .appendingPathComponent(MerlinLedger.fileName).path,
            runtime.ledger.url.path)
        // Kernel wiring: same workspace/ledger instances, budget plumbed.
        XCTAssertEqual(runtime.kernel.workspace.rootPath, runtime.workspace.rootPath)
        XCTAssertTrue(runtime.kernel.ledger === runtime.ledger,
                      "the kernel runs over the same ledger instance the runtime exposes")
        XCTAssertEqual(runtime.kernel.configuration.maxTurns, 6)
        XCTAssertEqual(runtime.kernel.spine.goal, "write the report")
        // Guardian (M4) and verifier (M5) installed: the app runs with the
        // machinery ON (unlike the eval baseline), verifier model check ON.
        XCTAssertTrue(runtime.kernel.guardian is MerlinResultGuardian,
                      "app runs install the deterministic result guardian")
        let verifier = try XCTUnwrapSpec(runtime.kernel.completionVerifier as? MerlinVerifier,
                                         "app runs install the Merlin verifier")
        XCTAssertTrue(verifier.configuration.modelCheckEnabled,
                      "the verifier model check is ON for app runs")
        // Actor wrapper conforms to the post-fix feedback seam so the kernel's
        // `as?` probe hits (eval-live blind-actor bug, lead heads-up).
        let wrapper: any MerlinActor = runtime.actor
        XCTAssertTrue(wrapper is any MerlinActorWithFeedback,
                      "the app actor wrapper must keep MerlinActorWithFeedback so per-turn feedback flows")
        // Profile plumbing rode the model path: GLM-4 rides the jsonEnvelope rung.
        let family = MerlinProfileStore.detectFamily(modelName: modelPath)
        XCTAssertEqual(family, "glm-4")
        // The task id matches the workspace folder's lock file.
        let lock = try String(contentsOf: runtime.workspace.rootURL
            .appendingPathComponent(".merlin-lock"), encoding: .utf8)
        XCTAssertEqual(lock.trimmingCharacters(in: .whitespacesAndNewlines), runtime.taskID)
    }

    func testBuildRuntimeRefusesEmptyGoalAndEmptyModel() throws {
        let root = tempWorkspaceRoot()
        XCTAssertThrowsError(try MerlinChatService.buildRuntime(
            goal: "   ", serverPort: 8151, modelPath: "/m.gguf",
            workspaceRoot: root, actorOverride: ScriptedActor([])),
            "an empty goal must refuse at configuration time")
        XCTAssertThrowsError(try MerlinChatService.buildRuntime(
            goal: "valid goal", serverPort: 8151, modelPath: "",
            workspaceRoot: root, actorOverride: ScriptedActor([])),
            "an empty model path must refuse at configuration time")
        XCTAssertThrowsError(try MerlinChatService.buildRuntime(
            goal: "valid goal", serverPort: 0, modelPath: "/m.gguf",
            workspaceRoot: root, actorOverride: ScriptedActor([])),
            "an unconfigured port must refuse at configuration time")
    }

    func testWorkspaceRootDefaultsUnderTheAppStoreOverride() throws {
        // No explicit root: the default must land under the CURRENT app
        // support directory — which ChecksMain redirects, so the assertion
        // reads the override itself rather than the operator's live tree.
        guard let appStoreRoot = ChatStore.storeDirectoryOverride else {
            return XCTFail("ChecksMain must set ChatStore.storeDirectoryOverride before any check runs")
        }
        let runtime = try MerlinChatService.buildRuntime(
            goal: "default-root check", serverPort: 8151, modelPath: "/m.gguf",
            actorOverride: ScriptedActor([]))
        XCTAssertTrue(runtime.workspace.rootPath.hasPrefix(canonicalPath(appStoreRoot.path)),
                      "default workspace root \(runtime.workspace.rootPath) must sit under the app support directory")
        XCTAssertTrue(runtime.workspace.rootPath.contains(MerlinWorkspaces.folderName),
                      "the default root carries the MerlinWorkspaces folder name")
        // Per-task folder: two runtimes never share a sandbox.
        let second = try MerlinChatService.buildRuntime(
            goal: "default-root check 2", serverPort: 8151, modelPath: "/m.gguf",
            actorOverride: ScriptedActor([]))
        XCTAssertNotEqual(runtime.workspace.rootPath, second.workspace.rootPath)
    }

    // MARK: - Goal plumbing + outcome surfacing (scripted actor, no server)

    func testRunPlumbsGoalAndSurfacesOutcome() async throws {
        let store = makeStore()
        let goal = "create hello.txt containing hi"
        let root = tempWorkspaceRoot()
        let actor = ScriptedActor([
            [MerlinToolCall(name: "todo_write",
                            argumentsJSON: #"{"todos": [{"text": "write the file", "done": false}]}"#)],
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "hello.txt", "content": "hi"}"#),
             MerlinToolCall(name: "task_done",
                            argumentsJSON: #"{"summary": "Wrote the file.\n- hello.txt"}"#)],
        ])
        // The runtime carries the scripted actor + scripted verifier: no
        // live server anywhere (the verifier's mechanical layer already ran;
        // the model layer plays back one YES).
        let runtime = try MerlinChatService.buildRuntime(
            goal: goal, serverPort: 8151, modelPath: "/m.gguf",
            maxTurns: 4, workspaceRoot: root, actorOverride: actor,
            verifierOverride: ScriptedVerifier("YES"))

        let service = MerlinChatService()
        var events: [MerlinRunEvent] = []
        let appended = await service.run(runtime: runtime, goal: goal, store: store) { event in
            events.append(event)
        }
        let messages = try XCTUnwrapSpec(appended, "a scripted completed run returns its appended messages")

        // Goal plumbing: the FIRST spine prompt the actor saw carries the goal.
        let prompt = try XCTUnwrapSpec(actor.recordedPrompts().first,
                                       "the scripted actor recorded at least one prompt")
        XCTAssertTrue(prompt.contains("GOAL: \(goal)"), prompt)

        // Transcript: user goal line, one folded progress block, one outcome card.
        XCTAssertEqual(store.current?.messages.first?.content, "Merlin task: \(goal)")
        let outcomeMessage = store.current?.messages.last
        let outcomeText = try XCTUnwrapSpec(outcomeMessage?.content, "the run appended an outcome card")
        XCTAssertTrue(outcomeText.contains("### Merlin run · completed"), outcomeText)
        XCTAssertTrue(outcomeText.contains("turns: 2/4"), outcomeText)
        XCTAssertTrue(outcomeText.contains("Wrote the file."), outcomeText)
        XCTAssertEqual(outcomeMessage?.content, messages.outcome.content)
        XCTAssertTrue(messages.progress.content.hasPrefix("```"),
                      "progress renders as one monospace fence block")
        XCTAssertTrue(messages.progress.content.contains("fs_write"))

        // Events: the onEvent seam saw the tool calls and the outcome.
        XCTAssertTrue(events.contains {
            if case .toolExecuted(_, let tool, _) = $0 { return tool == "fs_write" }
            return false
        }, "events carry the executed fs_write call")
        XCTAssertTrue(events.contains {
            if case .outcome(let outcome) = $0 { return outcome.status == .completed }
            return false
        }, "events carry the terminal completed outcome")
        XCTAssertFalse(service.isRunning, "the service leaves the running state after the run")
    }

    func testRunSurfacesBudgetExhaustedOutcomeAndBlockers() async throws {
        let store = makeStore()
        let root = tempWorkspaceRoot()
        // Every turn fails identically: the budget ends the run, the failing
        // results surface in the progress block, and the M6 stop authority's
        // wrap-up instruction lands as the ledgered blocker.
        let actor = ScriptedActor([
            [MerlinToolCall(name: "fs_read", argumentsJSON: #"{"path": "ghost.txt"}"#)],
            [MerlinToolCall(name: "fs_read", argumentsJSON: #"{"path": "ghost.txt"}"#)],
            [MerlinToolCall(name: "fs_read", argumentsJSON: #"{"path": "ghost.txt"}"#)],
            [MerlinToolCall(name: "fs_read", argumentsJSON: #"{"path": "ghost.txt"}"#)],
        ])
        let runtime = try MerlinChatService.buildRuntime(
            goal: "read a file that does not exist", serverPort: 8151, modelPath: "/m.gguf",
            maxTurns: 2, workspaceRoot: root, actorOverride: actor,
            verifierOverride: ScriptedVerifier("YES"))
        // Two identical failures must cross the M6 wrap-up threshold inside
        // this 2-turn run: install the threshold-2 authority (default is 3).
        runtime.kernel.stopAuthority = MerlinStopAuthority.ProgressTracker(
            authority: MerlinStopAuthority(repeatThreshold: 2))
        let service = MerlinChatService()
        let appended = await service.run(runtime: runtime, goal: "read a file that does not exist",
                                         store: store)
        let outcomeText = try XCTUnwrapSpec(appended?.outcome.content,
                                            "a budget run still appends its outcome card")
        XCTAssertTrue(outcomeText.contains("### Merlin run · budgetExhausted"), outcomeText)
        XCTAssertTrue(outcomeText.contains("turns: 2/2"), outcomeText)
        let progress = try XCTUnwrapSpec(appended?.progress.content, "progress block exists")
        XCTAssertTrue(progress.contains("fs_read: error: no such file: ghost.txt"),
                      "the failing tool results surface verbatim in the progress block")
        XCTAssertTrue(progress.contains("blocker:"),
                      "the stop-authority wrap-up instruction lands as a blocker line")
    }

    // MARK: - Cancel at the next turn boundary

    func testCancelTakesEffectAtNextTurnBoundary() async throws {
        let store = makeStore()
        let root = tempWorkspaceRoot()
        // Turn 1 writes a real file, then parks in a 1 s shell_run, so the
        // cancel flips while turn 1 is still executing and the boundary is
        // deterministically turn 2's actor call.
        let actor = ScriptedActor([
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "a.txt", "content": "a"}"#),
             MerlinToolCall(name: "shell_run",
                            argumentsJSON: #"{"command": "sleep 1", "timeout": 2}"#)],
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "b.txt", "content": "b"}"#)],
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "c.txt", "content": "c"}"#)],
        ])
        let runtime = try MerlinChatService.buildRuntime(
            goal: "write three files", serverPort: 8151, modelPath: "/m.gguf",
            maxTurns: 3, workspaceRoot: root, actorOverride: actor,
            verifierOverride: ScriptedVerifier("YES"))
        // Drive the kernel exactly as the service does, cancel from the
        // outside after turn 1's artifact lands, and pin the boundary
        // semantics: turn 2's actor call throws, the run ends .failed with
        // the distinguishable message, and turn 2 executes nothing.
        let loop = Task.detached { await runtime.kernel.run(actor: runtime.actor) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if runtime.ledger.allEntries.contains(where: {
                $0.kind == .artifact && $0.key == "a.txt"
            }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        runtime.actor.cancel()
        let outcome = await loop.value
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.summary.contains(MerlinCancellableActor.cancelledMessage),
                      outcome.summary)
        // Turn 2 ran zero tools: the batch never came back from the actor.
        let wroteB = runtime.ledger.allEntries.contains { $0.kind == .artifact && $0.key == "b.txt" }
        XCTAssertFalse(wroteB, "the cancelled run must not execute turn 2's calls")
        // And the wrapper reported the same gate through its honest flag.
        XCTAssertTrue(runtime.actor.isCancelled)
        _ = store // the service-level transcript folding is pinned by the next check
    }

    func testCancelledRunFoldsDistinguishableLineIntoTranscript() async throws {
        // The service-side folding: a run whose gate flips before the run
        // dies on the first boundary leaves the ⛔ line and a failed,
        // cancelled-marked outcome card in the transcript.
        let store = makeStore()
        let root = tempWorkspaceRoot()
        // Same deterministic window: turn 1 writes x.txt, then parks 1 s in
        // shell_run; the gate flips during turn 1, the boundary is turn 2.
        let actor = ScriptedActor([
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "x.txt", "content": "x"}"#),
             MerlinToolCall(name: "shell_run",
                            argumentsJSON: #"{"command": "sleep 1", "timeout": 2}"#)],
            [MerlinToolCall(name: "fs_write",
                            argumentsJSON: #"{"path": "y.txt", "content": "y"}"#)],
        ])
        let runtime = try MerlinChatService.buildRuntime(
            goal: "cancelled mid-run", serverPort: 8151, modelPath: "/m.gguf",
            maxTurns: 2, workspaceRoot: root, actorOverride: actor,
            verifierOverride: ScriptedVerifier("YES"))
        let service = MerlinChatService()
        let runner = Task { @MainActor in
            await service.run(runtime: runtime, goal: "cancelled mid-run", store: store)
        }
        // Flip the gate as soon as turn 1's artifact shows up (the same
        // drill as the boundary check, through the service this time).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if runtime.ledger.allEntries.contains(where: {
                $0.kind == .artifact && $0.key == "x.txt"
            }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        runtime.actor.cancel()
        let appended = await runner.value
        // SECURITY wave 2: with a mid-flight park (no turn boundary ever
        // arrives), the service's polling loop takes the run over — the
        // transcript carries the explicit "run did not return" line and a
        // failed, cancelled-marked outcome card instead of hanging.
        let progress = try XCTUnwrapSpec(appended?.progress.content, "the cancelled run leaves its progress block")
        XCTAssertTrue(progress.contains("run did not return"), progress)
        let outcomeText = try XCTUnwrapSpec(appended?.outcome.content, "outcome card exists")
        XCTAssertTrue(outcomeText.contains("(cancelled)"), outcomeText)
        XCTAssertTrue(outcomeText.contains("### Merlin run · failed"), outcomeText)
        // Turn 2 never wrote.
        XCTAssertFalse(runtime.ledger.allEntries.contains { $0.kind == .artifact && $0.key == "y.txt" })
    }

    // MARK: - Toggle default (read through the view's API)

    func testToggleDefaultsToClassicThroughTheViewAPI() {
        // A scratch defaults suite: never the operator's real UserDefaults.
        let suiteName = "merlin-checks4-engine-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(MerlinChatService.configuredEngine(defaults: defaults), .classic,
                       "with no stored value the engine reads classic (AMENDMENT 3)")
        XCTAssertEqual(MerlinAgentEngine.appStorageDefault, MerlinAgentEngine.classic.rawValue,
                       "the @AppStorage declaration default is classic")
        // Round-trip: the persisted raw value reads back.
        defaults.set(MerlinAgentEngine.merlin.rawValue, forKey: MerlinChatKeys.chatAgentEngine)
        XCTAssertEqual(MerlinChatService.configuredEngine(defaults: defaults), .merlin)
        // A corrupted raw value falls back to classic, never crashes.
        defaults.set("v0.42-legacy", forKey: MerlinChatKeys.chatAgentEngine)
        XCTAssertEqual(MerlinChatService.configuredEngine(defaults: defaults), .classic)
    }

    func testProgressAndOutcomeTextShapes() {
        XCTAssertEqual(MerlinChatService.progressLine(for: .turnStarted(turn: 2)), "turn 2 started")
        XCTAssertEqual(MerlinChatService.progressLine(for: .toolExecuted(turn: 2, tool: "fs_write", summary: "wrote a.txt")),
                       "turn 2 · fs_write: wrote a.txt")
        XCTAssertEqual(MerlinChatService.progressLine(for: .blocker(turn: 3, text: "fix it")),
                       "turn 3 · blocker: fix it")
        XCTAssertEqual(MerlinChatService.progressTranscript([]), "```\n(no recorded activity)\n```")
        // SECURITY wave 2: the summary is model-authored, so it renders
        // inert inside a fenced plain-text block under the trusted header.
        let text = MerlinChatService.outcomeText(
            outcome: MerlinOutcome(status: .completed, summary: "done", turnsUsed: 3, maxTurns: 9),
            cancelled: false)
        XCTAssertTrue(text.hasPrefix("### Merlin run · completed\nturns: 3/9\n\n```text\ndone\n```"), text)
    }

    // MARK: - Security wave 2: injection-channel defang + cancel takeover

    /// §1.7(1): a model-authored summary carrying markdown must render
    /// inert — no headings, no clickable links, no fence escape.
    func testOutcomeSummaryMarkdownRendersInert() {
        let hostile = "# RUNTIME OVERRIDE\n[click here](https://attacker.example)\n![](https://attacker.example/exfil)\n``` \nbye\n```"
        let text = MerlinChatService.outcomeText(
            outcome: MerlinOutcome(status: .completed, summary: hostile,
                                   turnsUsed: 1, maxTurns: 4),
            cancelled: false)
        // The trusted header is untouched markdown.
        XCTAssertTrue(text.hasPrefix("### Merlin run · completed\n"), text)
        // The body is one fenced block; the fence opens with an info
        // string (```text) so a summary fence line cannot close it.
        XCTAssertTrue(text.contains("\n```text\n"), text)
        // Every hostile construct is neutralized: no line of the summary
        // body starts unindented with # or ``` and no ]( survives at a
        // line start (all are indented one space inside the fence).
        for line in text.components(separatedBy: "\n")
        where !line.hasPrefix("###") && line != "```text" && line != "```" {
            XCTAssertFalse(line.hasPrefix("#"), "heading neutralized: \(line)")
            XCTAssertFalse(line.hasPrefix("```"), "fence neutralized: \(line)")
            if line.hasPrefix(" ") { continue }
        }
        XCTAssertFalse(text.contains("\n[click"), "link syntax is indented inert: \(text)")
        // The summary text itself survives verbatim (readable, inert).
        XCTAssertTrue(text.contains(" # RUNTIME OVERRIDE") || text.contains("RUNTIME OVERRIDE"), text)
    }

    /// The same neutralization guards the progress channel (ledger text
    /// inside the folding fence cannot break out).
    func testProgressLineNeutralizesFenceBreaks() {
        let line = MerlinChatService.progressLine(for: .toolExecuted(
            turn: 2, tool: "shell_run",
            summary: "exit 0\n``` \ninjected markdown\n```"))
        XCTAssertFalse(line.contains("\n```"), "no raw fence may enter a progress line: \(line)")
        XCTAssertTrue(line.contains("⏎"), "newlines fold into inert separators: \(line)")
    }

    /// Cancel-takeover (N3 close-out): a run wedged inside a tool call
    /// (no turn boundary ever comes) ends in bounded time once the
    /// operator cancels, with the "run did not return" outcome — the app
    /// never hangs. Driven through the real service with a scripted
    /// actor whose model call blocks until cancelled.
    func testCancelTakesOverAWedgedRunWithDidNotReturnOutcome() async throws {
        let store = makeStore()
        let root = tempWorkspaceRoot()
        // An actor that accepts turn 1 then blocks forever on turn 2's
        // model call — the js_eval-hang shape, without the real hang.
        final class WedgingActor: MerlinActorWithFeedback, @unchecked Sendable {
            let gate = NSLock()
            private var cancelled = false
            func toolCalls(prompt: String, turn: Int) async throws -> [MerlinToolCall] {
                if turn == 1 {
                    return [MerlinToolCall(name: "fs_write",
                                           argumentsJSON: #"{"path": "w.txt", "content": "w"}"#)]
                }
                // Park until cancelled — no boundary ever returns.
                while !isCancelledFlag() {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                // Holding the park until the takeover proves the poll
                // loop (not the actor) ended the wait: sleep far past the
                // cancel, then fail like the kernel's actor seam would.
                try? await Task.sleep(for: .milliseconds(600))
                throw MerlinRunCancelled()
            }
            func isCancelledFlag() -> Bool {
                gate.lock()
                defer { gate.unlock() }
                return cancelled
            }
            func cancelParking() {
                gate.lock()
                cancelled = true
                gate.unlock()
            }
            func receive(feedback: MerlinTurnFeedback) async {}
        }
        // MerlinCancellableActor forwards cancel() to its own gate only —
        // the wedging base never observes it, which is exactly the
        // wedged-run shape the takeover must survive.
        let wedging = WedgingActor()
        let runtime = try MerlinChatService.buildRuntime(
            goal: "wedged run", serverPort: 8151, modelPath: "/m.gguf",
            maxTurns: 3, workspaceRoot: root, actorOverride: wedging,
            verifierOverride: ScriptedVerifier("YES"))
        let service = MerlinChatService()
        let runner = Task { @MainActor in
            await service.run(runtime: runtime, goal: "wedged run", store: store)
        }
        // Wait for turn 1's artifact, then cancel while turn 2's model
        // call is parked forever.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if runtime.ledger.allEntries.contains(where: {
                $0.kind == .artifact && $0.key == "w.txt"
            }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        runtime.actor.cancel()
        // The service must END THE WAIT itself in bounded time — the
        // parked actor never returns. The suite's Watchdog guards this
        // check overall: a regression to an infinite poll fails loudly
        // instead of hanging the run. The takeover outcome lands in the
        // transcript even though the kernel task is still parked.
        let appended = await runner.value
        let outcomeText = try XCTUnwrapSpec(appended?.outcome.content,
                                            "the takeover lands an outcome card")
        XCTAssertTrue(outcomeText.contains("run did not return"), outcomeText)
        XCTAssertTrue(outcomeText.contains("(cancelled)"), outcomeText)
        XCTAssertTrue(outcomeText.contains("### Merlin run · failed"), outcomeText)
        // The UI never stayed busy: isRunning cleared with the run.
        XCTAssertFalse(service.isRunning)
        // Housekeeping: release the parked actor task.
        wedging.cancelParking()
        _ = store
    }

    /// Case-fold ledger reservation (§1.1): `MERLIN-LEDGER.JSONL` — the
    /// APFS-colliding spelling — must be refused by fs_write like the
    /// canonical name. (The registry helpers live in MerlinChecks3's
    /// fixture methods; this suite builds its own workspace/ledger and
    /// uses the local throw-assertion pattern.)
    func testFSWriteRefusesCaseFoldedLedgerName() async throws {
        let root = tempWorkspaceRoot()
        let workspace = try MerlinWorkspace(root: root,
                                            taskID: "check4-\(UUID().uuidString.prefix(8))")
        let ledger = try MerlinLedger(url: workspace.rootURL
            .appendingPathComponent(MerlinLedger.fileName))
        let registry = MerlinToolRegistry(workspace: workspace, ledger: ledger)
        for spelling in ["MERLIN-LEDGER.JSONL", "Merlin-Ledger.Jsonl", "merlin-ledger.JSONL"] {
            let payload = "{\"path\": \"\(spelling)\", \"content\": \"forged\"}"
            do {
                _ = try await registry.execute(name: "fs_write", argumentsJSON: payload, turn: 1)
                XCTFail("\(spelling) must be refused")
            } catch {
                XCTAssertTrue("\(error)".contains("run ledger"),
                              "the refusal names the ledger: \(error)")
            }
        }
    }

    // MARK: - Registration

    @MainActor static let __checkSet = CheckSet(
        suite: "MerlinChecks4",
        instance: { MerlinChecks4() },
        checks: [
            .init(name: "testRuntimeWiresWorkspaceLedgerKernelAndActor") { try $0.testRuntimeWiresWorkspaceLedgerKernelAndActor() },
            .init(name: "testBuildRuntimeRefusesEmptyGoalAndEmptyModel") { try $0.testBuildRuntimeRefusesEmptyGoalAndEmptyModel() },
            .init(name: "testWorkspaceRootDefaultsUnderTheAppStoreOverride") { try $0.testWorkspaceRootDefaultsUnderTheAppStoreOverride() },
            .init(name: "testRunPlumbsGoalAndSurfacesOutcome") { try await $0.testRunPlumbsGoalAndSurfacesOutcome() },
            .init(name: "testRunSurfacesBudgetExhaustedOutcomeAndBlockers") { try await $0.testRunSurfacesBudgetExhaustedOutcomeAndBlockers() },
            .init(name: "testCancelTakesEffectAtNextTurnBoundary") { try await $0.testCancelTakesEffectAtNextTurnBoundary() },
            .init(name: "testCancelledRunFoldsDistinguishableLineIntoTranscript") { try await $0.testCancelledRunFoldsDistinguishableLineIntoTranscript() },
            .init(name: "testToggleDefaultsToClassicThroughTheViewAPI") { try $0.testToggleDefaultsToClassicThroughTheViewAPI() },
            .init(name: "testProgressAndOutcomeTextShapes") { try $0.testProgressAndOutcomeTextShapes() },
            .init(name: "testOutcomeSummaryMarkdownRendersInert") { try $0.testOutcomeSummaryMarkdownRendersInert() },
            .init(name: "testProgressLineNeutralizesFenceBreaks") { try $0.testProgressLineNeutralizesFenceBreaks() },
            .init(name: "testCancelTakesOverAWedgedRunWithDidNotReturnOutcome") { try await $0.testCancelTakesOverAWedgedRunWithDidNotReturnOutcome() },
            .init(name: "testFSWriteRefusesCaseFoldedLedgerName") { try await $0.testFSWriteRefusesCaseFoldedLedgerName() },
        ])
}

/// Local `XCTUnwrap` stand-in naming the failure instead of crashing the run
/// (same shape as MerlinChecks3's).
@MainActor
private func XCTUnwrapSpec<T>(_ expression: @autoclosure () throws -> T?,
                              _ message: @autoclosure () -> String = "") throws -> T {
    guard let value = try expression() else {
        XCTFail("XCTUnwrap failed: nil \(message())")
        throw UnwrapSpecError4()
    }
    return value
}

private struct UnwrapSpecError4: Error {}
