// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Legacy-key retirement windows (mission T4-2, census W6-6/W6-12, W7-2/W7-3/
/// W7-4, H3): every migration is pinned by the same contract — legacy present
/// → migrated with values preserved + legacy key gone — and the specMTP
/// old-profile decode is pinned BEFORE any removal (the H3 ordering). The
/// checks seed the exact legacy shapes the old versions wrote, so deleting a
/// migration body leaves the seeded keys stranded and goes RED.
final class LegacyKeyMigrationTests: CheckCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "legacy-key-migration-tests")
        suite.removePersistentDomain(forName: "legacy-key-migration-tests")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "legacy-key-migration-tests")
        super.tearDown()
    }

    // MARK: ImageGen (census W7-2 + W6-12)

    /// Seeds all 16 legacy per-key image settings with distinct values, runs
    /// the migration, and asserts instance 1 of the store carries every value
    /// verbatim while all 16 legacy keys are gone. A second run is a no-op.
    func testImagenLegacyKeysMigrateIntoTheInstanceStorePreservingValues() throws {
        // The distinct legacy values, one per key.
        suite.set("zimage-turbo", forKey: "imagenModel")
        suite.set("/models/diT.gguf", forKey: "imagenCustomModel")
        suite.set("/models/vae.safetensors", forKey: "imagenCustomVAE")
        suite.set("/models/text-encoder.gguf", forKey: "imagenCustomTextEncoder")
        suite.set(true, forKey: "imagenCustomIsDiffusion")
        suite.set(3.5, forKey: "imagenCustomCfg")
        suite.set("a red fox on snow", forKey: "imagenPrompt")
        suite.set("/img/init.png", forKey: "imagenInitImage")
        suite.set(0.75, forKey: "imagenStrength")
        suite.set("9:16", forKey: "imagenAspect")
        suite.set(1536, forKey: "imagenBaseSize")
        suite.set(1, forKey: "imagenGPU")
        suite.set(20, forKey: "imagenSteps")
        suite.set(42, forKey: "imagenSeed")
        suite.set("jpg", forKey: "imagenFormat")
        suite.set(true, forKey: "imagenOffloadCPU")

        XCTAssertTrue(ImageGenLegacyMigration.run(in: suite), "legacy keys present → the migration runs")

        let data = try XCTUnwrap(suite.data(forKey: SettingsKeys.imagenInstances),
                                 "the migrated store must exist after the window runs")
        let (configs, unreadable) = ImageInstanceConfig.decodeConfigs(from: data)
        XCTAssertNil(unreadable)
        XCTAssertEqual(configs.count, 1)
        let c = try XCTUnwrap(configs.first)
        // Values preserved, field by field (the 16 keys in census W7-2 order).
        XCTAssertEqual(c.modelID, "zimage-turbo")
        XCTAssertEqual(c.customModelPath, "/models/diT.gguf")
        XCTAssertEqual(c.customVAEPath, "/models/vae.safetensors")
        XCTAssertEqual(c.customTextEncoderPath, "/models/text-encoder.gguf")
        XCTAssertTrue(c.customIsDiffusion)
        XCTAssertEqual(c.customCfg, 3.5)
        XCTAssertEqual(c.prompt, "a red fox on snow")
        XCTAssertEqual(c.initImagePath, "/img/init.png")
        XCTAssertEqual(c.strength, 0.75)
        XCTAssertEqual(c.aspect, "9:16")
        XCTAssertEqual(c.baseSize, 1536)
        XCTAssertEqual(c.gpuIndex, 1)
        XCTAssertEqual(c.steps, 20)
        XCTAssertEqual(c.seed, 42)
        XCTAssertEqual(c.format, "jpg")
        XCTAssertTrue(c.offloadCPU)

        for key in ImageGenLegacyMigration.legacyKeys {
            XCTAssertNil(suite.object(forKey: key), "legacy key '\(key)' must be gone after migrating")
        }

        // Idempotence: a present store means the window already ran.
        XCTAssertFalse(ImageGenLegacyMigration.run(in: suite), "a second run over a present store is a no-op")
        XCTAssertEqual(suite.data(forKey: SettingsKeys.imagenInstances), data, "the no-op must not rewrite the store")
    }

    /// A store that already exists is never clobbered by leftover legacy
    /// keys: the multi-instance world wins, the window only fills an absence.
    func testImageGenMigrationDoesNotClobberAnExistingStore() throws {
        let existing = try JSONEncoder().encode([ImageInstanceConfig()])
        suite.set(existing, forKey: SettingsKeys.imagenInstances)
        suite.set("stale prompt", forKey: "imagenPrompt")

        XCTAssertFalse(ImageGenLegacyMigration.run(in: suite), "a present store must block the migration")
        XCTAssertEqual(suite.data(forKey: SettingsKeys.imagenInstances), existing, "the existing store is untouched")
        XCTAssertEqual(suite.string(forKey: "imagenPrompt"), "stale prompt",
                       "legacy keys stay put when the window does not apply")
    }

    // MARK: DFlash (census W6-6/W7-3)

    /// The legacy per-model "disabled" list becomes "off" entries in the
    /// dflashModes map; entries the live map already carries are preserved
    /// untouched; the legacy key is gone after the window runs.
    func testDflashDisabledListMigratesIntoDflashModesMap() {
        suite.set(["/m/first.gguf", "/m/second.gguf"], forKey: DflashLegacyMigration.legacyKey)
        suite.set(["/m/live.gguf": DflashMode.forced.rawValue], forKey: SettingsKeys.dflashModes)

        XCTAssertTrue(DflashLegacyMigration.run(in: suite), "legacy list present → the migration runs")

        let modes = SettingsNumericCoercion.dictionary(SettingsKeys.dflashModes, in: suite) as? [String: String]
        XCTAssertEqual(modes?["/m/first.gguf"], DflashMode.off.rawValue, "legacy disabled → off")
        XCTAssertEqual(modes?["/m/second.gguf"], DflashMode.off.rawValue, "legacy disabled → off")
        XCTAssertEqual(modes?["/m/live.gguf"], DflashMode.forced.rawValue,
                       "an entry the live map already carries is preserved, not overwritten")
        XCTAssertEqual(modes?.count, 3)
        XCTAssertNil(suite.object(forKey: DflashLegacyMigration.legacyKey), "the legacy key must be gone after migrating")

        XCTAssertFalse(DflashLegacyMigration.run(in: suite), "a second run with no legacy key is a no-op")
    }

    // MARK: MemoryArchiveHook (census W7-4/W6-9)

    /// The KES-08 self-retiring migration, pinned: a plaintext UserDefaults
    /// secret is returned once (value preserved), lands in the local secret
    /// store, and the legacy key is gone after the read. The secret store
    /// rides the suite's directoryOverride seam (set by ChecksMain), so the
    /// sentinel can only land in the per-run directory — the live secrets
    /// file is never touched; only the UserDefaults prior is restored.
    func testMemoryArchiveHookSecretSelfRetiresIntoTheLocalSecretStore() {
        guard LocalSecretStore.directoryOverride != nil else {
            return XCTFail("ChecksMain must set LocalSecretStore.directoryOverride before any check runs — without it the sentinel migrates into the operator's live secrets file")
        }
        let storeName = "memory-archive-token"
        let priorLegacy = UserDefaults.standard.object(forKey: MemoryArchiveHook.legacySecretKey)
        let sentinel = "t4-2-migration-sentinel-\(UUID().uuidString)"
        UserDefaults.standard.set(sentinel, forKey: MemoryArchiveHook.legacySecretKey)
        defer {
            if let priorLegacy {
                UserDefaults.standard.set(priorLegacy, forKey: MemoryArchiveHook.legacySecretKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MemoryArchiveHook.legacySecretKey)
            }
            LocalSecretStore.delete(storeName)
        }

        let token = MemoryArchiveHook.receiverToken()
        XCTAssertEqual(token, sentinel, "the legacy value is returned, not dropped in transit")
        XCTAssertEqual(LocalSecretStore.value(storeName), sentinel, "the secret landed in the local store")
        XCTAssertEqual(
            LocalSecretStore.url(storeName).path,
            LocalSecretStore.directoryOverride!.appendingPathComponent("secrets/\(storeName)").path,
            "the migrated secret must land inside the per-run override, never the live secrets file")
        XCTAssertNil(UserDefaults.standard.object(forKey: MemoryArchiveHook.legacySecretKey),
                     "the legacy key self-retired on first read")
    }

    // MARK: H3 — old-profile decode pinned BEFORE any removal (census W6-5)

    /// An old saved profile that still carries specMTP must decode and apply:
    /// profile-format versioning does not exist, so the decode-compat field
    /// is the only thing between an old profile and an import failure.
    func testOldProfileWithSpecMTPDecodesAndApplies() throws {
        let json = """
        {"id": "064B0C41-3D5D-4E7B-9F52-4A2C1B6E8D90", "name": "old-profile",
         "modelPath": "/m/kimi.gguf", "ngl": 999, "ncmoe": 0, "ctx": 8192,
         "threads": 6, "flashAttn": "auto", "noMmap": true, "jinja": true,
         "vramReserve": 512, "gpuIndex": 1, "extraArgs": "", "cacheTypeK": "f16",
         "cacheTypeV": "f16", "mlock": false, "port": 8080,
         "specMTP": true, "engine": "bundled"}
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.specMTP, true, "old-profile decode keeps the legacy MTP field")

        var settings = ServerSettings.fromDefaults()
        settings.apply(profile)
        XCTAssertTrue(settings.specMTP, "the legacy field lands in settings state on apply")
    }
}

// MARK: - Generated registration (port from XCTest)
extension LegacyKeyMigrationTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "LegacyKeyMigrationTests",
        instance: { LegacyKeyMigrationTests() },
        checks: [
            .init(name: "testImagenLegacyKeysMigrateIntoTheInstanceStorePreservingValues") { try $0.testImagenLegacyKeysMigrateIntoTheInstanceStorePreservingValues() },
            .init(name: "testImageGenMigrationDoesNotClobberAnExistingStore") { try $0.testImageGenMigrationDoesNotClobberAnExistingStore() },
            .init(name: "testDflashDisabledListMigratesIntoDflashModesMap") { $0.testDflashDisabledListMigratesIntoDflashModesMap() },
            .init(name: "testMemoryArchiveHookSecretSelfRetiresIntoTheLocalSecretStore") { $0.testMemoryArchiveHookSecretSelfRetiresIntoTheLocalSecretStore() },
            .init(name: "testOldProfileWithSpecMTPDecodesAndApplies") { try $0.testOldProfileWithSpecMTPDecodesAndApplies() },
        ])
}
