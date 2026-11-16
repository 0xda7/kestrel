// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// MARK: - Live driver wiring (slice 4c-smoke)
//
// DESIGN DECISION (owned by eval-live, documented per the dispatch contract):
//
// For machinery=merlin this harness does NOT route the model through the
// `EvalTurnDriver` seam at all. It drives `MerlinKernel` directly per task:
//
//     harness seeder (EvalWorkspace.seed — boot hashes captured here)
//       → MerlinWorkspace + MerlinLedger over the SAME directory
//       → MerlinTaskSpine(goal: task.prompt, maxTurns: task.maxTurns)
//       → MerlinKernel.run(actor: LlamaServerActor(profile from MerlinProfileStore))
//       → ScoringEngine.score against that workspace
//
// Rationale: the kernel IS the Merlin machinery (M0 spine, M2/M3 ledger
// digest, M4 guardian, M6 stop authority, M7 retries). Threading it through
// the harness's own turn loop would re-implement the kernel's loop beside
// it — two code paths to drift. The `EvalTurnDriver` seam therefore serves
// ONLY machinery=baseline (NaiveBaselineDriver + the llama-server completion
// hook below).
//
// Fairness (SCORING.md §7 rule 3 — scoring is machinery-blind): both modes
// are scored by the identical `ScoringEngine.score` + `AssertionEngine`
// against identically seeded `EvalWorkspace` sandboxes. The pass gate
// (assertions + seed hashes + completion contract) reads the same bytes in
// both modes. One documented fidelity difference in the DIAGNOSTIC metrics
// only (§3 tool-trace counters): the Merlin path's trace source is the
// kernel ledger (tool arguments are not ledgered, only results are), so
// repeat-failure signatures compare on (tool, summarized result text)
// instead of (tool, normalized args). Pass/fail is unaffected; the delta is
// noted in report.json meta (`merlin_metrics_source`).
//
// Baseline (machinery=baseline): `NaiveBaselineDriver` gets a real
// completion hook — plain `/v1/chat/completions` (no tools[], no
// response_format — M1 off), one stock system prompt with a tools block and
// a call-format block in prompt text (M8 off: identical for every model),
// raw tool results echoed back as user turns (M2 off), no ledger/guardian/
// verifier/stop-authority (M3-M6 off), errors surface verbatim once (M7
// off), and lenient parsing: first balanced JSON blob or `name{...}` shape
// → call, with the ONE parse-repair retry SCORING.md §7 fairness rule 2
// allows per turn. When the repair also yields nothing, the hook returns an
// empty batch and the harness ends the run per the completion contract.
//
// Wall-clock guard (dispatch: a hung task run must not wedge the matrix):
// each task run is bounded at `wallGuardSeconds` (600 s). The Merlin path
// races the kernel against a timer task; the baseline hook checks elapsed
// time before each completion. A guard trip records
// `end_reason: harness_timeout` in the score and fails the task — a harness
// event, never a model score.

import Foundation
import KestrelCore

/// Live-path harness errors (transport/status faults). The kernel ledger
/// records these as actor failures; the run ends as a model-fault failure
/// (SCORING.md §6: only harness CRASHES may re-run, and these are not).
struct LiveDriverError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Configuration

/// Everything the live paths need to reach the model. Built once per CLI
/// invocation; the M8 profile (rung + think floor) comes from
/// `MerlinProfileStore` — ProfileStore picks the rung, the CLI only reports
/// it.
struct LiveDriverConfig: Sendable {
    let serverURL: URL
    let modelPath: String
    let modelID: String
    let profile: MerlinModelProfile
    /// Completion budget sent on every request: profile floor + action
    /// headroom — IDENTICAL in both machinery modes (SCORING.md §7 fairness
    /// rule 1: same sampling parameters).
    let maxTokens: Int
    let temperature: Double
    /// Context window the server was started with (reported in meta; the
    /// actor also sends it as `n_ctx`).
    let contextTokens: Int
    /// Per-task wall-clock guard (seconds).
    let wallGuardSeconds: TimeInterval

    static let defaultWallGuard: TimeInterval = 600

    static func make(serverURL: URL, modelPath: String, profileStore: MerlinProfileStore,
                     temperature: Double = 0, contextTokens: Int = 8192,
                     wallGuardSeconds: TimeInterval = defaultWallGuard) throws -> LiveDriverConfig {
        let profile = profileStore.profile(for: modelPath)
        let floor = profile.minCompletionTokens + MerlinModelProfile.actionHeadroom
        return LiveDriverConfig(serverURL: serverURL,
                                modelPath: modelPath,
                                modelID: (modelPath as NSString).lastPathComponent,
                                profile: profile,
                                maxTokens: floor,
                                temperature: temperature,
                                contextTokens: contextTokens,
                                wallGuardSeconds: wallGuardSeconds)
    }

    var metaJSON: JSONValue {
        .object([
            "driver": .string("live"),
            "model_path": .string(modelPath),
            "model_id": .string(modelID),
            "profile_family": .string(profile.family),
            "profile_rung": .string(profile.toolCallMode.rawValue),
            "profile_envelope_mode": .string(profile.envelopeMode.rawValue),
            "profile_min_completion_tokens": .number(Double(profile.minCompletionTokens)),
            "completion_max_tokens": .number(Double(maxTokens)),
            "temperature": .number(temperature),
            "context_tokens": .number(Double(contextTokens)),
            "server_url": .string(serverURL.absoluteString),
            "wall_guard_s": .number(wallGuardSeconds),
            "profile_template_notes": .string(profile.templateNotes),
        ])
    }
}

// MARK: - Merlin machinery path (kernel-driven)

