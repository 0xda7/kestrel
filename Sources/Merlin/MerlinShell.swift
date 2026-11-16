// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import JavaScriptCore

/// Kernel-side execution machinery for the two compute tools (slice 3):
/// `shell_run` (`MerlinShell`) and `js_eval` (`MerlinJS`).
///
/// Both run in the task workspace's frame of reference and return
/// model-facing text through a fixed, guardian-checkable result contract:
/// a result whose first line does not match the contract is treated by the
/// M4 guardian as a suspicious result, not as evidence of success.
///
/// SECURITY POSTURE (MISSION MERLIN security wave 2, 2026-11-15):
///
/// `shell_run` executes `/bin/sh -c` under a generated macOS seatbelt
/// profile (`/usr/bin/sandbox-exec -p`) when that facility is usable on
/// the host: network operations are DENIED, file WRITES are confined to
/// the task workspace (plus its scratch TMPDIR), and reads of the
/// operator's real HOME are denied — the child's `HOME` variable points at
/// a workspace scratch directory, so `~` expansion stays inside the
/// workspace. Availability is decided ONCE per process by
/// `MerlinShell.probe()`, a real spawn of `/usr/bin/true` under
/// `(allow default)` — no OS-version guessing. When the probe fails (the
/// documented nested-Seatbelt case: a host already inside a seatbelt
/// refuses `sandbox_apply` with EPERM/exit 71 — or the probe binary itself
/// is missing, which macOS 26 made true of `/bin/true`: exec fails ENOENT
/// with the same exit 71), the runner degrades to the
/// SCREENING fallback for the process's lifetime: the command text is
/// screened against the ledger filename (case-insensitively) and against
/// tokens naming absolute paths outside the workspace, and the model-facing
/// description states that honest boundary instead. Both branches correct
/// the pre-hardening false "network disabled" schema claim with what is
/// actually enforced.
///
/// The APPROACH of the process runner mirrors
/// `Sources/MerlinEval/ShellRunner.swift` (`EvalShell`): `/bin/sh -c`, a
/// fixed environment allowlist, concurrent pipe draining, and a
/// SIGTERM → SIGKILL timeout ladder — escalated by a PROCESS GROUP: the
/// child is spawned with `POSIX_SPAWN_SETPGROUP` (its own process group),
/// so the timeout path kills the whole tree with `kill(-pgid)` and a
/// backgrounded grandchild (`x &`, `nohup`, `disown`) cannot survive the
/// ladder and wedge the pipe drain (the pre-hardening hang). The drain
/// itself is bounded: after the group is down, the pipes get a 2 s
/// deadline to reach EOF, and a stuck drain abandons its buffers rather
/// than hanging the run.
public enum MerlinShell {
    /// Shell-runner configuration. The defaults are the contract: 30 s
    /// wall clock, 4000-character output cap, and a five-variable
    /// environment. Checks may tighten `timeout` for fast, deterministic
    /// kill-path coverage; nothing else is negotiable per run.
    public struct Configuration: Sendable {
        /// Wall-clock budget for one command. On expiry the process GROUP
        /// gets SIGTERM, then SIGKILL after a short grace period.
        public var timeout: TimeInterval = 30
        /// Combined stdout+stderr character cap in the model-facing text.
        public var outputCharacterCap: Int = 4000
        /// The exact environment handed to the child process. Nothing from
        /// this process leaks through: no proxy variables, no credentials,
        /// no network-facing settings. `HOME` here is a placeholder —
        /// `runBlocking` substitutes the workspace scratch directory (and
        /// `TMPDIR` the scratch tmp) so `~` expansion can never leave the
        /// workspace, in BOTH confinement modes.
        public var environmentAllowlist: [String: String] = Self.defaultEnvironment

        public init() {}

        /// PATH/HOME/TMPDIR/LANG/LC_ALL — the same allowlist shape the eval
        /// harness uses, so kernel and harness sandboxes stay comparable.
        public static let defaultEnvironment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
    }

