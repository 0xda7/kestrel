// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Kestrel

/// Agentic-core slice: transient-only retry classification (read-only tools
/// retry; deterministic failures and side-effecting tools never do) and the
/// per-conversation usage rollup.
final class AgentLoopTests: XCTestCase {
    func testTransportHiccupsAreTransient() {
        XCTAssertTrue(ChatToolsService.isTransient(URLError(.timedOut)))
        XCTAssertTrue(ChatToolsService.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(ChatToolsService.isTransient(URLError(.cannotConnectToHost)))
    }

    func testDeterministicFailuresAreNotTransient() {
        XCTAssertFalse(ChatToolsService.isTransient(URLError(.badURL)))
        XCTAssertFalse(ChatToolsService.isTransient(ChatToolsError.server(status: 404, message: "no such tool")))
        XCTAssertFalse(ChatToolsService.isTransient(ChatToolsError.invalidResponse))
    }

    func testServerSide5xxIsTransient() {
        XCTAssertTrue(ChatToolsService.isTransient(ChatToolsError.server(status: 502, message: "bad gateway")))
        XCTAssertTrue(ChatToolsService.isTransient(ChatToolsError.server(status: 503, message: "busy")))
    }

    func testUsageRollupSumsGeneratedAndCountsTurns() {
        var first = ChatMessage(role: "assistant", content: "a")
        first.timings = ChatTimings(promptTokens: 100, generatedTokens: 50)
        var second = ChatMessage(role: "assistant", content: "b")
        second.timings = ChatTimings(promptTokens: 300, generatedTokens: 120)
        let plain = ChatMessage(role: "user", content: "hi")

        let rollup = ChatStore.usageRollup(messages: [first, second, plain])
        XCTAssertEqual(rollup?.turns, 2)
        XCTAssertEqual(rollup?.generatedTokens, 170)
        XCTAssertEqual(rollup?.peakWindow, 420)
    }

    func testUsageRollupNilWithoutTimings() {
        XCTAssertNil(ChatStore.usageRollup(messages: [ChatMessage(role: "user", content: "hi")]))
    }
}
