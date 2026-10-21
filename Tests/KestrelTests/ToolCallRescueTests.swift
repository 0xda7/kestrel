// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission C1 Phase B froze the W1-1 rescue's parsing semantics; Phase C
/// converted it to doctrine: the checks below pin the UNCONSTRAINED
/// behavior (remote providers, custom engine binaries — where prose
/// emission is still possible and the rescue is deliberate), and the
/// constrained checks at the end pin the census drill: on the
/// grammar-constrained local path the rescue is retired and returns [].
final class ToolCallRescueTests: CheckCase {
    private let offeredTools: Set<String> = ["get_datetime", "read_file", "grep_logs"]

    // MARK: Blob shapes the rescue accepts

    /// A fenced ```json {"name":…} blob — the most common prose shape — must
    /// become a real pending call: balanced-brace extraction ignores the fence.
    func testFencedJSONBlobIsRescued() {
        let text = """
        Sure, let me check the time.
        ```json
        {"name": "get_datetime", "arguments": {}}
        ```
        """

        let calls = ToolCallRescue.rescuedCalls(text: text, toolNames: offeredTools)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "get_datetime")
        XCTAssertEqual(calls.first?.arguments, "{}")
    }

    /// A `<tool_call>{…}</tool_call>` tag span is extracted and rescued.
    func testToolCallTagSpanIsRescued() {
        let text = "<tool_call>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.txt\"}}</tool_call>"

        let calls = ToolCallRescue.rescuedCalls(text: text, toolNames: offeredTools)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertEqual(calls.first?.arguments, "{\"path\":\"a.txt\"}")
    }

    /// The call-name key may be `name`, `tool`, or `tool_name` — distilled
    /// finetunes emit all three shapes.
    func testNameKeyAliasesAreAccepted() {
        for alias in ["tool", "tool_name"] {
            let calls = ToolCallRescue.rescuedCalls(text: "{\"\(alias)\": \"get_datetime\"}",
                                                    toolNames: offeredTools)
            XCTAssertEqual(calls.count, 1, "alias \(alias) must rescue exactly one call")
            XCTAssertEqual(calls.first?.name, "get_datetime")
            XCTAssertEqual(calls.first?.arguments, "{}")
        }
    }

    /// The arguments key may be `arguments`, `parameters`, or `params`; each
    /// carries the payload verbatim into the rescued call.
    func testArgumentsKeyAliasesCarryThePayload() {
        for alias in ["parameters", "params"] {
            let calls = ToolCallRescue.rescuedCalls(
                text: "{\"name\": \"get_datetime\", \"\(alias)\": {\"tz\": \"UTC\"}}",
                toolNames: offeredTools)
            XCTAssertEqual(calls.count, 1, "arguments alias \(alias) must rescue exactly one call")
            XCTAssertEqual(calls.first?.name, "get_datetime")
            XCTAssertEqual(calls.first?.arguments, "{\"tz\":\"UTC\"}")
        }
    }

    // MARK: Rejections and limits

    /// A blob naming a tool that was never offered is skipped — the rescue
    /// never invents calls the permission gate could not have consented to.
    func testUnofferedToolNameIsSkipped() {
        let calls = ToolCallRescue.rescuedCalls(text: "{\"name\": \"rm_rf_everything\", \"arguments\": {}}",
                                                toolNames: offeredTools)
        XCTAssertTrue(calls.isEmpty)
    }

    /// A rambling turn cannot fire a dozen calls: five valid distinct blobs
    /// yield exactly maxPerTurn, in emission order.
    func testCapsRescuesAtMaxPerTurn() {
        let text = (1...5).map { "{\"name\": \"grep_logs\", \"note\": \"blob \($0)\"}" }
            .joined(separator: "\n")

        let calls = ToolCallRescue.rescuedCalls(text: text, toolNames: offeredTools)

        XCTAssertEqual(calls.count, ToolCallRescue.maxPerTurn)
        XCTAssertEqual(ToolCallRescue.maxPerTurn, 3)
    }

    /// Empty text rescues nothing.
    func testEmptyTextRescuesNothing() {
        XCTAssertTrue(ToolCallRescue.rescuedCalls(text: "", toolNames: offeredTools).isEmpty)
    }

    /// A non-dict arguments value (array, string, number) degrades to "no
    /// arguments" instead of killing the rescued call.
    func testNonDictArgumentsBecomeEmptyArguments() {
        let calls = ToolCallRescue.rescuedCalls(
            text: "{\"name\": \"get_datetime\", \"arguments\": [1, 2, 3]}",
            toolNames: offeredTools)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments, "{}")
    }

    // MARK: Constrained path (mission C1 census drill)

    /// THE census drill: post-conversion, a grammar-constrained turn
    /// rescues nothing — the envelope grammar has already made fenced blobs
    /// unemittable at the engine, so even a hand-fed fenced blob returns [].
    func testConstrainedFencedBlobRescuesNothing() {
        let text = """
        Sure, let me check the time.
        ```json
        {"name": "get_datetime", "arguments": {}}
        ```
        """

        XCTAssertTrue(ToolCallRescue.rescuedCalls(text: text, toolNames: offeredTools,
                                                  constrained: true).isEmpty)
    }

    /// Same drill for the `<tool_call>` tag shape: constrained turns never
    /// rescue, whatever prose shape arrives.
    func testConstrainedToolCallTagRescuesNothing() {
        let text = "<tool_call>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.txt\"}}</tool_call>"

        XCTAssertTrue(ToolCallRescue.rescuedCalls(text: text, toolNames: offeredTools,
                                                  constrained: true).isEmpty)
    }

    // MARK: Call-site gate

    /// The call-site gate extracted verbatim from ChatNative: rescue only
    /// when the channel delivered nothing usable (empty-name entries do not
    /// count as used), the turn was not cancelled, and no error was reported.
    func testShouldRescueGateMatchesCallSiteSemantics() {
        let channelCall = ChatToolCall(serverID: "call_1", name: "read_file", arguments: "{}")
        let unnamedChannelCall = ChatToolCall(serverID: nil, name: "", arguments: "{}")

        // Channel used → never rescue over it.
        XCTAssertFalse(ToolCallRescue.shouldRescue(channelToolCalls: [channelCall],
                                                   cancelled: false, reportedError: false))
        // Cancelled or errored turns → never rescue.
        XCTAssertFalse(ToolCallRescue.shouldRescue(channelToolCalls: [],
                                                   cancelled: true, reportedError: false))
        XCTAssertFalse(ToolCallRescue.shouldRescue(channelToolCalls: [],
                                                   cancelled: false, reportedError: true))
        // Empty-name channel entries are not a usable channel: rescue stays allowed.
        XCTAssertTrue(ToolCallRescue.shouldRescue(channelToolCalls: [unnamedChannelCall],
                                                  cancelled: false, reportedError: false))
        // All clear → rescue.
        XCTAssertTrue(ToolCallRescue.shouldRescue(channelToolCalls: [],
                                                  cancelled: false, reportedError: false))
    }
}