    /// One finished (or killed) command.
    public struct Outcome: Sendable, Equatable {
        /// Process exit status, or nil when the process was killed on
        /// timeout (`timedOut` distinguishes the two).
        public let exitCode: Int32?
        public let timedOut: Bool
        public let stdout: String
        public let stderr: String
        /// Which confinement boundary actually guarded this run: `.seatbelt`
        /// (profile applied) or `.screening` (fallback screens only).
        public let confinement: ConfinementMode

        public init(exitCode: Int32?, timedOut: Bool, stdout: String, stderr: String,
                    confinement: ConfinementMode = .screening) {
            self.exitCode = exitCode
            self.timedOut = timedOut
            self.stdout = stdout
            self.stderr = stderr
            self.confinement = confinement
        }

        public var ok: Bool { !timedOut && exitCode == 0 }
    }

    /// Which shell boundary shipped for a given run.
    public enum ConfinementMode: String, Sendable, Equatable {
        /// `sandbox-exec` applied the generated profile: no network, writes
        /// confined to the workspace + scratch TMPDIR, real HOME denied.
        case seatbelt
        /// Screening fallback: command-text screens + honest schema, no OS
        /// boundary (the probe could not apply a profile on this host —
        /// typically a nested-sandbox environment).
        case screening
    }

    // MARK: - Seatbelt availability probe

    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probedMode: ConfinementMode?

    /// Decides (once per process) whether the seatbelt boundary is usable:
    /// spawns `/usr/bin/true` under `(allow default)` through `sandbox-exec`
    /// and checks the exit status. A nested-sandbox host (the documented
    /// `forbidden-sandbox-reinit` case) fails this probe and the runner
    /// ships the screening fallback for the process's lifetime.
    /// Deliberately a REAL probe, not an OS-version table.
    public static func probe() -> ConfinementMode {
        probeLock.lock()
        if let decided = probedMode {
            probeLock.unlock()
            return decided
        }
        probeLock.unlock()
        let decided = probeOnce()
        probeLock.lock()
        probedMode = decided
        probeLock.unlock()
        return decided
    }

    /// Test seam: force the cached verdict (checks pin both branches
    /// without depending on the host's own sandbox state). Pass nil to
    /// re-arm the real probe.
    static func setProbeOverride(_ mode: ConfinementMode?) {
        probeLock.lock()
        probedMode = mode
        probeLock.unlock()
    }

