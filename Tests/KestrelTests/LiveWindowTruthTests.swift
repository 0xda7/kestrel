// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Launch-truth over read-time defaults (census W5-1..W5-5): the window
/// the UI shows follows the engine's published ctx in BOTH modes; slot
/// save/restore follow the published launch signature; window triage
/// tells "no engine" (solver estimate is planning) from "engine without a
/// published context" (solver estimate is a guess, and is logged); the
/// tool-result cap follows the conversation's own engine port; and the
/// solver's engine-default ubatch stand-in is pinned against the bundled
/// binary's documented default.
final class LiveWindowTruthTests: CheckCase {
    private let testPort = 83_99
    private let portA = 84_01
    private let portB = 84_02

    override func setUp() {
        ServerSettings.clearLiveCtx(port: testPort)
        ServerSettings.clearLaunchSlotSignature(port: testPort)
        ServerSettings.clearLiveCtx(port: portA)
        ServerSettings.clearLiveCtx(port: portB)
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

    /// Census W5-4 (the census drill): an engine serving on a non-default
    /// port — every added server gets freePort() — must cap tool results
    /// against ITS published window. The old code probed
    /// ServerSettings.fromDefaults().port inside completeToolCall, so the
    /// cap came from whichever engine (or solver estimate) sat on the
    /// defaults port. Sabotage drill: point ChatStore.toolResultContext
    /// back at fromDefaults().port -> this check RED.
    func testToolResultCapFollowsTheConversationsPortNotTheDefaultsPort() {
        defer {
            ServerSettings.clearLiveCtx(port: portA)
            ServerSettings.clearLiveCtx(port: portB)
        }
        ServerSettings.publishLiveCtx(3_000, port: portA)
        ServerSettings.publishLiveCtx(65_536, port: portB)
        let dump = String(repeating: "x", count: 20_000)

        // A 3,000-token window caps at exactly 3,000 characters (a quarter
        // of the headroom, above the 2,000 floor); a 65,536 window rides to
        // the 12,000 ceiling. Same input, different engines, different caps.
        XCTAssertEqual(ChatStore.toolResultContext(dump, port: portA, usedTokens: 0),
                       ChatToolsService.clampedToolResult(dump, cap: 3_000),
                       "the cap must follow the window published on the conversation's own port")
        XCTAssertEqual(ChatStore.toolResultContext(dump, port: portB, usedTokens: 0),
                       ChatToolsService.clampedToolResult(dump, cap: 12_000),
                       "a wide-window engine keeps the ceiling — proving the port drove the cap")

        // The permission request freezes the run's port at creation.
        let request = PendingToolPermission(
            conversationID: UUID(), messageID: UUID(), callID: UUID(), port: portA,
            name: "read_file", displayName: "read_file", arguments: "{}",
            writesData: false, serverID: nil, serverName: nil)
        XCTAssertEqual(request.port, portA)
    }

    /// Census W5-5: the solver's `effectiveUbatch ?? engineDefaultUbatch`
    /// stand-in must equal the bundled engine's OWN default. The binary's
    /// --help is the ground-truth artifact (the /props-at-publish option
    /// was rejected: every consumption site is launch-time solver math,
    /// with no engine to ask yet), so the constant is pinned against it.
    /// Sabotage drill: change ServerSettings.engineDefaultUbatch -> this
    /// check RED; a bundled engine that changes its default -> RED.
    func testEngineDefaultUbatchIsPinnedAgainstTheEngineBinary() {
        let candidates: [String?] = [Bundle.main.resourceURL?.appendingPathComponent("bin/llama-server").path,
                                     "/Applications/Kestrel.app/Contents/Resources/bin/llama-server"]
        var binary = candidates.compactMap { path in
            (path != nil && FileManager.default.fileExists(atPath: path!)) ? path : nil
        }.first
        if binary == nil,
           UserDefaults.standard.string(forKey: SettingsKeys.engineKind) == "custom",
           let custom = UserDefaults.standard.string(forKey: SettingsKeys.serverBinary),
           FileManager.default.fileExists(atPath: custom) {
            binary = custom
        }
        guard let enginePath = binary else {
            return XCTFail("no engine binary to pin the ubatch default against (tried Bundle.main bin/llama-server, /Applications/Kestrel.app, and the custom serverBinary)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: enginePath)
        process.arguments = ["--help"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return XCTFail("could not run \(enginePath) --help: \(error.localizedDescription)")
        }
        // llama-server prints its usage to stderr; read both before waiting.
        let help = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile()
                                   + stderr.fileHandleForReading.readDataToEndOfFile(),
                          as: UTF8.self)
        process.waitUntilExit()

        XCTAssertTrue(help.contains("--ubatch-size"),
                      "the engine must document --ubatch-size for the pin to be readable (\(enginePath))")
        XCTAssertTrue(help.contains("physical maximum batch size (default: \(ServerSettings.engineDefaultUbatch))"),
                      "the solver's stand-in constant must equal the binary's documented default (\(enginePath))")
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
            .init(name: "testToolResultCapFollowsTheConversationsPortNotTheDefaultsPort") { $0.testToolResultCapFollowsTheConversationsPortNotTheDefaultsPort() },
            .init(name: "testEngineDefaultUbatchIsPinnedAgainstTheEngineBinary") { $0.testEngineDefaultUbatchIsPinnedAgainstTheEngineBinary() },
        ])
}
