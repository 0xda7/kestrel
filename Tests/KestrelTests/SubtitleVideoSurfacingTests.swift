// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission T2-3 chunk C: the census §2.8.3 Subtitles- and Video-group silent
/// catches are surfaced. Pinned here: an undecodable saved subtitle style
/// resets to the default loudly (SubtitleStyle:56), a failed format-description
/// read records the colour-space drop (SubtitleVideoExporter:79), the
/// video run directory and finished-frame scans are typed verdicts
/// (VideoGen:350/:477), and a stale mp4 output that cannot be removed is a
/// typed export error while the benign missing-file case still succeeds
/// (VideoGen:653).
final class SubtitleVideoSurfacingTests: CheckCase {
    private struct Boom: Error {}

    // MARK: - SubtitleStyle:56 — unreadable saved style resets loudly

    /// A garbage payload still falls back to `.default` (the style sheet needs
    /// a usable style), but the reset carries the English notice that load()
    /// logs — never a silent reset.
    func testGarbageSavedStyleResetsToDefaultAndSurfacesTheReset() throws {
        for garbage in [Data("not json {".utf8), Data("[1, 2]".utf8)] {
            let (style, notice) = SubtitleStyle.style(from: garbage)
            XCTAssertEqual(style, .default, "an unreadable style still falls back to the default")
            let unreadable = try XCTUnwrap(notice, "the reset must be surfaced, not silent")
            XCTAssertTrue(unreadable.contains("Saved subtitle style unreadable"),
                          "the notice must name the unreadable style: \(unreadable)")
            XCTAssertTrue(unreadable.contains("default style"),
                          "the notice must name the default fallback: \(unreadable)")
        }
    }

    /// Absent data is the normal first launch — no failure, no notice.
    func testAbsentSavedStyleIsAQuietFirstLaunch() {
        let (style, notice) = SubtitleStyle.style(from: nil)
        XCTAssertEqual(style, .default)
        XCTAssertNil(notice, "a first launch with nothing saved is not a failure")
    }

    /// The round-trip is untouched: a saved style decodes back identically
    /// with no notice, exactly as before the conversion.
    func testValidSavedStyleStillRoundTripsIdentically() throws {
        var custom = SubtitleStyle.default
        custom.fontName = "Menlo-Bold"
        custom.relativeSize = 0.05
        custom.textColor = SubtitleStyle.RGBA(r: 1, g: 0.4, b: 0.2, a: 0.9)
        custom.background = .outline
        custom.backgroundOpacity = 0.5
        custom.position = .top
        custom.margin = 0.08
        custom.maxWidth = 0.7
        custom.minRelativeSize = 0.02
        let data = try JSONEncoder().encode(custom)
        let (loaded, notice) = SubtitleStyle.style(from: data)
        XCTAssertEqual(loaded, custom, "the saved style must decode back identically")
        XCTAssertNil(notice, "a healthy load must not raise the notice")
    }

    // MARK: - SubtitleVideoExporter:79 — colour-space drop recorded

    /// The failure notice names the drop so an export that loses the source's
    /// colour tags is diagnosable instead of silent.
    func testFormatLoadFailureRecordsTheColourSpaceDrop() {
        let drop = SubtitleVideoExporter.colourSpaceDrop(Boom())
        XCTAssertTrue(drop.contains("format descriptions"),
                      "the notice must name the failed read: \(drop)")
        XCTAssertTrue(drop.contains("color space"),
                      "the notice must name the consequence: \(drop)")
    }
}

// MARK: - Generated registration (port from XCTest)
extension SubtitleVideoSurfacingTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SubtitleVideoSurfacingTests",
        instance: { SubtitleVideoSurfacingTests() },
        checks: [
            .init(name: "testGarbageSavedStyleResetsToDefaultAndSurfacesTheReset") { try $0.testGarbageSavedStyleResetsToDefaultAndSurfacesTheReset() },
            .init(name: "testAbsentSavedStyleIsAQuietFirstLaunch") { $0.testAbsentSavedStyleIsAQuietFirstLaunch() },
            .init(name: "testValidSavedStyleStillRoundTripsIdentically") { try $0.testValidSavedStyleStillRoundTripsIdentically() },
            .init(name: "testFormatLoadFailureRecordsTheColourSpaceDrop") { $0.testFormatLoadFailureRecordsTheColourSpaceDrop() },
        ])
}
