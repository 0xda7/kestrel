// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import KestrelCore

/// merlin-eval CLI — slice 4b.
///
/// Runs merlin-eval-v1 tasks end-to-end: load tasks.json → seed fresh
/// sandboxes → drive the turn loop → score mechanically → print the
/// MODEL SCORECARD → write report.json. Exit 0 only when every selected
/// task passes.
///
/// Usage:
///   merlin-eval --tasks <tasks.json> --driver scripted --script <file> [--task T07]
///               [--runs-root <dir>] [--report-out <path>] [--model <id>]
///               [--machinery merlin|baseline]
///
/// The llama-server driver is a LATER dispatch; the seam is `EvalTurnDriver`
/// (harness twin of the kernel's landed `MerlinActor.toolCalls(prompt:turn:)`
/// — AMENDMENT 2 batched shape), and `NaiveBaselineDriver` carries the
/// baseline behavior skeleton per SCORING.md §7.
struct EvalCLI {
    struct Options {
        var tasksPath: String?
        var driver: String?
        var scriptPath: String?
        var taskFilter: [String] = []
        var runsRoot: String?
        var reportOut: String?
        var modelID: String = "scripted-reference"
        var machinery: MachineryMode = .merlin
        // Live-driver options (slice 4c; used when --driver live).
        var liveServerPort: Int?
        var liveModelPath: String?
        var liveTemperature: Double = 0
        var liveContextTokens: Int = 8192
        var liveWallGuard: TimeInterval = LiveDriverConfig.defaultWallGuard
        var interleave: Bool = false
        // Wedge hardening (slice 6): one fresh-instance retry per wedged
        // cell, then harness_event:wedge. ON by default.
        var wedgeRetry: Bool = WedgeRetryPolicy.default.enabled
        var serverBinary: String?
        var serverThreads: Int = WedgeRetryPolicy.default.serverThreads
        var help = false
    }

