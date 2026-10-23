// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Guardian slice: never destroy the only surviving copy of a secret on a
/// failed secret-store write. Three migrations moved secrets off legacy
/// homes (Keychain 'api-key' → engine-api-key file, plaintext
/// UserDefaults archive token → memory-archive-token file) and each retired
/// the legacy copy unconditionally — a failed 0600 write deleted the only
/// other copy, orphaning everything keyed to the secret. The pins inject a
/// failing store write deterministically at any uid: a directory planted
/// where the secret file must land makes OwnerOnlyFile's rename(2) fail
/// with EISDIR, so store() returns false without touching anything else.
final class SecretStoreFailureSafetyTests: CheckCase {

    /// The failure injection: a directory where the 0600 secret file must
    /// land. rename(2) onto an existing directory fails with EISDIR even
    /// for root, so the sabotage is uid-independent and cannot succeed by
    /// accident.
    private func makeTheNextStoreWriteFail(_ name: String) throws {
        LocalSecretStore.delete(name)
        let target = LocalSecretStore.url(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }

    /// Removes the sabotage directory and any cached value, so later
    /// checks see a clean store.
    private func letStoreWritesWorkAgain(_ name: String) {
        LocalSecretStore.delete(name)
    }

    private func requireHarnessSeams() {
        guard LocalSecretStore.directoryOverride != nil else {
            return XCTFail("ChecksMain must set LocalSecretStore.directoryOverride before any check runs — without it the sentinel writes the operator's live secrets file")
        }
        guard Keychain.itemsOverride != nil else {
            return XCTFail("ChecksMain must set Keychain.itemsOverride before any check runs — without it the seeded legacy item writes the operator's real keychain")
        }
    }

    /// (a) Keychain side: with the legacy 'api-key' item seeded and the
    /// store write failing, apiKey() must still load the legacy value as
    /// the active secret, must NOT retire the Keychain item (that would
    /// destroy the only surviving copy), and must record a typed
    /// SupportDiagnostics line instead of the old silent delete.
    func testFailedStoreKeepsTheLegacyKeychainItemAsTheActiveSecret() throws {
        requireHarnessSeams()
        try makeTheNextStoreWriteFail("engine-api-key")
        defer { letStoreWritesWorkAgain("engine-api-key") }
        let sentinel = "legacy-keychain-\(UUID().uuidString)"
        Keychain.itemsOverride?["api-key"] = sentinel
        defer { Keychain.itemsOverride?.removeValue(forKey: "api-key") }
        let ringBefore = SupportDiagnostics.failureReport().count

        let key = Keychain.apiKey()

        XCTAssertEqual(key, sentinel,
                       "the legacy Keychain key must load as the active secret when the store write fails")
        XCTAssertEqual(Keychain.itemsOverride?["api-key"], sentinel,
                       "a failed store must not retire the legacy Keychain item — that deletes the only surviving copy of the secret")
        XCTAssertTrue(Keychain.exists("api-key"),
                      "the legacy Keychain item must still exist as the fallback source")
        XCTAssertNil(LocalSecretStore.value("engine-api-key"),
                     "nothing may read as persisted when the write failed")
        let entries = SupportDiagnostics.failureReport()
        XCTAssertEqual(entries.count, ringBefore + 1,
                       "the failed migration is surfaced exactly once")
        let entry = try XCTUnwrap(entries.last)
        XCTAssertTrue(entry.contains("engine api-key migration"),
                      "the typed reason names the failed migration")
        XCTAssertTrue(entry.allSatisfy { $0.isASCII },
                      "product doctrine: new user-facing strings are English-only")
    }

    /// Fresh-key path: an unpersisted key is still handed to this launch's
    /// engine (launch behavior is unchanged) but is reported via
    /// SupportDiagnostics instead of silently regenerating every launch.
    func testUnpersistableFreshEngineKeyIsReportedNotSilent() throws {
        requireHarnessSeams()
        Keychain.itemsOverride?.removeValue(forKey: "api-key")
        try makeTheNextStoreWriteFail("engine-api-key")
        defer { letStoreWritesWorkAgain("engine-api-key") }
        let ringBefore = SupportDiagnostics.failureReport().count

        let key = Keychain.apiKey()

        XCTAssertEqual(key.count, 32,
                       "a fresh key still serves this launch — the fix surfaces the failure, it does not refuse to boot")
        XCTAssertNil(LocalSecretStore.value("engine-api-key"),
                     "the key must not read as persisted when the write failed")
        let entries = SupportDiagnostics.failureReport()
        XCTAssertEqual(entries.count, ringBefore + 1,
                       "the unpersisted fresh key is surfaced exactly once")
        XCTAssertTrue(try XCTUnwrap(entries.last).contains("freshly generated key"),
                      "the typed reason names the unpersisted key")
    }

    /// (a) UserDefaults side: with the legacy plaintext token seeded and
    /// the store write failing, receiverToken() must still return the
    /// legacy value as the active secret and must NOT delete the
    /// UserDefaults copy — the plaintext annoyance is kept over destroying
    /// the only surviving token.
    func testFailedStoreKeepsTheLegacyReceiverTokenAsTheActiveSecret() throws {
        requireHarnessSeams()
        try makeTheNextStoreWriteFail("memory-archive-token")
        defer { letStoreWritesWorkAgain("memory-archive-token") }
        let priorLegacy = UserDefaults.standard.object(forKey: MemoryArchiveHook.legacySecretKey)
        let sentinel = "legacy-token-\(UUID().uuidString)"
        UserDefaults.standard.set(sentinel, forKey: MemoryArchiveHook.legacySecretKey)
        defer {
            if let priorLegacy {
                UserDefaults.standard.set(priorLegacy, forKey: MemoryArchiveHook.legacySecretKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MemoryArchiveHook.legacySecretKey)
            }
        }
        let ringBefore = SupportDiagnostics.failureReport().count

        let token = MemoryArchiveHook.receiverToken()

        XCTAssertEqual(token, sentinel,
                       "the legacy token must load as the active secret when the store write fails")
        XCTAssertEqual(UserDefaults.standard.string(forKey: MemoryArchiveHook.legacySecretKey), sentinel,
                       "a failed store must not delete the legacy copy — that destroys the only surviving token")
        XCTAssertNil(LocalSecretStore.value("memory-archive-token"),
                     "nothing may read as migrated when the write failed")
        let entries = SupportDiagnostics.failureReport()
        XCTAssertEqual(entries.count, ringBefore + 1,
                       "the failed migration is surfaced exactly once")
        let entry = try XCTUnwrap(entries.last)
        XCTAssertTrue(entry.contains("memory-archive receiver token"),
                      "the typed reason names the failed migration")
        XCTAssertTrue(entry.allSatisfy { $0.isASCII },
                      "product doctrine: new user-facing strings are English-only")
    }

    /// (b) Keychain side: a confirmed store still retires the legacy item
    /// exactly once, the value survives in the file store, and later reads
    /// come from the store — the guard must not make retirement sticky-shy.
    func testSuccessfulStoreStillRetiresTheLegacyKeychainItem() throws {
        requireHarnessSeams()
        LocalSecretStore.delete("engine-api-key")
        let sentinel = "retire-keychain-\(UUID().uuidString)"
        Keychain.itemsOverride?["api-key"] = sentinel
        defer {
            Keychain.itemsOverride?.removeValue(forKey: "api-key")
            LocalSecretStore.delete("engine-api-key")
        }
        let ringBefore = SupportDiagnostics.failureReport().count

        XCTAssertEqual(Keychain.apiKey(), sentinel, "the legacy value migrates verbatim")
        XCTAssertNil(Keychain.itemsOverride?["api-key"],
                     "a confirmed store retires the legacy Keychain item")
        XCTAssertEqual(LocalSecretStore.value("engine-api-key"), sentinel,
                       "the retired copy's value lives in the local secret store")
        XCTAssertEqual(Keychain.apiKey(), sentinel,
                       "the second read comes from the store and changes nothing")
        XCTAssertNil(Keychain.itemsOverride?["api-key"],
                     "retirement happened exactly once; no later read re-retires or resurrects")
        XCTAssertEqual(SupportDiagnostics.failureReport().count, ringBefore,
                       "a successful migration records nothing")
    }

    /// (b) UserDefaults side: a confirmed store still retires the legacy
    /// plaintext token exactly once and later reads serve from the store.
    func testSuccessfulStoreStillRetiresTheLegacyReceiverToken() throws {
        requireHarnessSeams()
        LocalSecretStore.delete("memory-archive-token")
        let priorLegacy = UserDefaults.standard.object(forKey: MemoryArchiveHook.legacySecretKey)
        let sentinel = "retire-token-\(UUID().uuidString)"
        UserDefaults.standard.set(sentinel, forKey: MemoryArchiveHook.legacySecretKey)
        defer {
            if let priorLegacy {
                UserDefaults.standard.set(priorLegacy, forKey: MemoryArchiveHook.legacySecretKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MemoryArchiveHook.legacySecretKey)
            }
            LocalSecretStore.delete("memory-archive-token")
        }
        let ringBefore = SupportDiagnostics.failureReport().count

        XCTAssertEqual(MemoryArchiveHook.receiverToken(), sentinel,
                       "the legacy token migrates verbatim")
        XCTAssertNil(UserDefaults.standard.object(forKey: MemoryArchiveHook.legacySecretKey),
                     "a confirmed store retires the legacy plaintext copy")
        XCTAssertEqual(LocalSecretStore.value("memory-archive-token"), sentinel,
                       "the retired copy's value lives in the local secret store")
        XCTAssertEqual(MemoryArchiveHook.receiverToken(), sentinel,
                       "the second read serves from the store, not a re-migration")
        XCTAssertEqual(SupportDiagnostics.failureReport().count, ringBefore,
                       "a successful migration records nothing")
    }
}

// MARK: - Generated registration (port from XCTest)
extension SecretStoreFailureSafetyTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SecretStoreFailureSafetyTests",
        instance: { SecretStoreFailureSafetyTests() },
        checks: [
            .init(name: "testFailedStoreKeepsTheLegacyKeychainItemAsTheActiveSecret") { try $0.testFailedStoreKeepsTheLegacyKeychainItemAsTheActiveSecret() },
            .init(name: "testUnpersistableFreshEngineKeyIsReportedNotSilent") { try $0.testUnpersistableFreshEngineKeyIsReportedNotSilent() },
            .init(name: "testFailedStoreKeepsTheLegacyReceiverTokenAsTheActiveSecret") { try $0.testFailedStoreKeepsTheLegacyReceiverTokenAsTheActiveSecret() },
            .init(name: "testSuccessfulStoreStillRetiresTheLegacyKeychainItem") { try $0.testSuccessfulStoreStillRetiresTheLegacyKeychainItem() },
            .init(name: "testSuccessfulStoreStillRetiresTheLegacyReceiverToken") { try $0.testSuccessfulStoreStillRetiresTheLegacyReceiverToken() },
        ])
}
