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

    // MARK: checksums matcher (KES-09 fail-closed selection)

    func testChecksumMatcherExtractsThePublishedDigestForTheDMGBasename() {
        // sha256sum shape ("digest  name" — two spaces), the AVX2 and
        // no-AVX2 assets side by side with a non-matching line between:
        // the first line mentioning THIS basename decides, and its FIRST
        // token is the digest.
        let listing = "aaa1  Kestrel-0.82.dmg\nbbb2  Kestrel-0.81.dmg\nccc3  Kestrel-0.82-noavx2.dmg\n"
        XCTAssertEqual(
            UpdateChecker.expectedChecksum(in: listing, forDMGBasename: "Kestrel-0.82.dmg"),
            "aaa1",
            "the covering line's first token is the expected digest, double-space separators included")
        XCTAssertEqual(
            UpdateChecker.expectedChecksum(in: listing, forDMGBasename: "Kestrel-0.82-noavx2.dmg"),
            "ccc3",
            "a no-AVX2 install must never rebind to the AVX2 asset's line (or vice versa)")
    }

    func testChecksumMatcherFailsClosedWhenNoLineCoversTheAsset() {
        XCTAssertNil(
            UpdateChecker.expectedChecksum(in: "aaa1  Kestrel-0.81.dmg\n", forDMGBasename: "Kestrel-0.82.dmg"),
            "an entry that does not cover this asset yields no expected digest — the KES-09 guard discards the download")
        XCTAssertNil(
            UpdateChecker.expectedChecksum(in: "aaa1  other.dmg\nbbb2  Kestrel-0.82.txt\n", forDMGBasename: "Kestrel-0.82.dmg"),
            "a basename that appears nowhere verbatim yields no expected digest")
        XCTAssertNil(
            UpdateChecker.expectedChecksum(in: "", forDMGBasename: "Kestrel-0.82.dmg"),
            "an empty listing yields no expected digest")
    }

    func testChecksumMatcherPinsMalformedLines() {
        // A covering line with no digest token degenerates to its first
        // token (the basename itself), exactly like the historical inline
        // matcher — the digest comparison then fails and the install
        // aborts, so the shape is pinned rather than "improved".
        XCTAssertEqual(
            UpdateChecker.expectedChecksum(in: "Kestrel-0.82.dmg\n", forDMGBasename: "Kestrel-0.82.dmg"),
            "Kestrel-0.82.dmg",
            "a token-less covering line yields its only token, never nil")
        // Blank lines are skipped, and the FIRST covering line wins even
        // when a later line mentions the same basename.
        XCTAssertEqual(
            UpdateChecker.expectedChecksum(in: "\nfirst1  Kestrel-0.82.dmg\nsecond2  Kestrel-0.82.dmg\n",
                                           forDMGBasename: "Kestrel-0.82.dmg"),
            "first1")
        // More tokens than the two-field shape: still the first token.
        XCTAssertEqual(
            UpdateChecker.expectedChecksum(in: "leading1 trailing  Kestrel-0.82.dmg\n", forDMGBasename: "Kestrel-0.82.dmg"),
            "leading1")
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
            .init(name: "testChecksumMatcherExtractsThePublishedDigestForTheDMGBasename") { $0.testChecksumMatcherExtractsThePublishedDigestForTheDMGBasename() },
            .init(name: "testChecksumMatcherFailsClosedWhenNoLineCoversTheAsset") { $0.testChecksumMatcherFailsClosedWhenNoLineCoversTheAsset() },
            .init(name: "testChecksumMatcherPinsMalformedLines") { $0.testChecksumMatcherPinsMalformedLines() },
        ])
}
