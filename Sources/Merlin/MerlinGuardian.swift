// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The M4 Guardian: deterministic post-condition checks on every tool
/// result, per tool class, before the result is written to the ledger.
///
/// This replaces `MerlinPassThroughGuardian` (the slice-1 placeholder).
/// The small-model failure it kills is *silent failure acceptance*: a ≤9B
/// model reads a tool result that quietly says "error" — or narrates
/// success for work it never did — and moves on as if the step succeeded.
/// The guardian re-derives the truth from the filesystem, the ledger, and
/// the result's own contract line, so a claimed success that did not happen
/// becomes an explicit blocker with an actionable instruction instead of
/// absorbed confidence.
///
/// DETERMINISM CONTRACT: no model calls inside the guardian. Every check
/// reads local state (the workspace, the ledger, the result text). It is a
/// pure function of (tool, arguments, result, workspace, ledger) plus the
/// clock-free filesystem, so the same inputs always yield the same verdict
/// — pinned by checks in MerlinChecks3.
///
/// Rejections never end the run: the kernel marks the result rejected and
/// ledgers the instruction as a blocker, so the next digest hands the model
/// an explicit retry instruction (see MerlinKernel's guardian seam).
public struct MerlinResultGuardian: MerlinGuardian {
    /// Result-text markers that mean the tool itself reported failure even
    /// when the call "ran". Kept lowercase for case-insensitive matching;
    /// matched against the collapsed result text.
    static let errorMarkers: [String] = [
        "no such file", "not a directory", "escapes the task workspace",
        "invalid workspace path", "managed by the kernel",
        "is the run ledger", "not valid json", "missing or empty string field",
        "unknown tool", "error:", "failed to launch", "command not found",
        "permission denied", "timed out",
    ]

    /// Marker substrings that say success WITHOUT doing the work — the
    /// classic hallucinated-result shapes (DIAGNOSIS P0-1: prose narrating
    /// a call that never ran). A successful result carrying these is
    /// rejected; a genuinely-failed result is rejected on the error path
    /// above instead.
    static let suspiciousMarkers: [String] = [
        "i have successfully", "i successfully", "successfully wrote the file",
        "task completed successfully", "assume the file", "pretend",
        "as if the command succeeded", "simulated result",
        "cannot actually run", "not actually executed",
    ]

    public let workspace: MerlinWorkspace
    public let ledger: MerlinLedger

    public init(workspace: MerlinWorkspace, ledger: MerlinLedger) {
        self.workspace = workspace
        self.ledger = ledger
    }

    /// Reviews one executed tool call. Deterministic; no model involvement.
    public func review(tool: String, argumentsJSON: String, result: String) async -> MerlinGuardianVerdict {
        // Suspicious-content screen runs FIRST, for every tool: a result
        // that narrates success without evidence is never believed.
        if let instruction = Self.suspiciousContentInstruction(tool: tool, result: result) {
            return .reject(instruction: instruction)
        }
        switch tool {
        case "fs_write":
            return await Self.reviewFileWrite(argumentsJSON: argumentsJSON,
                                              result: result, workspace: workspace)
        case "fs_read":
            return Self.reviewFileRead(argumentsJSON: argumentsJSON, result: result,
                                       workspace: workspace)
        case "shell_run":
            return Self.reviewShellRun(result: result)
        case "todo_write":
            return Self.reviewTodoWrite(result: result, ledger: ledger)
        case "task_done":
            // The completion contract is enforced by the M5 verifier at the
            // task_done hook, not per-result here; the kernel never reaches
            // the guardian with task_done (its handler throws the
            // completion signal before the guardian hook runs). This arm
            // exists for direct registry callers and future rewiring.
            return .accept
        default:
            // fs_list, fs_grep, todo_read, note_add: no post-condition
            // beyond the suspicious-content screen above.
            return .accept
        }
    }

    // MARK: - Per-tool-class checks

