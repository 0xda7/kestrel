// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

final class ToolSupportTests: CheckCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SettingsKeys.toolsUnsupportedModels)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.toolsUnsupportedModels)
        super.tearDown()
    }

    func testBlocksOnlyTheModelThatFailed() {
        ToolSupport.block("/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf")

        XCTAssertTrue(ToolSupport.isBlocked("/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf"))
        XCTAssertFalse(ToolSupport.isBlocked("/models/Qwen3-8B-Q4_K_M.gguf"))
    }

    func testBlockingTwiceKeepsOneEntry() {
        ToolSupport.block("/models/a.gguf")
        ToolSupport.block("/models/a.gguf")

        XCTAssertEqual(ToolSupport.blockedModels, ["/models/a.gguf"])
    }

    func testUnblockRestoresTools() {
        ToolSupport.block("/models/a.gguf")
        ToolSupport.block("/models/b.gguf")
        ToolSupport.unblock("/models/a.gguf")

        XCTAssertFalse(ToolSupport.isBlocked("/models/a.gguf"))
        XCTAssertEqual(ToolSupport.blockedModels, ["/models/b.gguf"])
    }

    func testMissingModelIsNeverBlocked() {
        ToolSupport.block(nil)
        ToolSupport.block("")

        XCTAssertTrue(ToolSupport.blockedModels.isEmpty)
        XCTAssertFalse(ToolSupport.isBlocked(nil))
        XCTAssertFalse(ToolSupport.isBlocked(""))
    }
}

// MARK: - Generated registration (port from XCTest)
extension ToolSupportTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ToolSupportTests",
        instance: { ToolSupportTests() },
        checks: [
            .init(name: "testBlocksOnlyTheModelThatFailed") { $0.testBlocksOnlyTheModelThatFailed() },
            .init(name: "testBlockingTwiceKeepsOneEntry") { $0.testBlockingTwiceKeepsOneEntry() },
            .init(name: "testUnblockRestoresTools") { $0.testUnblockRestoresTools() },
            .init(name: "testMissingModelIsNeverBlocked") { $0.testMissingModelIsNeverBlocked() },
        ])
}
