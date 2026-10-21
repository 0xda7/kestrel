// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// T3-1 (census W3-1..W3-4 and W3-7..W3-15): the mandate-A1 constants and
/// their W3 siblings the engine ran on secretly are now real settings. These
/// checks pin the wiring contract for each: a seeded value drives the
/// behavior, an absent key falls to the declared default (so changing a
/// ChatDefaults/ServerSettings/service constant is caught), and — for the
/// cache-reuse value — both writers read the one setting. Sabotage drills:
/// remove a registry entry -> TypedSettingsRegistryTests
/// .testRegistryIsComplete RED; change a declared-default constant (e.g.
/// ChatDefaults.compactionTrigger, ChatDefaults.compactionSummaryMaxTokens)
/// -> the setting's wiring check RED.
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
                    SettingsKeys.cacheReuseWindowSize,
                    SettingsKeys.chatCompactionSummaryMaxTokens,
                    SettingsKeys.chatCompactionSummarizeTemp,
                    SettingsKeys.chatCompactionMinTailMessages,
                    SettingsKeys.chatRecallMaxResults,
                    SettingsKeys.chatRecallMaxCharacters,
                    SettingsKeys.chatToolResultMaxTokens,
                    SettingsKeys.chatToolResultMinTokens,
                    SettingsKeys.jsSandboxDefaultTimeoutMS,
                    SettingsKeys.jsSandboxMaxTimeoutMS,
                    SettingsKeys.jsSandboxMaxOutputCharacters,
                    SettingsKeys.memoryArchiveHookQueueLimit,
                    SettingsKeys.memoryArchiveHookTimeout,
                    SettingsKeys.engineControlTimeoutSeconds] {
            XCTAssertTrue(SettingsNumericCoercion.isRegistered(key), "\(key) must be registered typed")
            XCTAssertTrue(SettingsKeys.resettableOptionKeys.contains(key), "\(key) must be resettable")
        }
    }

    /// The summarize budget and temperature come from one setting pair:
    /// seeded values land in the request body, absent keys fall to the
    /// declared defaults, and the compaction prompt reserves the same budget
    /// it asks the engine for (the lockstep the census demanded). Sabotage
    /// drill: change ChatDefaults.compactionSummaryMaxTokens -> RED.
    func testSummarizeBudgetAndTempComeFromOneSetting() {
        let absent = ChatStore.summarizeRequestBody(prompt: "p", model: "m", in: suite)
        XCTAssertEqual(absent["max_tokens"] as? Int, 512,
                       "the declared default is the literal the census recorded")
        XCTAssertEqual(absent["temperature"] as? Double, 0.3)
        suite.set(768, forKey: SettingsKeys.chatCompactionSummaryMaxTokens)
        suite.set(0.1, forKey: SettingsKeys.chatCompactionSummarizeTemp)
        let seeded = ChatStore.summarizeRequestBody(prompt: "p", model: nil, in: suite)
        XCTAssertEqual(seeded["max_tokens"] as? Int, 768)
        XCTAssertEqual(seeded["temperature"] as? Double, 0.1)
        XCTAssertNil(seeded["model"])
        XCTAssertEqual(ChatStore.compactionSummaryMaxTokens(in: suite), 768,
                       "the prompt reservation reads the same setting the body carries")
    }

    /// The min-tail setting replaces the hardwired -4: the cutoff keeps the
    /// operator's N newest messages, the already-compacted +2 floor still
    /// applies, and an absent key falls to the declared default.
    func testMinTailMessagesSettingDrivesCutoff() {
        XCTAssertEqual(ChatStore.compactionMinTailMessages(in: suite),
                       ChatDefaults.compactionMinTailMessages)
        XCTAssertEqual(ChatStore.compactionMinTailMessages(in: suite), 4,
                       "the declared default is the literal the census recorded")
        let messages = (0..<10).map { ChatMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant",
                                                  content: "turn \($0)") }
        XCTAssertEqual(ChatStore.compactionCutoff(messages: messages, alreadyCompacted: 0,
                                                  minTailMessages: 4), 6)
        XCTAssertEqual(ChatStore.compactionCutoff(messages: messages, alreadyCompacted: 0,
                                                  minTailMessages: 6), 4)
        // The +2 already-compacted floor rides along as derived logic.
        XCTAssertNil(ChatStore.compactionCutoff(messages: messages, alreadyCompacted: 5,
                                                minTailMessages: 4))
        suite.set(6, forKey: SettingsKeys.chatCompactionMinTailMessages)
        XCTAssertEqual(ChatStore.compactionMinTailMessages(in: suite), 6)
    }

    /// The recall limits come from settings: the results cap follows its key
    /// (a missing model argument still falls to the tool-contract 4), and
    /// the character cap follows its own.
    func testRecallLimitsComeFromSettings() {
        XCTAssertEqual(ChatStore.recallResultLimit(arguments: [:], in: suite), 4)
        XCTAssertEqual(ChatStore.recallResultLimit(arguments: ["max_results": 100], in: suite),
                       ChatDefaults.recallMaxResults)
        XCTAssertEqual(ChatStore.recallResultLimit(arguments: ["max_results": 100], in: suite), 20,
                       "the declared default is the literal the census recorded")
        XCTAssertEqual(ChatMemoryService.recallCharacterCap(in: suite), 6_000)
        suite.set(5, forKey: SettingsKeys.chatRecallMaxResults)
        suite.set(1_000, forKey: SettingsKeys.chatRecallMaxCharacters)
        XCTAssertEqual(ChatStore.recallResultLimit(arguments: [:], in: suite), 4)
        XCTAssertEqual(ChatStore.recallResultLimit(arguments: ["max_results": 100], in: suite), 5)
        XCTAssertEqual(ChatStore.recallResultLimit(arguments: ["max_results": 2], in: suite), 2)
        XCTAssertEqual(ChatMemoryService.recallCharacterCap(in: suite), 1_000)
    }

    /// The tool-result caps come from settings: the dynamic cap never goes
    /// below the operator's floor nor above the operator's ceiling, absent
    /// keys fall to the declared defaults, and the static ceiling is the
    /// same single source the clamp's default parameter uses.
    func testToolResultCapsComeFromSettings() {
        XCTAssertEqual(ChatToolsService.dynamicToolResultCap(windowTokens: 16_384, usedTokens: 16_000, in: suite),
                       2_000, "the declared default is the literal the census recorded")
        XCTAssertEqual(ChatToolsService.dynamicToolResultCap(windowTokens: 32_768, usedTokens: 0, in: suite),
                       12_000)
        XCTAssertEqual(ChatToolsService.toolResultContextLimit, ChatDefaults.toolResultMaxTokens,
                       "the static ceiling is the one single-sourced constant")
        suite.set(3_000, forKey: SettingsKeys.chatToolResultMaxTokens)
        suite.set(500, forKey: SettingsKeys.chatToolResultMinTokens)
        XCTAssertEqual(ChatToolsService.dynamicToolResultCap(windowTokens: 16_384, usedTokens: 16_000, in: suite), 500)
        XCTAssertEqual(ChatToolsService.dynamicToolResultCap(windowTokens: 32_768, usedTokens: 0, in: suite), 3_000)
    }

    /// The sandbox limits come from settings; absent keys fall to the
    /// declared defaults execute() and formatReply() clamp with.
    func testJsSandboxLimitsComeFromSettings() {
        XCTAssertEqual(JavaScriptSandboxService.sandboxDefaultTimeoutMS(in: suite), 10_000)
        XCTAssertEqual(JavaScriptSandboxService.sandboxMaxTimeoutMS(in: suite), 30_000)
        XCTAssertEqual(JavaScriptSandboxService.sandboxOutputCharacterCap(in: suite), 8_192)
        suite.set(5_000, forKey: SettingsKeys.jsSandboxDefaultTimeoutMS)
        suite.set(60_000, forKey: SettingsKeys.jsSandboxMaxTimeoutMS)
        suite.set(4_096, forKey: SettingsKeys.jsSandboxMaxOutputCharacters)
        XCTAssertEqual(JavaScriptSandboxService.sandboxDefaultTimeoutMS(in: suite), 5_000)
        XCTAssertEqual(JavaScriptSandboxService.sandboxMaxTimeoutMS(in: suite), 60_000)
        XCTAssertEqual(JavaScriptSandboxService.sandboxOutputCharacterCap(in: suite), 4_096)
    }

    /// The archive hook's delivery policy comes from settings; absent keys
    /// fall to the declared defaults trim() and the delivery attempt use.
    func testMemoryArchiveHookLimitsComeFromSettings() {
        XCTAssertEqual(MemoryArchiveHook.queueLimit(in: suite), 500)
        XCTAssertEqual(MemoryArchiveHook.attemptTimeout(in: suite), 15)
        suite.set(3, forKey: SettingsKeys.memoryArchiveHookQueueLimit)
        suite.set(2.5, forKey: SettingsKeys.memoryArchiveHookTimeout)
        XCTAssertEqual(MemoryArchiveHook.queueLimit(in: suite), 3)
        XCTAssertEqual(MemoryArchiveHook.attemptTimeout(in: suite), 2.5)
    }

    /// The control-plane idle bound comes from the setting; the absent key
    /// falls to the declared 10 s (so changing the declared constant flips
    /// this check — the tripwire), and a seeded value reads through.
    func testEngineControlTimeoutComesFromSetting() {
        XCTAssertEqual(EngineHTTP.defaultTimeoutSeconds, 10)
        XCTAssertEqual(EngineHTTP.controlTimeoutSeconds(in: suite), EngineHTTP.defaultTimeoutSeconds)
        suite.set(5, forKey: SettingsKeys.engineControlTimeoutSeconds)
        XCTAssertEqual(EngineHTTP.controlTimeoutSeconds(in: suite), 5)
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
            .init(name: "testSummarizeBudgetAndTempComeFromOneSetting") { $0.testSummarizeBudgetAndTempComeFromOneSetting() },
            .init(name: "testMinTailMessagesSettingDrivesCutoff") { $0.testMinTailMessagesSettingDrivesCutoff() },
            .init(name: "testRecallLimitsComeFromSettings") { $0.testRecallLimitsComeFromSettings() },
            .init(name: "testToolResultCapsComeFromSettings") { $0.testToolResultCapsComeFromSettings() },
            .init(name: "testJsSandboxLimitsComeFromSettings") { $0.testJsSandboxLimitsComeFromSettings() },
            .init(name: "testMemoryArchiveHookLimitsComeFromSettings") { $0.testMemoryArchiveHookLimitsComeFromSettings() },
            .init(name: "testEngineControlTimeoutComesFromSetting") { $0.testEngineControlTimeoutComesFromSetting() },
            .init(name: "testSecretSettingsAreResettable") { $0.testSecretSettingsAreResettable() },
        ])
}
