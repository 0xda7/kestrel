// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// MISSION MERLIN slice 5 (app-1, 2026-11-15): Merlin surfaces in the Kestrel
// app behind a toggle (AMENDMENT 3 shape, conservative).
//
// This file owns the whole app-facing Merlin surface except two surgical
// view hunks (ChatTab.swift context menu, ChatAdvancedSettingsSection.swift
// picker) that mount it. ChatNative.swift is deliberately untouched; the
// service renders its results by appending ChatMessage values into the
// ChatStore transcript through the store's existing state.
//
// .agents/missions/2026-11-15-merlin/plan.md §3 + AMENDMENT 3 are the
// binding contract for what lands where.

import Foundation
import SwiftUI

// MARK: - Settings key (declared here on purpose)

/// Persisted key for the chat agent-engine toggle. NOT declared in
/// App/Support.swift: that file is outside this slice's writable set, and
/// the two self-enforcing settings laws (SettingsCompletenessTests,
/// SettingsUsageLintTests) both PARSE Support.swift's SettingsKeys block as
/// their source of truth — a constant declared anywhere else would evade
/// them either way. Declaring the constant beside its only two readers (the
/// picker and this service) keeps every reader on one symbol. If Merlin's
/// default ever flips to ON (an operator-approved moment), the key should
/// move to SettingsKeys with its reset-list decision made explicitly.
enum MerlinChatKeys {
    /// Raw value of `MerlinAgentEngine`. Default classic per AMENDMENT 3.
    static let chatAgentEngine = "chatAgentEngine"
}

/// Which agent engine the chat runs. Raw-value persisted exactly like
/// `ConversationSortOrder` (ChatNative.swift @AppStorage(SettingsKeys.chatSortOrder)
/// pattern); the default is "classic" per AMENDMENT 3: flipping the default
/// is an operator-approved moment after the eval gate passes.
enum MerlinAgentEngine: String, CaseIterable {
    /// The legacy loop in ChatNative.swift — untouched this release (rollback path).
    case classic
    /// The new small-model agent kernel (Sources/Merlin), driven by MerlinChatService.
    case merlin

    /// The default through the SAME API the settings view reads
    /// (`@AppStorage(MerlinChatKeys.chatAgentEngine)`), so a missing stored
    /// value can never disagree between the view, the composer, and checks.
    static let appStorageDefault = MerlinAgentEngine.classic.rawValue
}

/// Persisted under the operator's Application Support dir (never the
/// operator's ~/.kestrel tree — the app's store-dir convention wins, and the
/// check harness already redirects every AppSupport-rooted path through
/// AppSupport.directoryOverride so no check can write the live tree).
enum MerlinWorkspaces {
    static let folderName = "MerlinWorkspaces"

    /// AppSupport/Kestrel/MerlinWorkspaces/<uuid>/ per task.
    static func root() -> URL {
        AppSupport.directory.appendingPathComponent(folderName, isDirectory: true)
    }
}

// MARK: - Progress events (what the UI can show live)

/// Streaming-adjacent progress callback events. The kernel has no
/// progress-callback seam of its own (checked 2026-11-15: the loop is
/// `run(actor:) -> MerlinOutcome` only), so the service derives these from
/// the ledger — the kernel appends one entry per tool call, guardian
/// verdict, blocker, and completion, and the ledger file IS that trace.
enum MerlinRunEvent: Equatable {
    /// A turn started (the kernel asked the actor for a batch).
    case turnStarted(turn: Int)
    /// A tool call finished executing (text as the kernel ledgers it).
    case toolExecuted(turn: Int, tool: String, summary: String)
    /// A blocker landed (guardian rejection, verifier rejection, wrap-up advisory).
    case blocker(turn: Int, text: String)
    /// The run reached a terminal outcome.
    case outcome(MerlinOutcome)
}

// MARK: - Cancellation (kernel-visible flag)