    static func usage() -> String {
        """
        merlin-eval — mechanical eval harness for merlin-eval-v1 (slice 4b)

        USAGE:
          merlin-eval --tasks <path> --driver scripted --script <file> [options]
          merlin-eval --tasks <path> --driver live --model-path <gguf> --port <n>
                      --machinery merlin|baseline [--interleave] [options]

        REQUIRED:
          --tasks <path>        Path to tasks.json (suite merlin-eval-v1).
          --driver <name>       scripted | naive-baseline | live
          --script <file>       Scripted replay JSON (required with --driver scripted)

        LIVE DRIVER (slice 4c-smoke):
          --model-path <path>   GGUF path (family/rung from MerlinProfileStore, M8)
          --port <n>            llama-server port (http://127.0.0.1:<n>)
          --temperature <x>     Sampling temperature, both modes (fairness rule 1; default 0)
          --context-tokens <n>  Server context window (default 8192)
          --wall-guard-seconds  Per-task wall-clock guard (default 600; a trip is a
                                documented harness_timeout, not a model score)
          --interleave          Run ALL tasks × BOTH machinery modes, alternating
                                merlin/baseline per task (SCORING.md §7 rule 4) into
                                one run tree + one interleaved report.json
          With --driver live, --machinery baseline rides the NaiveBaselineDriver
          completion hook (lenient parse, one repair retry, no Merlin machinery).
          Merlin machinery (--machinery merlin) drives MerlinKernel + LlamaServerActor
          directly per task and scores from the same ScoringEngine (machinery-blind).

        WEDGE HARDENING (slice 6):
          --wedge-retry / --no-wedge-retry
                                A cell whose failure is a request-timeout wedge gets
                                exactly ONE automatic retry on a FRESH server instance
                                (kill + relaunch + re-seed), then scores permanently as
                                harness_event:wedge. Default ON. Every wedge appends a
                                one-line stamp to wedges.log in the run root.
          --server-binary <path> llama-server for the relaunch (default: the bundled
                                vendor binary, or $MERLIN_LLAMA_SERVER)
          --server-threads <n>  -t for the relaunch (default 16; the smoke's stable config)

        OPTIONS:
          --task T07            Run a single task by id (repeatable; default: all 14)
          --runs-root <dir>     Run-tree root (default ~/.kestrel/merlin-eval/runs;
                                the CLI creates <runs-root>/<timestamp>/)
          --report-out <path>   Where to write report.json (default <run-root>/report.json)
          --model <id>          Model id for the scorecard header (default scripted-reference)
          --machinery <mode>    merlin | baseline (scorecard label; SCORING.md §7)
          -h, --help            This text
        """
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        func takeValue(_ flag: String) throws -> String {
            guard let value = iterator.next(), !value.hasPrefix("--") else {
                throw EvalFatalError(message: "\(flag) requires a value")
            }
            return value
        }
        while let argument = iterator.next() {
            switch argument {
            case "--tasks": options.tasksPath = try takeValue("--tasks")
            case "--driver": options.driver = try takeValue("--driver")
            case "--script": options.scriptPath = try takeValue("--script")
            case "--task": options.taskFilter.append(try takeValue("--task"))
            case "--runs-root": options.runsRoot = try takeValue("--runs-root")
            case "--report-out": options.reportOut = try takeValue("--report-out")
            case "--model": options.modelID = try takeValue("--model")
            case "--model-path": options.liveModelPath = try takeValue("--model-path")
            case "--port":
                let raw = try takeValue("--port")
                guard let port = Int(raw), (1...65535).contains(port) else {
                    throw EvalFatalError(message: "--port must be an integer 1...65535, got \(raw)")
                }
                options.liveServerPort = port
            case "--temperature":
                let raw = try takeValue("--temperature")
                guard let value = Double(raw), value >= 0, value < 2 else {
                    throw EvalFatalError(message: "--temperature must be a number in [0, 2), got \(raw)")
                }
                options.liveTemperature = value
            case "--context-tokens":
                let raw = try takeValue("--context-tokens")
                guard let value = Int(raw), value >= 1024 else {
                    throw EvalFatalError(message: "--context-tokens must be an integer ≥ 1024, got \(raw)")
                }
                options.liveContextTokens = value
            case "--wall-guard-seconds":
                let raw = try takeValue("--wall-guard-seconds")
                guard let value = Double(raw), value >= 30 else {
                    throw EvalFatalError(message: "--wall-guard-seconds must be ≥ 30, got \(raw)")
                }
                options.liveWallGuard = value
            case "--interleave": options.interleave = true
            case "--wedge-retry": options.wedgeRetry = true
            case "--no-wedge-retry": options.wedgeRetry = false
            case "--server-binary": options.serverBinary = try takeValue("--server-binary")
            case "--server-threads":
                let raw = try takeValue("--server-threads")
                guard let value = Int(raw), (1...128).contains(value) else {
                    throw EvalFatalError(message: "--server-threads must be an integer 1...128, got \(raw)")
                }
                options.serverThreads = value
            case "--machinery":
                let raw = try takeValue("--machinery")
                guard let mode = MachineryMode(rawValue: raw) else {
                    throw EvalFatalError(message: "--machinery must be merlin or baseline, got \(raw)")
                }
                options.machinery = mode
            case "-h", "--help": options.help = true
            default:
                throw EvalFatalError(message: "unknown argument \(argument)\n\n\(usage())")
            }
        }
        return options
    }

    static func main(_ arguments: [String]) async -> Int32 {
        do {
            let options = try parse(arguments)
            if options.help {
                print(usage())
                return 0
            }
            return try await run(options: options)
        } catch let error as EvalFatalError {
            FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
            return 2
        }
    }

