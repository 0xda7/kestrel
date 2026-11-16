// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// `merlin` — the headless kernel CLI. Runs one agent task end to end and
// prints the run ledger plus the outcome. The model-facing actor (M1,
// grammar-constrained tool calls on the bundled llama-server) is slice 2:
// until it is wired the CLI verifies the kernel plumbing it can exercise
// (workspace, ledger, spine, tools) and exits 0 with an explicit note, so
// the target is runnable from day one.

import Foundation
import KestrelCore

@main
struct MerlinCLI {
    static func main() async {
        let arguments = CommandLine.arguments
        var goal: String?
        var workspaceRoot: URL?
        var maxTurns = 12

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--task":
                index += 1
                guard index < arguments.count else {
                    fail("--task requires a goal string")
                }
                goal = arguments[index]
            case "--workspace":
                index += 1
                guard index < arguments.count else {
                    fail("--workspace requires a directory path")
                }
                workspaceRoot = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--max-turns":
                index += 1
                guard index < arguments.count, let parsed = Int(arguments[index]), parsed > 0 else {
                    fail("--max-turns requires a positive integer")
                }
                maxTurns = parsed
            case "--help", "-h":
                print(usage)
                return
            default:
                fail("unknown argument: \(arguments[index])")
            }
            index += 1
        }

        guard let goal else {
            print(usage)
            print()
            print("kernel skeleton ready — actor not wired (slice 2); pass --task to see the kernel plumbing run")
            return
        }

        await run(goal: goal, workspaceRoot: workspaceRoot, maxTurns: maxTurns)
    }

    /// The day-one plumbing run: sandbox + ledger + spine come up, the tool
    /// registry answers, and the loop stops cleanly with no actor behind it.
    /// Every step prints what it proved, so the output doubles as a smoke
    /// check of the kernel's non-model systems.
    private static func run(goal: String, workspaceRoot: URL?, maxTurns: Int) async {
        let taskID = "cli-" + UUID().uuidString.prefix(8)
        do {
            let root = workspaceRoot ?? MerlinWorkspace.defaultRoot(taskID: taskID)
            let workspace = try MerlinWorkspace(root: root, taskID: taskID)
            let ledgerURL = workspace.rootURL.appendingPathComponent(MerlinLedger.fileName)
            let ledger = try MerlinLedger(url: ledgerURL)
            let spine = MerlinTaskSpine(goal: goal, planSketch: [], maxTurns: maxTurns)
            let kernel = MerlinKernel(workspace: workspace, ledger: ledger, spine: spine,
                                      configuration: MerlinKernel.Configuration(maxTurns: maxTurns))

            print("workspace: \(workspace.rootPath)")
            print("ledger:    \(ledgerURL.path)")
            print("spine:")
            for line in spine.systemPrompt(turn: 1, digest: ledger.digest(goal: goal)).split(separator: "\n") {
                print("  \(line)")
            }

            // The registry is live even without an actor: exercise one read
            // through it to prove the tool path works end to end.
            let listing = try await registryListing(kernel: kernel)
            print("fs_list probe via registry: \(listing)")

            print()
            print("kernel skeleton ready — actor not wired (slice 2)")
            print("outcome: not run (no actor); the loop stops cleanly at turn 0")
        } catch {
            FileHandle.standardError.write(Data("merlin: \(error)\n".utf8))
            exit(1)
        }
    }

    /// One round-trip through the registry to prove tool dispatch, sandbox
    /// resolution, and handler execution all work without a model.
    private static func registryListing(kernel: MerlinKernel) async -> String {
        do {
            return try await kernel.registry.execute(name: "fs_list",
                                                     argumentsJSON: #"{"path": "."}"#,
                                                     turn: 0)
        } catch {
            return "probe failed: \(error)"
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("merlin: \(message)\n".utf8))
        exit(2)
    }

    private static var usage: String {
        """
        merlin --task "<goal>" [--workspace dir] [--max-turns N]

        Runs one agent task inside a sandboxed workspace and prints the run
        ledger and outcome. Without --task, prints this help.

        Options:
          --task "<goal>"    The goal the agent works toward.
          --workspace dir    Workspace root (default: ~/.kestrel/merlin/workspaces/<task-id>/).
          --max-turns N      Hard turn budget (default: 12).
        """
    }
}
