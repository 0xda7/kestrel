// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Launch-truth over read-time defaults (census W5-1/W5-2/W5-3): the window
/// the UI shows follows the engine's published ctx in BOTH modes; slot
/// save/restore follow the published launch signature; and window triage
/// tells "no engine" (solver estimate is planning) from "engine without a
/// published context" (solver estimate is a guess, and is logged).
final class LiveWindowTruthTests: CheckCase {
    private let testPort = 83_99

    override func setUp() {
        ServerSettings.clearLiveCtx(port: testPort)
        ServerSettings.clearLaunchSlotSignature(port: testPort)
    }

    func testDisplayCtxPrefersPublishedWindowInBothModes() {
        ServerSettings.publishLiveCtx(16_384, port: testPort)
        XCTAssertEqual(ServerSettings.displayCtx(port: testPort, configured: 32_768,
                                                 automaticResolved: 65_536, automatic: false), 16_384,
                       "manual mode: a mid-run ctx edit must not lie to the meter")
        XCTAssertEqual(ServerSettings.displayCtx(port: testPort, configured: 32_768,
                                                 automaticResolved: 65_536, automatic: true), 16_384)
        ServerSettings.clearLiveCtx(port: testPort)
        XCTAssertEqual(ServerSettings.displayCtx(port: testPort, configured: 32_768,
                                                 automaticResolved: 65_536, automatic: false), 32_768,
                       "no engine: the configured manual value stands in")
        XCTAssertEqual(ServerSettings.displayCtx(port: testPort, configured: 32_768,
                                                 automaticResolved: 65_536, automatic: true), 65_536)
    }

    func testWindowStateTellsNoEngineFromEngineWithoutPublishedCtx() {
        let original = EngineLock.liveCountForTriage
        defer { EngineLock.liveCountForTriage = original }

        ServerSettings.publishLiveCtx(8_192, port: testPort)
        XCTAssertEqual(ServerSettings.windowState(port: testPort), .published(8_192))

        ServerSettings.clearLiveCtx(port: testPort)
        EngineLock.liveCountForTriage = { 0 }
        guard case .noEngine = ServerSettings.windowState(port: testPort) else {
            return XCTFail("nothing running and nothing published must triage as noEngine")
        }

        EngineLock.liveCountForTriage = { 2 }
        XCTAssertEqual(ServerSettings.windowState(port: testPort), .engineWithoutPublishedCtx,
                       "an engine up without a published window is a distinct, honest state")
        XCTAssertEqual(ServerSettings.liveResolvedCtx(port: testPort),
                       ServerSettings.fromDefaults().resolvedCtx,
                       "the ambiguous state falls back to the solver estimate — logged, not silent")
    }

    func testSlotDecisionsFollowTheLaunchSignatureNotCurrentDefaults() {
        let fallbackBeforePublish = ServerSettings.slotKVSignature(port: testPort)
        ServerSettings.publishLaunchSlotSignature(kv: "q8_0-turbo4-v", persistCache: true, port: testPort)
        XCTAssertEqual(ServerSettings.launchSlotKVSignature(port: testPort), "q8_0-turbo4-v")
        XCTAssertEqual(ServerSettings.slotKVSignature(port: testPort), "q8_0-turbo4-v",
                       "a mid-run KV toggle must not repoint slot files at a dir the engine never used")
        XCTAssertEqual(ServerSettings.launchSlotPersistCache(port: testPort), true)
        ServerSettings.clearLaunchSlotSignature(port: testPort)
        XCTAssertNil(ServerSettings.launchSlotKVSignature(port: testPort))
        XCTAssertNil(ServerSettings.launchSlotPersistCache(port: testPort))
        XCTAssertEqual(ServerSettings.slotKVSignature(port: testPort), fallbackBeforePublish,
                       "cleared: falls back to current defaults (no engine to disagree with)")
    }
}

// MARK: - Generated registration (port from XCTest)
extension LiveWindowTruthTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "LiveWindowTruthTests",
        instance: { LiveWindowTruthTests() },
        checks: [
            .init(name: "testDisplayCtxPrefersPublishedWindowInBothModes") { $0.testDisplayCtxPrefersPublishedWindowInBothModes() },
            .init(name: "testWindowStateTellsNoEngineFromEngineWithoutPublishedCtx") { $0.testWindowStateTellsNoEngineFromEngineWithoutPublishedCtx() },
            .init(name: "testSlotDecisionsFollowTheLaunchSignatureNotCurrentDefaults") { $0.testSlotDecisionsFollowTheLaunchSignatureNotCurrentDefaults() },
        ])
}
