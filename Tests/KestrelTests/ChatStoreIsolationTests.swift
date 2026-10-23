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
/// the real store; this check fails the run if that becomes possible again.
final class ChatStoreIsolationTests: CheckCase {
    @MainActor func testChatStoreLifecycleNeverTouchesTheLiveStore() throws {
        guard ChatStore.storeDirectoryOverride != nil else {
            return XCTFail("ChecksMain must set ChatStore.storeDirectoryOverride before any check runs — without it every ChatStore() reads and writes the operator's live store")
        }

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kestrel", isDirectory: true)
        let liveStoreURL = support.appendingPathComponent("conversations.json")
        let liveStoreBefore = try? Data(contentsOf: liveStoreURL)
        let liveSlotsBefore = Self.slotFileInventory(under: support.appendingPathComponent("slots", isDirectory: true))

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

        let liveStoreAfter = try? Data(contentsOf: liveStoreURL)
        XCTAssertEqual(liveStoreAfter, liveStoreBefore,
                       "a check-suite ChatStore lifecycle must not change the live conversations.json by one byte")
        XCTAssertEqual(Self.slotFileInventory(under: support.appendingPathComponent("slots", isDirectory: true)),
                       liveSlotsBefore,
                       "a check-suite ChatStore lifecycle must not add, remove, or touch live KV slot files")
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
        ])
}
