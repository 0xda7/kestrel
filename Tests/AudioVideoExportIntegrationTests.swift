// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
@testable import KestrelCore

final class AudioVideoExportIntegrationTests: CheckCase {
    @MainActor
    func testCaptionedVideoExportWhenFixtureIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["KESTREL_AUDIO_VIDEO_FIXTURE"] else {
            throw XCTSkip("Set KESTREL_AUDIO_VIDEO_FIXTURE to run the video export integration test")
        }
        let source = URL(fileURLWithPath: path)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-captioned-\(UUID().uuidString).mov")
        // Guardian slice (2026-10-23): a stale destination is the case the
        // atomic swap exists for — the happy path must replace it, not
        // require its absence.
        let stale = Data("the operator's previous export".utf8)
        try stale.write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        let exporter = SubtitleVideoExporter()
        exporter.export(
            sourceURL: source,
            cues: [SubtitleCue(id: 1, start: 0.2, end: 1.8, text: "Kestrel subtitle test")],
            outputURL: output
        )
        while exporter.isExporting {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(exporter.error)
        let after = try Data(contentsOf: output)
        XCTAssertNotEqual(after, stale, "a successful export replaces the existing destination")
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }

    // MARK: - Guardian slice (2026-10-23): a failed burn-in never destroys the existing file

    /// A tiny real video, generated in-process: the burn-in export checks
    /// run without an external fixture.
    @MainActor private static func tinySourceVideo() throws -> URL {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-burnin-source-\(UUID().uuidString).mp4")
        let frame = NSImage(size: NSSize(width: 64, height: 64))
        frame.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        frame.unlockFocus()
        try VideoExporter.writeMP4(frames: [frame, frame, frame, frame,
                                            frame, frame, frame, frame],
                                   fps: 8, to: source)
        return source
    }

    /// Forces the burn-in to fail at a protected destination (read-only
    /// folder holding the operator's previous export): the export fails,
    /// the surfaced error names the destination path, and the
    /// pre-existing file is byte-identical — the old remove-first try?
    /// destroyed it the moment the export started.
    @MainActor
    func testForcedBurnInFailureAtAProtectedDestinationKeepsTheOriginal() async throws {
        let source = try Self.tinySourceVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-burnin-protected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("captioned.mov")
        let previous = Data("the operator's previous export — must survive".utf8)
        try previous.write(to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let exporter = SubtitleVideoExporter()
        exporter.export(sourceURL: source,
                        cues: [SubtitleCue(id: 1, start: 0.2, end: 0.8, text: "Kestrel subtitle test")],
                        outputURL: dest)
        while exporter.isExporting {
            try await Task.sleep(for: .milliseconds(100))
        }
        let surfaced = try XCTUnwrap(exporter.error,
                                     "the forced failure must surface, not vanish into the old try?")
        XCTAssertTrue(surfaced.contains(dest.path),
                      "the surfaced error names the destination path: \(surfaced)")
        XCTAssertEqual(try Data(contentsOf: dest), previous,
                       "the pre-existing destination file is byte-identical")
    }

    /// A successful burn-in replaces an existing destination — the atomic
    /// swap, never a remove-first unlink.
    @MainActor
    func testSuccessfulBurnInReplacesTheExistingDestination() async throws {
        let source = try Self.tinySourceVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-burnin-\(UUID().uuidString).mov")
        let previous = Data("the operator's previous export".utf8)
        try previous.write(to: dest)
        defer { try? FileManager.default.removeItem(at: dest) }

        let exporter = SubtitleVideoExporter()
        exporter.export(sourceURL: source,
                        cues: [SubtitleCue(id: 1, start: 0.2, end: 0.8, text: "Kestrel subtitle test")],
                        outputURL: dest)
        while exporter.isExporting {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(exporter.error, "the happy-path export must succeed: \(exporter.error ?? "")")
        let after = try Data(contentsOf: dest)
        XCTAssertNotEqual(after, previous, "the stale destination was replaced by the fresh export")
        let size = try dest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }
}

// MARK: - Generated registration (port from XCTest)
extension AudioVideoExportIntegrationTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "AudioVideoExportIntegrationTests",
        instance: { AudioVideoExportIntegrationTests() },
        checks: [
            .init(name: "testCaptionedVideoExportWhenFixtureIsProvided") { try await $0.testCaptionedVideoExportWhenFixtureIsProvided() },
            .init(name: "testForcedBurnInFailureAtAProtectedDestinationKeepsTheOriginal") { try await $0.testForcedBurnInFailureAtAProtectedDestinationKeepsTheOriginal() },
            .init(name: "testSuccessfulBurnInReplacesTheExistingDestination") { try await $0.testSuccessfulBurnInReplacesTheExistingDestination() },
        ])
}
