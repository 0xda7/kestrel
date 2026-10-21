// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission T2-1 chunk C pins: the census W8 BUG-SHIELD doctrine on the tool
/// path (slot actions, /tools row decoding, the tool-exec SSE reader) and
/// the stream protocol's typed parse conversion. The repair-ladder and
/// prose-scan shields themselves stay pinned by ToolArgumentsRepairTests
/// and ToolCallRescueTests; this suite covers what they cannot.
final class ChatToolPathDoctrineTests: CheckCase {
    // MARK: Slot-action best-effort doctrine (census W8 ChatNative:1524)

    /// A failing slot save/restore surfaces NO error anywhere: the engine
    /// refuses slot actions for reasons outside the conversation's control
    /// (mmproj loaded), the degradation is a harmless cold prefill, and a
    /// chat error card for it would misreport a bounded, deliberate
    /// swallow as a failure. Pins the doctrine: the slot action must not
    /// CREATE an error state, whatever the store already carried.
    @MainActor
    func testSlotActionFailureSurfacesNoError() async {
        let store = ChatStore()
        let before = store.lastError

        await store.slotAction("restore", convID: UUID(), port: 1) // closed port: refused
        XCTAssertEqual(store.lastError, before)
        await store.slotAction("save", convID: UUID(), port: 1)
        XCTAssertEqual(store.lastError, before)
    }

    // MARK: Tool listing dropped-row surfacing (census W8 ChatToolsService:31)

    /// A /tools row that fails registration must not vanish: healthy tools
    /// still load and each dropped row is reported with its best-available
    /// identifier — the model cannot call what it was never offered, so a
    /// silent drop is a silent capability loss.
    func testToolListingSurfacesMalformedRowsInsteadOfDropping() {
        let good: [String: Any] = [
            "display_name": "Read file", "tool": "read_file", "type": "builtin",
            "permissions": ["write": false],
            "definition": ["type": "function", "function": ["name": "read_file"]]
        ]
        let nameless: [String: Any] = ["display_name": "Broken tool"]      // no "tool" key
        let opaque: [String: Any] = ["permissions": ["write": false]]      // no identifier at all

        var dropped: [String] = []
        let tools = ChatToolsService.decodeToolRows([good, nameless, opaque]) { dropped.append($0) }

        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "read_file")
        XCTAssertEqual(dropped, ["Broken tool", "unknown"])
    }

    // MARK: Tool stream typed parse (census W8 ChatToolsService:237)

    /// The tool-exec stream has no non-JSON sentinel (it terminates on the
    /// JSON "done" event), so a `data:` payload that fails to decode throws
    /// the typed error carrying a truncated fragment; SSE comment and
    /// prefix-less lines stay legal no-ops; well-formed events still parse.
    func testToolStreamMalformedDataPayloadThrowsInvalidStreamEvent() throws {
        XCTAssertNil(try ChatToolsService.toolStreamEvent(from: ": keepalive"))
        XCTAssertNil(try ChatToolsService.toolStreamEvent(from: "event: ping"))

        let event = try XCTUnwrap(ChatToolsService.toolStreamEvent(from: "data: {\"chunk\": \"hello\"}"))
        XCTAssertEqual(event["chunk"] as? String, "hello")

        XCTAssertThrowsError(try ChatToolsService.toolStreamEvent(from: "data: {broken")) { error in
            guard case let ChatToolsError.invalidStreamEvent(payload) = error else {
                return XCTFail("expected invalidStreamEvent, got \(error)")
            }
            XCTAssertEqual(payload, "{broken")
        }

        let oversized = "data: " + String(repeating: "x", count: 500)
        XCTAssertThrowsError(try ChatToolsService.toolStreamEvent(from: oversized)) { error in
            guard case let ChatToolsError.invalidStreamEvent(payload) = error else {
                return XCTFail("expected invalidStreamEvent, got \(error)")
            }
            XCTAssertEqual(payload.count, 120)
        }
    }

    // MARK: Chat stream typed parse (census W8 ChatStreamProtocol:33)

    /// [DONE] still completes and prefix-less lines are still no-ops, but a
    /// malformed `data:` payload now surfaces as a StreamError (rendered as
    /// a stream error card) instead of silently reshaping the transcript.
    func testChatStreamMalformedPayloadSurfacesAsStreamError() throws {
        var stream = ChatStreamAccumulator()

        XCTAssertNil(try stream.consume("event: ping"))
        XCTAssertNil(try stream.consume(": keepalive"))
        XCTAssertTrue(try XCTUnwrap(stream.consume("data: [DONE]")).completed)

        XCTAssertThrowsError(try stream.consume("data: {broken")) { error in
            guard let streamError = error as? StreamError else {
                return XCTFail("expected StreamError, got \(error)")
            }
            XCTAssertTrue(streamError.message.contains("malformed event"),
                          "message must name the malformed event, got: \(streamError.message)")
            XCTAssertTrue(streamError.message.contains("{broken"),
                          "message must carry the offending fragment, got: \(streamError.message)")
        }
    }
}

// MARK: - Generated registration (port from XCTest)
extension ChatToolPathDoctrineTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ChatToolPathDoctrineTests",
        instance: { ChatToolPathDoctrineTests() },
        checks: [
            .init(name: "testSlotActionFailureSurfacesNoError") { await $0.testSlotActionFailureSurfacesNoError() },
            .init(name: "testToolListingSurfacesMalformedRowsInsteadOfDropping") { $0.testToolListingSurfacesMalformedRowsInsteadOfDropping() },
            .init(name: "testToolStreamMalformedDataPayloadThrowsInvalidStreamEvent") { try $0.testToolStreamMalformedDataPayloadThrowsInvalidStreamEvent() },
            .init(name: "testChatStreamMalformedPayloadSurfacesAsStreamError") { try $0.testChatStreamMalformedPayloadSurfacesAsStreamError() },
        ]
    )
}
