// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
@testable import KestrelCore

/// Mission T2-3 chunk C: the census §2.8.3 Subtitles- and Video-group silent
/// catches are surfaced. Pinned here: an undecodable saved subtitle style
/// resets to the default loudly (SubtitleStyle:56), a failed format-description
/// read records the colour-space drop (SubtitleVideoExporter:79), the
/// video run directory and finished-frame scans are typed verdicts
/// (VideoGen:350/:477), and — since the 2026-10-23 guardian slice made
/// writeMP4 a staged atomic swap — a write forced to fail at a protected
/// destination leaves the operator's pre-existing file byte-identical,
/// while a successful write still replaces it and a first export to an
/// absent destination still lands.
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
    // MARK: - VideoGen:350 — failed run directory aborts the run

    /// A run directory that cannot be created is a typed abort (the standard
    /// .failed channel) naming the directory error — never a launched run
    /// with nowhere to write frames.
    func testRunDirectoryFailureAbortsAndNamesTheDirectory() throws {
        let message = try XCTUnwrapCase(VideoGenerator.runDirectoryFailure(.failure(Boom())),
                                        "a directory failure must produce the abort message")
        XCTAssertTrue(message.contains("run directory could not be created"),
                      "the abort must name the directory error: \(message)")
        XCTAssertNil(VideoGenerator.runDirectoryFailure(.success(())),
                     "a created directory must proceed, not abort")
    }

    // MARK: - VideoGen:477 — failed frame scan vs no-frames verdict

    /// A failed finished-run scan is its own verdict naming the scan error;
    /// it must never read as the exit-status/no-frames verdicts, and a
    /// successful-but-empty scan still keeps the existing exit-status path.
    func testScanFailureIsItsOwnVerdictDistinctFromExitStatus() throws {
        let verdict = try XCTUnwrapCase(VideoGenerator.scanFailureVerdict(.failure(Boom())),
                                        "a scan failure must produce its own verdict")
        XCTAssertTrue(verdict.contains("could not be read back"),
                      "the verdict must name the scan failure: \(verdict)")
        XCTAssertFalse(verdict.contains("exit"),
                       "a scan failure must never read as an exit-status verdict: \(verdict)")
        XCTAssertNotEqual(verdict, "OOM")
        XCTAssertNotEqual(verdict, "TIMEOUT")
        XCTAssertNil(VideoGenerator.scanFailureVerdict(.success([])),
                     "a successful empty scan keeps the existing no-frames handling")
    }

    // MARK: - VideoGen — writeMP4 is a staged atomic swap (2026-10-23)

    /// writeMP4 over a path with no stale output completes and leaves the mp4.
    @MainActor func testWriteMP4OverAnAbsentOutputSucceeds() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-check-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try VideoExporter.writeMP4(frames: [Self.tinyFrame()], fps: 12, to: output)
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 0, "the export must produce the mp4")
    }

    /// A write forced to fail at a protected destination (read-only folder
    /// holding the operator's previous export) surfaces SaveError naming
    /// the destination while the original stays byte-identical — the old
    /// remove-first unlink had already destroyed it by then.
    @MainActor func testWriteMP4FailureAtProtectedDestinationKeepsTheOriginal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("previous.mp4")
        let previous = Data("the operator's previous export".utf8)
        try previous.write(to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        XCTAssertThrowsError(try VideoExporter.writeMP4(frames: [Self.tinyFrame()], fps: 12, to: dest)) { error in
            guard let save = error as? AtomicFileSave.SaveError else {
                return XCTFail("a forced write failure must surface SaveError naming the destination, got \(error)")
            }
            XCTAssertEqual(save.destinationPath, dest.path,
                           "the surfaced failure names the destination")
            XCTAssertTrue(save.localizedDescription.contains(dest.path),
                          "the alert text names the destination: \(save.localizedDescription)")
        }
        XCTAssertEqual(try Data(contentsOf: dest), previous,
                       "the operator's pre-existing file is byte-identical")
    }

    /// A successful write still replaces an existing destination — the
    /// atomic swap is what makes the export fresh, never a remove-first
    /// unlink that could leave nothing behind on failure.
    @MainActor func testWriteMP4SuccessStillReplacesTheExistingDestination() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-check-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: dest) }
        let previous = Data("the operator's previous export".utf8)
        try previous.write(to: dest)

        try VideoExporter.writeMP4(frames: [Self.tinyFrame()], fps: 12, to: dest)
        XCTAssertNotEqual(try Data(contentsOf: dest), previous,
                          "the fresh export replaced the stale destination")
        let size = try dest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 100, "the replaced file is a real mp4, not the stale bytes")
    }

    /// A 4×4 opaque frame (even dimensions, real pixels for the encoder).
    @MainActor private static func tinyFrame() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }

    /// Unwraps an optional failure verdict with a recorded failure instead of
    /// a force-unwrap.
    private func XCTUnwrapCase(_ value: String?, _ message: String) throws -> String {
        guard let value else {
            XCTFail(message)
            throw CheckAbort()
        }
        return value
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
            .init(name: "testWriteMP4FailureAtProtectedDestinationKeepsTheOriginal") { try $0.testWriteMP4FailureAtProtectedDestinationKeepsTheOriginal() },
            .init(name: "testRunDirectoryFailureAbortsAndNamesTheDirectory") { try $0.testRunDirectoryFailureAbortsAndNamesTheDirectory() },
            .init(name: "testScanFailureIsItsOwnVerdictDistinctFromExitStatus") { try $0.testScanFailureIsItsOwnVerdictDistinctFromExitStatus() },
            .init(name: "testWriteMP4OverAnAbsentOutputSucceeds") { try $0.testWriteMP4OverAnAbsentOutputSucceeds() },
            .init(name: "testWriteMP4SuccessStillReplacesTheExistingDestination") { try $0.testWriteMP4SuccessStillReplacesTheExistingDestination() },
        ])
}
