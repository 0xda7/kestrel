// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Guardian slice: the MCP server list is the operator's only copy of the
/// configuration, and its stored form used to dissolve on failure — save()'s
/// `try?` handed nil to UserDefaults.set (erasing the key on any encode
/// failure), and load() read undecodable bytes as "no servers", so the very
/// next save blind-wiped them. The pins hold the fail-safe doctrine on the
/// storage side (mirroring SettingsArchive's import side): an encode failure
/// keeps the previous bytes, a decode failure refuses blind saves until
/// acknowledged, exports carry env key names but never values, and the
/// legacy plaintext env map migrates into the 0600 local secret store on
/// first read — retiring the UserDefaults copy only after the store
/// confirms the write (the receiverToken shape).
///
/// Diagnostics-ring note: SupportDiagnostics caps its ring at 8 entries, so
/// these pins assert on the LAST entry's content (append always refreshes
/// it) instead of count deltas, which stop moving once the ring is full.
final class MCPStoreFailSafeTests: CheckCase {

    override func setUp() {
        super.setUp()
        // Hygiene between checks: the unreadable-store refusal is pinned
        // within each check that sets it up deliberately.
        MCPServerStore.acknowledgeUnreadableStore()
    }

    private func requireHarnessSeams() {
        guard LocalSecretStore.directoryOverride != nil else {
            return XCTFail("ChecksMain must set LocalSecretStore.directoryOverride before any check runs — without it the sentinel writes the operator's live secrets file")
        }
    }