/// Kernel-visible cancellation wrapper around the real actor.
///
/// THE CLEAN SEAM, answered from the kernel source: `MerlinKernel.run(actor:)`
/// has no cancellation parameter, no Task.isCancelled check, and no abort
/// flag (kernel-2/kernel-3 shape, 2026-11-15). The honest implementation
/// wraps the actor: once cancelled it refuses the NEXT `toolCalls` call with
/// a distinguishable error, so the kernel ends the run as `.failed` with the
/// message below and the service folds that into the outcome card. A
/// mid-flight model completion or tool execution is NOT interrupted — a
/// documented limitation of this slice, stated in the UI help text too.
final class MerlinCancellableActor: MerlinActorWithFeedback, @unchecked Sendable {
    private let base: any MerlinActor
    private let lock = NSLock()
    private var cancelled = false

    init(_ base: any MerlinActor) { self.base = base }

    /// Flips the gate. Takes effect at the next turn boundary.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Cancellation state, exposed for checks. Synchronous on purpose:
    /// Swift 6 forbids taking an NSLock inside an async function (the
    /// MerlinChecks3 drill), so async callers go through this accessor.
    var isCancelled: Bool { _isCancelled() }

    private func _isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// The distinguishable failure text the kernel ledgers and the service
    /// recognizes when folding the outcome.
    static let cancelledMessage = "cancelled by the operator"

    func toolCalls(prompt: String, turn: Int) async throws -> [MerlinToolCall] {
        if _isCancelled() {
            throw MerlinRunCancelled()
        }
        return try await base.toolCalls(prompt: prompt, turn: turn)
    }

    /// Feedback hand-back (post-fix shape, kernel-3 slice 3b): the wrapper
    /// CONFORMS to MerlinActorWithFeedback and forwards to the transcript-
    /// keeping base actor, so the kernel's `as?` probe hits and the app path
    /// shows the model its own history exactly like the headless runs.
    /// (Conformance — not an `as?` inside the kernel — was the lead's check:
    /// a plain MerlinActor wrapper would silently reproduce the eval-live
    /// blind-actor bug the fix landed against.)
    func receive(feedback: MerlinTurnFeedback) async {
        if let feedbackBase = base as? any MerlinActorWithFeedback {
            await feedbackBase.receive(feedback: feedback)
        }
    }
}

/// Typed cancellation error (thrown at the actor seam only — the kernel
/// catches it there and ends the run as `.failed`).
struct MerlinRunCancelled: Error, CustomStringConvertible {
    var description: String { MerlinCancellableActor.cancelledMessage }
}

/// Hand-off box for the kernel loop's terminal outcome: the detached loop
/// task stores once, the polling loop takes once. `@unchecked Sendable` is
/// honest — the only mutable state is NSLock-guarded.
final class MerlinOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: MerlinOutcome?

    func store(_ outcome: MerlinOutcome) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    func take() -> MerlinOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

// MARK: - The service

/// One Merlin run inside the app: builds the full kernel stack for the
/// task, runs it against the app's ACTIVE server/model selection (no second
/// server spawn — AMENDMENT 3), reports progress as it goes, and folds the
/// terminal outcome into transcript messages. @MainActor like the ChatStore
/// it writes into; the kernel loop runs on a child task.
@MainActor
final class MerlinChatService: ObservableObject {
    /// Thrown by the runtime builder when the app cannot support a Merlin run.
    struct ServiceError: LocalizedError, Equatable {
        let errorDescription: String?
    }

    /// What a finished run appended to the transcript, for checks.
    struct AppendedMessages: Equatable {
        let user: ChatMessage
        let progress: ChatMessage
        let outcome: ChatMessage
    }

    // MARK: Published UI state

    /// True while a run is in flight; the context menu hides its run entry.
    @Published private(set) var isRunning = false

    private var cancellable: MerlinCancellableActor?

    /// The polling loop's hard wall guard (N3 close-out). Far above any
    /// legal run: 12 turns × (4 calls × 30 s shell cap + model budget) sits
    /// well under 600 s; a run still going at the deadline is wedged inside
    /// a tool that cannot return (the js_eval class of hang) and is
    /// abandoned client-side with a "run did not return" outcome.
    static let runWallGuardSeconds: TimeInterval = 600

