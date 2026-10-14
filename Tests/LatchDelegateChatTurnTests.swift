// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
@testable import KestrelCore

/// The direct-chat-agent contract of LatchDelegateService.runStreaming,
/// exercised against a scripted harness stub: stdout streams as growing
/// snapshots while the run works, the final stdout is the reply, a clean
/// exit with no output is surfaced (never a blank bubble), the budget
/// stops a runaway, and the chat-turn budget clamps to 60…900 s.
final class LatchDelegateChatTurnTests: CheckCase {
    private func makeStub(_ body: String) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kestrel-latch-stub-\(UUID().uuidString).sh")
        try? "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: url.path)
        return url.path
    }

    private func removeStub(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A streaming turn: three chunks over ~2 s. The pump must observe the
    /// reply GROW (snapshot-replace streaming, not one final blob), and the
    /// completed output must be the full report.
    @MainActor func testChatTurnStreamsGrowingSnapshotsAndCompletes() async throws {
        let stub = makeStub("printf 'Kestrel '\nsleep 1\nprintf 'chat via '\nsleep 1\nprintf 'latch.'")
        defer { removeStub(stub) }
        let snapshots = OSAllocatedUnfairLock<[String]>(initialState: [])
        let outcome = await LatchDelegateService.runStreaming(
            argv: [stub], workingDirectory: nil, timeout: 30, onLaunch: nil,
            onOutput: { _, fullSoFar in snapshots.withLock { $0.append(fullSoFar) } })
        guard case .completed(let output) = outcome else {
            return XCTFail("expected a completed turn, got \(outcome)")
        }
        XCTAssertEqual(output, "Kestrel chat via latch.")
        let seen = snapshots.withLock { $0 }
        XCTAssertGreaterThanOrEqual(seen.count, 2,
                                    "the reply must stream in several snapshots, got \(seen.count)")
        if seen.count >= 2 {
            XCTAssertTrue(seen[0].count < seen.last!.count,
                          "snapshots must grow while the turn runs")
        }
    }

    /// Clean exit, zero stdout: the outcome that triggers the chat path's
    /// empty-success guard, which surfaces ChatNative.latchEmptyReplyMessage
    /// instead of a blank bubble.
    @MainActor func testEmptyTurnSurfacesFailureText() async throws {
        let stub = makeStub("exit 0")
        defer { removeStub(stub) }
        let outcome = await LatchDelegateService.runStreaming(
            argv: [stub], workingDirectory: nil, timeout: 30, onLaunch: nil, onOutput: nil)
        guard case .completed(let output) = outcome else {
            return XCTFail("expected a completed turn, got \(outcome)")
        }
        XCTAssertTrue(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(ChatStore.latchEmptyReplyMessage
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the empty-success guard text must exist")
        XCTAssertTrue(ChatStore.latchEmptyReplyMessage.contains("latch"),
                      "the guard text must name latch")
    }

    /// A runaway turn is stopped by its budget and reported as a failure
    /// carrying partial output — the same machinery Stop and the 60…900 s
    /// chat budget reuse.
    @MainActor func testBudgetStopsARunawayTurn() async throws {
        let stub = makeStub("printf 'partial…'\nsleep 60")
        defer { removeStub(stub) }
        let started = Date()
        let outcome = await LatchDelegateService.runStreaming(
            argv: [stub], workingDirectory: nil, timeout: 2, onLaunch: nil, onOutput: nil)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected a budget failure, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("budget") || reason.contains("stopped"),
                      "the failure must name the budget stop: \(reason)")
        XCTAssertTrue(reason.contains("partial"), "partial output must ride along: \(reason)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 30,
                          "the escalation must not wait the full 60 s child")
    }

    /// The chat-turn budget contract: the stored latch timeout floored at
    /// 60 s and capped at 900 s.
    func testChatTurnBudgetClampsToFloorAndCap() {
        let key = SettingsKeys.latchDelegateTimeout
        let original = UserDefaults.standard.integer(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(5, forKey: key)
        XCTAssertEqual(LatchDelegateService.chatTurnTimeoutSeconds, 60,
                       "a chat turn below the 60 s floor can only die mid-work")

        UserDefaults.standard.set(5_000, forKey: key)
        XCTAssertEqual(LatchDelegateService.chatTurnTimeoutSeconds, 900,
                       "the hard cap for a chat turn is 900 s")

        UserDefaults.standard.set(0, forKey: key)
        XCTAssertEqual(LatchDelegateService.chatTurnTimeoutSeconds,
                       LatchDelegateService.defaultTimeoutSeconds,
                       "unset falls back to the default timeout")
    }
}

// MARK: - Generated registration (port from XCTest)
extension LatchDelegateChatTurnTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "LatchDelegateChatTurnTests",
        instance: { LatchDelegateChatTurnTests() },
        checks: [
            .init(name: "testChatTurnStreamsGrowingSnapshotsAndCompletes") { await try $0.testChatTurnStreamsGrowingSnapshotsAndCompletes() },
            .init(name: "testEmptyTurnSurfacesFailureText") { await try $0.testEmptyTurnSurfacesFailureText() },
            .init(name: "testBudgetStopsARunawayTurn") { await try $0.testBudgetStopsARunawayTurn() },
            .init(name: "testChatTurnBudgetClampsToFloorAndCap") { $0.testChatTurnBudgetClampsToFloorAndCap() },
        ])
}
