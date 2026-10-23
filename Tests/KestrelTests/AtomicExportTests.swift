// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Guardian slice (2026-10-23): every save-panel export is atomic — the
/// payload lands in a staging file beside the destination and only then
/// swaps in via FileManager.replaceItemAt, so a failed write leaves the
/// operator's existing file byte-identical (the class of loss commit
/// f436aef closed for the Markdown export). Pinned here: the
/// AtomicFileSave mechanics (a failed copy or a failed swap keeps the
/// original byte-identical and surfaces SaveError naming the destination;
/// a successful copy replaces it; an absent destination is created), and
/// the wiring of all four call sites — ImageGenTab's two save panels,
/// VideoGen's writeMP4, and the subtitle burn-in — which must
/// stage-then-commit and never remove the destination first.
final class AtomicExportTests: CheckCase {
    private let previous = Data("the operator's previous export — must survive".utf8)

    /// This suite lives in Tests/KestrelTests/, so the repo root is three
    /// components up from #filePath.
    private func repoSource(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The body of a member from its signature to the next member (or the
    /// type's closing brace). The harness renders no SwiftUI, so view
    /// wiring is pinned by reading the source — the doctrine of
    /// testChatErrorTextIsCopyable.
    private func member(_ source: String, from marker: String) -> Substring {
        guard let start = source.range(of: marker) else { return Substring() }
        let rest = source[start.lowerBound...]
        var end = rest.endIndex
        for closer in ["\n    private func ", "\n    private static func ",
                       "\n    private var ", "\n    @ViewBuilder ", "\n    // MARK", "\n}"] {
            if let r = rest.range(of: closer), r.lowerBound < end { end = r.lowerBound }
        }
        return rest[..<end]
    }

    /// A destination folder that is read-only and already holds the
    /// operator's previous export at `dest`: any write attempt is forced
    /// to fail while the original stays observable. Callers restore the
    /// permissions in their own defer.
    private func protectedDestination(name: String) throws -> (dir: URL, dest: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try previous.write(to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        return (dir, dest)
    }

    private func restore(_ dir: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func stagingLitter(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter {
            $0.hasPrefix(".kestrel-stage-")
        } ?? ["<unreadable>"]
    }

    // MARK: - the surfaced failure names the destination

    /// SaveError reads exactly failureMessage: the destination path is
    /// named, the message states the original survived, and the line is
    /// English-only (product doctrine).
    func testSaveErrorNamesTheDestinationAndTheUntouchedFile() {
        let message = AtomicFileSave.SaveError(
            destinationPath: "/tmp/kestrel/scene.png", reason: "not permitted"
        ).localizedDescription
        XCTAssertEqual(
            message,
            AtomicFileSave.failureMessage(destinationPath: "/tmp/kestrel/scene.png",
                                          reason: "not permitted"),
            "SaveError surfaces exactly the pinned failure message")
        XCTAssertTrue(message.contains("/tmp/kestrel/scene.png"),
                      "the destination path is named: \(message)")
        XCTAssertTrue(message.contains("left unchanged"),
                      "the message states the original survived: \(message)")
        XCTAssertTrue(message.allSatisfy { $0.isASCII },
                      "product doctrine: new user-facing strings are English-only")
    }

    // MARK: - AtomicFileSave.copy — the image save panels' path

    /// A copy that cannot land (read-only folder holding the operator's
    /// previous export) throws SaveError naming the destination, leaves
    /// the existing file byte-identical, and leaves no staging litter.
    func testFailedCopyToAProtectedDestinationKeepsTheOriginalByteIdentical() throws {
        let (dir, dest) = try protectedDestination(name: "scene.png")
        defer { restore(dir) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-atomic-source-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("fresh export".utf8).write(to: source)

        XCTAssertThrowsError(try AtomicFileSave.copy(from: source, to: dest)) { error in
            guard let save = error as? AtomicFileSave.SaveError else {
                return XCTFail("a failed copy must throw SaveError, got \(error)")
            }
            XCTAssertEqual(save.destinationPath, dest.path,
                           "the surfaced failure names the destination")
            XCTAssertTrue(save.localizedDescription.contains(dest.path),
                          "the alert text names the destination: \(save.localizedDescription)")
        }
        XCTAssertEqual(try Data(contentsOf: dest), previous,
                       "the operator's pre-existing file is byte-identical")
        XCTAssertTrue(stagingLitter(in: dir).isEmpty,
                      "a failed copy leaves no staging file behind")
    }

    /// A successful copy replaces an existing destination with the
    /// source's bytes — one atomic swap, never remove-then-copy.
    func testSuccessfulCopyReplacesTheExistingDestination() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-atomic-replace-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: dest) }
        try previous.write(to: dest)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-atomic-fresh-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        let fresh = Data("fresh export".utf8)
        try fresh.write(to: source)

        try AtomicFileSave.copy(from: source, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), fresh,
                       "a successful copy swaps the destination to the fresh bytes")
    }

    // MARK: - AtomicFileSave.commit — the writers' swap

    /// The normal first save: no destination yet, so the commit is one
    /// moveItem rename that creates it.
    func testCommitToAnAbsentDestinationCreatesTheFile() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-atomic-first-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: dest) }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-atomic-stage-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        let payload = Data("fully-written export".utf8)
        try payload.write(to: staged)

        try AtomicFileSave.commit(staged, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), payload,
                       "the first save lands through the rename")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                       "the staging file is consumed by the swap")
    }

    /// A swap that cannot land (read-only folder holding the operator's
    /// previous export) throws SaveError naming the destination and
    /// leaves the existing file byte-identical. Staging cleanup is
    /// best-effort by design — a read-only folder cannot be tidied — and
    /// is pinned in the writable-directory case below.
    func testFailedCommitKeepsTheOriginalByteIdentical() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-atomic-commit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("captioned.mov")
        try previous.write(to: dest)
        // Stage the payload while the folder is still writable, then lock
        // it down so only the swap is forced to fail.
        let staged = dir.appendingPathComponent(".kestrel-stage-test.tmp")
        try Data("fresh export".utf8).write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { restore(dir) }

        XCTAssertThrowsError(try AtomicFileSave.commit(staged, to: dest)) { error in
            guard let save = error as? AtomicFileSave.SaveError else {
                return XCTFail("a failed swap must throw SaveError, got \(error)")
            }
            XCTAssertEqual(save.destinationPath, dest.path,
                           "the surfaced failure names the destination")
        }
        XCTAssertEqual(try Data(contentsOf: dest), previous,
                       "the operator's pre-existing file is byte-identical")
    }

    /// A swap that fails in a writable folder (no staging file to swap —
    /// the writer never produced one) still names the destination and
    /// tidies after itself.
    func testFailedCommitInAWritableFolderDiscardsTheStagingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-atomic-writable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("captioned.mov")
        try previous.write(to: dest)
        let neverStaged = dir.appendingPathComponent(".kestrel-stage-never.tmp")

        XCTAssertThrowsError(try AtomicFileSave.commit(neverStaged, to: dest)) { error in
            guard let save = error as? AtomicFileSave.SaveError else {
                return XCTFail("a failed swap must throw SaveError, got \(error)")
            }
            XCTAssertEqual(save.destinationPath, dest.path,
                           "the surfaced failure names the destination")
        }
        XCTAssertEqual(try Data(contentsOf: dest), previous,
                       "the operator's pre-existing file is byte-identical")
        XCTAssertTrue(stagingLitter(in: dir).isEmpty,
                      "a failed swap in a writable folder leaves no staging litter")
    }

    // MARK: - the four call sites' wiring

    /// Both ImageGenTab save panels ride the staged copy and surface its
    /// failure through the alert — the remove-then-copy pair and its
    /// silent try?s must never return.
    func testImageSavePanelsStageAndCommitInsteadOfRemoveThenCopy() throws {
        let source = try repoSource("Sources/Images/ImageGenTab.swift")
        for marker in ["private func save(_ g: GeneratedImage)",
                       "private func saveAs(_ source: URL, format: ImageFormat)"] {
            let body = member(source, from: marker)
            XCTAssertFalse(body.isEmpty, "member must exist: \(marker)")
            XCTAssertTrue(body.contains("AtomicFileSave.copy(from:"),
                          "\(marker) must copy through the staging swap")
            XCTAssertTrue(body.contains("showImageSaveFailure(error)"),
                          "\(marker) must alert on failure instead of the old try? silence")
            XCTAssertFalse(body.contains("removeItem"),
                          "\(marker) must never remove the destination first")
            XCTAssertFalse(body.contains("try?"),
                           "\(marker) must not swallow the copy's outcome")
        }
    }

    /// writeMP4 writes the encode to a staging file beside the destination
    /// and commits the swap at the end — the remove-first unlink is gone.
    func testWriteMP4StagesAndCommitsInsteadOfRemoveFirst() throws {
        let source = try repoSource("Sources/Video/VideoGen.swift")
        let body = member(source, from: "static func writeMP4")
        XCTAssertFalse(body.isEmpty, "writeMP4 must exist in VideoGen.swift")
        XCTAssertTrue(body.contains("AtomicFileSave.stagingURL(beside: url)"),
                      "the encode targets a staging file beside the destination")
        XCTAssertTrue(body.contains("AtomicFileSave.commit(staged, to: url)"),
                      "only a completed export is swapped in")
        XCTAssertFalse(body.contains("removeItem"),
                       "writeMP4 must never remove the destination first")
        let encode = member(source, from: "private static func encode(")
        XCTAssertTrue(encode.contains("AVAssetWriter(outputURL: staged"),
                      "the writer itself targets the staging file")
    }

    /// The subtitle burn-in exports to a staging file beside the
    /// destination and commits the swap on completion — the silent
    /// removeItem try? is gone.
    func testSubtitleBurnInStagesAndCommitsInsteadOfRemoveFirst() throws {
        let source = try repoSource("Sources/Subtitles/SubtitleVideoExporter.swift")
        let body = member(source, from: "private func performExport")
        XCTAssertFalse(body.isEmpty, "performExport must exist in SubtitleVideoExporter.swift")
        XCTAssertTrue(body.contains("AtomicFileSave.stagingURL(beside: outputURL)"),
                      "the burn-in writes beside the destination, never at it")
        XCTAssertTrue(body.contains("export.outputURL = staged"),
                      "the export session targets the staging file")
        XCTAssertTrue(body.contains("AtomicFileSave.commit(staged, to: outputURL)"),
                      "only a completed export is swapped in")
        XCTAssertFalse(body.contains("removeItem(at: outputURL)"),
                       "the destination must never be removed first")
    }
}

