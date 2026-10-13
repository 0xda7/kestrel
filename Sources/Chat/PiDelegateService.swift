// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Streams a Kestrel conversation turn through the Pi agent runtime (the
/// engine under llm-space, https://github.com/earendil-works/pi and
/// https://github.com/deer-flow/llm-space, both MIT) as an external sidecar —
/// the same engine-independence pattern as LatchDelegateService. Pi is never
/// bundled, never patched: its binary path, model pattern, thinking level and
/// timeout all come from settings, and provider credentials come from Pi's own
/// auth chain (`pi auth`, models.json, env) — never from this process, never
/// on the command line, never in any file Kestrel writes.
///
/// Confinement (observed 2026-10-02): pi ships with
/// bash/read/edit/write tools ACTIVE, and system-prompt text cannot disable
/// them — a chat turn once wrote Swift files into this repository. Chat turns
/// therefore pass `--no-tools` by default; only an explicit per-conversation
/// agent opt-in leaves pi's tools enabled (with its own larger budget).
///
/// Output contract: `pi --mode json` emits one JSON record per LF-terminated
/// line (LF is the only delimiter; UTF-8 multi-byte sequences never contain
/// 0x0A, so byte scanning is safe). Deltas stream from
/// `message_update.assistantMessageEvent` records; the final
/// `message_end` whose message role is "assistant" is authoritative and
/// replaces the accumulated deltas, which can drop formatting.
enum PiDelegateService {
    static let defaultBinaryPath = "/usr/local/bin/pi"
    /// Chat-turn budget (tools off). Configurable; the agent budget below is
    /// separate so enabling tools does not silently inherit the chat cap.
    static let defaultTimeoutSeconds = 900
    static let maximumTimeoutSeconds = 1800
    /// Agent-mode budget: a tool-using turn legitimately runs longer than a
    /// plain reply, so the cap starts higher (capped by maximumTimeoutSeconds).
    static let defaultAgentTimeoutSeconds = 1800
    /// Hard cap on accumulated stream text. A chat reply past this is a
    /// runaway (not a real answer); the cap keeps memory bounded no matter
    /// what the runtime emits.
    static let maximumStreamCharacters = 512_000
    /// Session files land here — one JSONL trace per turn (llm-space trace
    /// convention; `--no-session` probe-proven to suppress the file entirely).
    /// Kestrel never resumes them — each turn stays self-contained; the files
    /// exist so the user can inspect and replay runs.
    static var sessionsDirectory: String {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory,
                                                       .userDomainMask, true).first
            ?? NSHomeDirectory() + "/Library/Application Support"
        return base + "/Kestrel/pi-sessions"
    }

    static var binaryPath: String {
        let stored = UserDefaults.standard.string(forKey: SettingsKeys.piBinaryPath)
            ?? defaultBinaryPath
        return NSString(string: stored).expandingTildeInPath
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.piPrimaryEnabled) && isInstalled
    }

    /// Budget for a plain chat turn (tools disabled by confinement).
    static var chatTimeoutSeconds: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.piTimeout)
        return stored > 0 ? min(stored, maximumTimeoutSeconds) : defaultTimeoutSeconds
    }

    /// Budget for an agent-opt-in turn (pi's tools enabled).
    static var agentTimeoutSeconds: Int {
        min(defaultAgentTimeoutSeconds, maximumTimeoutSeconds)
    }

    /// Model pattern for `--model` (fuzzy, glob, or provider/id). Empty means
    /// "let Pi's own configuration choose" — no model is ever hardcoded here.
    static var configuredModel: String {
        UserDefaults.standard.string(forKey: SettingsKeys.piModel) ?? ""
    }

    /// Optional provider restriction paired with --model. Empty = omit.
    static var configuredProvider: String {
        UserDefaults.standard.string(forKey: SettingsKeys.piProvider) ?? ""
    }

    /// Thinking level passed as `--thinking <level>` when thinking is enabled.
    /// pi 1.0.0 accepts off|minimal|low|medium|high|xhigh|max (verified against
    /// `pi --help` 2026-10-02). Empty or "default" omits the flag so pi's own
    /// configuration decides; "off" is never emitted from here because callers
    /// pass `thinking: false` for that case.
    static var configuredThinkingLevel: String {
        let stored = UserDefaults.standard.string(forKey: SettingsKeys.piThinkingLevel) ?? ""
        let level = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (level.isEmpty || level == "default") ? "" : level
    }

    /// Builds the pi argv for one conversation turn.
    /// - Chats run with `--no-tools`: pi answers as an assistant only. The
    ///   system prompt's "tools disabled" line is advisory; this flag is the
    ///   enforcement (observed in real use: a chat turn once edited this repository).
    /// - Agent opt-in (`agentMode`) omits the flag, restoring pi's native
    ///   tool surface under the conversation's working directory.
    /// - Session saving stays ON: every turn writes a JSONL trace under
    ///   sessionsDirectory for inspection/replay.
    /// - `systemPrompt` rides `--system-prompt`, so it reaches the model as a
    ///   real system message (llm-space semantics) instead of prompt preamble.
    static func argv(prompt: String, thinking: Bool, agentMode: Bool = false,
                     systemPrompt: String? = nil) -> [String] {
        var argv = [binaryPath, "--mode", "json",
                    "--session-dir", sessionsDirectory]
        if !agentMode { argv += ["--no-tools"] }
        // pi resolves custom (models.json) providers only through the
        // combined "provider/model" form of --model; a bare --provider is
        // ignored for them and the run silently falls back to pi's built-in
        // default (openrouter) — the routing bug that sent runs to a dead key.
        let provider = configuredProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let systemPrompt,
           !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            argv += ["--system-prompt", systemPrompt]
        } else {
            argv += ["--system-prompt", piSystemPrompt(provider: provider, model: model)]
        }
        if !thinking {
            argv += ["--thinking", "off"]
        } else {
            let level = configuredThinkingLevel
            if !level.isEmpty { argv += ["--thinking", level] }
        }
        if !provider.isEmpty, !model.isEmpty {
            argv += ["--model", "\(provider)/\(model)"]
        } else if !model.isEmpty {
            argv += ["--model", model]
        } else if !provider.isEmpty {
            argv += ["--provider", provider]
        }
        argv += ["-p", prompt]
        return argv
    }

    /// Fallback persona when the conversation carries no system prompt: this
    /// sidecar answers chat turns, it does not manage a repository.
    /// The sidecar cannot see its own provider or model, so the serving
    /// identity rides in the system prompt: asked "what model are you", it
    /// must answer in one word, not discover it has no introspection after
    /// five turns. The uncertainty rule is one line on purpose: name the
    /// missing input and ask — never lecture, never pivot to a résumé.
    static func piSystemPrompt(provider: String, model: String) -> String {
        let identity = provider.isEmpty || model.isEmpty
            ? "a model served through Kestrel on this Mac"
            : "\(model), served by \(provider) through Kestrel on this Mac"
        return "You are the Kestrel assistant, answered by \(identity). "
            + "Reply directly as the assistant; your reply becomes the next assistant message. "
            + "When asked what you are, answer from this identity in exactly the form the user requested. "
            + "When you lack information, say in one sentence what is missing and ask for it — "
            + "never lecture about premises and never answer a direct question with a capabilities list."
    }

    enum RunOutcome {
        case completed(output: String)
        case exited(status: Int32, output: String)
        case failed(reason: String)
        /// True when the run ended cleanly but produced no visible reply —
        /// e.g. the model spent its whole budget thinking (observed in real use: the
        /// "empty assistant bubble" report). Callers must surface a failure,
        /// never a blank bubble.
        var isEmptySuccess: Bool {
            switch self {
            case .completed(let output):
                return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }
    }

    /// pi is a Node script; GUI-spawned Kestrel processes don't inherit a
    /// shell PATH, so guarantee the standard local prefixes where npm global
    /// binaries and node live. Credentials are never passed here — PATH only.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        if !existing.split(separator: ":").contains("/usr/local/bin") {
            env["PATH"] = "/usr/local/bin:/usr/local/sbin:" + existing
        }
        return env
    }

    /// Creates the trace directory if needed. Called before each run so a
    /// turn never fails just because the folder is missing.
    static func ensureSessionsDirectory() {
        try? FileManager.default.createDirectory(atPath: sessionsDirectory,
                                                 withIntermediateDirectories: true)
    }

    /// Most recently written trace file, newest first — the entry point for
    /// llm-space-style inspection from the UI.
    static func latestSessionTraces(limit: Int = 20) -> [(path: String, date: Date)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDirectory) else { return [] }
        let dir = URL(fileURLWithPath: sessionsDirectory)
        let entries: [(String, Date)] = names.compactMap { name in
            guard name.hasSuffix(".jsonl") else { return nil }
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (url.path, date)
        }
        return Array(entries.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    /// Runs pi in JSON mode and reports the visible reply as it streams.
    /// `onOutput` receives (reasoningSoFar, visibleSoFar) full snapshots from
    /// a background reader thread — snapshot-replace, same contract as the
    /// latch stream pump — so thinking and tool activity reach the reasoning
    /// panel live instead of being discarded. stderr is drained and kept to
    /// a bounded tail so a provider failure surfaces real diagnostics
    /// instead of an empty reply.
    static func runStreaming(argv: [String], workingDirectory: String?, timeout: Int,
                             onLaunch: (@Sendable (Process) -> Void)?,
                             onOutput: (@Sendable (String, String) -> Void)?)
        async -> (reasoning: String, outcome: RunOutcome) {
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
        process.environment = childEnvironment()

        /// All mutable pump state behind one lock. `@unchecked Sendable`:
        /// every field is only touched with `lock` held (apply is documented
        /// to be called with it held), which is what makes the readability
        /// handlers safe to run on the pipe's own threads.
        final class PumpState: @unchecked Sendable {
            let lock = NSLock()
            var lineBuffer = Data()
            var visible = ""
            var reasoning = ""
            var finalAssistant: String?
            var stderrTail = ""

            /// Applies one parsed record to the guarded state. Called with the
            /// lock HELD; the caller delivers any onOutput snapshot after unlocking.
            func apply(_ line: String) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                      let record = (try? JSONSerialization.jsonObject(with: data))
                          as? [String: Any] else { return }
                let type = record["type"] as? String ?? ""
                switch type {
                case "message_update":
                    guard let event = record["assistantMessageEvent"] as? [String: Any],
                          let kind = event["type"] as? String else { return }
                    switch kind {
                    case "text_delta":
                        guard let delta = event["delta"] as? String else { return }
                        guard visible.count < PiDelegateService.maximumStreamCharacters else { return }
                        visible += delta
                    case "reasoning_delta", "thinking_delta":
                        guard let delta = event["delta"] as? String else { return }
                        guard reasoning.count < PiDelegateService.maximumStreamCharacters else { return }
                        reasoning += delta
                    case "toolcall_start", "tool_execution_start":
                        // Tool activity belongs in the reasoning panel: visible in
                        // real time, never mistaken for the reply itself.
                        let name = event["toolName"] as? String
                            ?? event["name"] as? String ?? "tool"
                        reasoning += "\n[tool: \(name)]\n"
                    default:
                        break
                    }
                case "message_end":
                    guard let message = record["message"] as? [String: Any],
                          message["role"] as? String == "assistant" else { return }
                    if let text = PiDelegateService.assistantText(from: message["content"]) {
                        finalAssistant = text
                    }
                default:
                    break
                }
            }
        }
        let state = PumpState()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            state.lock.lock()
            state.lineBuffer.append(chunk)
            // LF framing: split complete lines, keep the trailing remainder.
            // Records mutate the guarded state here; snapshots for onOutput are
            // taken under the lock and delivered after it is released, so the
            // callback can never race (or deadlock against) the accumulator.
            var snapshot: (reasoning: String, visible: String)?
            while let newline = state.lineBuffer.firstIndex(of: 0x0A) {
                let lineData = state.lineBuffer[state.lineBuffer.startIndex..<newline]
                state.lineBuffer.removeSubrange(state.lineBuffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                state.apply(line)
                snapshot = (state.reasoning, state.visible)
            }
            state.lock.unlock()
            if let snapshot, let onOutput {
                onOutput(snapshot.reasoning, snapshot.visible)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            state.lock.lock()
            state.stderrTail += String(decoding: chunk, as: UTF8.self)
            if state.stderrTail.count > 4000 {
                state.stderrTail = String(state.stderrTail.suffix(2000))
            }
            state.lock.unlock()
        }

        do { try process.run() } catch {
            return (state.reasoning, .failed(
                reason: "Failed to launch the pi runtime: \(error.localizedDescription)"))
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

        // Finalization runs on the reader-locked state; routed through a
        // synchronous helper so the lock is never taken from an async context.
        // Both pipes are drained to EOF first — the child has exited, so this
        // returns immediately, and stderr written just before exit is captured
        // instead of being lost to the async handler's lag.
        func collectResults() -> (streamed: String, authoritative: String?,
                                  reasoning: String, stderr: String) {
            state.lock.lock()
            let remainder = state.lineBuffer.isEmpty ? nil : String(decoding: state.lineBuffer, as: UTF8.self)
            state.lineBuffer.removeAll()
            if let remainder { state.apply(remainder) }
            var tail = state.stderrTail
            state.stderrTail = ""
            state.lock.unlock()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let stdoutLeftover = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrLeftover = stderr.fileHandleForReading.readDataToEndOfFile()
            state.lock.lock()
            if !stdoutLeftover.isEmpty {
                // Final line(s) without a trailing LF still parse as records.
                for line in String(decoding: stdoutLeftover, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true) {
                    state.apply(String(line))
                }
            }
            // An in-flight readabilityHandler can append after the
            // removeAll() above but before the handlers were detached —
            // nil'ing the handler fences nothing. Drain whatever reappeared
            // so a late authoritative message_end is never lost.
            if !state.lineBuffer.isEmpty {
                let late = String(decoding: state.lineBuffer, as: UTF8.self)
                state.lineBuffer.removeAll()
                for line in late.split(separator: "\n", omittingEmptySubsequences: true) {
                    state.apply(String(line))
                }
            }
            tail += String(decoding: stderrLeftover, as: UTF8.self)
            if tail.count > 4000 { tail = String(tail.suffix(2000)) }
            let values = (streamed: state.visible, authoritative: state.finalAssistant,
                          reasoning: state.reasoning, stderr: tail)
            state.lock.unlock()
            return values
        }
        let results = collectResults()
        let streamed = results.streamed
        let authoritative = results.authoritative
        let accumulatedReasoning = results.reasoning
        let err = results.stderr

        if timedOut {
            let partial = authoritative ?? streamed
            if partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Nothing to preserve: say so instead of a bare headline, and
                // never synthesize an empty "success".
                return (accumulatedReasoning, .failed(reason: Self.unavailableMessage(
                    headline: "pi excedió su presupuesto de \(timeout)s y fue detenido / pi exceeded its \(timeout)s budget and was stopped",
                    partial: "[no reply produced before the budget ran out]", stderr: err)))
            }
            return (accumulatedReasoning, .failed(reason: Self.unavailableMessage(
                headline: "pi excedió su presupuesto de \(timeout)s y fue detenido / pi exceeded its \(timeout)s budget and was stopped",
                partial: partial, stderr: err)))
        }
        let reply = authoritative ?? streamed
        if process.terminationStatus == 0 {
            return (accumulatedReasoning, .completed(output: reply))
        }
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (accumulatedReasoning, .failed(reason: Self.unavailableMessage(
                headline: "pi terminó de forma anómala (estado \(process.terminationStatus)). / pi exited abnormally (status \(process.terminationStatus)).",
                partial: "", stderr: err)))
        }
        // Abnormal exit with partial output: the bounded stderr tail rides
        // along (provider auth errors, model-not-found) instead of being lost —
        // same diagnostics contract as the latch sidecar.
        let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputWithDiagnostics = trimmedErr.isEmpty
            ? reply : reply + "\n\npi stderr: " + String(trimmedErr.prefix(600))
        return (accumulatedReasoning,
                .exited(status: process.terminationStatus, output: outputWithDiagnostics))
    }

    /// Bilingual user-facing failure text. A partial reply is preserved and
    /// the pi stderr tail (provider auth errors, model-not-found) rides along,
    /// bounded. The engine is never silently substituted.
    static func unavailableMessage(headline: String, partial: String, stderr: String) -> String {
        var text = headline
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text += "\n\n" + trimmed }
        let errTrimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errTrimmed.isEmpty {
            text += "\n\npi stderr: " + String(errTrimmed.prefix(600))
        }
        return text
    }

    /// Extracts the visible text of an assistant message: content may be a
    /// plain string or an array of typed blocks ({type:"text",text:...}).
    /// Thinking blocks are skipped — reasoning arrives via the event stream
    /// and must never leak into the visible reply.
    static func assistantText(from content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            let type = block["type"] as? String ?? "text"
            guard type == "text", let text = block["text"] as? String else { return nil }
            return text
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}