    // MARK: Settings seam (same API the settings view reads)

    /// Reads the persisted engine through UserDefaults with the declared
    /// default — the identical lookup an `@AppStorage` binding performs.
    static func configuredEngine(defaults: UserDefaults = .standard) -> MerlinAgentEngine {
        MerlinAgentEngine(rawValue: defaults.string(forKey: MerlinChatKeys.chatAgentEngine)
                          ?? MerlinAgentEngine.appStorageDefault) ?? .classic
    }

    // MARK: Runtime construction (scripted-actor injectable for checks)

    /// Everything a run needs, built before the loop starts. Split out of
    /// `run` so checks can pin the wiring (workspace root under the app
    /// store, profile by model path, verifier ON) without a live server.
    struct Runtime {
        let workspace: MerlinWorkspace
        let ledger: MerlinLedger
        let kernel: MerlinKernel
        let actor: MerlinCancellableActor
        let taskID: String
    }

    /// Builds the runtime: MerlinWorkspace + MerlinLedger + MerlinTaskSpine +
    /// MerlinKernel, LlamaServerActor on ProfileStore.profile(for: modelPath),
    /// MerlinResultGuardian + MerlinVerifier with the model check ON (app
    /// runs, unlike eval baselines), all wrapped in the cancelling actor.
    ///
    /// `actorOverride` and `verifierOverride` exist ONLY for checks: they
    /// substitute scripted doubles so no check ever opens a socket (the live
    /// verifier POSTs to the engine endpoint). Production passes nil for both.
    nonisolated static func buildRuntime(goal: String,
                                         serverPort: Int,
                                         modelPath: String,
                                         maxTurns: Int = 12,
                                         workspaceRoot: URL? = nil,
                                         profileStore: MerlinProfileStore = MerlinProfileStore(),
                                         actorOverride: (any MerlinActor)? = nil,
                                         verifierOverride: (any MerlinCompletionVerifier)? = nil) throws -> Runtime {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            throw ServiceError(errorDescription: "the task description is empty")
        }
        guard !modelPath.isEmpty else {
            throw ServiceError(errorDescription: "choose a model before running a Merlin task")
        }
        guard serverPort > 0 else {
            throw ServiceError(errorDescription: "the engine port is not configured")
        }

