// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The context-overflow wedge class of 2026-10-19: a 64K engine, a turn that
/// reserved more response tokens than the window had room for, a summarize
/// request that could no longer fit, and a conversation that could never
/// recover. These checks pin the three guards that kill it.
final class CompactionWindowTests: CheckCase {
    private func msg(_ role: String, _ text: String) -> ChatMessage {
        ChatMessage(role: role, content: text)
    }

    func testClampedResponseTokensNeverExceedWindowAfterPrompt() {
        XCTAssertEqual(ChatStore.clampedResponseTokens(65_536, window: 65_536, estimatedPrompt: 15_000),
                       65_536 - 15_000 - 256)
        XCTAssertEqual(ChatStore.clampedResponseTokens(1_024, window: 65_536, estimatedPrompt: 15_000),
                       1_024)
        // Unknown window: the request stands as configured.
        XCTAssertEqual(ChatStore.clampedResponseTokens(8_192, window: 0, estimatedPrompt: 15_000), 8_192)
        // Window already consumed down to the margin: one token, not zero or negative.
        XCTAssertEqual(ChatStore.clampedResponseTokens(4_096, window: 1_000, estimatedPrompt: 900), 1)
    }

    func testCompactionPromptKeepsEverythingWhenItFits() {
        let messages = (0..<8).map { msg($0.isMultiple(of: 2) ? "user" : "assistant", "turn \($0) with a little text") }
        let built = ChatStore.compactionPrompt(summary: "prior summary", messages: messages, window: 65_536)
        XCTAssertEqual(built.dropped, 0)
        XCTAssertTrue(built.prompt.contains("turn 0 with a little text"))
        XCTAssertTrue(built.prompt.contains("turn 7 with a little text"))
        XCTAssertTrue(built.prompt.contains("Previous summary:"))
    }

    func testCompactionPromptDropsOldestWhenHistoryExceedsWindow() {
        // ~46 characters ≈ 15 tokens per turn once roled; a 300-token budget
        // keeps only the tail.
        let messages = (0..<20).map { msg("user", String(repeating: "a", count: 36) + " \($0)") }
        let built = ChatStore.compactionPrompt(summary: nil, messages: messages,
                                               window: 300 + 512 + 256)
        XCTAssertGreaterThan(built.dropped, 0)
        // The newest turns survive, the oldest do not, and the prompt itself
        // fits the budget it was given.
        XCTAssertTrue(built.prompt.contains("aaa 19"))
        XCTAssertFalse(built.prompt.contains("aaa 0"))
        XCTAssertLessThanOrEqual(built.prompt.utf8.count / 4, 340)
    }

    func testCompactionPromptTruncatesLoneGiantTurnInsteadOfFailing() {
        let giant = msg("assistant", String(repeating: "x", count: 40_000))
        let built = ChatStore.compactionPrompt(summary: nil, messages: [giant], window: 2_048)
        // The turn is partially summarized, not dropped; the deadlock is gone.
        XCTAssertEqual(built.dropped, 0)
        XCTAssertTrue(built.prompt.contains("[…]"))
        XCTAssertLessThan(built.prompt.utf8.count, 6_000)
    }

    func testCompactionPromptWithoutWindowFallsBackToFullHistory() {
        let messages = [msg("user", "hello"), msg("assistant", "hi there")]
        let built = ChatStore.compactionPrompt(summary: nil, messages: messages, window: 0)
        XCTAssertEqual(built.dropped, 0)
        XCTAssertTrue(built.prompt.contains("hello"))
        XCTAssertTrue(built.prompt.contains("hi there"))
    }
}

// MARK: - Generated registration (port from XCTest)
extension CompactionWindowTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "CompactionWindowTests",
        instance: { CompactionWindowTests() },
        checks: [
            .init(name: "testClampedResponseTokensNeverExceedWindowAfterPrompt") { $0.testClampedResponseTokensNeverExceedWindowAfterPrompt() },
            .init(name: "testCompactionPromptKeepsEverythingWhenItFits") { $0.testCompactionPromptKeepsEverythingWhenItFits() },
            .init(name: "testCompactionPromptDropsOldestWhenHistoryExceedsWindow") { $0.testCompactionPromptDropsOldestWhenHistoryExceedsWindow() },
            .init(name: "testCompactionPromptTruncatesLoneGiantTurnInsteadOfFailing") { $0.testCompactionPromptTruncatesLoneGiantTurnInsteadOfFailing() },
            .init(name: "testCompactionPromptWithoutWindowFallsBackToFullHistory") { $0.testCompactionPromptWithoutWindowFallsBackToFullHistory() },
        ])
}
