// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Kestrel

/// KES-05 regression tests: tool consent is session-scoped, the shell is
/// never covered by standing consent, and legacy persisted grants die.
final class ToolConsentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ChatToolsService.revokeAllPermissions()
    }

    func testAlwaysIsSessionScoped() {
        XCTAssertFalse(ChatToolsService.isAlwaysAllowed("read_file"))
        ChatToolsService.allowAlways("read_file")
        XCTAssertTrue(ChatToolsService.isAlwaysAllowed("read_file"))
        ChatToolsService.revokeAllPermissions()
        XCTAssertFalse(ChatToolsService.isAlwaysAllowed("read_file"))
    }

    func testShellIsNeverAlwaysAllowed() {
        ChatToolsService.allowAlways("exec_shell_command")
        XCTAssertFalse(ChatToolsService.isAlwaysAllowed("exec_shell_command"),
                       "no standing consent for shell execution (KES-05)")
    }

    func testLegacyPersistedGrantIsSweptOnRevoke() {
        UserDefaults.standard.set(true, forKey: "toolPermission.always.read_file")
        ChatToolsService.revokeAllPermissions()
        XCTAssertNil(UserDefaults.standard.object(forKey: "toolPermission.always.read_file"))
    }

    func testLegacyPersistedGrantIsNotHonored() {
        UserDefaults.standard.set(true, forKey: "toolPermission.always.grep_search")
        defer { UserDefaults.standard.removeObject(forKey: "toolPermission.always.grep_search") }
        XCTAssertFalse(ChatToolsService.isAlwaysAllowed("grep_search"),
                       "pre-KES-05 permanent grants must stop working")
    }
}