    /// Seeds/restore dance for the live key (the AgentLoopTests pattern):
    /// every value the check plants in UserDefaults.standard is restored.
    private func storedBlob(_ body: () throws -> Void) rethrows {
        let prior = UserDefaults.standard.object(forKey: SettingsKeys.mcpServers)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: SettingsKeys.mcpServers)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKeys.mcpServers)
            }
        }
        try body()
    }

    /// The pre-migration stored form: a server list whose environment still
    /// carries plaintext VALUES (what every stored config looked like before
    /// the secret-store move, and what a pasted config still produces in
    /// memory). Built with JSONSerialization because MCPServer's own encoder
    /// now refuses to write values.
    private func legacyPlaintextBlob(id: UUID, env: [String: String]) throws -> Data {
        let entry: [String: Any] = [
            "id": id.uuidString,
            "name": "legacy",
            "url": "",
            "enabled": true,
            "transport": "stdio",
            "timeoutSeconds": 60,
            "command": "/usr/local/bin/legacy-server",
            "arguments": ["--flag"],
            "environment": env,
            "workingDirectory": "",
        ]
        return try JSONSerialization.data(withJSONObject: [entry])
    }

    private struct InjectedEncodeFailure: LocalizedError {
        var errorDescription: String? { "injected encode failure" }
    }

    /// (a) An encode failure must keep the previous stored bytes: the old
    /// `try?` handed nil to UserDefaults.set, which ERASED the key — the
    /// operator's whole server list vanished on a failure nobody saw.
    func testEncodeFailureKeepsThePreviousStoredServerList() throws {
        try storedBlob {
            var original = MCPServer(name: "kept", url: "")
            original.transport = .stdio
            original.command = "/usr/local/bin/kept-server"
            let seeded = try JSONEncoder().encode([original])
            UserDefaults.standard.set(seeded, forKey: SettingsKeys.mcpServers)
            _ = MCPServerStore.load()   // a healthy read clears any refusal state

            MCPServerStore.encodeFailureInjection = InjectedEncodeFailure()
            defer { MCPServerStore.encodeFailureInjection = nil }

            var replacement = MCPServer(name: "replacement", url: "")
            replacement.transport = .stdio
            MCPServerStore.save([replacement])

            XCTAssertEqual(UserDefaults.standard.data(forKey: SettingsKeys.mcpServers), seeded,
                           "an encode failure must keep the previous stored bytes — set(nil) erased the list")
            let reason = SupportDiagnostics.failureReport().last ?? ""
            XCTAssertTrue(reason.contains("could not be encoded"),
                          "the failed encode is surfaced, never silent: \(reason)")
            XCTAssertTrue(reason.allSatisfy { $0.isASCII },
                          "product doctrine: new user-facing strings are English-only")

            MCPServerStore.encodeFailureInjection = nil
            MCPServerStore.save([replacement])
            XCTAssertEqual(MCPServerStore.load().first?.name, "replacement",
                           "saving works again once encoding succeeds")
        }
    }

    /// (b) A decode failure cannot be followed by a blind save overwriting
    /// the store: present-but-undecodable bytes are the operator's only
    /// copy, so they read as unreadable (surfaced), not as "no servers",
    /// and save() refuses until explicitly acknowledged — the import-side
    /// fail-safe doctrine, storage side.
    func testDecodeFailureRefusesBlindSavesUntilAcknowledged() throws {
        try storedBlob {
            let corrupt = Data("not an mcp server list {{".utf8)
            UserDefaults.standard.set(corrupt, forKey: SettingsKeys.mcpServers)

            XCTAssertTrue(MCPServerStore.load().isEmpty,
                          "an undecodable store still loads as no servers (behavior unchanged)")
            XCTAssertTrue(MCPServerStore.hasUnreadableStore,
                          "the unreadable store is flagged, not conflated with empty")
            let decodeReason = SupportDiagnostics.failureReport().last ?? ""
            XCTAssertTrue(decodeReason.contains("cannot be decoded"),
                          "the decode failure is surfaced: \(decodeReason)")
            XCTAssertTrue(decodeReason.allSatisfy { $0.isASCII },
                          "product doctrine: new user-facing strings are English-only")

            var fresh = MCPServer(name: "fresh", url: "")
            fresh.transport = .stdio
            MCPServerStore.save([fresh])
            XCTAssertEqual(UserDefaults.standard.data(forKey: SettingsKeys.mcpServers), corrupt,
                           "a blind save over undecodable stored bytes is refused — they are the only surviving copy")
            let refusalReason = SupportDiagnostics.failureReport().last ?? ""
            XCTAssertTrue(refusalReason.contains("refused"),
                          "the refused save is surfaced: \(refusalReason)")

            MCPServerStore.acknowledgeUnreadableStore()
            XCTAssertFalse(MCPServerStore.hasUnreadableStore)
            MCPServerStore.save([fresh])
            XCTAssertEqual(MCPServerStore.load().first?.name, "fresh",
                           "after an explicit acknowledgment the store takes the save")
        }
    }

    /// (c) Exports carry env KEY NAMES but zero env VALUES — even from a
    /// not-yet-migrated legacy blob — so a shared settings file never
    /// leaves the machine carrying a token, while the KES-06 consent
    /// summary still sees what an import would set.
    func testExportsCarryEnvironmentKeysButNeverValues() throws {
        let suite = UserDefaults(suiteName: "mcp-store-fail-safe-export")!
        defer { suite.removePersistentDomain(forName: "mcp-store-fail-safe-export") }
        let id = UUID()
        let legacy = try legacyPlaintextBlob(id: id, env: ["API_TOKEN": "legacy-secret-value"])
        suite.set(legacy, forKey: SettingsKeys.mcpServers)

        let data = try SettingsArchive.exportData(defaults: suite)
        let text = String(decoding: data, as: UTF8.self)
        // The MCP blob rides the export base64-encoded, so the pin decodes
        // it below; the raw scan only proves the value never leaks as
        // plaintext anywhere else in the file.
        XCTAssertFalse(text.contains("legacy-secret-value"),
                       "a settings export must never carry env values")

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any],
              let tagged = config[SettingsKeys.mcpServers] as? [String: Any],
              let encoded = tagged["$data"] as? String,
              let blob = Data(base64Encoded: encoded) else {
            return XCTFail("the export must carry the MCP blob")
        }
        let exported = try JSONDecoder().decode([MCPServer].self, from: blob)
        XCTAssertEqual(exported.first?.environment, ["API_TOKEN": ""],
                       "the exported blob keeps env key names and zero env values")
        // The export never mutates the stored configuration.
        let stored = try JSONDecoder().decode([MCPServer].self,
                                              from: suite.data(forKey: SettingsKeys.mcpServers) ?? Data())
        XCTAssertEqual(stored.first?.environment, ["API_TOKEN": "legacy-secret-value"],
                       "scrubbing happens at the export boundary, not by rewriting the store")
    }

    /// The KES-06 consent row for an env-bearing server names the env KEY,
    /// never the value (the KES-03 banner doctrine).
    func testConsentSummaryListsEnvironmentKeyNamesNeverValues() throws {
        let suite = UserDefaults(suiteName: "mcp-store-fail-safe-consent")!
        defer { suite.removePersistentDomain(forName: "mcp-store-fail-safe-consent") }
        let blob = try legacyPlaintextBlob(id: UUID(), env: ["API_TOKEN": "sneaky-secret"])
        let config: [String: Any] = ["mcpServers": ["$data": blob.base64EncodedString()]]
        let payload = try JSONSerialization.data(withJSONObject:
                ["format": "kestrel-settings", "version": 1, "config": config])
        guard case .rows(let rows) = SettingsArchive.processSpawningSummary(for: payload, defaults: suite) else {
            return XCTFail("an env-bearing MCP server must still summarize (KES-06)")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].contains("/usr/local/bin/legacy-server"),
                      "the consent row still lists the command")
        XCTAssertTrue(rows[0].contains("API_TOKEN"),
                      "the consent row names the env key an import would set")
        XCTAssertFalse(rows[0].contains("sneaky-secret"),
                       "the consent row never shows env values")
    }

    /// (d) A legacy plaintext-env config migrates into the 0600 store on
    /// first read, the UserDefaults copy self-retires (key names only
    /// remain), later reads serve from the store, and a successful
    /// migration records nothing.
    func testLegacyPlaintextEnvironmentMigratesIntoTheOwnerOnlyStoreOnFirstRead() throws {
        requireHarnessSeams()
        try storedBlob {
            let id = UUID()
            let account = "mcp-env-\(id.uuidString)"
            LocalSecretStore.delete(account)
            defer { LocalSecretStore.delete(account) }
            UserDefaults.standard.set(
                try legacyPlaintextBlob(id: id, env: ["API_TOKEN": "legacy-secret-value"]),
                forKey: SettingsKeys.mcpServers)
            let before = SupportDiagnostics.failureReport().last

            let servers = MCPServerStore.load()

            XCTAssertEqual(servers.first?.environment, ["API_TOKEN": "legacy-secret-value"],
                           "the legacy value is returned, not dropped in transit")
            let storedRaw = try XCTUnwrap(LocalSecretStore.value(account),
                                          "the env map landed in the local secret store")
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(storedRaw.utf8)),
                           ["API_TOKEN": "legacy-secret-value"])
            let mode = try FileManager.default.attributesOfItem(
                atPath: LocalSecretStore.url(account).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, "the migrated env map lands owner-only")
            let retired = try JSONDecoder().decode(
                [MCPServer].self,
                from: try XCTUnwrap(UserDefaults.standard.data(forKey: SettingsKeys.mcpServers)))
            XCTAssertEqual(retired.first?.environment, ["API_TOKEN": ""],
                           "the legacy plaintext copy self-retired: key names only remain in UserDefaults")
            XCTAssertEqual(MCPServerStore.load().first?.environment,
                           ["API_TOKEN": "legacy-secret-value"],
                           "the second read serves from the secret store, not a re-migration")
            XCTAssertEqual(SupportDiagnostics.failureReport().last ?? "", before ?? "",
                           "a successful migration records nothing")
        }
    }

    /// (d, failure side) A failed secret-store write must keep the legacy
    /// plaintext copy as the only surviving one (surfaced, retried on a
    /// later read) — retiring it would destroy the values outright. The
    /// failure injection is the SecretStoreFailureTests one: a directory
    /// planted where the 0600 file must land makes rename(2) fail EISDIR.
    func testFailedEnvMigrationKeepsTheLegacyPlaintextCopy() throws {
        requireHarnessSeams()
        try storedBlob {
            let id = UUID()
            let account = "mcp-env-\(id.uuidString)"
            LocalSecretStore.delete(account)
            defer { LocalSecretStore.delete(account) }
            try FileManager.default.createDirectory(at: LocalSecretStore.url(account),
                                                    withIntermediateDirectories: true)
            let legacy = try legacyPlaintextBlob(id: id, env: ["API_TOKEN": "legacy-secret-value"])
            UserDefaults.standard.set(legacy, forKey: SettingsKeys.mcpServers)

            let servers = MCPServerStore.load()

            XCTAssertEqual(servers.first?.environment, ["API_TOKEN": "legacy-secret-value"],
                           "the legacy value still serves this launch")
            XCTAssertEqual(UserDefaults.standard.data(forKey: SettingsKeys.mcpServers), legacy,
                           "a failed store must not retire the legacy copy — that destroys the only surviving values")
            let reason = SupportDiagnostics.failureReport().last ?? ""
            XCTAssertTrue(reason.contains("environment"),
                          "the failed migration is surfaced: \(reason)")
            XCTAssertTrue(reason.allSatisfy { $0.isASCII },
                          "product doctrine: new user-facing strings are English-only")

            LocalSecretStore.delete(account)   // unsabotage: later writes succeed
            let migrated = MCPServerStore.load()
            XCTAssertEqual(migrated.first?.environment, ["API_TOKEN": "legacy-secret-value"],
                           "the retry on a later read migrates verbatim")
            XCTAssertNotNil(LocalSecretStore.value(account),
                            "the retried migration landed in the store")
        }
    }

    /// The paste-import path: a config pasted in carries env values in
    /// memory, so save() must land them in the 0600 store and leave only
    /// key names in the stored blob — and deleting the server removes its
    /// env secret (no orphan secret file outlives the row).
    func testSavedEnvironmentLandsInTheSecretStoreNotTheBlob() throws {
        requireHarnessSeams()
        try storedBlob {
            UserDefaults.standard.set(try JSONEncoder().encode([MCPServer]()),
                                      forKey: SettingsKeys.mcpServers)
            _ = MCPServerStore.load()
            var imported = MCPServer(name: "pasted", url: "")
            imported.transport = .stdio
            imported.command = "/usr/local/bin/pasted-server"
            imported.environment = ["API_TOKEN": "pasted-secret-value"]
            let account = imported.envAccount
            LocalSecretStore.delete(account)
            defer { LocalSecretStore.delete(account) }

            MCPServerStore.save([imported])

            let stored = try JSONDecoder().decode(
                [MCPServer].self,
                from: try XCTUnwrap(UserDefaults.standard.data(forKey: SettingsKeys.mcpServers)))
            XCTAssertEqual(stored.first?.environment, ["API_TOKEN": ""],
                           "the stored blob carries the env key name and zero values")
            let secret = try XCTUnwrap(LocalSecretStore.value(account),
                                       "the pasted values landed in the local secret store")
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(secret.utf8)),
                           ["API_TOKEN": "pasted-secret-value"])
            XCTAssertEqual(MCPServerStore.load().first?.environment,
                           ["API_TOKEN": "pasted-secret-value"],
                           "the next read hydrates the values from the store")

            MCPServerStore.deleteCredentials(for: imported)
            XCTAssertNil(LocalSecretStore.value(account),
                         "deleting the server removes its env secret — no orphan secret file")
        }
    }
}

