// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The DMG swap's never-leave-no-app contract (census C3): a failed
/// set-aside touches nothing, a failed copy always attempts restore, and a
/// failed restore escalates naming the aside's exact location instead of
/// dying silently with no app in /Applications.
///
/// T2-3 chunk F adds the census W8 Updates surfacing pins: the relaunch
/// decision (a failed launch surfaces and NEVER terminates — census
/// Updates:243, landed in 422ef5a, here census-citing and pinned), the
/// restore-removal gate (census Updates:173), and the update-check /
/// release-notes skip notices (census Updates:57/:59/:260/:262).
///
/// Honest limitations (chunk C/D/E doctrine): the AppLog lines for the
/// log-only steps — Updates:102 (DMG pre-clean), :114 (checksums fetch),
/// :121 (discard leftover), :168 (aside pre-clean), :177 (aside cleanup) —
/// have no seam because their outcomes are already surfaced through
/// installError or the typed errors, and AppLog is unobservable in this
/// harness. The relaunch wiring itself (DispatchQueue + Process +
/// NSApp.terminate) and the two fetch call sites are likewise unobservable;
/// every decision above is pinned on its pure seam. A quiet real
/// no-update emits no line by call-site structure — no seam exists for
/// silence.
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

    // MARK: census W8 Updates surfacing (T2-3 chunk F)

    func testUpdateCheckFetchFailureNoticeNamesTheSkip() {
        XCTAssertEqual(
            UpdateChecker.updateCheckFetchFailureNotice(reason: "offline"),
            "Could not fetch the releases list to check for updates; the check is skipped: offline")
    }

    func testUpdateCheckParseFailureNoticeIsDistinctFromAFetchFailure() {
        let fetch = UpdateChecker.updateCheckFetchFailureNotice(reason: "offline")
        let parse = UpdateChecker.updateCheckParseFailureNotice(reason: "offline")
        XCTAssertEqual(
            parse,
            "Could not read the releases response to check for updates; the check is skipped: offline")
        XCTAssertNotEqual(fetch, parse,
                          "a skipped fetch and an unreadable response must stay distinguishable from each other (census Updates:57 vs :59); a real no-update emits neither")
    }

    func testNotesFetchAndParseFailureNoticesNameThePopoverFallback() {
        XCTAssertEqual(
            UpdateChecker.notesFetchFailureNotice(reason: "timed out"),
            "Could not fetch the release notes; the popover shows its could-not-load note: timed out")
        XCTAssertEqual(
            UpdateChecker.notesParseFailureNotice(reason: "not a list"),
            "Could not read the releases response for the release notes; the popover shows its could-not-load note: not a list")
        XCTAssertNotEqual(
            UpdateChecker.notesFetchFailureNotice(reason: "x"),
            UpdateChecker.notesParseFailureNotice(reason: "x"),
            "fetch and parse skips stay distinguishable (census Updates:260 vs :262)")
    }

    func testRelaunchSuccessQuitsExactlyAsBefore() {
        XCTAssertEqual(UpdateChecker.relaunchOutcome(runError: nil), .launched,
                       "a successful launch is the one outcome that terminates (census Updates:243)")
    }

    func testRelaunchFailureSurfacesAndNeverTerminates() {
        struct LaunchError: Error {}
        let outcome = UpdateChecker.relaunchOutcome(runError: LaunchError())
        guard case let .launchFailed(message) = outcome else {
            return XCTFail("a failed relaunch must decide launchFailed — the branch that surfaces and NEVER terminates")
        }
        XCTAssertTrue(message.contains("did not launch"),
                      "the surfaced message names the failed launch")
        XCTAssertTrue(message.contains("/Applications"),
                      "the surfaced message names the manual recovery (open it from /Applications)")
    }

    func testSwapRestoreBlocksOnlyWhenTheHalfInstalledTargetIsStillPresent() {
        struct RemovalError: Error {}
        XCTAssertTrue(UpdateChecker.swapRestoreBlocked(by: RemovalError(), targetStillPresent: true),
                      "a genuinely blocked removal throws, so the typed escalation names the aside (census Updates:173)")
        XCTAssertFalse(UpdateChecker.swapRestoreBlocked(by: RemovalError(), targetStillPresent: false),
                       "an absent target (the copy never landed) is benign: the restore move proceeds")
        XCTAssertFalse(UpdateChecker.swapRestoreBlocked(by: nil, targetStillPresent: true),
                       "a successful removal never blocks the restore")
    }

    func testSwapRestoreBlockerMessageNamesTheHalfInstalledTarget() {
        XCTAssertEqual(
            UpdateChecker.swapRestoreBlockerMessage(target: "Kestrel.app", reason: "busy"),
            "Could not remove the half-installed Kestrel.app to restore the previous app: busy")
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
            .init(name: "testUpdateCheckFetchFailureNoticeNamesTheSkip") { $0.testUpdateCheckFetchFailureNoticeNamesTheSkip() },
            .init(name: "testUpdateCheckParseFailureNoticeIsDistinctFromAFetchFailure") { $0.testUpdateCheckParseFailureNoticeIsDistinctFromAFetchFailure() },
            .init(name: "testNotesFetchAndParseFailureNoticesNameThePopoverFallback") { $0.testNotesFetchAndParseFailureNoticesNameThePopoverFallback() },
            .init(name: "testRelaunchSuccessQuitsExactlyAsBefore") { $0.testRelaunchSuccessQuitsExactlyAsBefore() },
            .init(name: "testRelaunchFailureSurfacesAndNeverTerminates") { $0.testRelaunchFailureSurfacesAndNeverTerminates() },
            .init(name: "testSwapRestoreBlocksOnlyWhenTheHalfInstalledTargetIsStillPresent") { $0.testSwapRestoreBlocksOnlyWhenTheHalfInstalledTargetIsStillPresent() },
            .init(name: "testSwapRestoreBlockerMessageNamesTheHalfInstalledTarget") { $0.testSwapRestoreBlockerMessageNamesTheHalfInstalledTarget() },
        ])
}