/// Harness-owned M1 wire actor (LiveDriver.swift-owned; NO kernel edits).
///
/// Live evidence (T01 probes, 2026-11-15): the stock `LlamaServerActor`
/// appends only "Begin turn N" user cues — no kernel caller ever appends
/// the assistant's calls or their results, so the model re-issued the same
/// `fs_read` every turn (6/6 identical, budget exhausted) even with a
/// ledger-feedback wrapper stacking user messages in front of the cue: the
/// freshest message ("Begin turn N") won every time. Its own header
/// declares the intended shape ("user/assistant/tool turns roll underneath
/// [the spine] so each toolCalls(prompt:turn:) is one completion over a
/// coherent conversation") — the append calls are simply not wired into the
/// kernel loop yet (REPORT item for the lead; kernel-3 owns the file).
///
/// This actor implements that declared shape harness-side, using only
/// public Merlin API: kernel spine prompt as the system message
/// (re-seated every turn — M0), the actor's own assistant turns (content +
/// tool_calls, real OpenAI ids) and `role: "tool"` result turns appended
/// before the next completion, results sourced from the ledger deltas
/// (kernel-§summarized ≤200 chars — M2-faithful). The M1 constraint is the
/// server's grammar (rung payload per profile: tools[]+tool_choice
/// required / json_schema envelope / freeform), parsed through
/// `LlamaServerActor`'s public static rung parsers — byte-identical rung
/// semantics to the stock actor, with coherent bookkeeping.
final class LiveMerlinActor: MerlinActor, @unchecked Sendable {
    private let config: LiveDriverConfig
    private let ledger: MerlinLedger
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    /// Ledger entries already fed back as transcript turns.
    private var fedEntryCount = 0
    private let surface: Set<String>
    private let wireLogPath: String?
    private let transport: URLSession
    /// Rung used for the LAST completion (decides the feedback wire shape).
    private var lastRungWasNative = true
    /// The previous batch (with wire ids) awaiting its assistant turn.
    private var pendingAssistant: (content: String, calls: [[String: Any]], ids: [String])?

    /// Wall guard state: the runner's deadline; the actor refuses to start
    /// a completion past it (the kernel then sees an actor failure and the
    /// run unwinds quickly instead of mid-generation).
    private let deadline: Date

    init(config: LiveDriverConfig, ledger: MerlinLedger, taskPrompt: String,
         wallGuardSeconds: TimeInterval, wireLogPath: String? = nil) {
        self.config = config
        self.ledger = ledger
        self.surface = Set(EvalSuite.toolSurface)
        self.wireLogPath = wireLogPath
        self.deadline = Date().addingTimeInterval(wallGuardSeconds)
        self.transport = MerlinActorSessionTransport.shared
        // The task prompt rides the spine's GOAL (kernel passes it in
        // `prompt`), but an explicit user turn anchors turn 1's request.
        // The kernel re-seats the system message every turn, so this first
        // user message is the only fixed one.
        messages.append(["role": "user",
                         "content": "Task workspace is seeded. Begin turn 1; use the tool contract."])
    }

    // MARK: MerlinActor

    func toolCalls(prompt: String, turn: Int) async throws -> [MerlinToolCall] {
        guard Date() < deadline else {
            throw LiveDriverError(message: "harness wall guard reached before turn \(turn)")
        }
        locked {
            // M0: the kernel's spine prompt is ALWAYS the system message.
            if let first = messages.first, first["role"] as? String == "system" {
                messages[0] = ["role": "system", "content": prompt]
            } else {
                messages.insert(["role": "system", "content": prompt], at: 0)
            }
            appendFeedbackTurnLocked(turn: turn)
        }
        do {
            let calls = try await complete()
            logWire(turn: turn, calls: calls)
            return calls
        } catch {
            logWire(turn: turn, error: "\(error)")
            throw error
        }
    }

    /// Appends, for everything executed since the last completion: the
    /// assistant turn (what the model emitted), then its result turns, in
    /// the wire shape the rung's chat template requires:
    /// - nativeTools: assistant WITH `tool_calls` (real ids) → one
    ///   `role:"tool"` turn per id;
    /// - envelope/rescue: assistant content turn → ONE user message with
    ///   the results (no ids exist; a `role:"tool"` turn without a matching
    ///   assistant tool_calls block is an invalid template shape).
    /// Ends with this turn's single go-ahead message (results context plus
    /// the instruction to act — never a bare cue that outshouts the
    /// results; measured on the probe: the freshest message wins).
    private func appendFeedbackTurnLocked(turn: Int) {
        let entries = ledger.allEntries
        let fresh = entries.count > fedEntryCount
            ? entries[fedEntryCount...].filter { $0.kind == .result && $0.key.map(surface.contains) == true }
            : []
        fedEntryCount = entries.count

        if let pending = pendingAssistant {
            if lastRungWasNative && !pending.calls.isEmpty {
                var assistant: [String: Any] = ["role": "assistant",
                                                "content": pending.content]
                assistant["tool_calls"] = pending.calls
                messages.append(assistant)
                for (index, entry) in fresh.enumerated() {
                    messages.append([
                        "role": "tool",
                        "tool_call_id": index < pending.ids.count ? pending.ids[index] : "call_\(index)",
                        "content": entry.text,
                        "name": entry.key ?? "unknown",
                    ])
                }
            } else {
                messages.append(["role": "assistant", "content": pending.content])
                let lines = fresh.map { "- \($0.key ?? ""): \($0.text)" }
                if !lines.isEmpty {
                    messages.append(["role": "user",
                                     "content": "Results of your previous calls:\n" + lines.joined(separator: "\n")])
                }
            }
            pendingAssistant = nil
        } else if !fresh.isEmpty {
            // A batch executed without a stashed assistant turn (first
            // turn): surface the results as a user message regardless of
            // rung.
            let lines = fresh.map { "- \($0.key ?? ""): \($0.text)" }
            messages.append(["role": "user",
                             "content": "Results of your previous calls:\n" + lines.joined(separator: "\n")])
        }

        messages.append(["role": "user", "content":
            "Turn \(turn): the results above are already done — do NOT repeat them. " +
            "Take the NEXT step toward the GOAL (or call task_done with a summary citing artifact paths when done)."])
    }

    // MARK: - Wire