    static func run(options: Options) async throws -> Int32 {
        guard let tasksPath = options.tasksPath else {
            throw EvalFatalError(message: "--tasks is required\n\n\(usage())")
        }
        guard let driverName = options.driver else {
            throw EvalFatalError(message: "--driver is required (scripted | naive-baseline | live)\n\n\(usage())")
        }

        let suite = try TaskSpecLoader.load(path: tasksPath)
        let selected: [TaskSpec]
        if options.taskFilter.isEmpty {
            selected = suite.tasks
        } else {
            selected = try suite.tasks(named: options.taskFilter)
        }

        // Live driver (slice 4c): machinery=merlin drives MerlinKernel +
        // LlamaServerActor directly per task (design decision documented in
        // LiveDriver.swift); machinery=baseline rides the EvalTurnDriver
        // seam with the NaiveBaselineDriver completion hook. --interleave
        // runs BOTH modes for every task, alternating which mode goes first
        // per task (SCORING.md §7 fairness rule 4).
        if driverName == "live" {
            let config = try Self.liveConfig(options: options)
            if options.interleave {
                return try await Self.runLiveInterleaved(options: options, suite: suite,
                                                         tasks: selected, config: config)
            }
            if options.machinery == .merlin {
                return try await Self.runLiveMerlin(options: options, suite: suite,
                                                    tasks: selected, config: config)
            }
        }

        // Build the driver per selection.
        var scores: [TaskScore] = []
        var seedHashes: [String: [String: String]] = [:]
        let timestamp = Self.timestamp()
        let runsRoot = URL(fileURLWithPath: options.runsRoot ?? defaultRunsRoot().path)
        let runRoot = try EvalWorkspace.makeRunRoot(runsRoot: runsRoot, timestamp: timestamp)

        for task in selected {
            let taskDriver: any EvalTurnDriver
            switch driverName {
            case "scripted":
                guard let scriptPath = options.scriptPath else {
                    throw EvalFatalError(message: "--driver scripted requires --script <file>")
                }
                let script = try ScriptedDriver.load(path: scriptPath)
                if let declared = script.taskID, declared != task.id {
                    throw EvalFatalError(message: "script \(scriptPath) declares task \(declared) but --task selected \(task.id); scripts are per-task")
                }
                taskDriver = ScriptedDriver(script: script)
            case "naive-baseline", "live" where options.machinery == .baseline:
                // Baseline (SCORING.md §7): machinery all off. With live
                // options present (--driver live ... --machinery baseline,
                // or --driver naive-baseline with --model-path/--port) the
                // skeleton's completion hook is wired to the llama-server;
                // without them the skeleton fails loudly as before.
                let completion: NaiveBaselineDriver.Completion?
                if let liveConfig = try? Self.liveConfig(options: options) {
                    let session = BaselineSession(config: liveConfig)
                    completion = { context in try await session.hook(context) }
                } else if driverName == "naive-baseline" {
                    completion = nil
                } else {
                    throw EvalFatalError(message: "--driver live --machinery baseline requires --model-path and --port")
                }
                taskDriver = NaiveBaselineDriver(maxTurns: task.maxTurns, completion: completion)
            case "live":
                // machinery=merlin is dispatched above (kernel-driven);
                // reaching here means --driver live --machinery baseline
                // fell through without live options.
                throw EvalFatalError(message: "--driver live requires --model-path and --port")
            default:
                throw EvalFatalError(message: "--driver must be scripted, naive-baseline, or live, got \(driverName)")
            }

            let score = try await EvalHarness.run(task: task, runRoot: runRoot,
                                                  driver: taskDriver,
                                                  machinery: options.machinery)
            scores.append(score)
            seedHashes[task.id] = score.bootHashes
            print("  \(score.scorecardToken)\(score.passed ? "" : " — FAILED")")
        }

        let identity = ReportGenerator.RunIdentity(modelID: options.modelID,
                                                   date: ReportGenerator.RunIdentity.today(),
                                                   machinery: options.machinery)
        let card = ReportGenerator.scorecard(scores: scores, suite: suite, identity: identity)
        print(card)

        let report = ReportGenerator.reportJSON(suite: suite, scores: scores,
                                                identity: identity, runRoot: runRoot,
                                                seedHashes: seedHashes)
        let reportPath = options.reportOut ?? runRoot.appendingPathComponent("report.json").path
        try report.serialized(pretty: true).write(toFile: reportPath, atomically: true, encoding: .utf8)
        print("report.json → \(reportPath)")

        let allPassed = scores.allSatisfy(\.passed)
        print(allPassed ? "ALL GREEN (\(scores.count) task\(scores.count == 1 ? "" : "s"))" : "FAILURES PRESENT (\(scores.count - scores.filter(\.passed).count) of \(scores.count) failed)")
        return allPassed ? 0 : 1
    }

    // MARK: - Live driver (slice 4c)

