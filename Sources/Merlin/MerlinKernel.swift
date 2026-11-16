// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One tool call produced by the model-facing actor.
public struct MerlinToolCall: Equatable, Sendable {
    public let name: String
    /// The arguments object as raw JSON text; handlers decode it themselves.
    public let argumentsJSON: String

    public init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// The model-facing actor seam (M1).
///
/// The kernel never talks to an LLM directly: it asks an actor for one
/// BATCH of tool calls per turn and owns everything else. A turn is one
/// model completion; the actor returns one to four calls for it (the eval
/// protocol counts completions as turns, and per-call inference round-trips
/// on a 9B model make one-call turns cost-prohibitive). Slice 2 implements
/// this protocol against the bundled llama-server with grammar-constrained
/// decoding; checks script it to drive the loop deterministically.
public protocol MerlinActor: Sendable {
    /// Produce the tool-call batch for the given turn (1...4 calls).
    /// `prompt` is the task-spine system prompt for this turn. A thrown
    /// transport-class error (dead server, HTTP failure, malformed
    /// response) ends the run as a failure; a parse-class
    /// `LlamaServerActor.ActorError` (the server answered but the
    /// completion carried no usable tool call) is fed back correctively
    /// and ends the run only after the stop authority's repeat threshold
    /// of consecutive failures — see `MerlinActorFailureFeedback`.
    func toolCalls(prompt: String, turn: Int) async throws -> [MerlinToolCall]
}

/// Per-turn feedback payload (slice 3b): what the kernel executed from the
/// actor's last batch and what the runtime concluded about it.
///
/// `resultText` is the kernel-summarized model-facing text (the same
/// M2-faithful ≤200-char collapse the ledger carries), prefixed with its
/// verdict marker where one applies ("error:", "rejected by guardian:",
/// "rejected by verifier:"). The flags carry the verdict structurally so a
/// transcript-keeping actor can shape its wire turns without re-parsing
/// text.
public struct MerlinTurnFeedback: Sendable {
    /// One executed call's outcome.
    public struct CallOutcome: Sendable {
        public let call: MerlinToolCall
        public let resultText: String
        /// The handler threw (tool error, not a verdict).
        public let isError: Bool
        /// The M4 guardian refused the result.
        public let guardianRejected: Bool
        /// The M5 verifier refused this call's task_done claim.
        public let verifierRejected: Bool

        public init(call: MerlinToolCall, resultText: String,
                    isError: Bool, guardianRejected: Bool, verifierRejected: Bool) {
            self.call = call
            self.resultText = resultText
            self.isError = isError
            self.guardianRejected = guardianRejected
            self.verifierRejected = verifierRejected
        }
    }

    /// The turn the feedback describes.
    public let turn: Int
    /// Outcomes in execution order. A verifier-rejected `task_done`
    /// appears here (its `resultText` is the rejection instruction).
    public let outcomes: [CallOutcome]
    /// Stop-authority wrap-up instructions declared while this turn ran
    /// (M6). Folded into the feedback so the model reads them as
    /// conversation, not only as digest lines.
    public let stopAuthorityInstructions: [String]

    public init(turn: Int, outcomes: [CallOutcome], stopAuthorityInstructions: [String]) {
        self.turn = turn
        self.outcomes = outcomes
        self.stopAuthorityInstructions = stopAuthorityInstructions
    }
}

/// Optional actor extension point (slice 3b): transcript-keeping actors
/// implement this so the kernel can hand back each executed batch's
/// outcomes. Live evidence (eval-live T01 probes, 2026-11-15): without
/// feedback the stock actor saw only its spine + a bare "Begin turn N" cue
/// and re-issued the identical failing call 6/6 turns — the model was blind
/// to its own history. The kernel probes every actor with `as?` and calls
/// `receive(feedback:)` once per executed batch, BEFORE the next
/// `toolCalls` completion. Plain `MerlinActor` implementations keep
/// working unchanged, with the digest as their only feedback channel
/// (documented design decision: option (a) in the lead's re-dispatch — the
/// landed `toolCalls(prompt:turn:)` seam is NOT reshaped).
public protocol MerlinActorWithFeedback: MerlinActor {
    /// Receives the outcomes of the batch the actor produced for `turn`.
    /// Best-effort by contract: the kernel logs a failure to the ledger and
    /// continues rather than ending the run on a feedback error.
    func receive(feedback: MerlinTurnFeedback) async

