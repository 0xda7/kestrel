// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Pins the store-isolation doctrine: a full ChatStore lifecycle inside the
/// check suite — init (which prunes orphan KV slots), import, delete, wipe —
/// cannot change one byte of the operator's live conversations.json or the
/// live slot directory. On 2026-10-21 the suite leaked 106 fixture chats
/// ("importado"/"Pregunta") into the live sidebar because checks ran against
/// the real store; these checks fail the run if that becomes possible again.
/// The same doctrine covers the local secret store and the audio-studio
/// recovery project: their harness overrides must hold, and a full write
/// cycle through each seam must leave the live files untouched.
final class ChatStoreIsolationTests: CheckCase {
    @MainActor func testChatStoreLifecycleNeverTouchesTheLiveStore() throws {
        guard ChatStore.storeDirectoryOverride != nil else {
            return XCTFail("ChecksMain must set ChatStore.storeDirectoryOverride before any check runs — without it every ChatStore() reads and writes the operator's live store")
        }

        let liveStoreBefore = try? Data(contentsOf: CheckLivePaths.conversationsJSON)
        let liveSlotsBefore = Self.slotFileInventory(under: CheckLivePaths.slotsDirectory)
        let liveTemplatesBefore = Self.slotFileInventory(under: CheckLivePaths.toolTemplatesDirectory)

        let store = ChatStore()
        let fixture = Conversation(title: "importado", messages: [
            ChatMessage(role: "user", content: "Pregunta"),
        ])
        let jsonl = String(decoding: try ChatJSONL.encode([fixture]), as: UTF8.self)
        _ = try store.importArchiveData(Data(jsonl.utf8))
        if let imported = store.conversations.first(where: { $0.title == "importado" }) {
            store.delete(imported)
        }
        store.deleteAll()

        // Let any in-flight save-queue write land (it must land in the
        // per-run directory, never in the live store).
        Thread.sleep(forTimeInterval: 0.3)

        let liveStoreAfter = try? Data(contentsOf: CheckLivePaths.conversationsJSON)
        XCTAssertEqual(liveStoreAfter, liveStoreBefore,
                       "a check-suite ChatStore lifecycle must not change the live conversations.json by one byte")
        XCTAssertEqual(Self.slotFileInventory(under: CheckLivePaths.slotsDirectory),
                       liveSlotsBefore,
                       "a check-suite ChatStore lifecycle must not add, remove, or touch live KV slot files")

        // Derived tool templates (EngineToolTemplate) ride the same
        // isolation: a default-directory derivation must land beside the
        // per-run store, never in the operator's real tool-templates.
        let templateFixture = "{%- if tools -%}{{- '<|tool_call_start|>' + (tools|tojson) + '<|tool_call_end|>' -}}{%- endif -%}"
        let derivationModel = ChatStore.storeDirectoryOverride!
            .appendingPathComponent("native-mock.gguf")
        try EngineToolTemplateTests().writeTemplateGGUF(
            to: derivationModel, template: templateFixture, tokens: ["a"])
        XCTAssertNotNil(
            EngineToolTemplate.derivedTemplateFile(forModel: derivationModel.path),
            "the default-directory derivation must succeed against the overridden directory")
        XCTAssertEqual(Self.slotFileInventory(under: CheckLivePaths.toolTemplatesDirectory),
                       liveTemplatesBefore,
                       "a derived tool template must never land in the operator's real tool-templates folder")
    }

    /// Same doctrine for the engine's per-port slot KV tree: resolving
    /// slotCacheDir(port:) CREATES its folder (the engine requires an
    /// existing --slot-save-path directory), so with
    /// ServerSettings.slotsDirectoryOverride set the resolution, the
    /// argv seam that reaches it (ServerSettings.arguments with
    /// persistence on), and the mkdir itself must land inside the
    /// per-run directory — the live slots tree must not gain so much as
    /// an empty folder.
    @MainActor func testSlotCacheDirResolvesInsideThePerRunOverride() throws {
        guard let override = ServerSettings.slotsDirectoryOverride else {
            return XCTFail("ChecksMain must set ServerSettings.slotsDirectoryOverride before any check runs — without it every --slot-save-path resolution mkdirs the operator's live slots tree")
        }
        let liveSlotsBefore = Self.slotFileInventory(under: CheckLivePaths.slotsDirectory)

        let dir = ServerSettings.slotCacheDir(port: 4242)
        XCTAssertTrue(dir.path.hasPrefix(override.path + "/"),
                      "slotCacheDir must resolve inside the per-run override")
        XCTAssertFalse(dir.path.hasPrefix(CheckLivePaths.kestrelDirectory.path),
                       "slotCacheDir must never aim at the operator's live Kestrel tree")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "resolving slotCacheDir must create its folder inside the per-run override")

