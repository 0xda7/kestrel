// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The DMG swap's never-leave-no-app contract (census C3): a failed
/// set-aside touches nothing, a failed copy always attempts restore, and a
/// failed restore escalates naming the aside's exact location instead of
/// dying silently with no app in /Applications.
final class UpdateSwapSafetyTests: CheckCase {
    private struct Probe: Error { let tag: String }
    private func boom(_ tag: String) -> Error { Probe(tag: tag) }

    func testFailedSetAsideStopsWithoutTouchingAnything() throws {
        var copyRan = false
        var restoreRan = false
        XCTAssertThrowsError(try UpdateChecker.performAppSwap(
            setAside: { throw self.boom("set-aside") },
            copy: { copyRan = true },
            restore: { restoreRan = true },
            asidePath: "/Applications/Kestrel.old.app")) { error in
            guard let updateError = error as? UpdateError else {
                return XCTFail("set-aside failure must surface as UpdateError")
            }
            let m = updateError.message
            XCTAssertTrue(m.contains("without touching anything") || m.contains("sin tocar nada"),
                          "the error names the stopped-before-touching contract")
        }
        XCTAssertFalse(copyRan, "a failed set-aside must never reach the copy")
        XCTAssertFalse(restoreRan, "nothing was moved, so nothing needs restoring")
    }

    func testFailedCopyAlwaysAttemptsRestoreAndPropagatesTheCopyError() throws {
        var restored = false
        XCTAssertThrowsError(try UpdateChecker.performAppSwap(
            setAside: {},
            copy: { throw self.boom("ditto") },
            restore: { restored = true },
            asidePath: "/Applications/Kestrel.old.app")) { error in
            guard let probe = error as? Probe else {
                return XCTFail("the ORIGINAL copy error propagates after a clean restore")
            }
            XCTAssertEqual(probe.tag, "ditto")
        }
        XCTAssertTrue(restored, "a failed copy must always attempt the restore")
    }

    func testFailedRestoreEscalatesNamingTheAsideLocation() throws {
        XCTAssertThrowsError(try UpdateChecker.performAppSwap(
            setAside: {},
            copy: { throw self.boom("ditto") },
            restore: { throw self.boom("restore") },
            asidePath: "/Applications/Kestrel.old.app")) { error in
            guard let updateError = error as? UpdateError else {
                return XCTFail("a failed restore must escalate as UpdateError, not the raw copy error")
            }
            let m = updateError.message
            XCTAssertTrue(m.contains("/Applications/Kestrel.old.app"),
                          "the escalation names the aside's exact location")
            XCTAssertTrue((m.contains("/Applications") && m.contains("drag it back")) || m.contains("arrastrala"),
                          "the escalation names the manual recovery action")
        }
    }

    func testCleanSwapRunsSetAsideCopyAndNoRestore() throws {
        var order: [String] = []
        do {
            try UpdateChecker.performAppSwap(
                setAside: { order.append("set-aside") },
                copy: { order.append("copy") },
                restore: { order.append("restore") },
                asidePath: "/Applications/Kestrel.old.app")
        } catch {
            XCTFail("a clean swap must not throw: \(error)")
        }
        XCTAssertEqual(order, ["set-aside", "copy"], "happy path never restores")
    }
}

// MARK: - Generated registration (port from XCTest)
extension UpdateSwapSafetyTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "UpdateSwapSafetyTests",
        instance: { UpdateSwapSafetyTests() },
        checks: [
            .init(name: "testFailedSetAsideStopsWithoutTouchingAnything") { try $0.testFailedSetAsideStopsWithoutTouchingAnything() },
            .init(name: "testFailedCopyAlwaysAttemptsRestoreAndPropagatesTheCopyError") { try $0.testFailedCopyAlwaysAttemptsRestoreAndPropagatesTheCopyError() },
            .init(name: "testFailedRestoreEscalatesNamingTheAsideLocation") { try $0.testFailedRestoreEscalatesNamingTheAsideLocation() },
            .init(name: "testCleanSwapRunsSetAsideCopyAndNoRestore") { try $0.testCleanSwapRunsSetAsideCopyAndNoRestore() },
        ])
}
