// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

final class LogPresentationTests: CheckCase {
    func testParsesRealLlamaCppPrefix() {
        let line = "0.00.112.264 I srv    load_model: loading model '/models/Qwen.gguf'"
        let parsed = LogPresentationParser.parse(line, fallbackSource: "Engine")

        XCTAssertEqual(parsed.first?.time, "0.00.112.264")
        XCTAssertEqual(parsed.first?.level, .info)
        XCTAssertEqual(parsed.first?.source, "Server")
        XCTAssertEqual(parsed.first?.message, "load_model: loading model '/models/Qwen.gguf'")
    }

    func testKeepsUnprefixedMetalDiagnostics() {
        let line = "ggml_metal: device 0: AMD Radeon RX 6700 XT"
        let parsed = LogPresentationParser.parse(line, fallbackSource: "Engine")

        XCTAssertEqual(parsed.first?.source, "Metal")
        XCTAssertEqual(parsed.first?.message, line)
    }
}

// MARK: - Generated registration (port from XCTest)
extension LogPresentationTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "LogPresentationTests",
        instance: { LogPresentationTests() },
        checks: [
            .init(name: "testParsesRealLlamaCppPrefix") { $0.testParsesRealLlamaCppPrefix() },
            .init(name: "testKeepsUnprefixedMetalDiagnostics") { $0.testKeepsUnprefixedMetalDiagnostics() },
        ])
}
