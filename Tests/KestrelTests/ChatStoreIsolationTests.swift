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

    /// Stable inventory of every file under the slot tree: relative path plus
    /// byte count, so an add, a delete, or an in-place rewrite all show.
    private static func slotFileInventory(under root: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        var rows: [String] = []
        for case let url as URL in walker {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            rows.append("\(url.path.replacingOccurrences(of: root.path + "/", with: "")):\(size)")
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
        ])
}
