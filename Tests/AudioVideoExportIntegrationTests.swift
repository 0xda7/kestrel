// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
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
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }
}

// MARK: - Generated registration (port from XCTest)
extension AudioVideoExportIntegrationTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "AudioVideoExportIntegrationTests",
        instance: { AudioVideoExportIntegrationTests() },
        checks: [
            .init(name: "testCaptionedVideoExportWhenFixtureIsProvided") { await try $0.testCaptionedVideoExportWhenFixtureIsProvided() },
        ])
}