// MARK: - Generated registration (port from XCTest)
extension MCPStoreFailSafeTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "MCPStoreFailSafeTests",
        instance: { MCPStoreFailSafeTests() },
        checks: [
            .init(name: "testEncodeFailureKeepsThePreviousStoredServerList") { try $0.testEncodeFailureKeepsThePreviousStoredServerList() },
            .init(name: "testDecodeFailureRefusesBlindSavesUntilAcknowledged") { try $0.testDecodeFailureRefusesBlindSavesUntilAcknowledged() },
            .init(name: "testExportsCarryEnvironmentKeysButNeverValues") { try $0.testExportsCarryEnvironmentKeysButNeverValues() },
            .init(name: "testConsentSummaryListsEnvironmentKeyNamesNeverValues") { try $0.testConsentSummaryListsEnvironmentKeyNamesNeverValues() },
            .init(name: "testLegacyPlaintextEnvironmentMigratesIntoTheOwnerOnlyStoreOnFirstRead") { try $0.testLegacyPlaintextEnvironmentMigratesIntoTheOwnerOnlyStoreOnFirstRead() },
            .init(name: "testFailedEnvMigrationKeepsTheLegacyPlaintextCopy") { try $0.testFailedEnvMigrationKeepsTheLegacyPlaintextCopy() },
            .init(name: "testSavedEnvironmentLandsInTheSecretStoreNotTheBlob") { try $0.testSavedEnvironmentLandsInTheSecretStoreNotTheBlob() },
        ])
}
