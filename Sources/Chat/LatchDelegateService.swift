// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Delegates a self-contained task to the latch harness as an app-side tool.
/// The model never talks to latch's model directly; it hands off a task string
/// and receives latch's finished report. The binary path and timeout live in
/// settings — nothing about the delegate's model is hardcoded here; latch uses
/// whatever account and model its own configuration selects.
enum LatchDelegateService {
    static let toolName = "latch_delegate"
    static let defaultTimeoutSeconds = 300
    static let maximumTimeoutSeconds = 900
    static let maximumOutputCharacters = 12_000

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
                "description": "Delegate one self-contained task to the latch agent harness and wait for its final report. Use for work that needs its own multi-step agent run (research, a long refactor sweep, a repo-wide audit) while you keep the main conversation. The task must be fully self-contained: include every path, constraint, and expected output, because latch cannot ask you questions.",
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
                            "description": "How long to wait for the delegate before giving up. Default 300, max 900."
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
        let timeout = {
            if let requested = arguments["timeout_seconds"] as? NSNumber,
               requested.intValue > 0 {
                return min(requested.intValue, maximumTimeoutSeconds)
            }
            return timeoutSeconds
        }()

        var argv = [binaryPath, "-p", task]
        for path in attach { argv += ["--attach", path] }

        return await run(argv: argv, workingDirectory: workingDirectory, timeout: timeout)
    }

    private static func run(argv: [String], workingDirectory: String?,
                            timeout: Int) async -> ToolExecutionResult {
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
        var errData = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            lock.lock(); outData.append(chunk); lock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            lock.lock(); errData.append(chunk); lock.unlock()
        }

        do { try process.run() } catch {
            return ToolExecutionResult(
                content: "Failed to launch latch harness: \(error.localizedDescription)", isError: true)
        }

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @Sendable in
                process.waitUntilExit()
                return false
            }
            group.addTask { @Sendable in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                if process.isRunning { process.terminate(); return true }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        lock.lock()
        let out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self)
        lock.unlock()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        if timedOut {
            let partial = String(out.prefix(maximumOutputCharacters))
            return ToolExecutionResult(
                content: "latch_delegate exceeded its \(timeout)s budget and was stopped. Partial output:\n\(partial)",
                isError: true)
        }
        if process.terminationStatus != 0 {
            let detail = String((err.isEmpty ? out : err).prefix(2_000))
            return ToolExecutionResult(
                content: "latch harness exited with status \(process.terminationStatus): \(detail)",
                isError: true)
        }
        var report = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if report.isEmpty { report = err.trimmingCharacters(in: .whitespacesAndNewlines) }
        if report.isEmpty {
            report = "The delegate finished without producing output."
        }
        return ToolExecutionResult(content: ChatToolsService.clampedToolResult(report),
                                   isError: false)
    }
}
