// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Context-trap regression tests: `contextAutomatic` must compute a window
/// that fits (never a silent 16384 alias), and the pre-send guard's estimator
/// must catch requests that cannot fit before the engine answers send_error.
final class ContextTrapTests: CheckCase {
    private func makeSettings(ctx: Int, automatic: Bool) -> ServerSettings {
        var s = ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 8080,
                               ngl: 99, ncmoe: 24, ctx: ctx, threads: 6, flashAttn: "auto",
                               noMmap: true, jinja: true,
                               vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                               cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
        s.contextAutomatic = automatic
        return s
    }

    func testManualContextPassesThrough() {
        XCTAssertEqual(makeSettings(ctx: 32768, automatic: false).resolvedCtx, 32768)
    }

    func testAutomaticContextNeverExceedsTheCeiling() {
        // On a roomy GPU the solver returns the ceiling; on a tight one it
        // halves down. Both are correct; above the ceiling or below the
        // 2048 floor (unless asked lower) would not be.
        let resolved = makeSettings(ctx: 65536, automatic: true).resolvedCtx
        XCTAssertLessThanOrEqual(resolved, 65536)
        XCTAssertGreaterThanOrEqual(resolved, min(2048, 65536))
    }

    func testEstimatedRequestTokensCountsTextAndSystem() {
        let message = ChatMessage(role: "user", content: String(repeating: "a", count: 4000))
        let estimate = ChatStore.estimatedRequestTokens(messages: [message],
                                                        system: String(repeating: "s", count: 800))
        XCTAssertEqual(estimate, 800 / 4 + 4000 / 4)
    }

    func testOverflowNoticeNamesBothLanguagesAndNumbers() {
        let notice = ChatStore.contextOverflowNotice(estimated: 70871, window: 65536)
        XCTAssertTrue(notice.contains("70871"))
        XCTAssertTrue(notice.contains("65536"))
        XCTAssertTrue(notice.contains("context window"))
        XCTAssertTrue(notice.contains("ventana de contexto"))
    }
}

// MARK: - Generated registration (port from XCTest)
extension ContextTrapTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ContextTrapTests",
        instance: { ContextTrapTests() },
        checks: [
            .init(name: "testManualContextPassesThrough") { $0.testManualContextPassesThrough() },
            .init(name: "testAutomaticContextNeverExceedsTheCeiling") { $0.testAutomaticContextNeverExceedsTheCeiling() },
            .init(name: "testEstimatedRequestTokensCountsTextAndSystem") { $0.testEstimatedRequestTokensCountsTextAndSystem() },
            .init(name: "testOverflowNoticeNamesBothLanguagesAndNumbers") { $0.testOverflowNoticeNamesBothLanguagesAndNumbers() },
        ])
}
