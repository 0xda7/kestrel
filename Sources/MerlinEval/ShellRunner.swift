// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import KestrelCore

/// The one process primitive everything shell-shaped goes through:
/// `command_ok` assertions (SCORING.md §2: `/bin/sh -c` from the workspace
/// root, timeout 10 s) and the harness-side `shell_run` tool (timeout 30 s,
/// no network env — TASKS.md §2).
///
/// The environment passed to commands is a fixed allowlist, not the
/// harness's own environment: no proxy variables, no harness secrets, no
/// anything-else — the sandbox runtime is `python3` (stdlib) and `/bin/sh`,
/// and a command cannot accidentally inherit a way off the machine.
///
/// MISSION MERLIN security wave 2 (2026-11-15): the timeout ladder now
/// operates on the child's PROCESS GROUP. The spawn goes through
/// `MerlinProcessGroup.spawn` (POSIX_SPAWN_SETPGROUP — the same primitive
/// the kernel's `MerlinShell` uses), so `kill(-pgid)` on timeout takes down
/// backgrounded grandchildren (`x &`, `nohup`, `disown`) that previously
/// survived the direct-child SIGKILL and held the pipes open forever. The
/// post-exit drain is additionally bounded by a 2 s deadline, so a wedged
/// descriptor holder can never hang the harness loop.
enum EvalShell {
    struct Outcome: Sendable, Equatable {
        /// Process exit status, or nil when the process was killed on
        /// timeout (the two cases are distinguishable via `timedOut`).
        let exitCode: Int32?
        let timedOut: Bool
        let stdout: String
        let stderr: String

        var ok: Bool { !timedOut && exitCode == 0 }
    }

    /// Environment for sandboxed commands. Eval-supplied variables
    /// (`MERLIN_EVAL_*`) are appended on top by `run`.
    static let baseEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    ]

    /// Runs `command` via `/bin/sh -c` with cwd `cwd`. Blocks until exit or
    /// `timeout` elapses; on timeout the process is terminated (SIGTERM,
    /// then SIGKILL after a grace period) and `timedOut` is set. Output is
    /// drained concurrently so a chatty command can never deadlock the pipe
    /// buffers. Called from the harness's single turn loop, so the blocking
    /// wait is bounded by `timeout` and sequential by construction.
    static func run(command: String, cwd: String, timeout: TimeInterval,
                    environment: [String: String] = [:]) -> Outcome {
        var env = EvalShell.baseEnvironment
        for (key, value) in environment { env[key] = value }

        // Process-group spawn (POSIX_SPAWN_SETPGROUP): the timeout ladder
        // can then kill backgrounded grandchildren, not just the shell.
        let child: MerlinProcessGroup.SpawnedChild
        do {
            child = try MerlinProcessGroup.spawn(executable: "/bin/sh",
                                                 arguments: ["-c", command],
                                                 environment: env,
                                                 workingDirectory: cwd)
        } catch {
            return Outcome(exitCode: nil, timedOut: false,
                           stdout: "", stderr: "failed to launch /bin/sh: \(error)")
        }

        // Drain both pipes to EOF on background queues so a large output
        // volume cannot fill the OS pipe buffers and stall the child.
        // Captured buffers go through a lock-protected box class: closures
        // mutate the box, never a captured local, which keeps the
        // concurrency checker quiet without shared mutable state leaks.
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
        let drainQueue = DispatchQueue(label: "merlin-eval.shell-drain", attributes: .concurrent)
        let stdoutHandle = FileHandle(fileDescriptor: child.stdoutReadFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: child.stderrReadFD, closeOnDealloc: true)
        drainQueue.async(group: drainGroup) {
            box.store(stdout: stdoutHandle.readDataToEndOfFile())
        }
        drainQueue.async(group: drainGroup) {
            box.store(stderr: stderrHandle.readDataToEndOfFile())
        }

        final class StatusBox: @unchecked Sendable {
            var status: Int32 = -1
        }
        let statusBox = StatusBox()
        let exitSemaphore = DispatchSemaphore(value: 0)
        let waitQueue = DispatchQueue(label: "merlin-eval.shell-wait")
        waitQueue.async {
            statusBox.status = MerlinProcessGroup.waitpidBlocking(child.pid)
            exitSemaphore.signal()
        }

        var timedOut = false
        if exitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // Process-group ladder: SIGTERM to the whole group (shell plus
            // backgrounded grandchildren), then SIGKILL to the group after
            // the grace period — an orphaned `sleep 99999 &` can no longer
            // survive the timeout and wedge the drain.
            kill(-child.groupID, SIGTERM)
            kill(child.pid, SIGTERM)
            // Grace period for a clean exit before the hard kill.
            if exitSemaphore.wait(timeout: .now() + 2) == .timedOut {
                kill(-child.groupID, SIGKILL)
                kill(child.pid, SIGKILL)
                exitSemaphore.wait()
            }
        }

        // Bounded drain: normally the group kill guarantees EOF; a wedged
        // descriptor holder gets a 2 s deadline before the read ends are
        // closed and the buffers are abandoned as-is.
        if drainGroup.wait(timeout: .now() + 2.0) == .timedOut {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            _ = drainGroup.wait(timeout: .now() + 1.0)
        }
        let out = String(decoding: box.stdout, as: UTF8.self)
        let err = String(decoding: box.stderr, as: UTF8.self)

        let exitCode: Int32? = timedOut
            ? nil
            : MerlinProcessGroup.exitCode(of: statusBox.status)
        return Outcome(exitCode: exitCode, timedOut: timedOut, stdout: out, stderr: err)
    }

    /// Model-facing text for a command outcome: stdout + stderr, capped so a
    /// runaway print loop cannot flood the transcript.
    static func modelFacingText(_ outcome: Outcome, limit: Int = 4000) -> String {
        var text = ""
        if outcome.timedOut {
            text += "command timed out after the harness limit\n"
        }
        if !outcome.stdout.isEmpty { text += outcome.stdout }
        if !outcome.stderr.isEmpty {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += outcome.stderr
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = outcome.ok ? "(exit 0, no output)" : "(no output)" }
        if text.count > limit {
            text = String(text.prefix(limit - 20)) + "… [truncated]"
        }
        return text
    }
}