    private func complete() async throws -> [MerlinToolCall] {
        let endpoint = config.serverURL.appendingPathComponent("v1/chat/completions")
        var payload: [String: Any] = [
            "model": config.modelID,
            "messages": locked { messages },
            // KV-cache reuse wedged twice during the probes (slot re-launch
            // hanging after cached prefill); CPU prefill on this 1.7B is
            // only ~2-4s, so correctness and stability beat the cache.
            "cache_prompt": false,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
        ]
        if config.contextTokens > 0 { payload["n_ctx"] = config.contextTokens }
        let rung = config.profile.toolCallMode
        lastRungWasNative = (rung == .nativeTools)
        switch rung {
        case .nativeTools:
            payload["tools"] = MerlinToolSchema.openAIToolsPayload()
            payload["tool_choice"] = "required"
        case .jsonEnvelope:
            // Slice 6: grammar strength follows the profile — glm-4 rides
            // .perToolSchemas (per-tool argument branches), everything else
            // keeps the probe-verbatim shared shape.
            payload["response_format"] = MerlinToolSchema.envelopeResponseFormat(
                mode: config.profile.envelopeMode)
        case .rescue:
            break
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 420 // generous but bounded per completion
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LiveDriverError(message: "[\(rung.rawValue)] server returned HTTP \(status): " +
                String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LiveDriverError(message: "[\(rung.rawValue)] response is not a JSON object")
        }
        // Stash the raw assistant turn (content + tool_calls with ids) for
        // the next completion's history, then parse through the kernel's
        // public rung parser so the call contract is byte-identical to the
        // stock actor's.
        stashAssistantTurn(object)
        switch rung {
        case .nativeTools: return try LlamaServerActor.parseNativeTools(object)
        case .jsonEnvelope: return try LlamaServerActor.parseEnvelope(object)
        case .rescue: return try LlamaServerActor.parseRescue(object)
        }
    }

    private func stashAssistantTurn(_ object: [String: Any]) {
        locked {
            guard let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else { return }
            let content = (message["content"] as? String) ?? ""
            let rawCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
            let ids = rawCalls.compactMap { $0["id"] as? String }
            pendingAssistant = (content, rawCalls, ids)
        }
    }

    // MARK: - Wire log (smoke evidence)

    private func logWire(turn: Int, calls: [MerlinToolCall]? = nil, error: String? = nil) {
        guard let wireLogPath else { return }
        let payload: [String: Any] = [
            "turn": turn,
            "calls": calls?.map { ["name": $0.name, "arguments": $0.argumentsJSON] } ?? [],
            "error": error ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        locked {
            if let handle = FileHandle(forWritingAtPath: wireLogPath) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("\n".utf8))
                try? handle.write(contentsOf: data)
            } else {
                try? (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: wireLogPath))
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Runs one task through the real kernel and scores it with the harness
/// scorer. This is the machinery=merlin path; the `EvalTurnDriver` seam is
/// not involved.
enum LiveMerlinRunner {
    /// The Merlin tool-trace projection of a kernel ledger: one synthetic
    /// `ToolEvent` per ledgered tool result, so §3's trace metrics are
    /// computed with the SAME `ScoringEngine` helpers both modes use.
    /// Signatures compare on (tool, ledger result text) — args are not
    /// ledgered (documented fidelity note, see file header).
    static func transcript(fromLedger ledger: MerlinLedger, taskPrompt: String) -> EvalTranscript {
        var transcript = EvalTranscript(taskPrompt: taskPrompt)
        let surface = Set(EvalSuite.toolSurface)
        var eventsByTurn: [Int: [ToolEvent]] = [:]
        for entry in ledger.allEntries {
            guard entry.kind == .result, let key = entry.key, surface.contains(key) else { continue }
            let errorClass: String?
            if entry.text.hasPrefix("error:") {
                errorClass = ToolErrorClass.classify(tool: key, message: entry.text)
            } else if entry.text.hasPrefix("rejected by guardian:") {
                errorClass = ToolErrorClass.classify(tool: key, message: entry.text)
            } else {
                errorClass = nil
            }
            // The ledger text stands in for the arguments in the call
            // signature: identical (tool, summarized result) pairs compare
            // equal, which is the loop signature for every tool whose error
            // message embeds its argument (all ten do via the kernel's
            // error texts).
            let call = EvalToolCall(name: key, argumentsJSON: entry.text)
            eventsByTurn[entry.turn, default: []].append(
                ToolEvent(turn: entry.turn, call: call, errorClass: errorClass, resultText: entry.text))
        }
        for turn in eventsByTurn.keys.sorted() {
            transcript.beginTurn(turn)
            for event in eventsByTurn[turn] ?? [] {
                transcript.record(event)
            }
        }
        return transcript
    }

    /// Full merlin path for the CLI: seed through the harness seeder (boot
    /// hashes captured identically in both modes), then kernel-run.
    static func runSeeded(task: TaskSpec, runRoot: URL,
                          config: LiveDriverConfig) async throws -> TaskScore {
        let workspace = try EvalWorkspace.seed(task: task, runRoot: runRoot)
        return try await run(task: task, runRoot: runRoot, workspace: workspace, config: config)
    }

    /// Runs `task` on the live kernel. Throws only on harness-configuration
    /// faults; every model-side outcome — including the wall guard — comes
    /// back as a scored `TaskScore`.
    static func run(task: TaskSpec, runRoot: URL, workspace: EvalWorkspace,
                    config: LiveDriverConfig) async throws -> TaskScore {
        // The harness seeder already wrote the seed files; the kernel
        // adopts the SAME directory (one workspace, one ground truth).
        let kernelWorkspace = try MerlinWorkspace(root: URL(fileURLWithPath: workspace.rootPath),
                                                  taskID: "eval-\(task.id)")
        let ledger = try MerlinLedger(
            url: kernelWorkspace.rootURL.appendingPathComponent(MerlinLedger.fileName))
        let spine = MerlinTaskSpine(goal: task.prompt, planSketch: [], maxTurns: task.maxTurns)
        let kernel = MerlinKernel(workspace: kernelWorkspace, ledger: ledger, spine: spine,
                                  configuration: MerlinKernel.Configuration(maxTurns: task.maxTurns))
        // Harness-owned M1 actor (see LiveMerlinActor header): coherent
        // transcript bookkeeping + kernel-identical rung payloads/parsers,
        // with the wall guard enforced at completion boundaries. The wire
        // log lives OUTSIDE the task workspace (eval-validity: a harness
        // artifact inside the sandbox is visible to fs_list/fs_read and
        // breaks SCORING.md §7's identical-sandbox rule — caught live when
        // the T04 merlin run listed and READ the wire log).
        let wireLogURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("merlin-eval-wirelogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: wireLogURL, withIntermediateDirectories: true)
        let liveActor = LiveMerlinActor(
            config: config, ledger: ledger, taskPrompt: task.prompt,
            wallGuardSeconds: config.wallGuardSeconds,
            wireLogPath: wireLogURL.appendingPathComponent("\(task.id)-merlin.jsonl").path)

        let wallClock = EvalHarness.WallClock(start: Date())
        let raced = await race(kernelRun: { await kernel.run(actor: liveActor) },
                               guardSeconds: config.wallGuardSeconds)

        if raced.timedOut {
            let partial = ScoringEngine.score(task: task,
                                              workspace: workspace,
                                              transcript: transcript(fromLedger: ledger, taskPrompt: task.prompt),
                                              turnsUsed: 0,
                                              budgetExhausted: true,
                                              voluntaryStop: false,
                                              repairCount: 0,
                                              wallClockS: wallClock.elapsed)
            return scoreAppending(failReason: "harness_timeout: task exceeded the " +
                "\(Int(config.wallGuardSeconds))s wall guard (documented as a harness event, not a model score)",
                onto: partial, endReason: "harness_timeout")
        }
        guard let outcome = raced.outcome else {
            // Unreachable by race construction (one side always produces a
            // signal first); treated as a harness fault, never a pass.
            let partial = ScoringEngine.score(task: task,
                                              workspace: workspace,
                                              transcript: transcript(fromLedger: ledger, taskPrompt: task.prompt),
                                              turnsUsed: 0, budgetExhausted: true,
                                              voluntaryStop: false, repairCount: 0,
                                              wallClockS: wallClock.elapsed)
            return scoreAppending(failReason: "harness_fault: kernel race produced no outcome",
                                  onto: partial, endReason: "harness_fault")
        }

        let completed = outcome.status == .completed
        // Metrics from the ledger projection (see header note).
        let transcript = transcript(fromLedger: ledger, taskPrompt: task.prompt)
        var score = ScoringEngine.score(task: task,
                                        workspace: workspace,
                                        transcript: transcript,
                                        turnsUsed: outcome.turnsUsed,
                                        budgetExhausted: outcome.status == .budgetExhausted,
                                        voluntaryStop: completed,
                                        repairCount: 0,
                                        wallClockS: wallClock.elapsed)
        if outcome.status == .failed {
            score = scoreAppending(failReason: "actor_failure: \(outcome.summary) (completion contract unmet)",
                                   onto: score, endReason: "actor_failed")
        }
        return score
    }

    /// Race signal: the kernel's own outcome, or the harness wall guard
    /// firing. ( MerlinOutcome is constructed only by the kernel — this
    /// enum keeps the cross-module surface to the value the kernel already
    /// handed us.)
    private enum RaceSignal {
        case kernel(MerlinOutcome)
        case guardFired
    }

    /// Races `kernelRun` against a wall timer. When the timer wins first,
    /// `timedOut` is true and the kernel task is cancelled (URLSession
    /// throws on cancellation, so the kernel's actor-failure path unwinds).
    private static func race(kernelRun: @escaping @Sendable () async -> MerlinOutcome,
                             guardSeconds: TimeInterval) async -> (outcome: MerlinOutcome?, timedOut: Bool) {
        let first = await withTaskGroup(of: RaceSignal.self) { group -> RaceSignal? in
            group.addTask { .kernel(await kernelRun()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(guardSeconds * 1_000_000_000))
                return .guardFired
            }
            let winner = await group.next()
            group.cancelAll()
            return winner
        }
        switch first {
        case .kernel(let outcome):
            return (outcome, false)
        case .guardFired, .none:
            return (nil, true)
        }
    }

    /// Rebuilds a `TaskScore` with one extra fail reason (the scorer's
    /// factory is the only constructor; immutability is by design).
    private static func scoreAppending(failReason: String, onto score: TaskScore,
                                       endReason: String) -> TaskScore {
        TaskScore(taskID: score.taskID, axis: score.axis, tier: score.tier,
                  passed: false,
                  budgetExhausted: score.budgetExhausted,
                  seedDrift: score.seedDrift,
                  voluntaryStop: false,
                  turnsUsed: score.turnsUsed,
                  turnsBudget: score.turnsBudget,
                  wallClockS: score.wallClockS,
                  toolCalls: score.toolCalls,
                  toolErrors: score.toolErrors,
                  recoveryEvents: score.recoveryEvents,
                  repeatFailures: score.repeatFailures,
                  repairCount: score.repairCount,
                  assertionOutcomes: score.assertionOutcomes,
                  seedVerdicts: score.seedVerdicts,
                  bootHashes: score.bootHashes,
                  endReason: endReason,
                  failReasons: score.failReasons + [failReason],
                  workspacePath: score.workspacePath)
    }
}

// MARK: - Baseline machinery path (naive loop on the seam)

/// Per-task mutable state for the baseline completion hook. One instance per
/// (task × run): rolling assistant contents (so the stuffed transcript reads
/// as a real conversation), the parse-repair counter for report meta, and
/// the wall-clock start for the guard.
final class BaselineSession: @unchecked Sendable {
    private let lock = NSLock()
    private var assistantContents: [Int: String] = [:]
    private(set) var parseRepairs = 0
    private(set) var completions = 0
    private let wallStart = Date()
    private let config: LiveDriverConfig

    init(config: LiveDriverConfig) {
        self.config = config
    }

    var metaJSON: JSONValue {
        .object([
            "baseline_completions": .number(Double(completions)),
            "baseline_parse_repair_retries": .number(Double(parseRepairs)),
        ])
    }

    /// The completion hook handed to `NaiveBaselineDriver`. Throws on wall
    /// guard or transport fault; returns [] when the model produced no
    /// parseable call even after its one repair retry.
    func hook(_ context: NaiveBaselineDriver.NaiveLoopContext) async throws -> [EvalToolCall] {
        let elapsed = Date().timeIntervalSince(wallStart)
        guard elapsed < config.wallGuardSeconds else {
            throw EvalFatalError(message: "harness wall guard: task exceeded " +
                "\(Int(config.wallGuardSeconds))s before turn \(context.turn)")
        }

        let messages = Self.messages(for: context, assistantContents: assistantContentsSnapshot())
        let first = try await complete(messages: messages, rung: "baseline-freeform")
        let calls = BaselineLenientParser.parse(content: first, maxCalls: EvalHarness.maxCallsPerTurn)
        let repairUsed = withLock {
            completions += 1
            let repair = calls.isEmpty
            if repair { parseRepairs += 1 }
            assistantContents[context.turn] = first
            return repair
        }
        if !repairUsed {
            return calls
        }

        // SCORING.md §7 fairness rule 2: exactly ONE parse repair retry.
        // The retry nudge states the call shape — the same hint any naive
        // loop prints on a parse failure.
        var retryMessages = messages
        retryMessages.append(["role": "assistant", "content": first])
        retryMessages.append(["role": "user", "content": Self.parseRepairNudge])
        let second = try await complete(messages: retryMessages, rung: "baseline-freeform")
        let repaired = BaselineLenientParser.parse(content: second, maxCalls: EvalHarness.maxCallsPerTurn)
        withLock {
            completions += 1
            if !repaired.isEmpty { assistantContents[context.turn] = second }
        }
        return repaired
    }

    // MARK: - Sync lock helpers (Swift 6: NSLock.lock/unlock must not run
    // inside async contexts; every locked section is a synchronous body)

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func assistantContentsSnapshot() -> [Int: String] {
        withLock { assistantContents }
    }

    private func complete(messages: [[String: Any]], rung: String) async throws -> String {
        let endpoint = config.serverURL.appendingPathComponent("v1/chat/completions")
        let payload: [String: Any] = [
            "model": config.modelID,
            "messages": messages,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "cache_prompt": true,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await MerlinActorSessionTransport.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw EvalFatalError(message: "[\(rung)] server returned HTTP \(status): " +
                String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw EvalFatalError(message: "[\(rung)] response is not a chat completion: " +
                String(decoding: data.prefix(300), as: UTF8.self))
        }
        return content
    }

    /// The stuffed transcript: system (stock prompt + format block), the
    /// verbatim task prompt, then per completed turn one assistant message
    /// (what the model said) followed by one user message carrying the RAW
    /// tool results (M2 off — no summaries; results are already capped at
    /// `EvalToolExecutor.maxResultLength` by the executor).
    static func messages(for context: NaiveBaselineDriver.NaiveLoopContext,
                         assistantContents: [Int: String]) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt(maxTurns: context.maxTurns)],
            ["role": "user", "content": context.prompt],
        ]
        for event in context.events {
            if let said = assistantContents[event.turn] {
                messages.append(["role": "assistant", "content": said])
            }
            let args = event.call.argumentsJSON
            messages.append(["role": "user", "content": "Tool result for \(event.call.name)(\(args)):\n\(event.resultText)"])
        }
        messages.append(["role": "user", "content": "Continue working on the task. Reply with your next tool call(s)."])
        return messages
    }

    /// One stock prompt for every model (SCORING.md §7, M8-off row): chat
    /// template, the tool surface, and the call FORMAT in plain text. No
    /// spine, no digest, no ledger references, no guardian framing. Kept in
    /// LiveDriver.swift so Drivers.swift (not eval-live's file) stays
    /// byte-identical; the skeleton's `stockSystemPrompt` remains the
    /// scripted-checks reference.
    static func systemPrompt(maxTurns: Int) -> String {
        let signature = [
            "fs_read(path)", "fs_write(path, content)", "fs_list(path)",
            "fs_grep(pattern, path?)", "shell_run(command)", "js_eval(code)",
            "todo_write(todos)", "todo_read()", "note_add(kind, text)", "task_done(summary)",
        ]
        let lines = [
            "You are an agent working inside a sandboxed workspace directory. Complete the task using tools.",
            "",
            "Available tools:",
            signature.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "To use a tool, output a JSON object with keys \"name\" and \"arguments\", for example:",
            "{\"name\": \"fs_read\", \"arguments\": {\"path\": \"notes/a.txt\"}}",
            "Up to 4 tool calls per reply; each is one JSON object. Results arrive as the next message.",
            "When the task is complete, call task_done with a summary. Turn budget: \(maxTurns) replies.",
        ]
        return lines.joined(separator: "\n")
    }

    static let parseRepairNudge = """
        PARSE ERROR: your previous reply was not a parseable tool call. Reply with ONLY \
        tool-call JSON objects in the form {"name": "<tool>", "arguments": {...}} — no prose.
        """
}

/// The baseline's live transport. Separate from the kernel actor's session
/// on purpose: the baseline must not share Merlin machinery — this is a
/// plain ephemeral URLSession with the same generous CPU-server timeouts.
enum MerlinActorSessionTransport {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()
}

/// Lenient tool-call extraction for the baseline (SCORING.md §7, M1-off
/// row: "a json.loads-or-regex attempt, mirroring common naive loops").
/// Strategies, in order, until `maxCalls` are found:
///   1. every balanced `{...}` span in the content (string-aware brace
///      scan; fenced or `<tool_call>`-wrapped blobs qualify), parsed as
///      JSON; the tool name comes from `name` / `tool` / `tool_name` or a
///      nested OpenAI-style `function.name`, arguments from
///      `arguments` / `parameters` / `params` / the remaining keys;
///   2. the bare `name{...}` shape (`fs_read{"path":"x"}`) — identifier
///      immediately followed by a balanced object.
/// Nameless or unparseable blobs are skipped, never fatal: a naive loop
/// lives with whatever the model emits.
enum BaselineLenientParser {
    static func parse(content: String, maxCalls: Int) -> [EvalToolCall] {
        guard !content.isEmpty else { return [] }
        var calls: [EvalToolCall] = []

        for blob in balancedObjects(in: content) {
            guard calls.count < maxCalls else { break }
            guard let data = blob.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            guard let name = toolName(in: object) else { continue }
            calls.append(EvalToolCall(name: name, argumentsJSON: argumentsJSON(in: object, blob: blob)))
        }

        if calls.isEmpty {
            for (name, blob) in nameShapedCalls(in: content) {
                guard calls.count < maxCalls else { break }
                calls.append(EvalToolCall(name: name, argumentsJSON: blob))
            }
        }
        return Array(calls.prefix(maxCalls))
    }

    private static func toolName(in object: [String: Any]) -> String? {
        for key in ["name", "tool", "tool_name"] {
            if let name = object[key] as? String, !name.isEmpty { return name }
        }
        if let function = object["function"] as? [String: Any],
           let name = function["name"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

    /// Lenient arguments: a dedicated args key when present (nested or
    /// stringified), otherwise every key except the name keys — the naive
    /// shape `{"tool": "fs_read", "path": "x"}` still parses.
    private static func argumentsJSON(in object: [String: Any], blob: String) -> String {
        for key in ["arguments", "parameters", "params"] {
            if let args = object[key] {
                if let dict = args as? [String: Any],
                   JSONSerialization.isValidJSONObject(dict),
                   let data = try? JSONSerialization.data(withJSONObject: dict) {
                    return String(decoding: data, as: UTF8.self)
                }
                if let text = args as? String, !text.isEmpty {
                    if let data = text.data(using: .utf8),
                       (try? JSONSerialization.jsonObject(with: data)) != nil {
                        return text
                    }
                    return text // stringified junk: the executor reports bad_args honestly
                }
            }
        }
        if let function = object["function"] as? [String: Any],
           let args = function["arguments"] {
            if let dict = args as? [String: Any],
               JSONSerialization.isValidJSONObject(dict),
               let data = try? JSONSerialization.data(withJSONObject: dict) {
                return String(decoding: data, as: UTF8.self)
            }
            if let text = args as? String { return text }
        }
        // No args key: strip the name keys out of the raw blob and ship the
        // rest — the executor's decoder decides if that is a valid object.
        var remainder = object
        for key in ["name", "tool", "tool_name", "function"] { remainder.removeValue(forKey: key) }
        if JSONSerialization.isValidJSONObject(remainder),
           let data = try? JSONSerialization.data(withJSONObject: remainder) {
            return String(decoding: data, as: UTF8.self)
        }
        return "{}"
    }

    /// String-aware balanced `{...}` spans, outermost-first, in order.
    private static func balancedObjects(in text: String) -> [String] {
        var blobs: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let begin = start {
                    blobs.append(String(text[begin...index]))
                    start = nil
                }
            }
        }
        return blobs
    }

    /// The `name{...}` shape: an identifier directly followed by a balanced
    /// object (`fs_read{"path":"x"}`). Returns (name, objectSubstring).
    private static func nameShapedCalls(in text: String) -> [(String, String)] {
        var results: [(String, String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index] == "_" else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" {
                end = text.index(after: end)
            }
            let name = String(text[index..<end])
            var cursor = end
            while cursor < text.endIndex, text[cursor] == " " || text[cursor].isNewline {
                cursor = text.index(after: cursor)
            }
            if !name.isEmpty, cursor < text.endIndex, text[cursor] == "{" {
                if let close = balancedEnd(from: cursor, in: text) {
                    let blob = String(text[cursor...close])
                    if blob.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) != nil {
                        results.append((name, blob))
                    }
                    index = text.index(after: close)
                    continue
                }
            }
            index = end
        }
        return results
    }