    /// Builds the live driver config from CLI options. Loud on missing
    /// live options; the M8 profile (rung + think floor) comes from the
    /// MerlinProfileStore — the store picks the rung, the CLI only reports
    /// it (surfaced in report.json meta).
    static func liveConfig(options: Options) throws -> LiveDriverConfig {
        guard let modelPath = options.liveModelPath else {
            throw EvalFatalError(message: "--driver live requires --model-path <gguf>")
        }
        guard let port = options.liveServerPort else {
            throw EvalFatalError(message: "--driver live requires --port <n>")
        }
        guard let serverURL = URL(string: "http://127.0.0.1:\(port)") else {
            throw EvalFatalError(message: "--port \(port) does not form a valid URL")
        }
        let store = MerlinProfileStore()
        let config = try LiveDriverConfig.make(serverURL: serverURL,
                                               modelPath: modelPath,
                                               profileStore: store,
                                               temperature: options.liveTemperature,
                                               contextTokens: options.liveContextTokens,
                                               wallGuardSeconds: options.liveWallGuard)
        let note = "live: model \(config.modelID) → family '\(config.profile.family)', " +
            "rung \(config.profile.toolCallMode.rawValue), max_tokens \(config.maxTokens), " +
            "floor \(config.profile.minCompletionTokens) + 512 headroom\n"
        FileHandle.standardError.write(Data(note.utf8))
        return config
    }

    // MARK: - Wedge hardening wiring (slice 6)

    /// The wedge policy from CLI options (enabled flag + relaunch binary/threads).
    static func wedgePolicy(options: Options) -> WedgeRetryPolicy {
        WedgeRetryPolicy(enabled: options.wedgeRetry,
                         serverBinary: options.serverBinary,
                         serverThreads: options.serverThreads)
    }

    /// Runs one merlin-machinery cell under the wedge policy. The supervisor
    /// owns ONLY this run's port (kill + relaunch between cells); wedges.log
    /// and the relaunch log live in the run root so patterns accumulate.
    static func runMerlinCellWithWedgePolicy(task: TaskSpec, runRoot: URL,
                                             config: LiveDriverConfig,
                                             options: Options) async throws -> TaskScore {
        let policy = wedgePolicy(options: options)
        let supervisor = ServerSupervisor(
            port: config.serverURL.port ?? 0,
            modelPath: config.modelPath,
            contextTokens: config.contextTokens,
            temperature: config.temperature,
            threads: policy.serverThreads,
            binaryOverride: policy.serverBinary,
            launchLogURL: runRoot.appendingPathComponent("server-relaunch.log"))
        return try await WedgeHardening.runCell(task: task, runRoot: runRoot, config: config,
                                                policy: policy, supervisor: supervisor,
                                                wedgeLogURL: runRoot.appendingPathComponent("wedges.log")) { cellRoot in
            try await LiveMerlinRunner.runSeeded(task: task, runRoot: cellRoot, config: config)
        }
    }

    /// Baseline twin of the merlin wedge wrapper (same policy, same log).
    static func runBaselineCellWithWedgePolicy(task: TaskSpec, runRoot: URL,
                                               config: LiveDriverConfig,
                                               options: Options) async throws -> TaskScore {
        let policy = wedgePolicy(options: options)
        let supervisor = ServerSupervisor(
            port: config.serverURL.port ?? 0,
            modelPath: config.modelPath,
            contextTokens: config.contextTokens,
            temperature: config.temperature,
            threads: policy.serverThreads,
            binaryOverride: policy.serverBinary,
            launchLogURL: runRoot.appendingPathComponent("server-relaunch.log"))
        return try await WedgeHardening.runCell(task: task, runRoot: runRoot, config: config,
                                                policy: policy, supervisor: supervisor,
                                                wedgeLogURL: runRoot.appendingPathComponent("wedges.log")) { cellRoot in
            try await runLiveBaselineTask(task: task, runRoot: cellRoot, config: config)
        }
    }

    /// machinery=merlin, one mode: every task through MerlinKernel.
    static func runLiveMerlin(options: Options, suite: EvalSuite, tasks: [TaskSpec],
                              config: LiveDriverConfig) async throws -> Int32 {
        let runRoot = try EvalWorkspace.makeRunRoot(
            runsRoot: URL(fileURLWithPath: options.runsRoot ?? Self.defaultRunsRoot().path),
            timestamp: Self.timestamp())
        FileHandle.standardError.write(Data("run root: \(runRoot.path)\n".utf8))
        var scores: [TaskScore] = []
        var seedHashes: [String: [String: String]] = [:]
        for task in tasks {
            do {
                let score = try await runMerlinCellWithWedgePolicy(task: task, runRoot: runRoot,
                                                                   config: config, options: options)
                scores.append(score)
                seedHashes[task.id] = score.bootHashes
                print("  \(score.scorecardToken)\(score.passed ? "" : " — FAILED")")
            } catch {
                // A harness fault (server gone, config) must not poison the
                // whole matrix silently: name it and fail this task loudly.
                print("  \(task.id) ✘ — harness fault: \(error)")
                FileHandle.standardError.write(Data("live-merlin \(task.id): \(error)\n".utf8))
            }
        }
        return try await finishLiveRun(options: options, suite: suite, scores: scores,
                                       seedHashes: seedHashes, runRoot: runRoot, config: config,
                                       machinery: .merlin)
    }