    /// One real `sandbox-exec -p '(version 1)(allow default)' /usr/bin/true`.
    private static func probeOnce() -> ConfinementMode {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        // `/usr/bin/true`, never `/bin/true`: macOS 26 (darwin 25) ships no
        // `/bin/true`, and the missing-binary ENOENT (exit 71) is
        // indistinguishable from a seatbelt refusal — every host on that OS
        // silently degraded to `.screening` before this. `/usr/bin/true`
        // exists on every macOS that has `sandbox-exec`.
        process.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
        // Deliberately NOT the confined environment: the probe answers
        // "can this host apply a profile at all", independent of our env.
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? .seatbelt : .screening
        } catch {
            return .screening
        }
    }

    /// realpath(3) canonicalization so the SBPL subpath rules match the
    /// paths the kernel actually sees (`/tmp` → `/private/tmp` shape).
    static func canonicalized(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The seatbelt profile for one workspace (one line is valid SBPL).
    /// Writes land only in the workspace (its scratch TMPDIR is inside it,
    /// listed explicitly for clarity); network operations are denied; reads
    /// under the operator's real HOME are denied (the scratch HOME the
    /// child sees keeps `~` expansion inside the workspace). Explicit
    /// allows are re-stated AFTER the denies: SBPL is order-sensitive and
    /// the later rule wins for the paths it matches.
    static func confinementProfile(workspaceRoot: String, scratchTMPDIR: String,
                                   realHome: String) -> String {
        return "(version 1)"
            + "(allow default)"
            + "(deny network*)"
            + "(deny file-write*)"
            + "(allow file-write* (subpath \"\(workspaceRoot)\"))"
            + "(allow file-write* (subpath \"\(scratchTMPDIR)\"))"
            + "(deny file-read* (subpath \"\(realHome)\"))"
            + "(allow file-read* (subpath \"\(workspaceRoot)\"))"
    }

    // MARK: - Model-facing truth text (the schema/catalog read these)

    /// The honest `shell_run` description for THIS process's boundary mode.
    /// Registry and schema catalog both source this so neither can drift
    /// into a false claim again.
    public static func modelFacingDescription() -> String {
        switch probe() {
        case .seatbelt:
            return "Run a shell command inside the workspace (cwd = workspace; runs in a macOS seatbelt sandbox: no network, writes confined to the task workspace, HOME hidden)."
        case .screening:
            return "Run a shell command inside the workspace (cwd = workspace; this host could not apply the confinement sandbox, so commands referencing the run ledger or paths outside the workspace are refused by screening instead; network is NOT blocked)."
        }
    }

    // MARK: - Command screening (the N1 screen; also the fallback's screen)

    /// True when the command text names the run's ledger file in any case
    /// folding (`merlin-ledger.jsonl`, `MERLIN-LEDGER.JSONL`, …). The match
    /// is case-insensitive — on case-insensitive APFS the byte-different
    /// spelling still opens the same file.
    public static func commandTouchesLedger(_ command: String, ledgerFileName: String) -> Bool {
        command.range(of: ledgerFileName, options: .caseInsensitive) != nil
    }

    /// Conservative fallback screen: rejects commands that reference
    /// absolute paths outside the workspace by scanning `/`-rooted tokens.
    /// Deliberately conservative (a small allowlist of system roots,
    /// everything else refused): a false positive costs the model one
    /// rephrase; a false negative costs the operator's home directory.
    public static func commandReferencesOutsideWorkspace(_ command: String, workspaceRoot: String) -> Bool {
        let allowedPrefixes = [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin",
            "/usr/share", "/System", "/Library", "/dev/null", "/dev/stdin",
            "/dev/stdout", "/dev/stderr", "/private/tmp", "/tmp", "/var/folders",
        ]
        let cleaned = command
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "'", with: " ")
        for rawToken in cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" || $0 == "\n" }) {
            var token = String(rawToken)
            while let first = token.first, first == ">" || first == "<" || first == "$" {
                token.removeFirst()
            }
            guard token.hasPrefix("/") else { continue }
            if let eq = token.firstIndex(of: "=") {
                let head = String(token[..<eq])
                if head.hasPrefix("/") { token = head }
            }
            if allowedPrefixes.contains(where: { token == $0 || token.hasPrefix($0 + "/") }) {
                continue
            }
            if token == workspaceRoot || token.hasPrefix(workspaceRoot + "/") {
                continue
            }
            return true
        }
        return false
    }

    /// Pre-flight screen applied in BOTH modes: refuse any command whose
    /// text names the run ledger (defense in depth — the seatbelt denies
    /// writes outside the workspace but the ledger is INSIDE it, so only
    /// this screen blocks a forged ledger line). Throws a toolArg fault.
    public static func screenCommand(_ command: String, ledgerFileName: String) throws {
        if commandTouchesLedger(command, ledgerFileName: ledgerFileName) {
            throw MerlinRetry.ToolError(classification: .toolArg,
                message: "shell_run refused: the command references \(ledgerFileName), the run ledger managed by the kernel; use note_add, todo_write, and todo_read")
        }
    }

    /// Fallback-only extra screen (absolute paths outside the workspace).
    /// Runs ONLY when the OS boundary is absent, so it never degrades the
    /// seatbelt path's expressiveness.
    public static func screenCommandFallback(_ command: String, workspaceRoot: String,
                                             ledgerFileName: String) throws {
        try screenCommand(command, ledgerFileName: ledgerFileName)
        if commandReferencesOutsideWorkspace(command, workspaceRoot: workspaceRoot) {
            throw MerlinRetry.ToolError(classification: .toolArg,
                message: "shell_run refused: this host could not apply the confinement sandbox, so commands referencing paths outside the workspace are refused; keep the command inside the workspace")
        }
    }

    // MARK: - Entry point

    /// Screens `command`, then runs it via `/bin/sh -c` (directly, or under
    /// the generated seatbelt profile when available) with cwd
    /// `workspaceRoot`, awaiting the (bounded) blocking run off the
    /// cooperative thread pool. Throws (toolArg) only on the pre-flight
    /// screens; execution failures come back as Outcomes.
    public static func run(command: String, workspaceRoot: String,
                           ledgerFileName: String = "merlin-ledger.jsonl",
                           configuration: Configuration = Configuration()) async throws -> Outcome {
        let mode = probe()
        switch mode {
        case .seatbelt:
            try screenCommand(command, ledgerFileName: ledgerFileName)
        case .screening:
            try screenCommandFallback(command, workspaceRoot: workspaceRoot,
                                      ledgerFileName: ledgerFileName)
        }
        return await MerlinProcessQueue.yield(work: {
            Self.runBlocking(command: command, workspaceRoot: workspaceRoot,
                             configuration: configuration, mode: mode)
        })
    }

    /// Blocking core. Bounded by `timeout` (group SIGTERM → group SIGKILL);
    /// output is drained concurrently so a chatty command cannot deadlock
    /// the pipe buffers; the drain is bounded by a 2 s post-exit deadline
    /// so a stuck descriptor holder can never wedge the run.
    static func runBlocking(command: String, workspaceRoot: String,
                            configuration: Configuration, mode: ConfinementMode) -> Outcome {
        // Workspace scratch: HOME and TMPDIR for the child. Both live under
        // the workspace so `~` expansion stays inside the writable boundary
        // in both confinement modes.
        let scratch = workspaceRoot + "/.merlin-scratch"
        try? FileManager.default.createDirectory(atPath: scratch + "/tmp",
                                                 withIntermediateDirectories: true)

        var environment = configuration.environmentAllowlist
        environment["HOME"] = scratch
        environment["TMPDIR"] = scratch + "/tmp"

        let invocation = Self.argv(command: command, workspaceRoot: workspaceRoot,
                                   scratchTMPDIR: canonicalized(scratch + "/tmp"),
                                   mode: mode)

        let child: MerlinProcessGroup.SpawnedChild
        do {
            child = try MerlinProcessGroup.spawn(
                executable: invocation.executable,
                arguments: invocation.arguments,
                environment: environment,
                workingDirectory: workspaceRoot)
        } catch {
            return Outcome(exitCode: nil, timedOut: false, stdout: "",
                           stderr: "failed to launch \(invocation.executable): \(error)",
                           confinement: mode)
        }

        final class OutputBox: @unchecked Sendable {
            var stdout = Data()
            var stderr = Data()
            private let lock = NSLock()
            func store(stdout: Data? = nil, stderr: Data? = nil) {
                lock.lock()
                if let stdout { self.stdout = stdout }
                if let stderr { self.stderr = stderr }
                lock.unlock()
            }
        }
        let box = OutputBox()
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(label: "northlatchlabs.kestrel.merlin.shell-drain")
        let stdoutHandle = FileHandle(fileDescriptor: child.stdoutReadFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: child.stderrReadFD, closeOnDealloc: true)
        drainQueue.async(group: drainGroup) {
            box.store(stdout: stdoutHandle.readDataToEndOfFile())
        }
        drainQueue.async(group: drainGroup) {
            box.store(stderr: stderrHandle.readDataToEndOfFile())
        }

        final class ExitBox: @unchecked Sendable {
            var status: Int32 = -1
        }
        let exitBox = ExitBox()
        let exitSemaphore = DispatchSemaphore(value: 0)
        let waitQueue = DispatchQueue(label: "northlatchlabs.kestrel.merlin.shell-wait")
        waitQueue.async {
            exitBox.status = MerlinProcessGroup.waitpidBlocking(child.pid)
            exitSemaphore.signal()
        }

        var timedOut = false
        if exitSemaphore.wait(timeout: .now() + configuration.timeout) == .timedOut {
            timedOut = true
            // Process-group ladder: SIGTERM to the whole group first, then
            // SIGKILL to the group so backgrounded grandchildren (`x &`,
            // `nohup`, `disown`) cannot survive the timeout and hold the
            // pipes open (the pre-hardening hang).
            kill(-child.groupID, SIGTERM)
            kill(child.pid, SIGTERM)
            if exitSemaphore.wait(timeout: .now() + 2) == .timedOut {
                kill(-child.groupID, SIGKILL)
                kill(child.pid, SIGKILL)
                exitSemaphore.wait()
            }
        }

        // Bounded drain: normally the group kill guarantees EOF. If a
        // descriptor holder outside the group still wedges the pipes, give
        // the drain a 2 s deadline, close the read ends to force the
        // blocked reads to return, and abandon whatever did not land.
        if drainGroup.wait(timeout: .now() + 2.0) == .timedOut {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            _ = drainGroup.wait(timeout: .now() + 1.0)
        }
        return Outcome(
            exitCode: timedOut ? nil : MerlinProcessGroup.exitCode(of: exitBox.status),
            timedOut: timedOut,
            stdout: String(decoding: box.stdout, as: UTF8.self),
            stderr: String(decoding: box.stderr, as: UTF8.self),
            confinement: mode
        )
    }

    /// The argv for one run: the command behind `/usr/bin/sandbox-exec -p
    /// <profile>` when the seatbelt boundary is available, or direct
    /// `/bin/sh -c` under the screening fallback.
    static func argv(command: String, workspaceRoot: String, scratchTMPDIR: String,
                     mode: ConfinementMode) -> (executable: String, arguments: [String]) {
        switch mode {
        case .seatbelt:
            let profile = confinementProfile(workspaceRoot: canonicalized(workspaceRoot),
                                             scratchTMPDIR: scratchTMPDIR,
                                             realHome: canonicalized(NSHomeDirectory()))
            return ("/usr/bin/sandbox-exec",
                    ["-p", profile, "/bin/sh", "-c", command])
        case .screening:
            return ("/bin/sh", ["-c", command])
        }
    }

    // MARK: - Model-facing result contract

    /// First-line marker the guardian pins: `exit <code>` or a `timeout:`
    /// prefix. Always present; a `shell_run` result without it is malformed
    /// and rejected by M4 before the model can read success into it. The
    /// trailing `confinement:` line tells the model which boundary actually
    /// guarded the run.
    public static func outcomeText(_ outcome: Outcome, cap: Int = 4000) -> String {
        var lines: [String] = []
        if outcome.timedOut {
            lines.append("timeout: command exceeded its wall clock and was killed")
        } else {
            lines.append("exit \(outcome.exitCode ?? -1)")
        }
        let stdout = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(stdout.isEmpty ? "(no output)" : stdout)
        let stderr = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("stderr:")
        lines.append(stderr.isEmpty ? "(none)" : stderr)
        switch outcome.confinement {
        case .seatbelt:
            lines.append("confinement: seatbelt (no network; writes confined to the workspace; HOME hidden)")
        case .screening:
            lines.append("confinement: screening fallback (no OS boundary; ledger and outside-path screens active)")
        }
        var text = lines.joined(separator: "\n")
        if text.count > cap {
            text = String(text.prefix(cap - 14)) + "… [truncated]"
        }
        return text
    }
}