    /// End index of the balanced object beginning at `open` (string-aware),
    /// or nil when unbalanced.
    private static func balancedEnd(from open: String.Index, in text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                if character == "\"" { inString = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Wedge hardening (slice 6: codified one-retry-then-harness_event policy)
//
// The smoke gate (results/smoke-spark17/NOTES.md) lost 10 of 12 cells to the
// llama-server accept-then-silence wedge — each cell burned its full guard
// window and scored as an ordinary failure. The lead's policy, now codified:
// a cell whose failure is a request-timeout wedge gets exactly ONE automatic
// retry on a FRESH server instance (kill + relaunch + re-seed); a wedge that
// survives the retry scores permanently as `harness_event:wedge` (a harness
// event, never a model score). Every wedge appends a one-line stamp to
// `wedges.log` in the runs root so patterns accumulate across runs.
//
// Config: `--wedge-retry` (default on; `--no-wedge-retry` disables). The
// relaunch uses `--server-binary` (default: the bundled vendor llama-server,
// resolved below) with the run's model path, port, context, threads.

/// Wedge-retry configuration. Default-on per the slice-6 contract.
struct WedgeRetryPolicy: Sendable {
    var enabled: Bool
    /// Server binary for the fresh relaunch; `nil` falls back to
    /// `ServerSupervisor.defaultBinaryPath()` and, when that fails too,
    /// degrades to stamping the wedge without a retry (honest fail reason).
    var serverBinary: String?
    /// Server threads for the relaunch (the smoke's stable config rode `-t 16`).
    var serverThreads: Int

    static let `default` = WedgeRetryPolicy(enabled: true, serverBinary: nil, serverThreads: 16)
}

/// Wedge classification and the retry loop. `attempt` performs ONE fully
/// seeded cell run into the given run root (merlin or baseline — the caller
/// supplies the closure, so both machinery modes ride the same policy).
enum WedgeHardening {
    /// True when the score's failure is a request-timeout wedge: the wall
    /// guard fired with a request in flight, or the actor failed on a
    /// URLSession timeout (the smoke's two wedge signatures).
    static func isRequestTimeoutWedge(_ score: TaskScore) -> Bool {
        if score.endReason == "harness_timeout" { return true }
        if score.endReason == "actor_failed" {
            let text = score.failReasons.joined(separator: " ").lowercased()
            return text.contains("timed out") || text.contains("timeout")
        }
        return false
    }

    /// Runs one cell under the policy. Non-wedge scores pass through
    /// untouched; a wedge gets the stamp, the one fresh-instance retry, and
    /// — on a second wedge — the permanent `harness_event:wedge` score.
    /// Configuration faults from `attempt` (server gone before launch,
    /// seeder refusal) rethrow to the caller's existing fault handling —
    /// they are not wedges.
    static func runCell(task: TaskSpec, runRoot: URL, config: LiveDriverConfig,
                        policy: WedgeRetryPolicy, supervisor: ServerSupervisor?,
                        wedgeLogURL: URL?,
                        attempt: (URL) async throws -> TaskScore) async throws -> TaskScore {
        let score: TaskScore
        do {
            score = try await attempt(runRoot)
        } catch {
            // Harness-configuration faults are not wedges; let the caller's
            // existing fault handling see the throw.
            throw error
        }
        guard isRequestTimeoutWedge(score) else { return score }

        stamp(wedgeLogURL, task: task, config: config, port: config.serverURL.port ?? 0,
              event: "wedge_first_attempt", detail: score.endReason ?? "nil")

        guard policy.enabled else {
            return appending(failReason: "harness_event:wedge (retry disabled by --no-wedge-retry; " +
                "documented harness event, not a model score)",
                endReason: "harness_event_wedge", onto: score)
        }
        guard let supervisor else {
            return appending(failReason: "harness_event:wedge (retry impossible: no server supervisor " +
                "configured; documented harness event, not a model score)",
                endReason: "harness_event_wedge", onto: score)
        }

        // The one automatic retry: fresh server instance, fresh seed.
        let restartNote = supervisor.restart()
        stamp(wedgeLogURL, task: task, config: config, port: config.serverURL.port ?? 0,
              event: "wedge_retry_server_restarted", detail: restartNote)
        guard restartNote.contains("ready") else {
            return appending(failReason: "harness_event:wedge (fresh-instance relaunch failed: \(restartNote); " +
                "documented harness event, not a model score)",
                endReason: "harness_event_wedge", onto: score)
        }
        let retryRoot = runRoot.appendingPathComponent("wedge-retry-1", isDirectory: true)
        let retried: TaskScore
        do {
            retried = try await attempt(retryRoot)
        } catch {
            return appending(failReason: "harness_event:wedge (retry attempt threw: \(error); " +
                "documented harness event, not a model score)",
                endReason: "harness_event_wedge", onto: score)
        }
        if isRequestTimeoutWedge(retried) {
            stamp(wedgeLogURL, task: task, config: config, port: config.serverURL.port ?? 0,
                  event: "wedge_retry_wedged", detail: "permanent harness_event:wedge")
            return appending(failReason: "harness_event:wedge: request-timeout wedge persisted after the " +
                "one fresh-instance retry (codified policy: one retry, then harness_event:wedge; " +
                "a harness event, never a model score)",
                endReason: "harness_event_wedge", onto: retried)
        }
        stamp(wedgeLogURL, task: task, config: config, port: config.serverURL.port ?? 0,
              event: "wedge_retry_recovered", detail: "cell scored on the fresh instance")
        return retried
    }

    /// One wedge-stamp line: `<ISO8601>\t<port>\t<task>/<mode>\t<event>\t<detail>`.
    /// Best-effort by contract — a log failure must never take the matrix down.
    static func stamp(_ url: URL?, task: TaskSpec, config: LiveDriverConfig,
                      port: Int, event: String, detail: String) {
        guard let url else { return }
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date()))\tport=\(port)\tcell=\(task.id)/\(config.profile.family)-\(config.profile.toolCallMode.rawValue)\t\(event)\t\(detail)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// TaskScore rebuild with one appended fail reason + new end reason
    /// (the scorer's factory stays the only other constructor).
    static func appending(failReason: String, endReason: String, onto score: TaskScore) -> TaskScore {
        TaskScore(taskID: score.taskID, axis: score.axis, tier: score.tier,
                  passed: false,
                  budgetExhausted: score.budgetExhausted,
                  seedDrift: score.seedDrift,
                  voluntaryStop: false,
                  turnsUsed: score.turnsUsed,
                  turnsBudget: score.turnsBudget,
                  wallClockS: score.wallClockS,
                  toolCalls: score.toolCalls,
                  toolErrors: score.toolErrors,
                  recoveryEvents: score.recoveryEvents,
                  repeatFailures: score.repeatFailures,
                  repairCount: score.repairCount,
                  assertionOutcomes: score.assertionOutcomes,
                  seedVerdicts: score.seedVerdicts,
                  bootHashes: score.bootHashes,
                  endReason: endReason,
                  failReasons: score.failReasons + [failReason],
                  workspacePath: score.workspacePath)
    }
}

/// Kills and relaunches the llama-server on the run's port (the wedge
/// policy's fresh-instance requirement). Only ever touches the process
/// listening on ITS OWN configured port — nothing else on the box.
final class ServerSupervisor: @unchecked Sendable {
    let port: Int
    let modelPath: String
    let contextTokens: Int
    let temperature: Double
    let threads: Int
    let binaryOverride: String?
    /// Append-only relaunch log beside wedges.log (nil → console only).
    let launchLogURL: URL?

    init(port: Int, modelPath: String, contextTokens: Int, temperature: Double,
         threads: Int, binaryOverride: String?, launchLogURL: URL?) {
        self.port = port
        self.modelPath = modelPath
        self.contextTokens = contextTokens
        self.temperature = temperature
        self.threads = threads
        self.binaryOverride = binaryOverride
        self.launchLogURL = launchLogURL
    }

    /// The bundled server, resolved without a bundle: env override, the
    /// package checkout relative to the CWD, then relative to the running
    /// executable (.build/<config>/merlin-eval → package root).
    static func defaultBinaryPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["MERLIN_LLAMA_SERVER"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let relative = "vendor/llama.cpp/build-static/bin/llama-server"
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relative).path
        if FileManager.default.isExecutableFile(atPath: cwd) { return cwd }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let beside = executable.deletingLastPathComponent()
            .appendingPathComponent("../../\(relative)").path
        if FileManager.default.isExecutableFile(atPath: beside) { return beside }
        return nil
    }

    /// One restart: kill the port's listener, wait for the port to free,
    /// relaunch, wait for /health. Returns a one-line result ending in
    /// `ready` on success (the wedge loop greps for it). Every step leaves
    /// a breadcrumb in the relaunch log — a stall names its step.
    func restart() -> String {
        guard let binary = binaryOverride ?? Self.defaultBinaryPath() else {
            return "relaunch_failed: no llama-server binary found (set --server-binary or MERLIN_LLAMA_SERVER)"
        }
        log("restart: killing the port listener")
        killPortListener()
        guard waitForPortFree() else { return "relaunch_failed: port \(port) still occupied after kill" }
        log("restart: port free; launching \(binary)")
        let logHandle = openLaunchLog()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-m", modelPath,
            "--port", String(port),
            "-ngl", "0",
            "-c", String(max(contextTokens, 1024)),
            "-t", String(max(threads, 1)),
            "--temp", String(temperature),
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            return "relaunch_failed: \(error)"
        }
        log("launched pid \(process.processIdentifier) \(binary) -m \(modelPath) --port \(port) -t \(threads); waiting for /health")
        guard waitForHealth(process: process) else {
            return "relaunch_failed: /health not ok within the load window (see the relaunch log)"
        }
        return "ready: pid \(process.processIdentifier) on port \(port)"
    }