    /// machinery=live, BOTH modes: alternate merlin/baseline per task into
    /// one run tree (fairness rule 4 — thermal/load drift hits both), one
    /// report per mode, and an interleaved combined report with the delta.
    /// Alternate order also flips (merlin first on odd tasks, baseline first
    /// on even) so neither mode systematically rides fresher state.
    static func runLiveInterleaved(options: Options, suite: EvalSuite, tasks: [TaskSpec],
                                   config: LiveDriverConfig) async throws -> Int32 {
        let runRoot = try EvalWorkspace.makeRunRoot(
            runsRoot: URL(fileURLWithPath: options.runsRoot ?? Self.defaultRunsRoot().path),
            timestamp: Self.timestamp())
        FileHandle.standardError.write(Data("run root: \(runRoot.path)\n".utf8))
        // Per-mode sub-roots: the seeder derives each task dir from task.id
        // and refuses a pre-existing dir, so the two machinery modes for the
        // same task must not share one parent.
        let merlinRoot = runRoot.appendingPathComponent("merlin", isDirectory: true)
        let baselineRoot = runRoot.appendingPathComponent("baseline", isDirectory: true)
        try FileManager.default.createDirectory(at: merlinRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baselineRoot, withIntermediateDirectories: true)
        var merlinScores: [TaskScore] = []
        var baselineScores: [TaskScore] = []
        var seedHashes: [String: [String: String]] = [:]

        for (index, task) in tasks.enumerated() {
            let merlinFirst = index % 2 == 0
            var merlinScore: TaskScore?
            var baselineScore: TaskScore?
            for mode in merlinFirst ? [MachineryMode.merlin, .baseline] : [.baseline, .merlin] {
                do {
                    switch mode {
                    case .merlin:
                        merlinScore = try await runMerlinCellWithWedgePolicy(task: task, runRoot: merlinRoot,
                                                                             config: config, options: options)
                    case .baseline:
                        baselineScore = try await runBaselineCellWithWedgePolicy(task: task, runRoot: baselineRoot,
                                                                                 config: config, options: options)
                    }
                } catch {
                    // Harness fault on one cell (server gone, seeder
                    // refusal): record it as a failed harness_fault score
                    // for that mode and keep the matrix moving.
                    let message = "harness fault: \(error)"
                    print("  \(task.id) [\(mode.label)] ✘ — \(message)")
                    FileHandle.standardError.write(Data("live \(task.id)/\(mode.label): \(message)\n".utf8))
                    if mode == .merlin { merlinScore = Self.faultScore(task: task, message: message) }
                    else { baselineScore = Self.faultScore(task: task, message: message) }
                }
            }
            if let score = merlinScore {
                merlinScores.append(score)
                seedHashes["merlin-\(task.id)"] = score.bootHashes
                print("  [merlin] \(score.scorecardToken)\(score.passed ? "" : " — FAILED")")
            }
            if let score = baselineScore {
                baselineScores.append(score)
                seedHashes["baseline-\(task.id)"] = score.bootHashes
                print("  [baseline] \(score.scorecardToken)\(score.passed ? "" : " — FAILED")")
            }
        }

        let merlinCode = try await finishLiveRun(options: options, suite: suite, scores: merlinScores,
                                                 seedHashes: [:], runRoot: runRoot, config: config,
                                                 machinery: .merlin, reportName: "report-merlin.json",
                                                 quietCard: true)
        let baselineCode = try await finishLiveRun(options: options, suite: suite, scores: baselineScores,
                                                   seedHashes: [:], runRoot: runRoot, config: config,
                                                   machinery: .baseline, reportName: "report-baseline.json",
                                                   quietCard: true)
        // Combined interleaved report + delta (§5), plus out.txt.
        let identityMerlin = ReportGenerator.RunIdentity(modelID: options.modelID,
                                                         date: ReportGenerator.RunIdentity.today(),
                                                         machinery: .merlin)
        let identityBaseline = ReportGenerator.RunIdentity(modelID: options.modelID,
                                                           date: ReportGenerator.RunIdentity.today(),
                                                           machinery: .baseline)
        let merlinReport = ReportGenerator.reportJSON(suite: suite, scores: merlinScores,
                                                      identity: identityMerlin, runRoot: merlinRoot,
                                                      seedHashes: seedHashes.filter { $0.key.hasPrefix("merlin-") })
        let baselineReport = ReportGenerator.reportJSON(suite: suite, scores: baselineScores,
                                                        identity: identityBaseline, runRoot: baselineRoot,
                                                        seedHashes: seedHashes.filter { $0.key.hasPrefix("baseline-") })
        var meta = config.metaJSON
        if case .object(var object) = meta {
            object["interleave"] = .bool(true)
            object["interleave_order"] = .string("merlin-first on T01/T03/…, baseline-first on T02/T04/…")
            object["merlin_metrics_source"] = .string("kernel ledger projection (results summarize; signature = tool+result-text; documented in LiveDriver.swift header)")
            meta = .object(object)
        }
        let combined = LiveReport.interleaved(merlin: merlinReport, baseline: baselineReport, meta: meta)
        let reportPath = options.reportOut ?? runRoot.appendingPathComponent("report.json").path
        try combined.serialized(pretty: true).write(toFile: reportPath, atomically: true, encoding: .utf8)
        print("report.json → \(reportPath)")

        // out.txt: both scorecards + the delta table (§5 skeleton).
        var lines: [String] = []
        lines.append(ReportGenerator.scorecard(scores: merlinScores, suite: suite, identity: identityMerlin))
        lines.append("")
        lines.append(ReportGenerator.scorecard(scores: baselineScores, suite: suite, identity: identityBaseline))
        lines.append("")
        lines.append(ReportGenerator.overallReport(rows: [
            ReportGenerator.RunSummary(modelID: options.modelID, machinery: .merlin, scores: merlinScores),
            ReportGenerator.RunSummary(modelID: options.modelID, machinery: .baseline, scores: baselineScores),
        ]))
        let outText = lines.joined(separator: "\n") + "\n"
        let outPath = runRoot.appendingPathComponent("out.txt").path
        try outText.write(toFile: outPath, atomically: true, encoding: .utf8)
        print("out.txt → \(outPath)")
        print(outText)

        _ = (merlinCode, baselineCode) // per-mode exit codes are informational under --interleave
        let allPassed = merlinScores.allSatisfy(\.passed) && baselineScores.allSatisfy(\.passed)
        return allPassed ? 0 : 1
    }