        // The argv seam that reaches slotCacheDir in production: with
        // persistence on, the emitted --slot-save-path must carry the
        // overridden directory, never a live path.
        var settings = ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 4242,
                                      ngl: 99, ncmoe: 24, ctx: 16384, threads: 6, flashAttn: "auto",
                                      noMmap: true, jinja: true,
                                      vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                                      cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
        settings.persistCache = true
        settings.faAmd = true
        let args = settings.arguments
        let slotPath = args[args.firstIndex(of: "--slot-save-path")! + 1]
        XCTAssertTrue(slotPath.hasPrefix(override.path + "/"),
                      "the --slot-save-path argv must carry the per-run override, not a live path")

        // The extended inventory sees a bare directory creation — the
        // exact shape a live-tree mkdir would leave — so a seeded empty
        // slot folder inside a fixture root shows as a new dir row.
        let fixtureRoot = override.appendingPathComponent("inventory-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let fixtureBefore = Self.slotFileInventory(under: fixtureRoot)
        try FileManager.default.createDirectory(
            at: fixtureRoot.appendingPathComponent("4242/f16-f16-v", isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertNotEqual(Self.slotFileInventory(under: fixtureRoot), fixtureBefore,
                          "the inventory must catch a bare directory creation — the shape slotCacheDir leaves before any slot file exists")

        XCTAssertEqual(Self.slotFileInventory(under: CheckLivePaths.slotsDirectory),
                       liveSlotsBefore,
                       "a slot-directory resolution must not add, remove, or touch so much as a folder in the live slots tree")
    }

    /// Same doctrine for the local secret store: with
    /// LocalSecretStore.directoryOverride set, a full store/read/delete
    /// cycle — the exact cycle the KES-08 migration performs on the archive
    /// token — must resolve inside the per-run directory and leave every
    /// live secret file untouched.
    @MainActor func testLocalSecretStoreCycleNeverTouchesTheLiveSecrets() throws {
        guard let override = LocalSecretStore.directoryOverride else {
            return XCTFail("ChecksMain must set LocalSecretStore.directoryOverride before any check runs — without it every secret write aims at the operator's live secrets file")
        }
        let liveSecretsBefore = Self.slotFileInventory(under: CheckLivePaths.secretsDirectory)
        let liveTokenBefore = try? Data(contentsOf: CheckLivePaths.secretsDirectory
            .appendingPathComponent("memory-archive-token"))

        XCTAssertEqual(
            LocalSecretStore.url("memory-archive-token").path,
            override.appendingPathComponent("secrets/memory-archive-token").path,
            "LocalSecretStore.url must honor the harness override")

        let sentinel = "isolation-sentinel-\(UUID().uuidString)"
        XCTAssertTrue(LocalSecretStore.store("memory-archive-token", sentinel),
                      "the isolated store cycle must write")
        XCTAssertEqual(LocalSecretStore.value("memory-archive-token"), sentinel,
                       "the sentinel must round-trip through the isolated store")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: override.appendingPathComponent("secrets/memory-archive-token").path),
                      "the sentinel file must land inside the per-run override")
        LocalSecretStore.delete("memory-archive-token")

        XCTAssertEqual(Self.slotFileInventory(under: CheckLivePaths.secretsDirectory),
                       liveSecretsBefore,
                       "a check-suite secret cycle must not add, remove, or touch any live secret file")
        XCTAssertEqual(try? Data(contentsOf: CheckLivePaths.secretsDirectory
            .appendingPathComponent("memory-archive-token")), liveTokenBefore,
                       "the live archive-token secret must not change by one byte")
    }

