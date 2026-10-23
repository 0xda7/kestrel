// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Pins the inline LFM thought-channel split (2026-10-23): with
/// --reasoning-format none the engine leaves `<|channel>thought …
/// <channel|>` inside `content`, and transcripts showed the raw channel
/// syntax to the operator. ChatStore.splitInlineChannelThought moves the
/// thought into the reasoning block so the visible answer is clean.
final class InlineThoughtSplitTests: CheckCase {
    func testClosedThoughtChannelSplitsIntoReasoningAndVisible() {
        let split = ChatStore.splitInlineChannelThought(
            "<|channel>thought\nI should read the file first.<channel|>The first line is KESTREL.")
        XCTAssertEqual(split.reasoning, "I should read the file first.")
        XCTAssertEqual(split.visible, "The first line is KESTREL.")
    }

    func testTextBeforeTheChannelStaysVisible() {
        let split = ChatStore.splitInlineChannelThought(
            "preamble<|channel>thought\nthinking<channel|>answer")
        XCTAssertEqual(split.reasoning, "thinking")
        XCTAssertEqual(split.visible, "preambleanswer",
                       "model text before the channel is never dropped")
    }

    func testTruncatedThoughtWithoutCloseMarkerStillCapturesTheThought() {
        let split = ChatStore.splitInlineChannelThought(
            "<|channel>thought\nThe stream died mid-thought")
        XCTAssertEqual(split.reasoning, "The stream died mid-thought")
        XCTAssertEqual(split.visible, "",
                       "a truncated stream has no answer text after the thought")
    }

    func testTextWithoutChannelSyntaxReturnsUnchanged() {
        for clean in ["Plain answer.", "", "   \n\t ", "<think>old style</think>answer"] {
            let split = ChatStore.splitInlineChannelThought(clean)
            XCTAssertEqual(split.reasoning, "", "no channel syntax means no reasoning extracted")
            XCTAssertEqual(split.visible, clean)
        }
    }
}

// MARK: - Generated registration (port from XCTest)
extension InlineThoughtSplitTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "InlineThoughtSplitTests",
        instance: { InlineThoughtSplitTests() },
        checks: [
            .init(name: "testClosedThoughtChannelSplitsIntoReasoningAndVisible") { $0.testClosedThoughtChannelSplitsIntoReasoningAndVisible() },
            .init(name: "testTextBeforeTheChannelStaysVisible") { $0.testTextBeforeTheChannelStaysVisible() },
            .init(name: "testTruncatedThoughtWithoutCloseMarkerStillCapturesTheThought") { $0.testTruncatedThoughtWithoutCloseMarkerStillCapturesTheThought() },
            .init(name: "testTextWithoutChannelSyntaxReturnsUnchanged") { $0.testTextWithoutChannelSyntaxReturnsUnchanged() },
        ])
}
