// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The one-shot sweeps and bounded kill ladders of mission T4-3 (census
/// W6-2/W6-3, W2-3/W2-5): the sweep records persist so a second launch
/// performs no sweep, the SIGTERM→SIGKILL family polls instead of sleeping
/// a fixed grace with a single late observation, and the VideoGen writer
/// wait is capped with a typed timeout. Behavioral checks run the shared
/// ladder against real children (EngineTeardownTests pattern); the source
/// check pins that no unconverted fixed-grace shape returns.
final class BoundedTeardownTests: CheckCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "bounded-teardown-tests")
        suite.removePersistentDomain(forName: "bounded-teardown-tests")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "bounded-teardown-tests")
        super.tearDown()
    }

    // MARK: H5 — escalation contract (real processes)

    private func spawn(_ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = arguments
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        p.terminationHandler = { _ in }   // Foundation reaps; kill(pid,0) sees true death
        try? p.run()
        return p
    }

    /// A SIGTERM-cooperative child must be observed dead well before the
    /// cap — the ladder returns the moment liveness reads false, it never
    /// burns the full grace on a child that already left.
    func testCooperativeChildIsObservedBeforeTheCap() {
        let p = spawn(["-c", "sleep 5"])
        Thread.sleep(forTimeInterval: 0.3)   // let the child exist
        kill(p.processIdentifier, SIGTERM)
        let start = Date()
        // 20 × 50 ms = 1 s cap, same shape as the production call sites.
        EngineLock.terminateBounded(pid: p.processIdentifier, pollMs: 50, capAttempts: 20)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(p.isRunning, "a SIGTERM-cooperative child must be dead")
        XCTAssertLessThan(elapsed, 1.5,
                          "the ladder must not hang past its cap on a cooperative child")
    }

    /// A SIGTERM-immune child must die from the SIGKILL at the cap — never
    /// before the grace (it holds the trap), never hanging past it.
    func testSigtermImmuneChildIsSigkilledAtTheCap() {
        let p = spawn(["-c", "trap '' TERM; sleep 5"])
        Thread.sleep(forTimeInterval: 0.3)   // let the trap install
        kill(p.processIdentifier, SIGTERM)
        XCTAssertTrue(p.isRunning, "the trap must hold SIGTERM so only the SIGKILL can win")
        let start = Date()
        EngineLock.terminateBounded(pid: p.processIdentifier, pollMs: 50, capAttempts: 20)
        let elapsed = Date().timeIntervalSince(start)
        var settled = false
        for _ in 0..<20 {
            if !p.isRunning { settled = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(settled, "a SIGTERM-immune child must die from the cap's SIGKILL")
        XCTAssertGreaterThan(elapsed, 0.5, "the SIGKILL waits out the grace cap, not less")
        XCTAssertLessThan(elapsed, 2.5, "the cap holds: never hangs past cap + slack")
    }

    // MARK: H4 — the sweeps persist (census W6-2, W6-3)

    /// One sweep per install, not per launch: the record is written with
    /// the sweep, a second launch never enumerates again (a legacy key
    /// seeded after the record survives — proof the enumeration did not
    /// run), and the explicit revoke path still sweeps regardless.
    func testToolPermissionSweepRunsOncePerInstall() {
        // First launch: legacy grant present, record absent → swept + recorded.
        suite.set(true, forKey: "toolPermission.always.web_search")
        XCTAssertFalse(suite.bool(forKey: SettingsKeys.toolPermissionsLegacySwept))
        ChatToolsService.sweepLegacyPermissionsIfNeeded(in: suite)
        XCTAssertNil(suite.object(forKey: "toolPermission.always.web_search"),
                     "the legacy grant must die on the first sweep")
        XCTAssertTrue(suite.bool(forKey: SettingsKeys.toolPermissionsLegacySwept),
                      "the sweep writes its one-shot record")

        // Second launch: record present → no enumeration at all. A legacy
        // key appearing now is left untouched; removing it would prove the
        // dictionaryRepresentation() sweep ran again.
        suite.set(true, forKey: "toolPermission.always.exec_shell_command")
        ChatToolsService.sweepLegacyPermissionsIfNeeded(in: suite)
        XCTAssertNotNil(suite.object(forKey: "toolPermission.always.exec_shell_command"),
                        "a second launch must not enumerate — the record short-circuits")

        // Explicit revoke always sweeps, record or not: standing consent
        // dies on the operator's command.
        ChatToolsService.sweepLegacyPermissionsIfNeeded(force: true, in: suite)
        XCTAssertNil(suite.object(forKey: "toolPermission.always.exec_shell_command"),
                     "the force path (revokeAllPermissions) sweeps regardless of the record")
    }

    /// The legacy launch heals (W6-3) run once per install: first run heals
    /// every legacy shape (extraArgs strip, engine path, stale language,
    /// mistyped numerics) and writes the record; a second run leaves the
    /// same legacy state untouched — proof no heal executed again.
    func testLegacyLaunchHealsRunOnceThenNeverAgain() {
        // First launch: the full legacy state a pre-T4 install could carry.
        suite.set("--spec-type draft-mtp -c 64", forKey: SettingsKeys.extraArgs)
        suite.set("/opt/old/llama.cpp-b7833/bin/llama-server", forKey: "serverBinary")
        suite.set("es", forKey: "lang")
        suite.set("33", forKey: SettingsKeys.vramReserve)   // mistyped numeric (registry .int)
        LegacyLaunchHeals.run(in: suite)
        XCTAssertEqual(suite.string(forKey: SettingsKeys.extraArgs), "-c 64",
                       "the --spec-type strip heals once")
        XCTAssertEqual(suite.string(forKey: "serverBinary"), ServerSettings.defaultBinary,
                       "the legacy engine path heals to the bundled binary")
        XCTAssertNil(suite.object(forKey: "lang"), "the stale language key clears")
        XCTAssertEqual(suite.object(forKey: SettingsKeys.vramReserve) as? Int, 33,
                       "a string-typed numeric is rewritten typed (value preserved)")
        XCTAssertTrue(suite.bool(forKey: SettingsKeys.legacyLaunchHealsSwept),
                      "the heals write their one-shot record")

        // Second launch: the same legacy state is left untouched — any
        // change would prove a heal ran again.
        suite.set("--spec-type draft-mtp", forKey: SettingsKeys.extraArgs)
        suite.set("/opt/old/llama.cpp-b7833/bin/llama-server", forKey: "serverBinary")
        LegacyLaunchHeals.run(in: suite)
        XCTAssertEqual(suite.string(forKey: SettingsKeys.extraArgs), "--spec-type draft-mtp",
                       "no second sweep: the record short-circuits the strip")
        XCTAssertEqual(suite.string(forKey: "serverBinary"), "/opt/old/llama.cpp-b7833/bin/llama-server",
                       "no second sweep: the record short-circuits the engine-path heal")
    }

    // MARK: H5 — no unconverted shape remains (source contract)

    private func repoSource(_ relative: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KestrelTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // package root
        return try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The body of `signature` up to its closing brace at the member level
    /// (4-space `}`), so assertions target one function, never the file.
    private func body(of signature: String, in source: String) throws -> String {
        let range = try XCTUnwrap(source.range(of: signature), "function not found: \(signature)")
        let rest = String(source[range.lowerBound...])
        let close = try XCTUnwrap(rest.range(of: "\n    }"), "function end not found: \(signature)")
        return String(rest[..<close.lowerBound])
    }

    /// Every fixed-grace/single-observation kill ladder is gone: the four
    /// converted functions ride the shared bounded poll, and the VideoGen
    /// writer wait carries a deadline with a typed throw (census W2-3/W2-5).
    /// Asserted on function-body slices, not whole-file globs.
    func testKillLaddersAreBoundedAndObserved() throws {
        let support = try repoSource("Sources/App/Support.swift")

        let reapOrphans = try body(of: "static func reapOrphans()", in: support)
        XCTAssertTrue(reapOrphans.contains("terminateBounded(pid: pid, pollMs: 50, capAttempts: 10)"),
                      "reapOrphans must ride the bounded ladder at its 500 ms total cap")
        XCTAssertFalse(reapOrphans.contains("usleep(500_000)"),
                       "the blind 500 ms grace sleep must not return")
        XCTAssertFalse(reapOrphans.contains("asyncAfter"))

        let reapStrayEngines = try body(of: "static func reapStrayEngines()", in: support)
        XCTAssertTrue(reapStrayEngines.contains("terminateBounded"),
                      "reapStrayEngines must ride the bounded ladder")
        XCTAssertFalse(reapStrayEngines.contains("asyncAfter("),
                       "the fixed 5 s asyncAfter escalation must not return")

        let server = try repoSource("Sources/Servers/Server.swift")

        let reapChildren = try body(of: "nonisolated static func reapChildren", in: server)
        XCTAssertTrue(reapChildren.contains("terminateBounded"),
                      "reapChildren must ride the bounded ladder")
        XCTAssertFalse(reapChildren.contains("asyncAfter("),
                       "the fixed 5 s asyncAfter escalation must not return")

        let escalateKill = try body(of: "nonisolated static func escalateKill", in: server)
        XCTAssertTrue(escalateKill.contains("terminateBounded"),
                      "escalateKill must ride the bounded ladder")
        XCTAssertFalse(escalateKill.contains("Task.sleep"),
                       "the blind full-grace Task.sleep must not return")
        let videoGen = try repoSource("Sources/Video/VideoGen.swift")
        XCTAssertTrue(videoGen.contains("case writerInputStalled(timeoutSeconds: Double)"),
                      "ExportError must carry the typed stall timeout")
        XCTAssertTrue(videoGen.contains("static let writerInputStallCapSeconds"),
                      "the cap is a named, documented constant")
        let spin = try XCTUnwrap(videoGen.range(of: "while !input.isReadyForMoreMediaData"),
                                 "the writer wait loop must exist")
        let window = videoGen[spin.upperBound...].prefix(400)
        XCTAssertTrue(window.contains("stallDeadline"),
                      "the writer wait compares against a deadline inside the loop")
        XCTAssertTrue(window.contains("throw ExportError.writerInputStalled"),
                      "the writer wait throws its typed timeout at the deadline")
    }
}

// MARK: - Generated registration (port from XCTest)
extension BoundedTeardownTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "BoundedTeardownTests",
        instance: { BoundedTeardownTests() },
        checks: [
            .init(name: "testCooperativeChildIsObservedBeforeTheCap") { $0.testCooperativeChildIsObservedBeforeTheCap() },
            .init(name: "testSigtermImmuneChildIsSigkilledAtTheCap") { $0.testSigtermImmuneChildIsSigkilledAtTheCap() },
            .init(name: "testToolPermissionSweepRunsOncePerInstall") { $0.testToolPermissionSweepRunsOncePerInstall() },
            .init(name: "testLegacyLaunchHealsRunOnceThenNeverAgain") { $0.testLegacyLaunchHealsRunOnceThenNeverAgain() },
            .init(name: "testKillLaddersAreBoundedAndObserved") { try $0.testKillLaddersAreBoundedAndObserved() },
        ])
}