/// The one POSIX-spawn primitive shared by the kernel shell runner and the
/// eval harness: spawns a child in its OWN PROCESS GROUP via
/// `POSIX_SPAWN_SETPGROUP` (Foundation's `Process` exposes no setpgid
/// seam), with stdin at /dev/null and stdout/stderr on pipes, so the
/// caller's timeout ladder can `kill(-pgid)` the whole tree.
public enum MerlinProcessGroup {
    public struct SpawnedChild {
        public let pid: pid_t
        /// The child's process group (== pid by POSIX_SPAWN_SETPGROUP+0).
        public let groupID: pid_t
        public let stdoutReadFD: Int32
        public let stderrReadFD: Int32
    }

    public struct SpawnError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Spawns `executable` with `arguments` and exactly `environment`,
    /// cwd `workingDirectory`, stdin /dev/null, stdout/stderr piped. The
    /// child is its own process group leader from the first instruction —
    /// no race, no parent-side setpgid gamble.
    public static func spawn(executable: String, arguments: [String],
                             environment: [String: String],
                             workingDirectory: String) throws -> SpawnedChild {
        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        func closeAll() {
            for fd in outFDs + errFDs where fd >= 0 { close(fd) }
        }
        guard pipe(&outFDs) == 0 else {
            throw SpawnError(description: "pipe() failed: \(String(cString: strerror(errno)))")
        }
        guard pipe(&errFDs) == 0 else {
            close(outFDs[0]); close(outFDs[1])
            throw SpawnError(description: "pipe() failed: \(String(cString: strerror(errno)))")
        }

        var attr: posix_spawnattr_t? = nil
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attr, 0) == 0 else {
            closeAll()
            throw SpawnError(description: "posix_spawnattr setpgroup failed")
        }
        guard posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) == 0 else {
            closeAll()
            throw SpawnError(description: "cannot queue chdir to \(workingDirectory)")
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        // Close every inherited copy of the pipe fds in the child so EOF
        // propagation stays exact.
        for fd in [outFDs[0], outFDs[1], errFDs[0], errFDs[1]] {
            posix_spawn_file_actions_addclose(&actions, fd)
        }

        let cArgs = ([executable] + arguments).map { strdup($0)! }
        let cEnv = environment.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)")! }
        var argv: [UnsafeMutablePointer<CChar>?] = cArgs + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = cEnv + [nil]
        defer {
            for p in cArgs { free(p) }
            for p in cEnv { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, &argv, &envp)
        // Parent-side write ends go away regardless of the spawn result.
        close(outFDs[1])
        close(errFDs[1])
        guard rc == 0 else {
            close(outFDs[0])
            close(errFDs[0])
            throw SpawnError(description: "posix_spawn failed: \(String(cString: strerror(rc)))")
        }
        return SpawnedChild(pid: pid, groupID: pid,
                            stdoutReadFD: outFDs[0], stderrReadFD: errFDs[0])
    }

    /// Reaps the child (blocking) and returns the raw waitpid status.
    public static func waitpidBlocking(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status
    }

    /// Foundation-compatible status conversion: exit code, or the signal
    /// number on a signal death (mirrors `Process.terminationStatus`).
    /// Darwin's W* macros are function-like and Swift cannot import them,
    /// so the bit layout is applied directly (sys/wait.h):
    /// `_WSTATUS(x) = x & 0x7F`; WIFEXITED: status == 0; WIFSIGNALED:
    /// status != 0 && status != 0x7F (0x7F is the stopped bit pattern);
    /// WEXITSTATUS: (x >> 8) & 0xFF.
    public static func exitCode(of status: Int32) -> Int32 {
        let wstatus = status & 0x7F
        if wstatus == 0 { return (status >> 8) & 0xFF }
        if wstatus != 0x7F { return wstatus }
        return -1
    }
}