    /// One baseline task end-to-end: seed → drive the seam → score.
    static func runLiveBaselineTask(task: TaskSpec, runRoot: URL,
                                    config: LiveDriverConfig) async throws -> TaskScore {
        let workspace = try EvalWorkspace.seed(task: task, runRoot: runRoot)
        let executor = EvalToolExecutor(workspace: workspace)
        var transcript = EvalTranscript(taskPrompt: task.prompt)
        let session = BaselineSession(config: config)
        let driver = NaiveBaselineDriver(maxTurns: task.maxTurns) { context in
            try await session.hook(context)
        }

        let wallClock = EvalHarness.WallClock(start: Date())
        var turn = 0
        var completedVoluntarily = false
        var harnessTimedOut = false
        while turn < task.maxTurns {
            turn += 1
            transcript.beginTurn(turn)
            let batch: [EvalToolCall]
            do {
                batch = try await driver.toolCalls(prompt: task.prompt, turn: turn,
                                                   events: transcript.recentEvents(limit: 20))
            } catch let error as EvalFatalError where error.message.hasPrefix("harness wall guard") {
                harnessTimedOut = true
                transcript.annotateDriver("harness_timeout: \(error)")
                break
            } catch {
                transcript.annotateDriver("driver failed: \(error)")
                break
            }
            if batch.isEmpty {
                transcript.annotateDriver("driver returned an empty batch; turn consumed")
                break
            }
            let calls = Array(batch.prefix(EvalHarness.maxCallsPerTurn))
            if batch.count > calls.count {
                transcript.annotateDriver("driver returned \(batch.count) calls; kept the first \(calls.count) (protocol max 4 per turn)")
            }
            for call in calls {
                let event = executor.execute(call, turn: turn)
                transcript.record(event)
                if executor.isCompleted { break }
            }
            if executor.isCompleted {
                completedVoluntarily = true
                break
            }
        }
        var score = ScoringEngine.score(task: task, workspace: workspace,
                                        transcript: transcript,
                                        turnsUsed: turn,
                                        budgetExhausted: !completedVoluntarily,
                                        voluntaryStop: completedVoluntarily,
                                        repairCount: session.parseRepairs,
                                        wallClockS: wallClock.elapsed)
        if harnessTimedOut {
            score = TaskScore(taskID: score.taskID, axis: score.axis, tier: score.tier,
                              passed: false, budgetExhausted: score.budgetExhausted,
                              seedDrift: score.seedDrift, voluntaryStop: false,
                              turnsUsed: score.turnsUsed, turnsBudget: score.turnsBudget,
                              wallClockS: score.wallClockS, toolCalls: score.toolCalls,
                              toolErrors: score.toolErrors, recoveryEvents: score.recoveryEvents,
                              repeatFailures: score.repeatFailures, repairCount: score.repairCount,
                              assertionOutcomes: score.assertionOutcomes,
                              seedVerdicts: score.seedVerdicts, bootHashes: score.bootHashes,
                              endReason: "harness_timeout",
                              failReasons: score.failReasons + ["harness_timeout: baseline wall guard fired"],
                              workspacePath: score.workspacePath)
        }
        return score
    }

