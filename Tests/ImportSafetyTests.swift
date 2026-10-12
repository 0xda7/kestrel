// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Kestrel

/// KES-06/KES-07 regression tests: imports never adopt process-spawning
/// configuration or tool working directories without the operator seeing them.
final class ImportSafetyTests: XCTestCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "import-safety-tests")
        suite.removePersistentDomain(forName: "import-safety-tests")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "import-safety-tests")
        super.tearDown()
    }

    func testProcessSpawningSummaryListsBinaryOverride() throws {
        let json = #"{"format":"kestrel-settings","version":1,"config":{"serverBinary":"/tmp/evil-llama-server"}}"#
        let rows = SettingsArchive.processSpawningSummary(for: Data(json.utf8), defaults: suite)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].contains("/tmp/evil-llama-server"),
                      "a replaced engine binary must be surfaced before import (KES-06)")
    }

    func testProcessSpawningSummaryListsMCPCommands() throws {
        var server = MCPServer(name: "evil", url: "")
        server.transport = .stdio
        server.command = "/tmp/evil-mcp"
        server.arguments = ["--steal"]
        let blob = try JSONEncoder().encode([server])
        let config: [String: Any] = ["mcpServers": ["$data": blob.base64EncodedString()]]
        let payload = try JSONSerialization.data(withJSONObject:
                ["format": "kestrel-settings", "version": 1, "config": config])
        let rows = SettingsArchive.processSpawningSummary(for: payload, defaults: suite)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].contains("/tmp/evil-mcp"))
        XCTAssertTrue(rows[0].contains("--steal"))
    }

    func testProcessSpawningSummaryEmptyForBenignConfig() {
        let json = #"{"format":"kestrel-settings","version":1,"config":{"port": 9999}}"#
        let rows = SettingsArchive.processSpawningSummary(for: Data(json.utf8), defaults: suite)
        XCTAssertTrue(rows.isEmpty)
    }

    func testImportedWorkingDirectoryIsNeutralized() {
        var withCwd = Conversation(title: "imported")
        withCwd.workingDirectory = "/etc"
        var withoutCwd = Conversation(title: "clean")
        withoutCwd.workingDirectory = nil

        let result = ChatStore.neutralizedWorkingDirectories([withCwd, withoutCwd])
        XCTAssertNil(result[0].workingDirectory,
                     "a transcript must not aim the agent tools at an arbitrary directory (KES-07)")
        XCTAssertNil(result[1].workingDirectory)
    }
}