    // MARK: process/port plumbing (synchronous; called off the run path)

    /// Signals SIGTERM to each listener pid directly — no helper subprocess
    /// (a pipe-backed Process can deadlock on a pipe nobody drains).
    private func killPortListener() {
        for pid in portListenerPIDs() {
            kill(pid_t(pid), SIGTERM)
            log("sent SIGTERM to port listener pid \(pid)")
        }
        if portListenerPIDs().isEmpty { log("no listener found on port \(port)") }
    }

    /// `lsof -t -sTCP:LISTEN` with a hard timeout: a wedged read (the smoke
    /// gate's own wedge signature) must never stall the supervisor.
    private func portListenerPIDs() -> [Int] {
        let lsof = Process()
        let pipe = Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // LISTEN-state only: client sockets pointed at this port (other
        // processes' hung requests, our own prior attempt) must not be
        // mistaken for the server we are about to replace — and must never
        // be killed (functional proof 2026-11-16: without the filter the
        // supervisor "found" the eval process's own outbound socket and
        // refused to relaunch).
        lsof.arguments = ["-t", "-i", "tcp:\(port)", "-sTCP:LISTEN"]
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        do { try lsof.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(5)
        var data = Data()
        let handle = pipe.fileHandleForReading
        while Date() < deadline {
            let chunk = handle.availableData
            if !chunk.isEmpty { data.append(chunk) }
            if lsof.isRunning { Thread.sleep(forTimeInterval: 0.1) } else { break }
        }
        if lsof.isRunning {
            kill(lsof.processIdentifier, SIGKILL)
            log("lsof exceeded its 5s window; killed the probe")
            return []
        }
        lsof.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .compactMap { Int($0) }
    }

    private func waitForPortFree(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if portListenerPIDs().isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return portListenerPIDs().isEmpty
    }

    /// Waits for `/health` to return ok (model load: seconds on Spark,
    /// minutes on a CPU 9B — the window is generous on purpose). Bounded
    /// per-request waits (semaphore with timeout) so a half-open probe
    /// cannot stall the loop.
    private func waitForHealth(process: Process, timeout: TimeInterval = 900) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        while Date() < deadline {
            if let url = URL(string: "http://127.0.0.1:\(port)/health") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let semaphore = DispatchSemaphore(value: 0)
                var healthy = false
                let task = session.dataTask(with: request) { data, _, _ in
                    if let data,
                       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       (object["status"] as? String) == "ok" {
                        healthy = true
                    }
                    semaphore.signal()
                }
                task.resume()
                _ = semaphore.wait(timeout: .now() + 8)
                if healthy { return true }
            }
            if !process.isRunning { return false }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    private func openLaunchLog() -> FileHandle {
        if let url = launchLogURL {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                return handle
            }
            try? Data().write(to: url)
            if let handle = try? FileHandle(forWritingTo: url) { return handle }
        }
        return FileHandle.nullDevice
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) supervisor: \(line)\n"
        if let url = launchLogURL, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            FileHandle.standardError.write(Data(text.utf8))
        }
    }
}