    /// Receives one recoverable actor failure (parse class): the kernel
    /// hands back the model's own words and the corrective instruction so
    /// the next completion happens over a transcript where the model can
    /// see its contract violation. Best-effort by the same contract as
    /// `receive(feedback:)`. The default implementation is a no-op, so
    /// plain transcript-less actors keep working unchanged.
    func receiveActorFailure(_ feedback: MerlinActorFailureFeedback) async
}

extension MerlinActorWithFeedback {
    public func receiveActorFailure(_ feedback: MerlinActorFailureFeedback) async {}
}

/// One recoverable actor failure (parse class), handed back before the
/// next completion (2026-11-16 gate fix): the live Spark gate lost 6/14
/// cells to the FIRST completion that narrated instead of calling a tool —
/// several after real progress — because the kernel treated one content-
/// only reply as machinery death. This payload is the corrective channel:
/// what the model said, and what it must do instead.
public struct MerlinActorFailureFeedback: Sendable {
    /// The turn whose completion carried no usable tool call.
    public let turn: Int
    /// The actor's error description (carries the rung, finish reason,
    /// and excerpt where the actor captured them).
    public let errorDescription: String
    /// The model's own narration when the actor captured it; the
    /// transcript-keeping actor appends it as the assistant turn being
    /// corrected.
    public let responseExcerpt: String?
    /// The corrective instruction, phrased for the model.
    public let instruction: String

    public init(turn: Int, errorDescription: String,
                responseExcerpt: String?, instruction: String) {
        self.turn = turn
        self.errorDescription = errorDescription
        self.responseExcerpt = responseExcerpt
        self.instruction = instruction
    }
}

/// Guardian hook point (M4).
///
/// After each tool call in the batch executes and before its result is
/// written to the ledger, the guardian reviews it. A rejection does not end
/// the run: the result is marked rejected and the instruction is logged as
/// a blocker, so the next turn's digest hands the model an explicit retry
/// instruction. Slice 3 fills this with real post-condition checks (file
/// exists, tests green, JSON valid).
public enum MerlinGuardianVerdict: Sendable {
    case accept
    /// The result is refused; `instruction` tells the model what to do
    /// instead and surfaces in the digest as an open blocker.
    case reject(instruction: String)
}

public protocol MerlinGuardian: Sendable {
    func review(tool: String, argumentsJSON: String, result: String) async -> MerlinGuardianVerdict
}

/// The M5 verifier hook point (slice 3): consulted when the actor files
/// `task_done`, BEFORE the run may end as completed. Mechanical artifact
/// checks always run; the adversarial model layer runs when a
/// `MerlinVerifier` (or a scripted client) is installed and enabled.
public protocol MerlinCompletionVerifier: Sendable {
    /// `summary` is the folded completion claim (summary + artifact lines);
    /// `claimedArtifacts` is the authoritative path list from the registry
    /// handler; `ledgerUnchangedSinceLastRejection` supports the documented
    /// skip rule for a repeated task_done after a rejection.
    func check(goal: String, ledgerDigest: String, summary: String,
               claimedArtifacts: [String], ledgerUnchangedSinceLastRejection: Bool) async -> MerlinVerifier.Decision
}

/// The default guardian accepts everything; installed only so the loop is
/// complete before slice 3 lands.
public struct MerlinPassThroughGuardian: MerlinGuardian {
    public init() {}
    public func review(tool: String, argumentsJSON: String, result: String) async -> MerlinGuardianVerdict {
        _ = tool; _ = argumentsJSON; _ = result
        return .accept
    }
}

/// Progress events surfaced by `MerlinKernel.Configuration.onEvent`
/// (slice 6, app-1's documented seam). Fire-and-forget by contract: the
/// callback is invoked synchronously at natural points in the loop and the
/// kernel NEVER inspects or awaits its effects — a slow or throwing
/// observer cannot stall the run (throws are swallowed; document-driven
/// guidance for the app side lives on the Configuration property).
public enum MerlinKernelEvent: Sendable {
    /// A turn began: the spine prompt was built and the actor is being asked
    /// for this turn's batch.
    case turnStarted(turn: Int)
    /// One call from the turn's batch finished executing; `summary` is the
    /// ledger-faithful collapsed result text (≤200 chars, verdict markers
    /// included).
    case callExecuted(call: MerlinToolCall, summary: String)
    /// A blocker was ledgered (guardian/verifier/stop-authority instruction
    /// or actor failure text).
    case blocker(text: String)
    /// The run reached a terminal outcome. Delivered last, exactly once.
    case completed(MerlinOutcome)
}

/// Terminal state of a Merlin run.
public struct MerlinOutcome: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// The model filed the completion contract through `task_done`.
        case completed
        /// The turn budget ran out first (M6 stop authority).
        case budgetExhausted
        /// The actor failed: transport-class failures end the run
        /// immediately (nothing in-loop can fix a dead server); parse-class
        /// failures end it only after the repeat threshold of consecutive
        /// completions that no corrective turn could shape into a tool call.
        case failed
    }

    public let status: Status
    /// The completion summary (for `completed`) or the kernel's reason.
    public let summary: String
    public let turnsUsed: Int
    public let maxTurns: Int

    /// Public memberwise init (slice 3, lead-approved): the eval target
    /// constructs outcomes across the module boundary (wall-guard and
    /// failure synthesis in MerlinEval/LiveDriver.swift). Declared inside
    /// the type because a cross-module extension can neither redeclare the
    /// synthesized memberwise signature nor assign internal stored
    /// properties. Documented in mission journal, 2026-11-15.
    public init(status: Status, summary: String, turnsUsed: Int, maxTurns: Int) {
        self.status = status
        self.summary = summary
        self.turnsUsed = turnsUsed
        self.maxTurns = maxTurns
    }
}