    /// fs_write: the file must exist, be readable, and be non-empty unless
    /// the call wrote empty content. Refusal when the result claims success
    /// but the filesystem disagrees.
    static func reviewFileWrite(argumentsJSON: String, result: String,
                                workspace: MerlinWorkspace) async -> MerlinGuardianVerdict {
        let args = (try? MerlinToolRegistry.decodeArguments(argumentsJSON)) ?? [:]
        let path = (args["path"] as? String) ?? ""
        let content = (args["content"] as? String) ?? ""

        guard !path.isEmpty else {
            return .reject(instruction:
                "your fs_write call had no readable path argument, so the guardian cannot verify any file; " +
                "call fs_write again with both \"path\" and \"content\" filled in")
        }
        let url: URL
        do {
            url = try workspace.resolve(path)
        } catch {
            return .reject(instruction:
                "the path you wrote to (\(path)) does not resolve inside the workspace (\(error)); " +
                "pick a workspace-relative path and write again")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .reject(instruction:
                "the file you claim to have written does not exist at \(path); " +
                "write it again or correct the path")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if content.isEmpty && size == 0 {
            return .accept
        }
        if size == 0 {
            return .reject(instruction:
                "the file at \(path) is empty after your write, which does not match the content you sent; " +
                "write the file again with the full content")
        }
        if (try? String(contentsOf: url, encoding: .utf8)) == nil {
            return .reject(instruction:
                "the file at \(path) is not readable text after your write; " +
                "rewrite it as plain UTF-8 text")
        }
        return .accept
    }

    /// fs_read: the file must have existed when the call ran. A "success"
    /// result whose target is gone is a contradiction.
    static func reviewFileRead(argumentsJSON: String, result: String,
                               workspace: MerlinWorkspace) -> MerlinGuardianVerdict {
        let args = (try? MerlinToolRegistry.decodeArguments(argumentsJSON)) ?? [:]
        let path = (args["path"] as? String) ?? ""
        guard !path.isEmpty else {
            return .reject(instruction:
                "your fs_read call had no readable path argument; call fs_read again with a workspace-relative path")
        }
        guard let url = try? workspace.resolve(path),
              FileManager.default.fileExists(atPath: url.path) else {
            return .reject(instruction:
                "the file you claim to have read does not exist at \(path); " +
                "check the path with fs_list and read the correct file")
        }
        return .accept
    }

    /// shell_run: the exit code must be surfaced and stderr captured — the
    /// kernel-side runner guarantees the shape (`exit <code>` first line,
    /// `stderr:` section last), and a non-zero exit or timeout is a failure
    /// the model must see, never absorb as success.
    static func reviewShellRun(result: String) -> MerlinGuardianVerdict {
        guard let firstLine = result.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) else {
            return .reject(instruction:
                "your shell_run produced no readable result line; run the command again")
        }
        if firstLine.hasPrefix("timeout:") {
            return .reject(instruction:
                "your command was killed at the wall-clock limit; shorten it, add a step-wise approach, or split it across several shell_run calls")
        }
        guard firstLine.hasPrefix("exit "), let code = Int32(firstLine.dropFirst("exit ".count)) else {
            return .reject(instruction:
                "your shell_run result is malformed (no exit-code line), so its outcome cannot be trusted; run the command again")
        }
        guard result.contains("stderr:") else {
            return .reject(instruction:
                "your shell_run result is missing its stderr section, so errors may be hidden; run the command again")
        }
        if code != 0 {
            return .reject(instruction:
                "your command exited with code \(code); read the stderr section of the result and fix the command before moving on — do not treat this as success")
        }
        return .accept
    }

    /// todo_write: the ledger entry must be present after the call —
    /// the handler's contract is a decision entry keyed "todos".
    static func reviewTodoWrite(result: String, ledger: MerlinLedger) -> MerlinGuardianVerdict {
        let wrote = ledger.allEntries.contains { $0.kind == .decision && $0.key == "todos" }
        guard wrote else {
            return .reject(instruction:
                "your todo_write did not reach the ledger, so the plan you sent is lost; call todo_write again with the full {text, done} list")
        }
        return .accept
    }

    // MARK: - Suspicious-content screen

    /// Detects the hallucinated-result shapes (DIAGNOSIS P0-1/P0-2: the
    /// legacy loop let GLM narrate results for calls that never ran):
    /// (a) success vocabulary in a failed result, (b) a fs_write result
    /// claiming success while naming an error, (c) self-doubt markers that
    /// admit the work was simulated.
    static func suspiciousContentInstruction(tool: String, result: String) -> String? {
        let lowered = result.lowercased()
        let failed = errorMarkers.contains { lowered.contains($0) }
        let suspicious = suspiciousMarkers.contains { lowered.contains($0) }
        if suspicious {
            return "your \(tool) result narrates success while admitting the work was not actually performed; do not simulate results — re-issue the call and report only what the runtime returns"
        }
        if failed {
            let hasExitLine = lowered.contains("exit 0")
            let claimsSuccess = lowered.contains("success") || lowered.contains("successfully")
            if claimsSuccess && !(tool == "shell_run" && hasExitLine) {
                return "your \(tool) result claims success but carries an error; treat the call as failed, fix the cause, and call the tool again"
            }
        }
        return nil
    }
}
