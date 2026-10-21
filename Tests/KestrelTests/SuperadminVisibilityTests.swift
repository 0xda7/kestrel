// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// T3-1 (census W3-1..W3-4): the four mandate-A1 constants the engine ran on
/// secretly are now real settings. These checks pin the wiring contract for
/// each: a seeded value drives the behavior, an absent key falls to the
/// declared default (so changing a ChatDefaults/ServerSettings constant is
/// caught), and both cache-reuse writers read the one setting. Sabotage
/// drills: remove a registry entry -> TypedSettingsRegistryTests
/// .testRegistryIsComplete RED; change ChatDefaults.compactionTrigger ->
/// testCompactionTriggerSettingDrivesAutoCompaction RED.
final class SuperadminVisibilityTests: CheckCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "superadmin-visibility-tests")
        suite.removePersistentDomain(forName: "superadmin-visibility-tests")
        SettingsNumericCoercion.resetDriftReportingForChecks()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "superadmin-visibility-tests")
        super.tearDown()
    }

    private func makeSettings() -> ServerSettings {
        ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/superadmin-m.gguf", port: 8080,
                       ngl: 99, ncmoe: 24, ctx: 16384, threads: 6, flashAttn: "auto",
                       noMmap: true, jinja: true,
                       vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                       cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
    }

    /// The compaction trigger setting draws the auto-compaction line. Absent
    /// key: the declared 0.7 default. Seeded: the operator's value. Sabotage
    /// drill: change ChatDefaults.compactionTrigger -> this check RED.
    func testCompactionTriggerSettingDrivesAutoCompaction() {
        XCTAssertFalse(ChatStore.autoCompactionDue(contextUsed: 69, window: 100, in: suite))
        XCTAssertTrue(ChatStore.autoCompactionDue(contextUsed: 71, window: 100, in: suite))
        suite.set(0.9, forKey: SettingsKeys.chatCompactionTrigger)
        XCTAssertFalse(ChatStore.autoCompactionDue(contextUsed: 75, window: 100, in: suite))
        XCTAssertTrue(ChatStore.autoCompactionDue(contextUsed: 95, window: 100, in: suite))
        // No published window, no compaction decision.
        XCTAssertFalse(ChatStore.autoCompactionDue(contextUsed: 95, window: 0, in: suite))
    }

    /// The keep-tail fraction setting replaces the hardwired limit/4: absent
    /// key reproduces the old 25% behavior, a seeded fraction overrides it.
    func testKeepTailFractionSettingDrivesTailTokens() {
        XCTAssertEqual(ChatStore.compactionKeepTailTokens(window: 8192, in: suite), 2048)
        XCTAssertEqual(ChatStore.compactionKeepTailTokens(window: 0, in: suite), 0)
        suite.set(0.5, forKey: SettingsKeys.chatCompactionKeepTailFraction)
        XCTAssertEqual(ChatStore.compactionKeepTailTokens(window: 8192, in: suite), 4096)
    }

    /// The response-margin setting is the one headroom for the context-trap
    /// guard, the clamp, and the compaction-prompt budget. Absent key: the
    /// declared default, and the pure clamp agrees with it. Seeded: the read
    /// follows, and a larger margin shrinks the compaction prompt's budget.
    func testResponseMarginSettingDrivesClampAndBudget() {
        XCTAssertEqual(ChatStore.responseMarginTokens(in: suite), ChatDefaults.responseMarginTokens)
        XCTAssertEqual(ChatStore.clampedResponseTokens(65_536, window: 65_536, estimatedPrompt: 15_000),
                       65_536 - 15_000 - ChatDefaults.responseMarginTokens)
        suite.set(512, forKey: SettingsKeys.chatResponseMarginTokens)
        XCTAssertEqual(ChatStore.responseMarginTokens(in: suite), 512)
        let messages = (0..<20).map { ChatMessage(role: "user",
                                                  content: String(repeating: "a", count: 36) + " \($0)") }
        let window = 300 + 512 + ChatDefaults.responseMarginTokens
        let small = ChatStore.compactionPrompt(summary: nil, messages: messages, window: window)
        let large = ChatStore.compactionPrompt(summary: nil, messages: messages, window: window, margin: 512)
        XCTAssertGreaterThan(large.dropped, 0)
        XCTAssertGreaterThanOrEqual(large.dropped, small.dropped)
    }

    /// Both cache-reuse writers read the ONE setting: the single-model argv
    /// and the router preset emit the same chunk size, seeded or default, and
    /// neither emits anything when reuse is off.
    func testCacheReuseWindowSizeDrivesBothWriters() {
        // The declared default is one source: a default-constructed settings
        // carries it, and the typed read fromDefaults uses falls back to it.
        XCTAssertEqual(ServerSettings.defaultCacheReuseWindowSize, 256)
        XCTAssertEqual(makeSettings().cacheReuseWindowSize, ServerSettings.defaultCacheReuseWindowSize)
        XCTAssertEqual(
            SettingsNumericCoercion.int(SettingsKeys.cacheReuseWindowSize,
                                        default: ServerSettings.defaultCacheReuseWindowSize, in: suite),
            ServerSettings.defaultCacheReuseWindowSize)

        var s = makeSettings()
        s.cacheReuse = true
        let args0 = s.arguments
        let i0 = args0.firstIndex(of: "--cache-reuse")!
        XCTAssertEqual(args0[i0 + 1], "256", "the argv writer reads the declared default")
        var seeded = makeSettings()
        seeded.cacheReuse = true
        seeded.cacheReuseWindowSize = 512
        let args = seeded.arguments
        let idx = args.firstIndex(of: "--cache-reuse")!
        XCTAssertEqual(args[idx + 1], "512", "the argv writer reads the setting")
        let ini = seeded.routerPresetINI(modelPaths: ["/tmp/superadmin-m.gguf"], ncmoeByPath: [:])
        XCTAssertTrue(ini.contains("cache-reuse = 512"), "the router preset reads the same setting")
        let defaultIni = s.routerPresetINI(modelPaths: ["/tmp/superadmin-m.gguf"], ncmoeByPath: [:])
        XCTAssertTrue(defaultIni.contains("cache-reuse = 256"))
        var off = makeSettings()
        off.cacheReuse = false
        XCTAssertFalse(off.arguments.contains("--cache-reuse"))
        XCTAssertFalse(off.routerPresetINI(modelPaths: ["/tmp/superadmin-m.gguf"],
                                           ncmoeByPath: [:]).contains("cache-reuse"))
    }

    /// The "real setting" law (A2): every new key is registered typed AND
    /// resettable (which is also what SettingsArchive exports).
    func testSecretSettingsAreResettable() {
        for key in [SettingsKeys.chatCompactionTrigger,
                    SettingsKeys.chatCompactionKeepTailFraction,
                    SettingsKeys.chatResponseMarginTokens,
                    SettingsKeys.cacheReuseWindowSize] {
            XCTAssertTrue(SettingsNumericCoercion.isRegistered(key), "\(key) must be registered typed")
            XCTAssertTrue(SettingsKeys.resettableOptionKeys.contains(key), "\(key) must be resettable")
        }
    }
}

// MARK: - Generated registration (port from XCTest)
extension SuperadminVisibilityTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SuperadminVisibilityTests",
        instance: { SuperadminVisibilityTests() },
        checks: [
            .init(name: "testCompactionTriggerSettingDrivesAutoCompaction") { $0.testCompactionTriggerSettingDrivesAutoCompaction() },
            .init(name: "testKeepTailFractionSettingDrivesTailTokens") { $0.testKeepTailFractionSettingDrivesTailTokens() },
            .init(name: "testResponseMarginSettingDrivesClampAndBudget") { $0.testResponseMarginSettingDrivesClampAndBudget() },
            .init(name: "testCacheReuseWindowSizeDrivesBothWriters") { $0.testCacheReuseWindowSizeDrivesBothWriters() },
            .init(name: "testSecretSettingsAreResettable") { $0.testSecretSettingsAreResettable() },
        ])
}
