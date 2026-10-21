// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The quit-path teardown ladder (census C6 / W2-4): inline by doctrine —
/// a detached task does not outlive the app — but BOUNDED by contract:
/// SIGTERM, at most 20 × 100 ms of waiting, then SIGKILL. Pinned against
/// both a cooperative child (dies on SIGTERM) and a SIGTERM-immune one
/// (must die by SIGKILL inside the cap, not hang past it).
final class EngineTeardownTests: CheckCase {
    private func spawn(_ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = arguments
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        return p
    }

    func testCooperativeChildDiesOnSigtermWithoutBurningTheCap() {
        let p = spawn(["-c", "sleep 5"])
        Thread.sleep(forTimeInterval: 0.3)   // let the child exist
        let start = Date()
        ServerController.terminateAndReap(p)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(p.isRunning, "a SIGTERM-cooperative child must be dead")
        XCTAssertLessThan(elapsed, 1.5, "cooperative exit must not burn the 2 s cap")
    }

    func testSigtermImmuneChildIsSigkilledInsideTheCap() {
        let p = spawn(["-c", "trap '' TERM; sleep 5"])
        Thread.sleep(forTimeInterval: 0.3)   // let the trap install
        let start = Date()
        ServerController.terminateAndReap(p)
        let elapsed = Date().timeIntervalSince(start)
        var settled = false
        for _ in 0..<20 {
            if !p.isRunning { settled = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(settled, "a SIGTERM-immune child must die from the SIGKILL fallback")
        XCTAssertGreaterThan(elapsed, 0.8, "the ladder waits for the grace period before escalating")
        XCTAssertLessThan(elapsed, 4.5, "the cap holds: never waits out the child's full 5 s lifetime")
    }
}

// MARK: - Generated registration (port from XCTest)
extension EngineTeardownTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "EngineTeardownTests",
        instance: { EngineTeardownTests() },
        checks: [
            .init(name: "testCooperativeChildDiesOnSigtermWithoutBurningTheCap") { $0.testCooperativeChildDiesOnSigtermWithoutBurningTheCap() },
            .init(name: "testSigtermImmuneChildIsSigkilledInsideTheCap") { $0.testSigtermImmuneChildIsSigkilledInsideTheCap() },
        ])
}