// MARK: - Generated registration (port from XCTest)
extension AtomicExportTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "AtomicExportTests",
        instance: { AtomicExportTests() },
        checks: [
            .init(name: "testSaveErrorNamesTheDestinationAndTheUntouchedFile") { $0.testSaveErrorNamesTheDestinationAndTheUntouchedFile() },
            .init(name: "testFailedCopyToAProtectedDestinationKeepsTheOriginalByteIdentical") { try $0.testFailedCopyToAProtectedDestinationKeepsTheOriginalByteIdentical() },
            .init(name: "testSuccessfulCopyReplacesTheExistingDestination") { try $0.testSuccessfulCopyReplacesTheExistingDestination() },
            .init(name: "testCommitToAnAbsentDestinationCreatesTheFile") { try $0.testCommitToAnAbsentDestinationCreatesTheFile() },
            .init(name: "testFailedCommitKeepsTheOriginalByteIdentical") { try $0.testFailedCommitKeepsTheOriginalByteIdentical() },
            .init(name: "testFailedCommitInAWritableFolderDiscardsTheStagingFile") { try $0.testFailedCommitInAWritableFolderDiscardsTheStagingFile() },
            .init(name: "testImageSavePanelsStageAndCommitInsteadOfRemoveThenCopy") { try $0.testImageSavePanelsStageAndCommitInsteadOfRemoveThenCopy() },
            .init(name: "testWriteMP4StagesAndCommitsInsteadOfRemoveFirst") { try $0.testWriteMP4StagesAndCommitsInsteadOfRemoveFirst() },
            .init(name: "testSubtitleBurnInStagesAndCommitsInsteadOfRemoveFirst") { try $0.testSubtitleBurnInStagesAndCommitsInsteadOfRemoveFirst() },
        ])
}
