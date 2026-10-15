// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Pins the 2026-10-14 incident: a bundled z.ai runtime left inside the
/// agent sandbox made the harness prefer the dead builtin provider path
/// (bootstrap 404, exit 1) over the correct kestrel-local config.
final class LatchRuntimeGuardTests: CheckCase {
    func testSandboxSpawnRemovesStaleBundledRuntime() throws {
        let home = LatchDelegateService.sandboxHome
        let v2 = home.appendingPathComponent(".latch/v2")
        let bundled = v2.appendingPathComponent("runtime/provider/bundled/zcode-builtin.json")
        try FileManager.default.createDirectory(
            at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ \"stale\": true }".utf8).write(to: bundled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.path))

        // Spawn hygiene runs on every sandboxHome access — the guard itself
        // cleans the fixture, so the test leaves nothing behind.
        _ = LatchDelegateService.sandboxHome
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: v2.appendingPathComponent("runtime").path),
            "the bridge file is the embedded agent's only provider source; a bundled runtime must not survive a spawn")
    }
}

extension LatchRuntimeGuardTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "LatchRuntimeGuardTests",
        instance: { LatchRuntimeGuardTests() },
        checks: [
            .init(name: "testSandboxSpawnRemovesStaleBundledRuntime") { try await $0.testSandboxSpawnRemovesStaleBundledRuntime() },
        ])
}