    /// Same doctrine for the audio-studio recovery project: with
    /// AudioStudioController.recoveryURLOverride set, a real controller
    /// round-trip — load the recovery project, which ends in saveRecovery()
    /// — must aim at the per-run directory and leave the operator's live
    /// AudioRecovery.json untouched.
    @MainActor func testAudioRecoveryRoundTripNeverTouchesTheLiveFile() throws {
        guard let override = AudioStudioController.recoveryURLOverride else {
            return XCTFail("ChecksMain must set AudioStudioController.recoveryURLOverride before any check runs — without it a recovery save rewrites the operator's live AudioRecovery.json")
        }
        let liveRecoveryBefore = try? Data(contentsOf: CheckLivePaths.audioRecoveryJSON)

        XCTAssertEqual(AudioStudioController.recoveryURL.path, override.path,
                       "recoveryURL must honor the harness override")
        XCTAssertNotEqual(AudioStudioController.recoveryURL.path,
                          CheckLivePaths.audioRecoveryJSON.path,
                          "a check-suite recovery save must never aim at the live file")

        // A genuine controller write: a recovery project written at the
        // overridden URL (media fixture beside it) loads back through the
        // controller, and loading ends in saveRecovery().
        let media = override.deletingLastPathComponent()
            .appendingPathComponent("recovery-fixture.m4a")
        try Data("fixture".utf8).write(to: media)
        let document = AudioProjectDocument(
            version: 1, savedAt: .now, sourcePath: media.path,
            detectedLanguage: "es", targetLanguage: "en",
            translationModel: "whisper-mock", glossary: "",
            originalCues: [SubtitleCue(id: 1, start: 0, end: 1, text: "hola")],
            translatedCues: [])
        try FileManager.default.createDirectory(at: override.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder.audioProject.encode(document).write(to: override)

        let studio = AudioStudioController()
        try studio.loadRecoveryProject()
        XCTAssertTrue(studio.hasRecoveryProject,
                      "the controller must read the recovery project back through the override")

        XCTAssertEqual(try? Data(contentsOf: CheckLivePaths.audioRecoveryJSON), liveRecoveryBefore,
                       "an audio recovery round-trip must not change the live AudioRecovery.json by one byte")
    }

    /// Same doctrine for the AppSupport-rooted stores: with
    /// AppSupport.directoryOverride set, a full ServerController()
    /// create/prune cycle (the RotatingFileLog retention prune that used
    /// to delete the operator's live server logs on every construction)
    /// plus direct queue, profile, prompt-library, and PID-lockfile
    /// writes must land entirely inside the per-run directory and leave
    /// the live tree byte-identical.
    @MainActor func testServerCycleAndSupportStoresNeverTouchTheLiveTree() throws {
        guard let override = AppSupport.directoryOverride else {
            return XCTFail("ChecksMain must set AppSupport.directoryOverride before any check runs — without it every ServerController() prunes the operator's live logs and rewrites the live PID lockfile")
        }
        let fm = FileManager.default
        let liveLogsBefore = Self.slotFileInventory(under: CheckLivePaths.logsDirectory)
        let liveQueueBefore = Self.slotFileInventory(under: CheckLivePaths.memoryArchiveQueueDirectory)
        let liveProfilesBefore = Self.slotFileInventory(under: CheckLivePaths.dynamicMoeDirectory)
        let livePromptLibraryBefore = try? Data(contentsOf: CheckLivePaths.promptLibraryJSON)
        let liveEnginePIDBefore = try? Data(contentsOf: CheckLivePaths.enginePID)

        // A stale session log planted inside the per-run override gives
        // the retention prune something real to delete — proving the
        // exact code path that deleted live server logs now prunes only
        // the override.
        let overrideLogs = override.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: overrideLogs, withIntermediateDirectories: true)
        let staleLog = overrideLogs.appendingPathComponent("server-2020-01-01_00-00-00.log")
        try Data("stale".utf8).write(to: staleLog)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86_400)],
                             ofItemAtPath: staleLog.path)

        let server = ServerController()
        XCTAssertEqual(server.logsDirectory.path, overrideLogs.path,
                       "a check-suite ServerController's rotating log must honor the harness override")
        _ = server.logFileURL   // sync point: the init-time retention prune has run
        XCTAssertFalse(fm.fileExists(atPath: staleLog.path),
                       "the retention prune must delete the stale session log inside the per-run override")

        // Memory-archive queue: a genuine send() through the actor writes
        // its durable delivery file via the resolver. The hook points at
        // an unbound loopback port (plain-http loopback carries no
        // network exposure); the prior UserDefaults value is restored at
        // the end, and a drain pass that wakes mid-backoff re-checks the
        // key, finds it gone, and returns — no receiver is ever polled.
        let hookKey = SettingsKeys.memoryArchiveHookURL
        let priorHook = UserDefaults.standard.string(forKey: hookKey)
        UserDefaults.standard.set("http://127.0.0.1:1/hook", forKey: hookKey)
        defer {
            if let priorHook {
                UserDefaults.standard.set(priorHook, forKey: hookKey)
            } else {
                UserDefaults.standard.removeObject(forKey: hookKey)
            }
        }
        let overrideQueue = override.appendingPathComponent("memory-archive-hook", isDirectory: true)
        MemoryArchiveHook.send(conversationID: "isolation", title: "isolation",
                               from: 0, to: 1, note: "isolation pin",
                               messages: [(index: 0, role: "user", content: "fixture")])
        var queuedUnderOverride = false
        let queueDeadline = Date().addingTimeInterval(3)
        while !queuedUnderOverride && Date() < queueDeadline {
            queuedUnderOverride = !MemoryArchiveHook.pending(in: overrideQueue).isEmpty
            if !queuedUnderOverride { Thread.sleep(forTimeInterval: 0.005) }
        }
        XCTAssertTrue(queuedUnderOverride,
                      "the durable queue write must land inside the per-run override")

        // Dynamic-MoE profile store: a real save through the resolver.
        let gpu = GPUDevice(index: 0, name: "isolation-fixture-gpu", vramMB: 8_192)
        let profile = DynamicMoeOptimizationProfile(
            version: DynamicMoeOptimizationProfile.currentVersion,
            modelFingerprint: "isolation-fingerprint",
            modelName: "isolation-model",
            gpuName: gpu.name,
            gpuVRAMMB: gpu.vramMB,
            route: .direct,
            slots: 1,
            ringSlots: 1,
            prefetch: 1,
            hotMapPath: nil,
            promptTokensPerSecond: 1,
            generationTokensPerSecond: 1,
            baselinePromptTokensPerSecond: 1,
            baselineGenerationTokensPerSecond: 1,
            estimatedVRAMFraction: nil,
            createdAt: Date())
        try DynamicMoeProfileStore.save(profile, gpu: gpu)
        let overrideProfiles = override.appendingPathComponent("dynamic-moe", isDirectory: true)
        XCTAssertEqual(DynamicMoeProfileStore.directory.path, overrideProfiles.path,
                       "the dynamic-MoE profile store must honor the harness override")
        XCTAssertFalse(Self.slotFileInventory(under: overrideProfiles).isEmpty,
                       "the profile save must land inside the per-run override")

        // Prompt library: a first-run load seeds and persists through the
        // resolver.
        XCTAssertEqual(PromptLibrary.fileURL.path,
                       override.appendingPathComponent("prompt-library.json").path,
                       "the prompt library must honor the harness override")
        XCTAssertFalse(PromptLibrary.load().isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: override.appendingPathComponent("prompt-library.json").path),
                      "the seeded prompt library must land inside the per-run override")

        // PID lockfile: a real add/remove cycle through the resolver. The
        // sentinel is recorded only — nothing reaps inside a check.
        let overridePID = override.appendingPathComponent("engine.pid")
        let sentinelPID = Int32.max
        EngineLock.add(pid: sentinelPID)
        XCTAssertTrue(fm.fileExists(atPath: overridePID.path),
                      "the PID lockfile write must land inside the per-run override")
        EngineLock.remove(pid: sentinelPID)
        XCTAssertFalse(fm.fileExists(atPath: overridePID.path),
                       "removing the last recorded PID clears the per-run lockfile")

        XCTAssertEqual(Self.slotFileInventory(under: CheckLivePaths.logsDirectory),
                       liveLogsBefore,
                       "a check-suite ServerController lifecycle must not add, remove, or touch live session logs")
        XCTAssertEqual(Self.slotFileInventory(under: CheckLivePaths.memoryArchiveQueueDirectory),
                       liveQueueBefore,
                       "a queued memory-archive delivery must never land in the operator's live queue")
        XCTAssertEqual(Self.slotFileInventory(under: CheckLivePaths.dynamicMoeDirectory),
                       liveProfilesBefore,
                       "a dynamic-MoE profile save must never land in the operator's live store")
        XCTAssertEqual(try? Data(contentsOf: CheckLivePaths.promptLibraryJSON), livePromptLibraryBefore,
                       "the live prompt library must not change by one byte")
        XCTAssertEqual(try? Data(contentsOf: CheckLivePaths.enginePID), liveEnginePIDBefore,
                       "the live engine PID lockfile must not change by one byte")
    }

    /// Stable inventory of every file AND directory under the slot tree:
    /// kind plus relative path (plus byte count for files), so an add, a
    /// delete, an in-place rewrite, or a bare directory creation — the
    /// shape slotCacheDir's mkdir leaves before any slot file exists —
    /// all show.
    private static func slotFileInventory(under root: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return []
        }
        var rows: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            rows.append((values?.isDirectory ?? false) ? "dir:\(rel)" : "file:\(rel):\(values?.fileSize ?? -1)")
        }
        return rows.sorted()
    }
}

// MARK: - Generated registration (port from XCTest)
extension ChatStoreIsolationTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ChatStoreIsolationTests",
        instance: { ChatStoreIsolationTests() },
        checks: [
            .init(name: "testChatStoreLifecycleNeverTouchesTheLiveStore") { try $0.testChatStoreLifecycleNeverTouchesTheLiveStore() },
            .init(name: "testLocalSecretStoreCycleNeverTouchesTheLiveSecrets") { try $0.testLocalSecretStoreCycleNeverTouchesTheLiveSecrets() },
            .init(name: "testAudioRecoveryRoundTripNeverTouchesTheLiveFile") { try $0.testAudioRecoveryRoundTripNeverTouchesTheLiveFile() },
            .init(name: "testServerCycleAndSupportStoresNeverTouchTheLiveTree") { try $0.testServerCycleAndSupportStoresNeverTouchTheLiveTree() },
            .init(name: "testSlotCacheDirResolvesInsideThePerRunOverride") { try $0.testSlotCacheDirResolvesInsideThePerRunOverride() },
        ])
}
