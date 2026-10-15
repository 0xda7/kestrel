// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import os

/// The latch harness as Kestrel's agent, in two roles: the `latch_delegate`
/// app-side tool (the model hands off a self-contained task and receives the
/// finished report) and the direct chat agent (a conversation turn runs
/// through `runStreaming`, stdout streaming live into the chat, the final
/// report as the assistant reply). The binary path and timeout live in
/// settings. Latch's provider config is owned by Kestrel (LatchBridge): it is
/// generated from Settings → Providers with the local engine as the default,
/// so agent turns stay on this machine unless an active remote route says
/// otherwise.
enum LatchDelegateService {
    static let toolName = "latch_delegate"
    static let defaultTimeoutSeconds = 300
    /// Floor for model-requested budgets: below this a multi-step agent run
    /// can only die mid-work (observed-in-use 2026-10-02: a model asked for 30 s).
    static let minimumTimeoutSeconds = 60
    static let maximumTimeoutSeconds = 900
    static let maximumOutputCharacters = 12_000
    /// Hard cap on a successful primary-assistant reply. Far above any real
    /// report (the delegate tool caps at maximumOutputCharacters), but keeps a
    /// runaway harness from growing memory without bound.
    static let maximumReplyCharacters = 512_000

    static var defaultBinaryPath: String { "~/.latch/bin/latch-harness" }