// MARK: - Generated registration (port from XCTest)
extension ToolCallRescueTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ToolCallRescueTests",
        instance: { ToolCallRescueTests() },
        checks: [
            .init(name: "testFencedJSONBlobIsRescued") { $0.testFencedJSONBlobIsRescued() },
            .init(name: "testToolCallTagSpanIsRescued") { $0.testToolCallTagSpanIsRescued() },
            .init(name: "testNameKeyAliasesAreAccepted") { $0.testNameKeyAliasesAreAccepted() },
            .init(name: "testArgumentsKeyAliasesCarryThePayload") { $0.testArgumentsKeyAliasesCarryThePayload() },
            .init(name: "testUnofferedToolNameIsSkipped") { $0.testUnofferedToolNameIsSkipped() },
            .init(name: "testCapsRescuesAtMaxPerTurn") { $0.testCapsRescuesAtMaxPerTurn() },
            .init(name: "testEmptyTextRescuesNothing") { $0.testEmptyTextRescuesNothing() },
            .init(name: "testNonDictArgumentsBecomeEmptyArguments") { $0.testNonDictArgumentsBecomeEmptyArguments() },
            .init(name: "testConstrainedFencedBlobRescuesNothing") { $0.testConstrainedFencedBlobRescuesNothing() },
            .init(name: "testConstrainedToolCallTagRescuesNothing") { $0.testConstrainedToolCallTagRescuesNothing() },
            .init(name: "testShouldRescueGateMatchesCallSiteSemantics") { $0.testShouldRescueGateMatchesCallSiteSemantics() },
        ]
    )
}
