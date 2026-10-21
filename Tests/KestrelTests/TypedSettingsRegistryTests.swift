// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The registry's completeness contract (mission C2, census C2): every
/// numeric/Bool `SettingsKeys` constant the app reads must be registered, so
/// no reader can ever fall back to the legacy untyped path. The expected set
/// below was derived by sweeping Sources/ for every typed read shape
/// (@AppStorage with a numeric/Bool literal default, .integer/.double/
/// .bool(forKey:), as? Int/Double/Bool, stringArray/dictionary(forKey:)) —
/// multi-line calls included; string/Data/enum-raw-value keys are not
/// registry kinds and stay out. Removing a registry entry (sabotage) fails
/// testRegistryIsComplete; adding a key without updating the contract fails
/// it too, so the list and the registry can never silently drift apart.
final class TypedSettingsRegistryTests: CheckCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "typed-settings-registry-tests")
        suite.removePersistentDomain(forName: "typed-settings-registry-tests")
        SettingsNumericCoercion.resetDriftReportingForChecks()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "typed-settings-registry-tests")
        super.tearDown()
    }

    /// Every numeric/Bool key the app reads is registered, and the registry
    /// holds nothing outside that contract. Sabotage drill: remove one
    /// registry entry -> this check goes RED.
    func testRegistryIsComplete() {
        let expected: Set<String> = [
        SettingsKeys.agentToolsEnabled,
        SettingsKeys.apiKeyEnabled,
        SettingsKeys.audioFollowTranscript,
        SettingsKeys.audioVADMaxSpeechSeconds,
        SettingsKeys.audioVADMinSilenceMS,
        SettingsKeys.audioVADMinSpeechMS,
        SettingsKeys.audioVADSpeechPadMS,
        SettingsKeys.audioVADThreshold,
        SettingsKeys.autoStart,
        SettingsKeys.benchDepth,
        SettingsKeys.benchPP,
        SettingsKeys.benchTG,
        SettingsKeys.cacheRAM,
        SettingsKeys.cacheReuse,
        SettingsKeys.chatAgenticMaxTurns,
        SettingsKeys.chatAutoCompact,
        SettingsKeys.chatBackendSampling,
        SettingsKeys.chatDryAllowedLength,
        SettingsKeys.chatDryBase,
        SettingsKeys.chatDryMultiplier,
        SettingsKeys.chatDryPenaltyLastN,
        SettingsKeys.chatDynatempExponent,
        SettingsKeys.chatDynatempRange,
        SettingsKeys.chatFontScale,
        SettingsKeys.chatFrequencyPenalty,
        SettingsKeys.chatMaxImageMegapixels,
        SettingsKeys.chatMaxTokens,
        SettingsKeys.chatMinP,
        SettingsKeys.chatPDFAsImages,
        SettingsKeys.chatPasteLongTextLength,
        SettingsKeys.chatPresencePenalty,
        SettingsKeys.chatRepeatLastN,
        SettingsKeys.chatRepeatPenalty,
        SettingsKeys.chatSeed,
        SettingsKeys.chatShowSystemMessage,
        SettingsKeys.chatTemp,
        SettingsKeys.chatThinking,
        SettingsKeys.chatTopK,
        SettingsKeys.chatTopP,
        SettingsKeys.chatTypicalP,
        SettingsKeys.chatXTCProbability,
        SettingsKeys.chatXTCThreshold,
        SettingsKeys.contextAutomatic,
        SettingsKeys.ctx,
        SettingsKeys.dynamicMoe,
        SettingsKeys.dynamicMoePrefetch,
        SettingsKeys.dynamicMoeSlots,
        SettingsKeys.embeddings,
        SettingsKeys.faAmd,
        SettingsKeys.forcePrivateBuffers,
        SettingsKeys.gpuIndex,
        SettingsKeys.gpusCardCollapsed,
        SettingsKeys.imageMaxTokens,
        SettingsKeys.imagenBaseSize,
        SettingsKeys.imagenCanvasGrid,
        SettingsKeys.imagenCleanupOnClose,
        SettingsKeys.imagenCustomCfg,
        SettingsKeys.imagenCustomIsDiffusion,
        SettingsKeys.imagenGPU,
        SettingsKeys.imagenOffloadCPU,
        SettingsKeys.imagenQueueGrid,
        SettingsKeys.imagenSeed,
        SettingsKeys.imagenSteps,
        SettingsKeys.imagenStrength,
        SettingsKeys.jinja,
        SettingsKeys.jsSandboxEnabled,
        SettingsKeys.loadVision,
        SettingsKeys.localNetworkDiscovery,
        SettingsKeys.memoryToolsEnabled,
        SettingsKeys.menuBarIcon,
        SettingsKeys.mgpuEvents,
        SettingsKeys.mgpuPeer,
        SettingsKeys.mlock,
        SettingsKeys.multiGPU,
        SettingsKeys.multiGPUCount,
        SettingsKeys.ncmoe,
        SettingsKeys.ngl,
        SettingsKeys.noMmap,
        SettingsKeys.onboardingDone,
        SettingsKeys.parallelSlots,
        SettingsKeys.persistCache,
        SettingsKeys.port,
        SettingsKeys.prefetchExperts,
        SettingsKeys.reasoningInline,
        SettingsKeys.routerMode,
        SettingsKeys.routerModelsMax,
        SettingsKeys.serverConfigurationAdvanced,
        SettingsKeys.smoothTyping,
        SettingsKeys.specMTP,
        SettingsKeys.splitGroupSize,
        SettingsKeys.threads,
        SettingsKeys.ubatch,
        SettingsKeys.uiMcpProxy,
        SettingsKeys.updateAutoCheck,
        SettingsKeys.videoFrames,
        SettingsKeys.videoGPU,
        SettingsKeys.videoNegativeSeeded,
        SettingsKeys.videoRecipeVersion,
        SettingsKeys.videoSteps,
        SettingsKeys.videoVAETiling,
        SettingsKeys.vramReserve,
        SettingsKeys.dflashDisabled,
        SettingsKeys.dflashWarningAcknowledged,
        SettingsKeys.incompatibleMmproj,
        SettingsKeys.mtpDisabledModels,
        SettingsKeys.toolsUnsupportedModels,
        SettingsKeys.dflashModes,
        SettingsKeys.extraArgsByModel,
        SettingsKeys.mmprojOverride,
        SettingsKeys.modelDigest,
        SettingsKeys.modelSource,
        SettingsKeys.ncmoeByModel,
        SettingsKeys.prefetchCliffByModel,
        ]
        let registered = Set(SettingsNumericCoercion.registry.keys)
        XCTAssertEqual(registered, expected,
                       "registry and contract differ — remove: \(registered.subtracting(expected).sorted()), add: \(expected.subtracting(registered).sorted())")
    }

    /// The load-bearing kinds are pinned so a silent kind flip (e.g. the
    /// fail-safe gate demoted to a plain bool) cannot pass.
    func testKindsSpotPinned() {
        XCTAssertEqual(SettingsNumericCoercion.kind(forKey: SettingsKeys.apiKeyEnabled), .boolFailSafe,
                       "the KES-01 gate is the fail-safe kind; demoting it un-arms under drift")
        XCTAssertEqual(SettingsNumericCoercion.kind(forKey: SettingsKeys.ctx), .int)
        XCTAssertEqual(SettingsNumericCoercion.kind(forKey: SettingsKeys.port), .int)
        XCTAssertEqual(SettingsNumericCoercion.kind(forKey: SettingsKeys.audioVADThreshold), .double)
        XCTAssertEqual(SettingsNumericCoercion.kind(forKey: SettingsKeys.chatTemp), .double)
        XCTAssertEqual(SettingsNumericCoercion.kind(forKey: SettingsKeys.chatAgenticMaxTurns), .int)
        XCTAssertEqual(SettingsNumericCoercion.kind(forKey: SettingsKeys.loadVision), .bool)
        XCTAssertEqual(SettingsNumericCoercion.kind(forKey: SettingsKeys.chatAutoCompact), .bool)
    }

    /// W4-1: Int drift yields the declared default and is reported — never a
    /// silent 0, never a silent coercion.
    func testIntDriftYieldsDefaultAndReported() {
        suite.set("garbage", forKey: SettingsKeys.ctx)
        XCTAssertEqual(SettingsNumericCoercion.int(SettingsKeys.ctx, default: ServerSettings.defaultCtx, in: suite),
                       ServerSettings.defaultCtx)
        suite.set("9999", forKey: SettingsKeys.port)
        XCTAssertEqual(SettingsNumericCoercion.int(SettingsKeys.port, default: 8080, in: suite), 8080)
        XCTAssertTrue(SettingsNumericCoercion.reportedDriftKeys.contains(SettingsKeys.ctx))
        XCTAssertTrue(SettingsNumericCoercion.reportedDriftKeys.contains(SettingsKeys.port))
    }

    /// W4-4: Double drift yields the declared default and is reported.
    func testDoubleDriftYieldsDefaultAndReported() {
        suite.set("0.35", forKey: SettingsKeys.audioVADThreshold)
        XCTAssertEqual(SettingsNumericCoercion.double(SettingsKeys.audioVADThreshold, default: 0.5, in: suite), 0.5,
                       accuracy: 1e-12)
        XCTAssertTrue(SettingsNumericCoercion.reportedDriftKeys.contains(SettingsKeys.audioVADThreshold))
    }

    /// IfPresent semantics: absent -> nil (caller keeps its own default),
    /// typed -> the value, drift -> nil + reported.
    func testIfPresentSemantics() {
        XCTAssertNil(SettingsNumericCoercion.intIfPresent(SettingsKeys.imagenSteps, in: suite))
        suite.set(12, forKey: SettingsKeys.imagenSteps)
        XCTAssertEqual(SettingsNumericCoercion.intIfPresent(SettingsKeys.imagenSteps, in: suite), 12)
        suite.set("eight", forKey: SettingsKeys.imagenSteps)
        XCTAssertNil(SettingsNumericCoercion.intIfPresent(SettingsKeys.imagenSteps, in: suite),
                     "drift reads as absent so ImageInstanceConfig's member default survives")
        XCTAssertTrue(SettingsNumericCoercion.reportedDriftKeys.contains(SettingsKeys.imagenSteps))
        suite.set("7.0", forKey: SettingsKeys.imagenCustomCfg)
        XCTAssertNil(SettingsNumericCoercion.doubleIfPresent(SettingsKeys.imagenCustomCfg, in: suite))
    }

    /// W4-5: the tri-state absent-means-true keys keep their semantics —
    /// absent true, typed honored, drift reported + declared default.
    func testTriStateBoolAbsentMeansTrue() {
        XCTAssertTrue(SettingsNumericCoercion.bool(SettingsKeys.chatAutoCompact, default: true, in: suite))
        XCTAssertTrue(SettingsNumericCoercion.bool(SettingsKeys.updateAutoCheck, default: true, in: suite))
        suite.set(false, forKey: SettingsKeys.chatAutoCompact)
        XCTAssertFalse(SettingsNumericCoercion.bool(SettingsKeys.chatAutoCompact, default: true, in: suite),
                       "a typed opt-out is honored")
        suite.set("off", forKey: SettingsKeys.chatAutoCompact)
        XCTAssertTrue(SettingsNumericCoercion.bool(SettingsKeys.chatAutoCompact, default: true, in: suite),
                      "drift falls to the declared default (true), never a silent disable")
    }

    /// The launch migration now sweeps the FULL registry, not just the
    /// sampling keys: parseable numerics survive typed, garbage is removed.
    func testMigrationRewritesNumericsTyped() {
        suite.set("4096", forKey: SettingsKeys.ctx)
        suite.set("1024", forKey: SettingsKeys.ubatch)
        suite.set("garbage", forKey: SettingsKeys.port)
        let touched = SettingsNumericCoercion.migrateMistypedNumerics(in: suite)
        XCTAssertEqual(suite.object(forKey: SettingsKeys.ctx) as? Int, 4096)
        XCTAssertEqual(suite.object(forKey: SettingsKeys.ubatch) as? Int, 1024)
        XCTAssertNil(suite.object(forKey: SettingsKeys.port),
                     "unparseable garbage is removed so the declared default applies")
        for key in [SettingsKeys.ctx, SettingsKeys.ubatch, SettingsKeys.port] {
            XCTAssertTrue(touched.contains(key), "\(key) must be migrated")
        }
    }

    /// Criterion: the archive import routes through typedImportValue for
    /// every registered key — a numeric key outside the old sampling set is
    /// never stored as String.
    func testImportRoutesThroughRegistry() throws {
        let json = #"{"format":"kestrel-settings","version":1,"config":{"ctx":"8192","apiKeyEnabled":"true"}}"#
        _ = try SettingsArchive.importData(Data(json.utf8), defaults: suite)
        XCTAssertEqual(suite.object(forKey: SettingsKeys.ctx) as? Int, 8192,
                       "a String '8192' imports typed, not as a String")
        XCTAssertEqual(suite.object(forKey: SettingsKeys.apiKeyEnabled) as? Bool, true,
                       "a String 'true' under the gate imports typed")
    }

    /// W4-11: a String where a string-array belongs surfaces instead of
    /// silently reading empty (the tool blocklist would quietly vanish).
    func testStringArrayDriftSurfaces() {
        suite.set(["model-a"], forKey: SettingsKeys.toolsUnsupportedModels)
        XCTAssertEqual(SettingsNumericCoercion.stringArray(SettingsKeys.toolsUnsupportedModels, in: suite),
                       ["model-a"], "a typed array round-trips")
        suite.set("model-a", forKey: SettingsKeys.toolsUnsupportedModels)
        XCTAssertEqual(SettingsNumericCoercion.stringArray(SettingsKeys.toolsUnsupportedModels, in: suite), [],
                       "drift reads empty — but reported, never silent")
        XCTAssertTrue(SettingsNumericCoercion.reportedDriftKeys.contains(SettingsKeys.toolsUnsupportedModels))
        XCTAssertNil(SettingsNumericCoercion.typedImportValue("model-a", forKey: SettingsKeys.toolsUnsupportedModels),
                     "a String import for a collection key is dropped")
    }

    /// W4-11: a String where a per-model dictionary belongs surfaces instead
    /// of silently reading empty (overrides would quietly be lost).
    func testDictionaryDriftSurfaces() {
        suite.set(["/m/gguf": 4], forKey: SettingsKeys.ncmoeByModel)
        XCTAssertEqual((SettingsNumericCoercion.dictionary(SettingsKeys.ncmoeByModel, in: suite) as? [String: Int])?["/m/gguf"],
                       4, "a typed dictionary round-trips")
        suite.set("/m/gguf:4", forKey: SettingsKeys.ncmoeByModel)
        XCTAssertNil(SettingsNumericCoercion.dictionary(SettingsKeys.ncmoeByModel, in: suite),
                     "drift reads nil — the caller's ?? [:] applies, reported")
        XCTAssertTrue(SettingsNumericCoercion.reportedDriftKeys.contains(SettingsKeys.ncmoeByModel))
        _ = SettingsNumericCoercion.migrateMistypedNumerics(in: suite)
        XCTAssertNil(suite.object(forKey: SettingsKeys.ncmoeByModel),
                     "migration removes the unusable String so the default applies")
    }

    /// Typed storage is untouched by the readers: what was written typed is
    /// what comes back, for every kind.
    func testTypedValuesPassThroughUnchanged() {
        suite.set(4096, forKey: SettingsKeys.ctx)
        XCTAssertEqual(SettingsNumericCoercion.int(SettingsKeys.ctx, default: 1, in: suite), 4096)
        suite.set(0.7, forKey: SettingsKeys.chatTemp)
        XCTAssertEqual(SettingsNumericCoercion.double(SettingsKeys.chatTemp, default: 1, in: suite), 0.7, accuracy: 1e-12)
        suite.set(false, forKey: SettingsKeys.loadVision)
        XCTAssertFalse(SettingsNumericCoercion.bool(SettingsKeys.loadVision, default: true, in: suite))
    }
}