/// The Merlin kernel loop (M0 + M6 stop conditions, with M4/M7 seams).
///
/// Per turn: build the spine prompt (goal + digest + tool contract), take
/// the actor's batch, then execute the calls in order — each through the
/// tool registry under the retry policy, each past the guardian (M4), each
/// ledgered, with the turn budget checked after every call and every call
/// fingerprinted by the progress detector (M6). A `task_done` mid-batch
/// goes through the completion verifier (M5) before the run may end as
/// completed; a rejection ledgers a blocker and the loop continues. The
/// run ends on a verified `task_done`, on the turn budget, or on an actor
/// failure — transport-class actor failures immediately, parse-class
/// failures (a completion with no usable tool call) only after the stop
/// authority's repeat threshold of corrective turns — never on a tool
/// error, which is ledgered and handed back to the model as state.
public final class MerlinKernel: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Hard ceiling on executed turns (model completions).
        public var maxTurns: Int = 12
        /// Maximum calls the actor may pack into one turn.
        public var maxCallsPerTurn: Int = 4
        /// Line budget for the re-injected digest.
        public var digestMaxLines: Int = 24
        /// Progress seam (slice 6, app-1's documented follow-up): invoked
        /// fire-and-forget at natural loop points — `turnStarted` per turn,
        /// `callExecuted` per executed call, `blocker` per ledgered blocker,
        /// `completed` exactly once at the terminal outcome. The callback
        /// runs synchronously inline; the kernel never awaits, retries, or
        /// inspects it, and a throw is swallowed. An app may later switch
        /// from its 100ms ledger-polling to this seam (MerlinChatService is
        /// a documented follow-up — do NOT assume the app uses it today).
        /// nil (the default) preserves the pre-slice-6 behavior exactly.
        public var onEvent: (@Sendable (MerlinKernelEvent) -> Void)? = nil
        public init() {}

        /// Full initializer (the synthesized memberwise init is internal).
        public init(maxTurns: Int, maxCallsPerTurn: Int = 4, digestMaxLines: Int = 24,
                    onEvent: (@Sendable (MerlinKernelEvent) -> Void)? = nil) {
            self.maxTurns = maxTurns
            self.maxCallsPerTurn = maxCallsPerTurn
            self.digestMaxLines = digestMaxLines
            self.onEvent = onEvent
        }
    }

    public let workspace: MerlinWorkspace
    public let ledger: MerlinLedger
    public let registry: MerlinToolRegistry
    public let configuration: Configuration
    /// The task spine; the host may rewrite `planSketch` between runs.
    public var spine: MerlinTaskSpine
    /// Guardian hook (M4). Default stays pass-through so a host that never
    /// configures one keeps working; kernel runs install
    /// `MerlinResultGuardian` (deterministic post-condition checks).
    public var guardian: any MerlinGuardian
    /// M5 verifier (slice 3). nil preserves the pre-slice-3 contract: any
    /// task_done ends the run as completed unchecked. Eval baseline runs
    /// keep this nil (machinery off, SCORING.md §7); kernel runs install a
    /// `MerlinVerifier`.
    public var completionVerifier: (any MerlinCompletionVerifier)?
    /// M6 progress detector (slice 3). One tracker per run; the kernel
    /// records every executed call's signature into it.
    public var stopAuthority = MerlinStopAuthority.ProgressTracker()

    /// Ledger entry count captured right after the last verifier rejection —
    /// feeds the documented repeat-task_done skip rule (a second task_done
    /// against an unchanged ledger re-applies the instruction without a
    /// second model call). A count, not a digest: the attempt's own claim
    /// entry lands before the comparison, so "unchanged" is
    /// `count <= captured + 1`.
    private var ledgerCountAtLastRejection: Int?

    /// Consecutive recoverable actor failures (parse class — the server
    /// answered, the completion carried no usable tool call). Reset by any
    /// successfully parsed batch; at the stop authority's repeat threshold
    /// the run ends as failed rather than burning the whole budget
    /// correcting an unteachable model. The 2026-11-16 gate fix: before
    /// this counter, ONE content-only completion ended the run, killing
    /// 6/14 Spark cells mid-progress.
    private var consecutiveActorFailures = 0

    /// The corrective instruction for a parse-class actor failure, phrased
    /// in the spine's voice. Names the violation and the two legal exits,
    /// and answers budget truncation (finish_reason "length") by demanding
    /// terse, call-only replies.
    private static let actorContractCorrection =
        "Your last reply was not a tool call — it was prose the runtime could not execute. " +
        "Every reply must be one to four tool calls (or a single task_done when finished); " +
        "plain text is a contract violation. Reply again now with tool calls only, no narration."

    public init(workspace: MerlinWorkspace, ledger: MerlinLedger,
                spine: MerlinTaskSpine, configuration: Configuration = Configuration()) {
        self.workspace = workspace
        self.ledger = ledger
        self.configuration = configuration
        self.spine = spine
        self.guardian = MerlinPassThroughGuardian()
        self.completionVerifier = nil
        self.registry = MerlinToolRegistry(workspace: workspace, ledger: ledger)
    }

    /// Fire-and-forget event delivery. Synchronous and best-effort by
    /// contract: no await, no capture of observer state, no error channel —
    /// an observer can observe the run but can never stall or reshape it.
    private func emit(_ event: MerlinKernelEvent) {
        configuration.onEvent?(event)
    }

    /// Runs the loop to a terminal outcome.
    public func run(actor: any MerlinActor) async -> MerlinOutcome {
        var turn = 0
        while turn < configuration.maxTurns {
            turn += 1
            emit(.turnStarted(turn: turn))
            var digest = ledger.digest(goal: spine.goal, maxLines: configuration.digestMaxLines)
            // M6 wrap-up advisory (slice 3): once the stop authority has
            // declared wrap-up, its instruction rides the digest every turn
            // until the model changes approach (a success resets it).
            if let advisory = stopAuthority.wrapUpAdvisory(turn: turn) {
                digest += "\n" + advisory
            }
            let prompt = spine.systemPrompt(turn: turn, digest: digest)

            let batch: [MerlinToolCall]
            do {
                batch = try await actor.toolCalls(prompt: prompt, turn: turn)
            } catch {
                // Parse-class actor failures — the server answered but the
                // completion carried no usable tool call — are model
                // behavior, not machinery death: the same class of
                // contract mistake the kernel already absorbs for tool
                // errors, guardian rejections, and verifier rejections
                // (2026-11-16 gate: 6/14 Spark cells died to the FIRST
                // content-only completion, several mid-progress). Ledger
                // it, correct the model through the transcript, continue;
                // only transport-class failures — or a streak past the
                // repeat threshold — end the run.
                guard let actorError = error as? LlamaServerActor.ActorError,
                      actorError.parseFailure else {
                    try? ledger.append(turn: turn, kind: .blocker, key: "actor",
                                       text: "actor failed: \(error)")
                    try? ledger.append(turn: turn, kind: .result, key: "actor",
                                       text: "run ended on an actor failure")
                    emit(.blocker(text: "actor failed: \(error)"))
                    let outcome = MerlinOutcome(status: .failed, summary: "actor failed: \(error)",
                                                turnsUsed: turn, maxTurns: configuration.maxTurns)
                    emit(.completed(outcome))
                    return outcome
                }
                consecutiveActorFailures += 1
                let threshold = stopAuthority.authority.repeatThreshold
                let summarized = "actor produced no usable tool call " +
                    "(attempt \(consecutiveActorFailures) of \(threshold)): \(actorError)"
                try? ledger.append(turn: turn, kind: .blocker, key: "actor", text: summarized)
                try? ledger.append(turn: turn, kind: .result, key: "actor",
                                   text: "contract violation fed back; turn consumed")
                emit(.blocker(text: summarized))
                if let feedbackActor = actor as? any MerlinActorWithFeedback {
                    await feedbackActor.receiveActorFailure(MerlinActorFailureFeedback(
                        turn: turn,
                        errorDescription: String(describing: actorError),
                        responseExcerpt: actorError.responseExcerpt,
                        instruction: Self.actorContractCorrection))
                }
                if consecutiveActorFailures >= threshold {
                    try? ledger.append(turn: turn, kind: .result, key: "actor",
                                       text: "run ended after \(consecutiveActorFailures) consecutive unparseable completions")
                    let outcome = MerlinOutcome(
                        status: .failed,
                        summary: "actor failed \(consecutiveActorFailures) consecutive turns: " +
                            "no usable tool call despite corrective feedback",
                        turnsUsed: turn, maxTurns: configuration.maxTurns)
                    emit(.completed(outcome))
                    return outcome
                }
                continue
            }
            // A parsed batch is progress on the contract itself: the
            // recoverable-failure streak starts over.
            consecutiveActorFailures = 0

            // Out-of-contract batches are clamped, never trusted.
            let calls = Array(batch.prefix(max(1, configuration.maxCallsPerTurn)))
            if batch.count > calls.count {
                try? ledger.append(turn: turn, kind: .blocker, key: "actor",
                                   text: "actor returned \(batch.count) calls; kept the first \(calls.count)")
                emit(.blocker(text: "actor returned \(batch.count) calls; kept the first \(calls.count)"))
            }
            if calls.isEmpty {
                try? ledger.append(turn: turn, kind: .result, key: "actor",
                                   text: "actor returned an empty batch; turn consumed")
                continue
            }

            // Per-batch feedback collection (slice 3b): every executed
            // call's outcome lands here and is handed to a
            // `MerlinActorWithFeedback` actor after the batch completes.
            var outcomes: [MerlinTurnFeedback.CallOutcome] = []
            var stopAuthorityInstructions: [String] = []

            for (position, call) in calls.enumerated() {
                // Per-call M6 bookkeeping: the outcome class this iteration
                // records into the progress detector. The task_done catch
                // below overwrites it to `.failure` when the verifier
                // rejects the completion claim, so the rejected task_done
                // call is itself the failing fingerprint.
                var outcomeClass = MerlinStopAuthority.ResultSignature.OutcomeClass.success
                var isError = false
                var guardianRejected = false
                var verifierRejected = false

                do {
                    let result = try await registry.execute(name: call.name,
                                                            argumentsJSON: call.argumentsJSON,
                                                            turn: turn)
                    // `task_done` never reaches here: its handler throws the
                    // completion signal after ledgering the summary.
                    let verdict = await guardian.review(tool: call.name,
                                                        argumentsJSON: call.argumentsJSON,
                                                        result: result)
                    switch verdict {
                    case .accept:
                        outcomeClass = .success
                        try? ledger.append(turn: turn, kind: .result, key: call.name,
                                           text: Self.summarize(result))
                        emit(.callExecuted(call: call, summary: Self.summarize(result)))
                        outcomes.append(.init(call: call, resultText: Self.summarize(result),
                                              isError: false, guardianRejected: false,
                                              verifierRejected: false))
                    case .reject(let instruction):
                        outcomeClass = .guardianRejection
                        guardianRejected = true
                        let summarized = "rejected by guardian: \(Self.summarize(result))"
                        try? ledger.append(turn: turn, kind: .result, key: call.name, text: summarized)
                        try? ledger.append(turn: turn, kind: .blocker, key: call.name, text: instruction)
                        emit(.callExecuted(call: call, summary: summarized))
                        emit(.blocker(text: instruction))
                        outcomes.append(.init(call: call, resultText: summarized,
                                              isError: false, guardianRejected: true,
                                              verifierRejected: false))
                    }
                } catch let done as MerlinToolRegistry.TaskDoneSignal {
                    // Completion contract (M5): the verifier reviews the
                    // claim BEFORE the run may end as completed. A rejection
                    // does not end the run — the instruction is ledgered as
                    // a blocker and the loop continues (budget still
                    // applies; remaining batch calls still execute, because
                    // the model planned them for this turn). With no
                    // verifier installed the pre-slice-3 behavior is
                    // preserved: task_done is accepted as-is.
                    if let verifier = completionVerifier {
                        // Unchanged-ledger test (documented repeat-task_done
                        // rule): the ledger at this catch already contains
                        // this attempt's own claim entry, so "nothing new"
                        // means the count grew by exactly 1 since the last
                        // rejection. Evidence that landed mid-turn (a
                        // fs_write earlier in the same batch) counts as new.
                        let unchanged = ledgerCountAtLastRejection
                            .map { ledger.allEntries.count <= $0 + 1 } ?? false
                        let decision = await verifier.check(goal: spine.goal,
                                                            ledgerDigest: ledger.digest(goal: spine.goal, maxLines: configuration.digestMaxLines),
                                                            summary: done.summary,
                                                            claimedArtifacts: done.claimedArtifacts,
                                                            ledgerUnchangedSinceLastRejection: unchanged)
                        switch decision {
                        case .accept:
                            try? ledger.append(turn: turn, kind: .result, key: "verifier",
                                               text: "completion verified: accepted")
                            emit(.callExecuted(call: call, summary: "task_done: completion verified"))
                            let outcome = MerlinOutcome(status: .completed, summary: done.summary,
                                                        turnsUsed: turn, maxTurns: configuration.maxTurns)
                            emit(.completed(outcome))
                            return outcome
                        case .rejectMechanically(let instruction), .reject(let instruction):
                            // Capture the ledger count AFTER the rejection
                            // entries are ledgered: the next task_done skips
                            // its model call only when nothing beyond its
                            // own claim entry was added since this point
                            // (documented repeat-task_done rule).
                            let summarized = "rejected by verifier: \(Self.summarize(done.summary))"
                            try? ledger.append(turn: turn, kind: .result, key: "task_done", text: summarized)
                            try? ledger.append(turn: turn, kind: .blocker, key: "verifier", text: instruction)
                            ledgerCountAtLastRejection = ledger.allEntries.count
                            outcomeClass = .failure
                            verifierRejected = true
                            emit(.callExecuted(call: call, summary: summarized + " — " + instruction))
                            emit(.blocker(text: instruction))
                            outcomes.append(.init(call: call, resultText: summarized + " — " + instruction,
                                                  isError: false, guardianRejected: false,
                                                  verifierRejected: true))
                        }
                    } else {
                        let outcome = MerlinOutcome(status: .completed, summary: done.summary,
                                                    turnsUsed: turn, maxTurns: configuration.maxTurns)
                        emit(.callExecuted(call: call, summary: "task_done: \(done.summary)"))
                        emit(.completed(outcome))
                        return outcome
                    }
                } catch {
                    // Tool errors do not end the run: the model sees the
                    // failure in the next digest and corrects course.
                    outcomeClass = .failure
                    isError = true
                    let summarized = "error: \(Self.summarize(String(describing: error)))"
                    try? ledger.append(turn: turn, kind: .result, key: call.name, text: summarized)
                    emit(.callExecuted(call: call, summary: summarized))
                    outcomes.append(.init(call: call, resultText: summarized,
                                          isError: true, guardianRejected: false,
                                          verifierRejected: false))
                }

                // M6 progress detection (slice 3): every executed call is
                // fingerprinted; N identical consecutive failing signatures
                // trigger the wrap-up advisory, which the next turn's
                // digest carries (injected at the top of the loop) and the
                // feedback turn carries as conversation.
                if case .wrapUp(let instruction) = stopAuthority.record(
                    MerlinStopAuthority.ResultSignature(
                        tool: call.name,
                        normalizedArguments: MerlinStopAuthority.normalizedArguments(call.argumentsJSON),
                        outcomeClass: outcomeClass),
                    turn: turn) {
                    try? ledger.append(turn: turn, kind: .blocker, key: "stop-authority", text: instruction)
                    stopAuthorityInstructions.append(instruction)
                    emit(.blocker(text: instruction))
                }

                // Stop authority runs after EVERY call, not per turn: on the
                // final turn the first call is the last chance, so remaining
                // batch calls are dropped rather than executed over budget.
                if turn >= configuration.maxTurns && position < calls.count - 1 {
                    try? ledger.append(turn: turn, kind: .result, key: "kernel",
                                       text: "dropped \(calls.count - position - 1) remaining call(s): turn budget reached")
                    break
                }
            }

            // Slice 3b: hand the executed batch's outcomes back to a
            // transcript-keeping actor, so the next completion sees its own
            // assistant turn + results as conversation (live-evidence fix,
            // eval-live T01: without this the model was blind to its own
            // history and looped 6/6 on the same failing call). Fire once
            // per executed batch; a feedback failure is ledgered, never
            // run-ending.
            if let feedbackActor = actor as? any MerlinActorWithFeedback, !outcomes.isEmpty {
                await feedbackActor.receive(feedback: MerlinTurnFeedback(
                    turn: turn, outcomes: outcomes, stopAuthorityInstructions: stopAuthorityInstructions))
            }

            if turn >= configuration.maxTurns {
                try? ledger.append(turn: turn, kind: .result, key: "kernel",
                                   text: "turn budget exhausted")
                let outcome = MerlinOutcome(status: .budgetExhausted,
                                            summary: "stopped at the turn budget (\(configuration.maxTurns) turns) without task_done",
                                            turnsUsed: turn, maxTurns: configuration.maxTurns)
                emit(.completed(outcome))
                return outcome
            }
        }
        let outcome = MerlinOutcome(status: .budgetExhausted,
                                    summary: "stopped at the turn budget (\(configuration.maxTurns) turns) without task_done",
                                    turnsUsed: min(turn, configuration.maxTurns),
                                    maxTurns: configuration.maxTurns)
        emit(.completed(outcome))
        return outcome
    }

    /// Collapses whitespace and truncates a tool result for the ledger's
    /// `result` entries, so a huge read can never blow the digest budget.
    /// Pure; pinned by checks.
    public static func summarize(_ text: String, limit: Int = 200) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}