/// The `js_eval` machinery: one fresh, host-free JavaScriptCore context per
/// evaluation, guarded by a watchdog (MISSION MERLIN security wave 2).
///
/// Security posture:
/// - The context exports NOTHING: no `fetch`, no `XMLHttpRequest`, no
///   `require`, no `process`, no file or host bindings of any kind. A
///   script can compute, but it cannot reach anything.
/// - The context is created per call and dropped after, so no state leaks
///   between evaluations.
/// - Scripts are capped at 100,000 bytes before evaluation.
///
/// WATCHDOG (honest semantics): JavaScriptCore cannot preempt a running
/// script and exposes no interrupt callback on this Darwin surface, so the
/// evaluation runs on a dedicated worker thread and the watchdog returns a
/// tool-level timeout error once the wall clock expires. THE WORKER THREAD
/// ITSELF IS NOT PREEMPTIBLE: a non-terminating script (`while (true) {}`)
/// leaks that one thread until the process exits. The leak is bounded — at
/// most one leaked thread per timed-out js_eval call, never re-entered,
/// no context retained — and the RUN and the APP recover: the tool call
/// fails promptly, the kernel ledgers the error, the loop continues, and
/// the app never hangs. The child-process alternative (a JSCLI helper
/// target) was rejected this wave because Package.swift is lead-owned; the
/// subprocess route remains the documented follow-up that would remove the
/// residual thread leak entirely.
public enum MerlinJS {
    /// Hard cap on script size, in UTF-8 bytes.
    public static let maxScriptBytes = 100_000
    /// Cap on the model-facing result text.
    public static let outputCharacterCap = 4000
    /// Wall-clock budget for one evaluation (the killable boundary).
    public static let evaluationTimeout: TimeInterval = 10

