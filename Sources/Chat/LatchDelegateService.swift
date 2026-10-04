// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Delegates a self-contained task to the latch harness as an app-side tool.
/// The model never talks to latch's model directly; it hands off a task string
/// and receives latch's finished report. The binary path and timeout live in
/// settings — nothing about the delegate's model is hardcoded here; latch uses
/// whatever account and model its own configuration selects.
enum LatchDelegateService {
    static let toolName = "latch_delegate"
    static let defaultTimeoutSeconds = 300
    /// Floor for model-requested budgets: below this a multi-step agent run
    /// can only die mid-work (live-fire 2026-10-02: a model asked for 30 s).
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

    static let tool: BuiltinToolInfo = try! BuiltinToolInfo(
        displayName: "Latch delegate",
        name: toolName,
        writesData: true,
        definition: [
            "type": "function",
            "function": [
                "name": toolName,
                "description": "Delegate one self-contained task to the latch agent harness and wait for its final report. Use for work that needs its own multi-step agent run (research, a long refactor sweep, a repo-wide audit) while you keep the main conversation. This is a real agent loop that typically runs for minutes; give it a realistic timeout_seconds (120 or more) or it will be stopped mid-work. The task must be fully self-contained: include every path, constraint, and expected output, because latch cannot ask you questions. IMPORTANT: the model and provider latch uses come from latch's OWN configuration, not from Kestrel — depending on that configuration the delegate may run on the local engine or on REMOTE cloud endpoints, and Kestrel does not route or constrain it. Check latch's provider configuration before delegating anything that must stay on this machine.",
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
        // writes) and models routinely underestimate it — live-fire showed a
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

    private static func run(argv: [String], workingDirectory: String?,
                            timeout: Int) async -> ToolExecutionResult {
        var report = ""
        let outcome = await runStreaming(argv: argv, workingDirectory: workingDirectory,
                                         timeout: timeout, onLaunch: nil,
                                         onOutput: { _, fullSoFar in report = fullSoFar })
        switch outcome {
        case .failed(let reason): return ToolExecutionResult(content: reason, isError: true)
        case .exited(let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : " Partial output:\n" + String(output.prefix(2_000))
            return ToolExecutionResult(
                content: "latch harness exited with status \(status).\(detail)", isError: true)
        case .completed(let output):
            var trimmed = (output.isEmpty ? report : output)
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
    /// raw chunk and then the FULL output so far (copied under the same lock),
    /// so callers can snapshot-replace instead of racing accumulation of their
    /// own. The pipe still accumulates under a lock — a full 64 KiB pipe
    /// deadlocks the child mid-run. Stderr is drained into a bounded tail and
    /// surfaced on failure (provider auth errors, missing model), but never
    /// mixed into a successful reply — the reply is stdout only.
    static func runStreaming(argv: [String], workingDirectory: String?, timeout: Int,
                             onLaunch: (@Sendable (Process) -> Void)?,
                             onOutput: (@Sendable (String, String) -> Void)?) async -> RunOutcome {
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
        // Harnesses can be chatty; drain both pipes continuously or a full
        // 64 KiB pipe buffer deadlocks the child mid-run.
        let lock = NSLock()
        var outData = Data()
        var stderrTail = ""
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
        /// remainder arrives.
        func utf8SafeEnd(_ data: Data) -> Int {
            let count = data.count
            var back = 0
            while back < 3, count - back > decodeOffset {
                let byte = data[data.startIndex + count - back - 1]
                if byte & 0x80 == 0 { return count - back }
                if byte & 0xC0 != 0x80 { return count - back - 1 }
                back += 1
            }
            return count - back
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            lock.lock()
            // Stop accumulating past the reply cap: a runaway harness must
            // not grow memory without bound during the run (the cap was
            // previously applied only after exit), and bounded accumulation
            // also bounds the decode.
            if outData.count < LatchDelegateService.maximumReplyCharacters {
                outData.append(chunk)
                let safeEnd = utf8SafeEnd(outData)
                if safeEnd > decodeOffset {
                    decoded += String(decoding: outData[decodeOffset..<safeEnd], as: UTF8.self)
                    decodeOffset = safeEnd
                }
            }
            let snapshot = decoded
            lock.unlock()
            if let onOutput {
                onOutput(String(decoding: chunk, as: UTF8.self), snapshot)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            lock.lock()
            stderrTail += String(decoding: chunk, as: UTF8.self)
            if stderrTail.count > 4000 {
                stderrTail = String(stderrTail.suffix(2000))
            }
            lock.unlock()
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
            lock.lock()
            var tail = stderrTail
            stderrTail = ""
            lock.unlock()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let stdoutLeftover = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrLeftover = stderr.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            let output = String(decoding: outData + stdoutLeftover, as: UTF8.self)
            outData.removeAll()
            tail += String(decoding: stderrLeftover, as: UTF8.self)
            if tail.count > 4000 { tail = String(tail.suffix(2000)) }
            lock.unlock()
            return (output, tail)
        }
        let results = collectResults()
        let finalOutput = results.output
        let err = results.stderr

        func withStderr(_ headline: String) -> String {
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? headline : headline + "\n\nlatch stderr: " + trimmed.prefix(600)
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
