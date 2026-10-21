// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission C1 Phase B pins (pre-conversion freeze): every repair tier of the
/// W1-2 arguments ladder exactly as it behaves BEFORE grammar-constrained
/// tool calls. The strict-pass and array-throw tiers are already pinned in
/// KestrelTests.swift (testToolArgumentsRequireAJSONObject); these checks
/// cover the tiers nothing else covers: BOM, fence, trailing comma, single
/// quotes, whitespace-means-empty, and the unrepairable throw. When Phase C
/// makes argument blobs grammar-enforced on the constrained path, these
/// checks keep pinning the ladder for every unconstrained path.
final class ToolArgumentsRepairTests: CheckCase {
    // MARK: Individual repair tiers

    /// A UTF-8 BOM glued to the JSON is stripped before parsing.
    func testStripsByteOrderMarkBeforeParsing() throws {
        let value = try ChatToolsService.parseArguments("\u{FEFF}{\"path\":\"a.txt\"}")

        XCTAssertEqual(value["path"] as? String, "a.txt")
    }

    /// A ```json … ``` fence around the object is cut to the object itself.
    func testCutsMarkdownFenceToObject() throws {
        let value = try ChatToolsService.parseArguments("```json\n{\"path\":\"a.txt\"}\n```")

        XCTAssertEqual(value["path"] as? String, "a.txt")
    }

    /// A trailing comma before `}` is removed by the string-aware scan.
    func testRepairsTrailingComma() throws {
        let value = try ChatToolsService.parseArguments("{\"path\":\"a.txt\",}")

        XCTAssertEqual(value["path"] as? String, "a.txt")
    }

    /// Single-quoted keys and values are normalized to double quotes.
    func testRepairsSingleQuotedKeysAndValues() throws {
        let value = try ChatToolsService.parseArguments("{'path':'a.txt'}")

        XCTAssertEqual(value["path"] as? String, "a.txt")
    }

    /// Trailing comma AND single quotes in the same blob: the ladder runs
    /// comma-strip first, then quote-normalization, then parses.
    func testCombinedTrailingCommaAndSingleQuotesRepair() throws {
        let value = try ChatToolsService.parseArguments("{'path':'a.txt',}")

        XCTAssertEqual(value["path"] as? String, "a.txt")
    }

    // MARK: The no-arguments and error tiers

    /// A whitespace-only blob means "no arguments": `get_datetime`-style
    /// tools must not die on an empty payload.
    func testWhitespaceOnlyBlobMeansNoArguments() throws {
        let value = try ChatToolsService.parseArguments("   \n\t  ")

        XCTAssertTrue(value.isEmpty)
    }

    /// A comment-only blob is NOT whitespace-only under the current
    /// implementation (strippedOfStrings only strips double-quoted strings),
    /// so it throws — pinned as-is: this is the pre-conversion freeze.
    func testCommentOnlyBlobStillThrows() {
        XCTAssertThrowsError(try ChatToolsService.parseArguments("// just a comment")) { error in
            guard case ChatToolsError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    /// Unrepairable garbage throws the typed error instead of silently
    /// becoming "no arguments".
    func testUnrepairableBlobThrowsInvalidResponse() {
        XCTAssertThrowsError(try ChatToolsService.parseArguments("not json at all {")) { error in
            guard case ChatToolsError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }
}

// MARK: - Generated registration (port from XCTest)
extension ToolArgumentsRepairTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ToolArgumentsRepairTests",
        instance: { ToolArgumentsRepairTests() },
        checks: [
            .init(name: "testStripsByteOrderMarkBeforeParsing") { try $0.testStripsByteOrderMarkBeforeParsing() },
            .init(name: "testCutsMarkdownFenceToObject") { try $0.testCutsMarkdownFenceToObject() },
            .init(name: "testRepairsTrailingComma") { try $0.testRepairsTrailingComma() },
            .init(name: "testRepairsSingleQuotedKeysAndValues") { try $0.testRepairsSingleQuotedKeysAndValues() },
            .init(name: "testCombinedTrailingCommaAndSingleQuotesRepair") { try $0.testCombinedTrailingCommaAndSingleQuotesRepair() },
            .init(name: "testWhitespaceOnlyBlobMeansNoArguments") { try $0.testWhitespaceOnlyBlobMeansNoArguments() },
            .init(name: "testCommentOnlyBlobStillThrows") { $0.testCommentOnlyBlobStillThrows() },
            .init(name: "testUnrepairableBlobThrowsInvalidResponse") { $0.testUnrepairableBlobThrowsInvalidResponse() },
        ]
    )
}