// MARK: - Live report assembly

/// Merges the run-level `meta` object into a generated report JSON and
/// appends the delta block (SCORING.md §5) when both machinery modes ran.
enum LiveReport {
    static func merged(base: JSONValue, meta: JSONValue) -> JSONValue {
        guard case .object(var object) = base else { return base }
        if case .object(let additions) = meta {
            for (key, value) in additions { object[key] = value }
        }
        return .object(object)
    }

    /// report.json for an interleaved (both-machinery) run: the two
    /// per-mode run objects under `runs`, plus meta and the §5 delta text.
    static func interleaved(merlin: JSONValue, baseline: JSONValue,
                            meta: JSONValue) -> JSONValue {
        var object: [String: JSONValue] = [
            "report_kind": .string("merlin-eval-interleaved"),
            "runs": .array([merlin, baseline]),
            "meta": meta,
        ]
        if case .object(let merlinObject) = merlin,
           case .object(let baselineObject) = baseline {
            for (key, value) in merlinObject where key != "tasks" && key != "summary" {
                object[key] = value
            }
            object["delta"] = deltaJSON(merlin: merlinObject, baseline: baselineObject)
        }
        return .object(object)
    }

    /// Mechanical merlin − baseline delta per task (pass, turns) plus the
    /// suite-level rollup — the honest raw material for the §7 signature
    /// reading (big on B/D/E, small on A — or not, as measured).
    static func deltaJSON(merlin: [String: JSONValue], baseline: [String: JSONValue]) -> JSONValue {
        func tasks(_ run: [String: JSONValue]) -> [String: JSONValue] {
            guard case .array(let list) = run["tasks"] else { return [:] }
            var byID: [String: JSONValue] = [:]
            for task in list {
                if case .object(let object) = task, case .string(let id) = object["id"] {
                    byID[id] = .object(object)
                }
            }
            return byID
        }
        let merlinTasks = tasks(merlin)
        let baselineTasks = tasks(baseline)
        var perTask: [String: JSONValue] = [:]
        for id in merlinTasks.keys.sorted() {
            guard case .object(let m) = merlinTasks[id],
                  case .object(let b) = baselineTasks[id] else { continue }
            let mPass = (m["pass"], b["pass"])
            if case (.bool(let mp), .bool(let bp)) = mPass {
                let relation = (mp && bp) ? "both" : (mp && !bp) ? "merlin_only" : (!mp && bp) ? "baseline_only" : "neither"
                perTask[id] = .object([
                    "merlin_pass": .bool(mp),
                    "baseline_pass": .bool(bp),
                    "relation": .string(relation),
                    "merlin_turns": m["turns_used"] ?? .null,
                    "baseline_turns": b["turns_used"] ?? .null,
                ])
            }
        }
        func summaryCounts(_ run: [String: JSONValue]) -> (Int, Int) {
            guard case .object(let summary) = run["summary"],
                  case .number(let passed) = summary["passed"],
                  case .number(let total) = summary["tasks"] else { return (0, 0) }
            return (Int(passed), Int(total))
        }
        let (mPassed, mTotal) = summaryCounts(merlin)
        let (bPassed, bTotal) = summaryCounts(baseline)
        return .object([
            "per_task": .object(perTask),
            "suite": .object([
                "merlin_passed": .number(Double(mPassed)),
                "merlin_total": .number(Double(mTotal)),
                "baseline_passed": .number(Double(bPassed)),
                "baseline_total": .number(Double(bTotal)),
            ]),
        ])
    }
}