// MARK: - Generated registration (port from XCTest)
extension TypedSettingsRegistryTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "TypedSettingsRegistryTests",
        instance: { TypedSettingsRegistryTests() },
        checks: [
            .init(name: "testRegistryIsComplete") { $0.testRegistryIsComplete() },
            .init(name: "testKindsSpotPinned") { $0.testKindsSpotPinned() },
            .init(name: "testIntDriftYieldsDefaultAndReported") { $0.testIntDriftYieldsDefaultAndReported() },
            .init(name: "testDoubleDriftYieldsDefaultAndReported") { $0.testDoubleDriftYieldsDefaultAndReported() },
            .init(name: "testIfPresentSemantics") { $0.testIfPresentSemantics() },
            .init(name: "testTriStateBoolAbsentMeansTrue") { $0.testTriStateBoolAbsentMeansTrue() },
            .init(name: "testMigrationRewritesNumericsTyped") { $0.testMigrationRewritesNumericsTyped() },
            .init(name: "testImportRoutesThroughRegistry") { try $0.testImportRoutesThroughRegistry() },
            .init(name: "testTypedValuesPassThroughUnchanged") { $0.testTypedValuesPassThroughUnchanged() },
            .init(name: "testStringArrayDriftSurfaces") { $0.testStringArrayDriftSurfaces() },
            .init(name: "testDictionaryDriftSurfaces") { $0.testDictionaryDriftSurfaces() },
        ])
}