        let taskID = UUID().uuidString
        let root = workspaceRoot ?? MerlinWorkspaces.root()
            .appendingPathComponent(taskID, isDirectory: true)
        let workspace = try MerlinWorkspace(root: root, taskID: taskID)
        let ledger = try MerlinLedger(url: workspace.rootURL
            .appendingPathComponent(MerlinLedger.fileName))
        let profile = profileStore.profile(for: modelPath)
        let serverURL = URL(string: "http://127.0.0.1:\(serverPort)")!
        // The think-budget gate is LOUD by design (M8, binding rule 3): a
        // budget below floor + headroom refuses here, before any model call,
        // instead of starving a thinking model into inaction.
        let base = try actorOverride ?? LlamaServerActor(
            serverURL: serverURL,
            modelPath: modelPath,
            profile: profile,
            maxTokens: profile.minCompletionTokens + MerlinModelProfile.actionHeadroom)
        let spine = MerlinTaskSpine(goal: trimmedGoal, maxTurns: maxTurns)
        let kernel = MerlinKernel(workspace: workspace, ledger: ledger, spine: spine,
                                  configuration: MerlinKernel.Configuration(maxTurns: maxTurns))
        // M4 deterministic post-conditions + M5 adversarial verifier with the
        // model layer ON — the SCORING.md §7 "machinery off" baseline is the
        // eval-only configuration; kernel runs default the verifier on.
        kernel.guardian = MerlinResultGuardian(workspace: workspace, ledger: ledger)
        if let verifierOverride {
            kernel.completionVerifier = verifierOverride
        } else {
            kernel.completionVerifier = MerlinVerifier(
                workspace: workspace,
                client: LlamaVerifierClient(serverURL: serverURL),
                configuration: MerlinVerifier.Configuration())
        }
        let cancellable = MerlinCancellableActor(base)
        return Runtime(workspace: workspace, ledger: ledger, kernel: kernel,
                       actor: cancellable, taskID: taskID)
    }

    // MARK: Running

    /// Runs one Merlin task end to end, reporting progress through `onEvent`
    /// and appending the transcript messages to the given store. Returns the
    /// three appended messages for checks; nil when a run is already active.
    ///
    /// `onEvent` is called ON the main actor (the service is @MainActor), so
    /// a SwiftUI surface can update per turn without a streaming protocol.
    @discardableResult
    func run(goal: String,
             serverPort: Int,
             modelPath: String,
             store: ChatStore,
             onEvent: ((MerlinRunEvent) -> Void)? = nil) async -> AppendedMessages? {
        let runtime: Runtime
        do {
            runtime = try Self.buildRuntime(goal: goal, serverPort: serverPort,
                                            modelPath: modelPath)
        } catch {
            let message = (error as? ServiceError)?.errorDescription
                ?? error.localizedDescription
            store.appendErrorNotice(message)
            return nil
        }
        return await run(runtime: runtime, goal: goal, store: store, onEvent: onEvent)
    }

    /// The runtime-injected variant: production goes through `run(goal:…)`
    /// above; checks hand in a runtime built over a scripted actor so no
    /// check ever constructs a live server actor or opens a socket.
    @discardableResult
    func run(runtime: Runtime,
             goal: String,
             store: ChatStore,
             onEvent: ((MerlinRunEvent) -> Void)? = nil) async -> AppendedMessages? {
        guard !isRunning else { return nil }

        isRunning = true
        cancellable = runtime.actor
        defer {
            isRunning = false
            cancellable = nil
        }

        // The user goal enters the transcript as a normal user message first
        // (the run keeps its context in the ledger; the transcript shows what
        // was asked), then progress accumulates in one folding block, then
        // the outcome card lands as its own message.
        let userMessage = ChatMessage(role: "user", content: "Merlin task: \(goal)")
        store.appendExternalMessage(userMessage)

        // Kernel loop on a detached task; progress polling in THIS (main
        // actor) context. The kernel has no progress seam
        // (MerlinKernel.run returns only the final outcome), so the service
        // polls the run's ledger — the kernel's own durable per-call trace —
        // on the documented polling design, folding each new entry into a
        // progress line as it lands. The loop's terminal outcome arrives
        // through a lock-guarded box (Task has no completion probe).
        let kernel = runtime.kernel
        let actor = runtime.actor
        let ledger = runtime.ledger
        let box = MerlinOutcomeBox()
        let loop = Task.detached(priority: .userInitiated) {
            let result = await kernel.run(actor: actor)
            box.store(result)
        }
        var reported = 0
        var progressLines: [String] = []
        var outcome = MerlinOutcome(status: .failed,
                                    summary: "the run ended without an outcome",
                                    turnsUsed: 0, maxTurns: kernel.configuration.maxTurns)
        // SECURITY wave 2 (N3 close-out): the polling loop is bounded by a
        // wall guard and cancellation can TAKE OVER a wedged run. Before
        // this change, one js_eval call that never returned parked the
        // detached kernel task forever: the loop below spun at 100 ms
        // indefinitely, `isRunning` stayed true, and cancel() — which takes
        // effect only at the next turn boundary, which never came — could
        // not recover the tab. Now: a wall guard (default 600 s, above any
        // legal 12-turn run) and a cancelled flag both break the wait with
        // a synthesized "run did not return" outcome, the kernel task is
        // cancelled so its awaits unwind at their next suspension point,
        // and the transcript always gets its outcome card. The app NEVER
        // hangs on a wedged tool call.
        let wallGuard: TimeInterval = MerlinChatService.runWallGuardSeconds
        let wallDeadline = Date().addingTimeInterval(wallGuard)
        var takeover = false
        while true {
            let entries = ledger.allEntries
            if entries.count > reported {
                for entry in entries[reported...] {
                    let event = Self.event(for: entry)
                    let line = Self.progressLine(for: event)
                    progressLines.append(line)
                    onEvent?(event)
                    store.appendExternalProgress(line)
                }
                reported = entries.count
            }
            if let result = box.take() {
                outcome = result
                break
            }
            let cancelledNow = cancellable?.isCancelled ?? false
            if cancelledNow || Date() >= wallDeadline {
                takeover = true
                loop.cancel()
                let reason = cancelledNow
                    ? "run did not return (cancelled while a tool was executing; the run task was abandoned)"
                    : "run did not return (exceeded the \(Int(wallGuard)) s wall guard while a tool was executing; the run task was abandoned)"
                let lastTurn = entries.map(\.turn).max() ?? 0
                outcome = MerlinOutcome(status: .failed, summary: reason,
                                        turnsUsed: lastTurn,
                                        maxTurns: kernel.configuration.maxTurns)
                progressLines.append("⛔ " + reason)
                store.appendExternalProgress("⛔ " + reason)
                onEvent?(.outcome(outcome))
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // A cancellation surfaces as the kernel's actor-failure path with the
        // service's distinguishable message; surface it as an explicit line
        // so the transcript says what happened without parsing the summary.
        // The takeover path already appended its own explicit line.
        let cancelled = (cancellable?.isCancelled ?? false) || takeover
        if cancelled && !takeover {
            let line = "⛔ " + MerlinCancellableActor.cancelledMessage
            progressLines.append(line)
            store.appendExternalProgress(line)
        }

        // The live progress lines already live in one folding fence block in
        // the transcript (appendExternalProgress); adopt it as the run's
        // progress message instead of appending a duplicate. When no event
        // ever fired, land the explicit empty block so the run shows what it
        // did: nothing.
        let progressMessage: ChatMessage
        if let last = store.current?.messages.last,
           last.role == "assistant", last.content.hasPrefix("```") {
            progressMessage = last
        } else {
            progressMessage = ChatMessage(role: "assistant",
                                          content: Self.progressTranscript(progressLines))
            store.appendExternalMessage(progressMessage)
        }
        let outcomeMessage = ChatMessage(role: "assistant",
                                         content: Self.outcomeText(outcome: outcome,
                                                                   cancelled: cancelled))
        store.appendExternalMessage(outcomeMessage)
        onEvent?(.outcome(outcome))
        return AppendedMessages(user: userMessage,
                                progress: progressMessage,
                                outcome: outcomeMessage)
    }

    /// Cancels the in-flight run. Honest semantics: the gate flips now; the
    /// kernel observes it at the NEXT turn boundary and ends the run as a
    /// failure with the cancelled message. A mid-flight completion or tool
    /// execution is not interrupted at the kernel — but the service's
    /// polling loop (SECURITY wave 2) no longer waits forever: a cancelled
    /// flag flips through even when no boundary ever comes, taking the run
    /// over client-side with the "run did not return" outcome, so Stop
    /// ALWAYS ends the wait in bounded time (≤ ~100 ms).
    func cancel() {
        cancellable?.cancel()
    }

    // MARK: Pure text shaping (checks pin these)

    /// One progress line per event, transcript-shaped. SECURITY wave 2:
    /// ledger-derived text (`summary`, blocker text) is rendered inert by
    /// the same `plainTextLines` neutralization the outcome card uses — a
    /// ledger line carrying ``` must not break the progress fence, and a
    /// `[link](url)` shape must not survive into rendered markdown anywhere.
    static func progressLine(for event: MerlinRunEvent) -> String {
        switch event {
        case .turnStarted(let turn):
            return "turn \(turn) started"
        case .toolExecuted(let turn, let tool, let summary):
            return "turn \(turn) · \(tool): \(Self.plainTextLines(summary).joined(separator: " ⏎ "))"
        case .blocker(let turn, let text):
            return "turn \(turn) · blocker: \(Self.plainTextLines(text).joined(separator: " ⏎ "))"
        case .outcome(let outcome):
            return "outcome: \(outcome.status.rawValue) — \(Self.plainTextLines(outcome.summary).joined(separator: " ⏎ "))"
        }
    }

    /// The progress transcript block: plain monospace lines in one code
    /// fence. The kernel's ledger deliberately stores no tool arguments
    /// (M2 token-efficiency), so the existing ToolCallCard would render an
    /// empty code panel per call; the contract's documented fallback ("else
    /// plain monospace lines") is what renders.
    static func progressTranscript(_ lines: [String]) -> String {
        guard !lines.isEmpty else {
            return "```\n(no recorded activity)\n```"
        }
        return "```\n" + lines.joined(separator: "\n") + "\n```"
    }

    /// The outcome card body: status / turns / summary, headed by an H3 so
    /// the existing markdown rendering gives it a distinct block presence.
    ///
    /// SECURITY wave 2 (§1.7(1) injection channel, defanged): the summary
    /// is MODEL-AUTHORED text — under prompt injection it can carry
    /// markdown (leading `#` headings, `[link](url)` runs that render
    /// clickable, `![](img)` exfil probes, fence breaks). It is therefore
    /// rendered as PLAIN TEXT inside a fenced code block: the service-
    /// authored header stays markdown (trusted), everything after it is
    /// inert. A leading fence character in the summary itself cannot break
    /// out: the block opens with ```text (an info-string fence, which
    /// CommonMark only closes on a bare ``` fence) and summary fence lines
    /// are indented one space so they cannot match a closing fence.
    static func outcomeText(outcome: MerlinOutcome, cancelled: Bool) -> String {
        let head = "### Merlin run · \(outcome.status.rawValue)"
            + (cancelled ? " (cancelled)" : "")
        return head + "\nturns: \(outcome.turnsUsed)/\(outcome.maxTurns)\n\n"
            + Self.inertFence(Self.plainTextLines(outcome.summary))
    }

    /// Wraps `body` lines in an inert fenced block (the outcome-card and
    /// any future model-authored surface's rendering contract).
    static func inertFence(_ lines: [String]) -> String {
        "```text\n" + lines.joined(separator: "\n") + "\n```"
    }

    /// Neutralizes markdown-significant shapes in model-authored text:
    /// leading `#` markers (headings), `](` link/image tails, and any bare
    /// ``` fence line that could close a wrapper block early. One leading
    /// space per dangerous line is enough to keep every construct inert
    /// inside the fenced block — the text stays readable and verbatim.
    static func plainTextLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            var line = String(raw)
            if line.hasPrefix("#") { line = " " + line }
            if line.contains("](") { line = " " + line }
            if line.hasPrefix("```") { line = " " + line }
            return line
        }
    }

    /// Maps one fresh ledger entry to its progress event. The model's own
    /// memory writes (facts, decisions, artifacts) are not UI events — they
    /// stay in the ledger, auditable in the workspace, without flooding the
    /// transcript — so they surface as the neutral turn marker.
    static func event(for entry: MerlinLedger.Entry) -> MerlinRunEvent {
        switch entry.kind {
        case .result:
            return .toolExecuted(turn: entry.turn, tool: entry.key ?? "tool",
                                 summary: entry.text)
        case .blocker:
            return .blocker(turn: entry.turn, text: entry.text)
        case .fact, .decision, .artifact:
            return .turnStarted(turn: entry.turn)
        }
    }
}