    /// Scorecard + per-mode report.json for a live run. `reportName`
    /// distinguishes the two per-mode reports under --interleave.
    static func finishLiveRun(options: Options, suite: EvalSuite, scores: [TaskScore],
                              seedHashes: [String: [String: String]], runRoot: URL,
                              config: LiveDriverConfig, machinery: MachineryMode,
                              reportName: String = "report.json",
                              quietCard: Bool = false) async throws -> Int32 {
        let identity = ReportGenerator.RunIdentity(modelID: options.modelID,
                                                   date: ReportGenerator.RunIdentity.today(),
                                                   machinery: machinery)
        let card = ReportGenerator.scorecard(scores: scores, suite: suite, identity: identity)
        if !quietCard { print(card) }
        let report = LiveReport.merged(
            base: ReportGenerator.reportJSON(suite: suite, scores: scores, identity: identity,
                                             runRoot: runRoot, seedHashes: seedHashes),
            meta: config.metaJSON)
        let reportPath = (options.reportOut == nil && reportName != "report.json")
            ? runRoot.appendingPathComponent(reportName).path
            : (options.reportOut ?? runRoot.appendingPathComponent(reportName).path)
        try report.serialized(pretty: true).write(toFile: reportPath, atomically: true, encoding: .utf8)
        print("\(reportName) → \(reportPath)")
        let allPassed = scores.allSatisfy(\.passed)
        if !quietCard {
            print(allPassed ? "ALL GREEN (\(scores.count) task\(scores.count == 1 ? "" : "s"))"
                             : "FAILURES PRESENT (\(scores.count - scores.filter(\.passed).count) of \(scores.count) failed)")
        }
        return allPassed ? 0 : 1
    }

    /// A harness-fault score for one cell: budget-exhausted fail with the
    /// fault named. Passes no assertions review — it exists so the matrix
    /// rows stay complete when the harness itself trips.
    static func faultScore(task: TaskSpec, message: String) -> TaskScore {
        TaskScore(taskID: task.id, axis: task.axis, tier: task.tier,
                  passed: false, budgetExhausted: true, seedDrift: false,
                  voluntaryStop: false, turnsUsed: 0, turnsBudget: task.maxTurns,
                  wallClockS: 0, toolCalls: 0, toolErrors: 0, recoveryEvents: 0,
                  repeatFailures: 0, repairCount: 0, assertionOutcomes: [],
                  seedVerdicts: [], bootHashes: [:], endReason: "harness_fault",
                  failReasons: [message], workspacePath: "(no workspace)")
    }

    static func defaultRunsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kestrel", isDirectory: true)
            .appendingPathComponent("merlin-eval", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}

// SwiftPM executable entry: top-level code in main.swift. The harness is
// async end-to-end (the driver seam is async); a detached task bridges the
// synchronous process entry point.
let cliExitCode: Int32 = await Task.detached {
    await EvalCLI.main(CommandLine.arguments.dropFirst().map { $0 })
}.value
exit(cliExitCode)