    static var binaryPath: String {
        let stored = UserDefaults.standard.string(forKey: SettingsKeys.latchBinaryPath)
            ?? defaultBinaryPath
        return NSString(string: stored).expandingTildeInPath
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.latchDelegateEnabled) && isInstalled
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    static var timeoutSeconds: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.latchDelegateTimeout)
        return stored > 0 ? min(stored, maximumTimeoutSeconds) : defaultTimeoutSeconds
    }

    /// Budget for a direct chat turn through the harness: the configured
    /// delegation timeout, floored at the agent minimum (below it a
    /// multi-step turn can only die mid-work) and capped at the hard
    /// maximum.
    static var chatTurnTimeoutSeconds: Int {
        min(max(timeoutSeconds, minimumTimeoutSeconds), maximumTimeoutSeconds)
    }

    static let tool: BuiltinToolInfo = BuiltinToolInfo(
        displayName: "Latch delegate",
        name: toolName,
        writesData: true,
        definition: [
            "type": "function",
            "function": [
                "name": toolName,
                "description": "Delegate one self-contained task to the latch agent harness and wait for its final report. Use for work that needs its own multi-step agent run (research, a long refactor sweep, a repo-wide audit) while you keep the main conversation. This is a real agent loop that typically runs for minutes; give it a realistic timeout_seconds (120 or more) or it will be stopped mid-work. The task must be fully self-contained: include every path, constraint, and expected output, because latch cannot ask you questions. Routing: Kestrel maintains latch's provider configuration from Settings → Providers — by default the delegate runs on THIS machine's local engine, and only an active remote route sends it to that cloud endpoint. If you hand-replaced ~/.latch/v2/provider_config.json, that file applies instead and may point elsewhere.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "task": [
                            "type": "string",
                            "description": "Complete, self-contained instructions for the delegate. State the goal, the relevant paths, the constraints, and what the final report must contain."
                        ],
                        "attach": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional absolute paths (files or folders) the delegate should read before starting."
                        ],
                        "timeout_seconds": [
                            "type": "number",
                            "description": "How long to wait for the delegate before giving up. Default 300; requests are floored at 60 and clamped at 900. Give multi-step work at least 120."
                        ]
                    ],
                    "required": ["task"]
                ]
            ]
        ]
    )

    static func execute(arguments: [String: Any],
                        workingDirectory: String?) async -> ToolExecutionResult {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.latchDelegateEnabled) else {
            return ToolExecutionResult(
                content: "latch_delegate is disabled. Enable it in Chat advanced settings.",
                isError: true)
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            return ToolExecutionResult(
                content: "The latch harness binary was not found or is not executable at \(binaryPath).",
                isError: true)
        }
        guard let task = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty
        else {
            return ToolExecutionResult(
                content: "The 'task' argument is required and must be a non-empty string.",
                isError: true)
        }
        let attach = (arguments["attach"] as? [Any])?.compactMap { $0 as? String } ?? []
        // Floor at 60 s: latch is a multi-step agent loop (it plans, reads,
        // writes) and models routinely underestimate it — practice showed a
        // model requesting 30 s, which can only end in a budget kill. The
        // request is honored above the floor and clamped at the maximum.
        let timeout = {
            let requested: Int?
            if let value = arguments["timeout_seconds"] as? NSNumber, value.intValue > 0 {
                requested = value.intValue
            } else if let value = arguments["timeout_seconds"] as? Int, value > 0 {
                requested = value
            } else {
                requested = nil
            }
            return min(max(requested ?? timeoutSeconds, minimumTimeoutSeconds), maximumTimeoutSeconds)
        }()

        var argv = [binaryPath, "-p", task]
        for path in attach { argv += ["--attach", path] }

        return await run(argv: argv, workingDirectory: workingDirectory, timeout: timeout)
    }

    /// Private home for the embedded latch harness. The harness keeps its
    /// sessions, history and state under `~/.zcode` and its provider config
    /// under `~/.latch`; with the inherited home those landed in the
    /// operator's real ZCode data — chat history showing up inside the ZCode
    /// app and the agent reading that app's settings. Everything the embedded
    /// agent writes now lives under Kestrel's Application Support, seeded
    /// once with a minimal boot config; the two products never share state.
    static var sandboxHome: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Kestrel/latch-home")
        let fm = FileManager.default
        let latchV2 = home.appendingPathComponent(".latch/v2")
        try? fm.createDirectory(at: latchV2, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Idempotent tighten on every access: the tree holds the plaintext
        // provider_config.json LatchBridge writes, so a directory created
        // looser (by an older build or a restored backup) is corrected here,
        // not only at creation.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: latchV2.path)
        let cli = home.appendingPathComponent(".zcode/cli")
        try? fm.createDirectory(at: cli, withIntermediateDirectories: true)
        let bootConfig = cli.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: bootConfig.path) {
            // A minimal empty boot config — deliberately NOT a copy of the
            // operator's real ~/.zcode/cli/config.json. That file is the
            // outer product's own state (plugin and per-skill enablement
            // pointing at the operator's real paths), and seeding the sandbox
            // from it would bridge credentials and state into the embedded
            // agent's HOME. Providers and the gateway key reach the harness
            // only through LatchBridge's provider_config.json and
            // LATCH_API_KEY; because nothing is copied, there is also nothing
            // to refresh when the outer config changes.
            try? Data("{}".utf8).write(to: bootConfig, options: .atomic)
        }
        return home
    }

    /// Environment the harness runs in: an explicit allowlist on top of its
    /// own isolated home (see sandboxHome) — nothing inherited wholesale.
    /// Providers are user-configured in Settings → Providers and reach the
    /// harness only through the provider_config.json LatchBridge generates
    /// in that sandbox home — no hidden embedded login, no baked-in gateway
    /// key. A remote provider the user adds (z.ai or any OpenAI-compatible
    /// endpoint) carries its own key inside that file. Building the child
    /// environment by allowlist (not inherit-and-subtract) also keeps any
    /// OTHER provider credential exported by the launching environment
    /// (OPENAI_API_KEY, ANTHROPIC_API_KEY, …) out of the separate product's
    /// process.
    static func childEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": Self.sandboxHome.path,
            "PATH": parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": parent["TMPDIR"] ?? NSTemporaryDirectory(),
        ]
        // Locale only: the harness's messages should match the operator's
        // terminal encoding, and locale carries no credentials.
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] where parent[key] != nil {
            env[key] = parent[key]
        }
        // The harness needs its provider config inside the sandbox; if no
        // server event has written one yet (fresh sandbox), generate it now
        // so a first chat turn can never boot into the 0.89.6 failure shape.
        if !FileManager.default.fileExists(atPath: LatchBridge.configFileURL.path) {
            _ = LatchBridge.sync()
        }
        // The harness refuses to boot without a gateway key (the entire
        // 0.89.6 outage). Only a key the operator actually stored passes
        // through — never a baked-in default, never a hidden login; every
        // provider route itself still comes from LatchBridge's file.
        if let stored = LocalSecretStore.value("latch-api-key") {
            env["LATCH_API_KEY"] = stored
        }
        return env
    }

    private static func run(argv: [String], workingDirectory: String?,
                            timeout: Int) async -> ToolExecutionResult {
        // Boxed: onOutput is @Sendable, so the pump thread may only touch the
        // accumulator through a lock.
        let report = OSAllocatedUnfairLock<String>(initialState: "")
        let outcome = await runStreaming(argv: argv, workingDirectory: workingDirectory,
                                         timeout: timeout, onLaunch: nil,
                                         onOutput: { fullSoFar in report.withLock { $0 = fullSoFar } })
        switch outcome {
        case .failed(let reason): return ToolExecutionResult(content: reason, isError: true)
        case .exited(let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : " Partial output:\n" + String(output.prefix(2_000))
            return ToolExecutionResult(
                content: "latch harness exited with status \(status).\(detail)", isError: true)
        case .completed(let output):
            var trimmed = (output.isEmpty ? report.withLock { $0 } : output)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                trimmed = "The delegate finished without producing output."
            }
            return ToolExecutionResult(content: ChatToolsService.clampedToolResult(trimmed),
                                       isError: false)
        }
    }

    /// Outcome of a streaming latch run. `failed` covers launch errors and
    /// timeouts (reason already carries the user-facing text); the other cases
    /// carry the accumulated stdout so callers can show partial output.
    enum RunOutcome {
        case failed(reason: String)
        case exited(status: Int32, output: String)
        case completed(output: String)
    }

    /// Streams a latch run: mirrors `run()`'s Process/Pipe machinery, but hands
    /// the accumulated stdout to `onOutput` as it arrives so the UI can render
    /// the reply live while latch's agent loop works. `onOutput` receives the
    /// FULL output so far (copied under the same lock), so callers can
    /// snapshot-replace instead of racing accumulation of their own. The pipe
    /// still accumulates under a lock — a full 64 KiB pipe deadlocks the child
    /// mid-run. Stderr is drained into a bounded tail and surfaced on failure
    /// (provider auth errors, missing model), but never mixed into a
    /// successful reply — the reply is stdout only.
    static func runStreaming(argv: [String], workingDirectory: String?, timeout: Int,
                             onLaunch: (@Sendable (Process) -> Void)?,
                             onOutput: (@Sendable (String) -> Void)?) async -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        if let workingDirectory, FileManager.default.fileExists(atPath: workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = Self.childEnvironment()
        // Harnesses can be chatty; drain both pipes continuously or a full
        // 64 KiB pipe buffer deadlocks the child mid-run.
        /// All mutable pump state behind one lock. `@unchecked Sendable`:
        /// every field is only touched with `lock` held, which is what makes
        /// the readability handlers safe to run on the pipe's own threads.
        final class PumpState: @unchecked Sendable {
            let lock = NSLock()
            var outData = Data()
            var stderrTail = ""
            /// Bytes of an incomplete trailing UTF-8 sequence read from stderr;
            /// at most 3, held until the sequence's remainder arrives.
            var stderrRemainder = Data()
            // Incremental decode state: `decoded` grows by only the NEW bytes each
            // chunk, instead of re-decoding the whole accumulation per chunk
            // (which is O(n²) — a 512 KB reply with line-sized chunks re-decoded
            // ~1.3 GB of UTF-8). `decodeOffset` always sits on a UTF-8 sequence
            // boundary, so multi-byte characters split across pipe chunks are
            // completed on the next chunk rather than corrupted.
            var decoded = ""
            var decodeOffset = 0

            /// Last offset in `data` that ends on a complete UTF-8 sequence: scan
            /// back at most 3 bytes (the longest continuation run) for an ASCII or
            /// leading byte; a truncated sequence tail stays undecoded until its
            /// remainder arrives. `from` is the offset the decode has already
            /// consumed (0 for the stderr remainder buffer).
            static func utf8SafeEnd(_ data: Data, from offset: Int) -> Int {
                let count = data.count
                var back = 0
                while back < 3, count - back > offset {
                    let byte = data[data.startIndex + count - back - 1]
                    if byte & 0x80 == 0 { return count - back }
                    if byte & 0xC0 != 0x80 { return count - back - 1 }
                    back += 1
                }
                return count - back
            }
        }
        let state = PumpState()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            state.lock.lock()
            // Stop accumulating past the reply cap: a runaway harness must
            // not grow memory without bound during the run (the cap was
            // previously applied only after exit), and bounded accumulation
            // also bounds the decode.
            if state.outData.count < LatchDelegateService.maximumReplyCharacters {
                state.outData.append(chunk)
                let safeEnd = PumpState.utf8SafeEnd(state.outData, from: state.decodeOffset)
                if safeEnd > state.decodeOffset {
                    state.decoded += String(decoding: state.outData[state.decodeOffset..<safeEnd], as: UTF8.self)
                    state.decodeOffset = safeEnd
                }
            }
            let snapshot = state.decoded
            state.lock.unlock()
            if let onOutput {
                onOutput(snapshot)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            state.lock.lock()
            // Same UTF-8 sequence boundary as stdout: a multi-byte character
            // split across pipe chunks stays in the remainder buffer until it
            // completes, instead of decoding to U+FFFD in the failure tail.
            let pending = state.stderrRemainder + chunk
            let safeEnd = PumpState.utf8SafeEnd(pending, from: 0)
            state.stderrTail += String(decoding: pending.prefix(safeEnd), as: UTF8.self)
            state.stderrRemainder = safeEnd < pending.count
                ? Data(pending.dropFirst(safeEnd)) : Data()
            if state.stderrTail.count > 4000 {
                state.stderrTail = String(state.stderrTail.suffix(2000))
            }
            state.lock.unlock()
        }

        do { try process.run() } catch {
            return .failed(reason: "Failed to launch latch harness: \(error.localizedDescription)")
        }
        onLaunch?(process)

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @Sendable in
                process.waitUntilExit()
                return false
            }
            group.addTask { @Sendable in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                guard process.isRunning else { return false }
                process.terminate()
                // SIGKILL escalation runs detached: the budget verdict must
                // not wait on the grace period, or a fast-dying child wins
                // the race and the run is misread as a clean exit.
                Task.detached { @Sendable in
                    for _ in 0..<50 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if !process.isRunning { return }
                    }
                    kill(process.processIdentifier, SIGKILL)
                }
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        // Finalization under the reader lock, routed through a synchronous
        // helper so the lock is never taken from an async context. Both pipes
        // drain to EOF first — the child has exited (or SIGKILL escalation
        // bounds the wait), so stderr written just before exit is captured
        // instead of being lost to the async handler's lag.
        func collectResults() -> (output: String, stderr: String) {
            state.lock.lock()
            var tail = state.stderrTail
            state.stderrTail = ""
            let stderrRemainder = state.stderrRemainder
            state.stderrRemainder = Data()
            state.lock.unlock()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let stdoutLeftover = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrLeftover = stderr.fileHandleForReading.readDataToEndOfFile()
            state.lock.lock()
            let output = String(decoding: state.outData + stdoutLeftover, as: UTF8.self)
            state.outData.removeAll()
            // The pending remainder joins the post-exit leftover, so a
            // sequence split across the last chunk and the drain still
            // completes.
            tail += String(decoding: stderrRemainder + stderrLeftover, as: UTF8.self)
            if tail.count > 4000 { tail = String(tail.suffix(2000)) }
            state.lock.unlock()
            return (output, tail)
        }
        let results = collectResults()
        let finalOutput = results.output
        let err = results.stderr

        func withStderr(_ headline: String) -> String {
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            var prefix = ""
            // The #1 real-world latch failure is the local engine being down;
            // the harness's Node stack hides ECONNREFUSED in a wall of text.
            // Name it first, in both languages, with the one-click fix.
            if trimmed.contains("ECONNREFUSED") {
                prefix = "El motor local no está en marcha — pulsa Inicio en la pestaña Home/Servers. / "
                    + "The local engine is not running — press Start on the Home/Servers tab. "
                    + "(ECONNREFUSED)\n\n"
            }
            return prefix + (trimmed.isEmpty ? headline : headline + "\n\nlatch stderr: " + trimmed.prefix(600))
        }

        if timedOut {
            let partial = String(finalOutput.prefix(maximumOutputCharacters))
            return .failed(reason: withStderr(
                "latch exceeded its \(timeout)s budget and was stopped. Partial output:\n\(partial)"))
        }
        if process.terminationStatus == 0 {
            let output = String(finalOutput.prefix(maximumReplyCharacters))
            return .completed(output: output)
        }
        // Raw output plus a bounded stderr suffix: abnormal-exit diagnostics
        // (provider auth errors, missing model) reach the user, while the
        // callers keep composing their own status headline.
        let status = process.terminationStatus
        let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrSuffix = trimmedErr.isEmpty
            ? "" : "\n\nlatch stderr: " + String(trimmedErr.prefix(600))
        return .exited(status: status, output: finalOutput + stderrSuffix)
    }
}