// MARK: - ChatStore transcript seams (write-side only; ChatNative.swift untouched)

/// The service appends its messages through these seams. They live here (not
/// in ChatNative.swift) to keep this slice's edits inside its file set; they
/// only use existing internal ChatStore state (`conversations`, `currentIndex`,
/// `save()`), so no legacy-loop behavior changes.
extension ChatStore {
    /// Appends a message to the open conversation and persists the store.
    /// The service is @MainActor like the store, so the mutation is ordered.
    func appendExternalMessage(_ message: ChatMessage) {
        appendToCurrent(message)
    }

    /// Appends one progress line, folding consecutive lines into the last
    /// progress block so a 12-turn run does not grow 40 bubbles.
    func appendExternalProgress(_ line: String) {
        if let i = currentIndex,
           let last = conversations[i].messages.last,
           last.role == "assistant",
           last.content.hasPrefix("```") {
            // Fold: replace the closing fence with the new line + fence.
            var content = last.content
            if content.hasSuffix("\n```") {
                content.removeLast(4)
                content += "\n" + line + "\n```"
            } else {
                content += "\n" + line
            }
            conversations[i].messages[conversations[i].messages.count - 1].content = content
        } else {
            appendToCurrent(ChatMessage(role: "assistant",
                                        content: "```\n\(line)\n```"))
        }
    }

