// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission T2-1 chunk B: the import/summarize/sampling silent catches are now
/// surfaced failures. These checks pin the converted behaviors — the strict
/// custom-sampling rule at both enforcement points, the wedge-proof compaction
/// failure contract (5a455ce), and JSONL skipped-record counting on the
/// import path.
final class ChatImportSurfacingTests: CheckCase {
    // MARK: - Custom sampling JSON (census W8 ChatNative:1014 + ChatAdvancedSettingsSection:428)

    func testCustomJSONIssueEnforcesTopLevelObject() {
        // Empty overrides nothing: valid.
        XCTAssertEqual(ChatSamplingSettings.customJSONIssue(""), nil)
        XCTAssertEqual(ChatSamplingSettings.customJSONIssue("   \n "), nil)
        // A healthy object passes.
        XCTAssertEqual(ChatSamplingSettings.customJSONIssue(#"{"temperature": 0.9}"#), nil)
        // Everything else is rejected with the reason the turn will carry.
        XCTAssertEqual(ChatSamplingSettings.customJSONIssue("not json {"),
                       "must be a JSON object like {\"temperature\": 0.7}")
        XCTAssertNotNil(ChatSamplingSettings.customJSONIssue("[1, 2]"),
                        "a top-level array cannot override request parameters key by key")
        XCTAssertNotNil(ChatSamplingSettings.customJSONIssue(#""0.9""#),
                        "bare JSON fragments are not objects")
        XCTAssertNotNil(ChatSamplingSettings.customJSONIssue("null"))
    }

    func testCustomSamplingMergeRejectsNonObjectAndFailsTheTurn() {
        let body = ["temperature": 0.7, "top_p": 0.95] as [String: Any]
        for broken in ["not json {", "[1, 2]", #""0.9""#] {
            XCTAssertThrowsError(try ChatStore.mergedCustomSampling(body, customJSON: broken)) { error in
                guard let streamError = error as? StreamError else {
                    return XCTFail("the rejection must ride the turn's typed StreamError channel")
                }
                let message = streamError.localizedDescription
                XCTAssertTrue(message.contains("Custom sampling JSON"),
                              "the surfaced error must name the custom sampling JSON: \(message)")
                XCTAssertTrue(message.contains("must be a JSON object"),
                              "the surfaced error must carry the rule: \(message)")
            }
        }
    }

    func testCustomSamplingMergeAppliesHealthyObjectWithCustomPrecedence() throws {
        let body = ["temperature": 0.7, "top_p": 0.95] as [String: Any]
        let merged = try ChatStore.mergedCustomSampling(
            body, customJSON: #"{"temperature": 0.9, "top_k": 5}"#)
        XCTAssertEqual(merged["temperature"] as? Double, 0.9, "the custom value wins")
        XCTAssertEqual(merged["top_p"] as? Double, 0.95, "unlisted parameters survive")
        XCTAssertEqual(merged["top_k"] as? Int, 5, "new parameters are added")
    }

    func testCustomSamplingMergeWithEmptyFieldLeavesBodyUntouched() throws {
        let body = ["temperature": 0.7] as [String: Any]
        XCTAssertEqual(try ChatStore.mergedCustomSampling(body, customJSON: "") as? [String: Double],
                       body as? [String: Double])
    }

    // MARK: - Wedge-proof compaction failure contract (census W8 ChatNative:2014-2017, 5a455ce)

    /// A failed summarize (nil) must leave the conversation uncompacted and
    /// retryable — never advance summarizedCount, never wedge the store.
    @MainActor func testFailedSummarizeKeepsTheConversationCompactable() throws {
        try withBackedUpConversationStore {
            let store = ChatStore()
            guard let conversation = store.current else {
                return XCTFail("ChatStore must open with a conversation")
            }
            store.compacting = true
            store.applyCompaction(conversation: conversation.id, cutoff: 3, summary: nil)
            XCTAssertFalse(store.compacting,
                           "a failed summarize must clear the compacting flag so compaction can retry")
            let afterFailure = store.conversations.first(where: { $0.id == conversation.id })
            XCTAssertNil(afterFailure?.summary, "a failed summarize must not store a summary")
            XCTAssertNil(afterFailure?.summarizedCount,
                         "a failed summarize must not advance summarizedCount")

            // The store may reuse an existing empty conversation, so locate
            // the target by id — index 0 is not guaranteed to be it.
            guard let target = store.conversations.firstIndex(where: { $0.id == conversation.id }) else {
                return XCTFail("the open conversation must stay in the store")
            }
            store.conversations[target].messages.append(ChatMessage(role: "user", content: "hola"))
            store.compacting = true
            store.applyCompaction(conversation: conversation.id, cutoff: 1, summary: "resumen")
            let afterSuccess = store.conversations.first(where: { $0.id == conversation.id })
            XCTAssertEqual(afterSuccess?.summary, "resumen", "a healthy summary applies")
            XCTAssertEqual(afterSuccess?.summarizedCount, 1, "the cutoff advances summarizedCount")
            XCTAssertFalse(store.compacting)
        }
    }

    // MARK: - JSONL skipped-record surfacing (census W8 ChatJSONL:28)

    func testJSONLDecodeCountsSkippedLinesAndStillImportsTheRest() throws {
        let conversation = Conversation(title: "super Pulse", messages: [
            ChatMessage(role: "user", content: "Pregunta"),
            ChatMessage(role: "assistant", content: "Respuesta"),
        ])
        let healthy = String(decoding: try ChatJSONL.encode([conversation]), as: UTF8.self)
        let withGarbage = healthy + "\n{this line is broken"

        let decoded = try ChatJSONL.decode(Data(withGarbage.utf8))
        XCTAssertEqual(decoded.skippedLines, 1, "the malformed line is counted, not swallowed")
        XCTAssertEqual(decoded.conversations.count, 1, "the healthy lines still import")
        XCTAssertEqual(decoded.conversations.first?.title, "super Pulse")

        XCTAssertThrowsError(try ChatJSONL.decode(Data("garbage only".utf8)),
                             "an archive with no sessions is still the typed unsupported error")

        let roundTrip = try ChatJSONL.decode(Data(healthy.utf8))
        XCTAssertEqual(roundTrip.skippedLines, 0, "a healthy export skips nothing")
        XCTAssertEqual(roundTrip.conversations.first?.messages.count, 2)
    }

    @MainActor func testImportArchiveDataReportsSkippedLinesThroughTheImportPath() throws {
        try withBackedUpConversationStore {
            let store = ChatStore()
            let conversation = Conversation(title: "importado", messages: [
                ChatMessage(role: "user", content: "Pregunta"),
            ])
            let healthy = String(decoding: try ChatJSONL.encode([conversation]), as: UTF8.self)
            let result = try store.importArchiveData(Data((healthy + "\n{broken").utf8))
            XCTAssertEqual(result.imported, 1)
            XCTAssertEqual(result.skippedLines, 1,
                           "the import result must carry the skipped count for the UI to surface")
            XCTAssertNotNil(store.conversations.first(where: { $0.title == "importado" }))
        }
    }

    // MARK: - Store backup discipline (same pattern as the agent-loop checks)

    /// ChatStore persists to the real Application Support store; every check
    /// that instantiates one backs the file up byte-exact and restores it.
    @MainActor private func withBackedUpConversationStore(_ body: @MainActor () throws -> Void) throws {
        let storeURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kestrel/conversations.json")
        let priorBytes = try? Data(contentsOf: storeURL)
        let hadFile = FileManager.default.fileExists(atPath: storeURL.path)
        defer {
            if let priorBytes {
                try? priorBytes.write(to: storeURL)
            } else if !hadFile {
                try? FileManager.default.removeItem(at: storeURL)
            }
        }
        try body()
    }
}

// MARK: - Generated registration (port from XCTest)
extension ChatImportSurfacingTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ChatImportSurfacingTests",
        instance: { ChatImportSurfacingTests() },
        checks: [
            .init(name: "testCustomJSONIssueEnforcesTopLevelObject") { $0.testCustomJSONIssueEnforcesTopLevelObject() },
            .init(name: "testCustomSamplingMergeRejectsNonObjectAndFailsTheTurn") { try $0.testCustomSamplingMergeRejectsNonObjectAndFailsTheTurn() },
            .init(name: "testCustomSamplingMergeAppliesHealthyObjectWithCustomPrecedence") { try $0.testCustomSamplingMergeAppliesHealthyObjectWithCustomPrecedence() },
            .init(name: "testCustomSamplingMergeWithEmptyFieldLeavesBodyUntouched") { try $0.testCustomSamplingMergeWithEmptyFieldLeavesBodyUntouched() },
            .init(name: "testFailedSummarizeKeepsTheConversationCompactable") { try $0.testFailedSummarizeKeepsTheConversationCompactable() },
            .init(name: "testJSONLDecodeCountsSkippedLinesAndStillImportsTheRest") { try $0.testJSONLDecodeCountsSkippedLinesAndStillImportsTheRest() },
            .init(name: "testImportArchiveDataReportsSkippedLinesThroughTheImportPath") { try $0.testImportArchiveDataReportsSkippedLinesThroughTheImportPath() },
        ])
}