    /// The honest `js_eval` description (registry + catalog source this).
    public static func modelFacingDescription() -> String {
        return "Evaluate JavaScript in the host-free JS sandbox (10 s wall clock; a script exceeding it is abandoned and reported as a timeout)."
    }

    /// Evaluates `code` in a fresh context, off the cooperative pool.
    /// Returns the model-facing text; throws a tool-arg error for oversized
    /// scripts and JS exceptions, and the watchdog timeout error when the
    /// evaluation exceeds the wall clock.
    public static func evaluate(code: String) async throws -> String {
        try await MerlinProcessQueue.yieldThrowing(work: {
            try Self.evaluateBlocking(code: code)
        })
    }

    /// Blocking core: fresh context on a dedicated worker thread, watchdog
    /// on the wall clock. On expiry the WAITER throws; the wedged worker
    /// thread is abandoned, never joined (see the honest limitation above).
    static func evaluateBlocking(code: String) throws -> String {
        guard let bytes = code.data(using: .utf8)?.count else {
            throw MerlinRetry.ToolError(classification: .toolArg,
                                        message: "js_eval code is not encodable as UTF-8")
        }
        guard bytes <= maxScriptBytes else {
            throw MerlinRetry.ToolError(classification: .toolArg,
                                        message: "js_eval script is \(bytes) bytes; the cap is \(maxScriptBytes). Split the work into smaller evaluations.")
        }

        // Sealed result slot: JSContext is not thread-safe to poke from
        // outside and there is no interrupt API, so the watchdog never
        // touches the context — it only stops WAITING.
        final class ResultBox: @unchecked Sendable {
            enum Value { case pending, done(String), failed(Error) }
            private let lock = NSLock()
            private var value: Value = .pending
            func fulfill(_ v: Value) {
                lock.lock()
                if case .pending = self.value { self.value = v }
                lock.unlock()
            }
            func snapshot() -> Value {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let box = ResultBox()

        let worker = Thread {
            let context = JSContext()
            let clock = Date()
            let value = context?.evaluateScript(code)
            let elapsedMS = Int(Date().timeIntervalSince(clock) * 1000)
            if let exception = context?.exception, exception.isObject {
                let message = exception.toString() ?? "unknown JS error"
                box.fulfill(.failed(MerlinRetry.ToolError(
                    classification: .toolArg,
                    message: "js_eval error: \(message)")))
                return
            }
            var rendered = "undefined"
            if let value, !value.isUndefined {
                rendered = value.toString() ?? "undefined"
                if value.isNull { rendered = "null" }
            }
            if rendered.count > MerlinJS.outputCharacterCap {
                rendered = String(rendered.prefix(MerlinJS.outputCharacterCap - 14)) + "… [truncated]"
            }
            box.fulfill(.done(rendered + "\n(js_eval completed in \(elapsedMS)ms)"))
        }
        worker.name = "northlatchlabs.kestrel.merlin.js-eval"
        worker.stackSize = 4 << 20
        worker.start()

        let deadline = Date().addingTimeInterval(evaluationTimeout)
        while case .pending = box.snapshot() {
            if Date() >= deadline {
                throw MerlinRetry.ToolError(classification: .toolArg,
                    message: "js_eval timeout: the script exceeded \(Int(evaluationTimeout))s and was abandoned (non-terminating scripts cannot be preempted in-process); rewrite the script to terminate")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        switch box.snapshot() {
        case .done(let text):
            return text
        case .failed(let error):
            throw error
        case .pending:
            // Unreachable: the loop exits only when the box is not pending.
            throw MerlinRetry.ToolError(classification: .permanent,
                                        message: "js_eval watchdog state error")
        }
    }
}

/// Offloads bounded blocking work (process waits, synchronous JS) off the
/// cooperative thread pool so a 30-second command never stalls unrelated
/// tasks. Every unit runs on the global utility queue; work results must
/// be Sendable because they cross back into the awaiting context.
enum MerlinProcessQueue {
    /// Throwing twin for the JS evaluator.
    static func yieldThrowing<T: Sendable>(work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Non-throwing twin for the shell runner (which reports failures as
    /// outcomes rather than throws).
    static func yield<T: Sendable>(work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