    /// The refusal variant used when the runtime cannot be built (no model,
    /// no port, empty goal): one short assistant line, no kernel run.
    func appendErrorNotice(_ text: String) {
        appendToCurrent(ChatMessage(role: "assistant",
                                    content: "Merlin could not start: \(text)"))
    }

    private func appendToCurrent(_ message: ChatMessage) {
        guard let i = currentIndex else { return }
        conversations[i].messages.append(message)
        conversations[i].updated = Date()
        save()
    }
}

// MARK: - The surface (AMENDMENT 3 option (a): the composer context menu)

/// Attaches the "Run as Merlin task" affordance to the chat surface. MINIMAL
/// viable surface by design (AMENDMENT 3): a context menu on the chat detail
/// that takes the CURRENT composer text — the conversation's persisted draft,
/// which the debounced draft save keeps current within a few hundred
/// milliseconds — as the goal, runs MerlinChatService, and lets the appended
/// messages render through the existing transcript.
///
/// Modifier placement: ChatTab.swift's `chatDetail` — the one view in the
/// chat surface this slice may touch — so the legacy loop in ChatNative.swift
/// stays untouched and the menu simply does not exist when the toggle is off.
struct MerlinChatContextModifier: ViewModifier {
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var loc: Localizer
    @AppStorage(MerlinChatKeys.chatAgentEngine) private var engineRaw = MerlinAgentEngine.appStorageDefault
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.port) private var port = 8080
    @StateObject private var service = MerlinChatService()

    private var engine: MerlinAgentEngine {
        MerlinAgentEngine(rawValue: engineRaw) ?? .classic
    }

    /// Merlin targets the local engine's OpenAI endpoint; a configured remote
    /// route serves chat but not the kernel's server-shaped actor, so the
    /// menu hides rather than promising a run it cannot make.
    private var canRunMerlin: Bool {
        engine == .merlin
            && server.state == .running
            && !modelPath.isEmpty
            && !service.isRunning
    }

    private var draftGoal: String? {
        guard let text = chat.current?.draft?.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if canRunMerlin {
                    Button {
                        runAsMerlinTask()
                    } label: {
                        Label(loc.t("Ejecutar como tarea Merlin", "Run as Merlin task"),
                              systemImage: "wand.and.stars")
                    }
                    .disabled(draftGoal == nil)
                    if service.isRunning {
                        Button {
                            service.cancel()
                        } label: {
                            Label(loc.t("Detener tarea Merlin", "Stop Merlin task"),
                                  systemImage: "stop.circle")
                        }
                        .help(loc.t("La parada surte efecto en el límite del próximo turno.",
                                    "The stop takes effect at the next turn boundary."))
                    }
                }
            }
    }

    private func runAsMerlinTask() {
        guard canRunMerlin, let goal = draftGoal else { return }
        // The goal leaves the composer: clear the persisted draft so the next
        // send does not re-send the same text through the legacy loop.
        if let id = chat.currentID {
            chat.updateDraft(conversationID: id, text: "", attachments: [], imageURIs: [])
        }
        let port = port
        let modelPath = modelPath
        Task { @MainActor in
            await service.run(goal: goal, serverPort: port, modelPath: modelPath,
                              store: chat)
        }
    }
}
