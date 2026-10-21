// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission T2-3 chunk E: the census §2.8.3 Models-group silent catches are
/// surfaced. Pinned here: a healthy shard layout keeps its exact golden size
/// while an unreadable shard leaves the total unknown (never a wrong sum the
/// VRAM math trusts) with both failure kinds named (GGUFFile:72/:78), an
/// unenumerable inventory entry is skipped but named while the readable
/// entries survive (ModelFileIndex:37), an unreadable model size still counts
/// as 0 with the gap named (Models:39), an update check skipped by a failed
/// fetch/parse is distinguishable from a real no-update (ModelUpdates:24/:25),
/// the disk-space gate keeps its documented proceed-on-unknown direction
/// (Models:193), a blocked finalize names the destination it could not
/// replace (Models:329), a failed transfer close names the file at risk
/// (Models:131), and a failed projector lookup names the repo instead of
/// reading as "no projector" (Models:622/:623).
///
/// Honest limitations: the AppLog lines themselves are not observable
/// in-harness; each is pinned through the pure seam that assembles its
/// English line (the chunk C/D doctrine). The log-once cache-key failure
/// (GGUFMetadata:185) has no seam — its once-flag is private and its
/// behavior is otherwise identical — and is noted here instead of distorting
/// the code with a test-only logging seam. DownloadSink (private) and
/// finishTransfer's async routing are not harnessable without a real
/// transfer; their seams' value-level outcomes are pinned, and the
/// benign-absent-destination direction of Models:329 rides the
/// finalizeBlocked seam. The mmproj success path and the real no-update path
/// are untouched code and stay quiet by construction.
final class ModelScanSurfacingTests: CheckCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-scan-surfacing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - GGUFFile:72/:78 — shard sizes are exact, unknown, or named

    /// Golden: a healthy shard layout — shards plus an mmproj sibling and a
    /// non-GGUF file — must produce exactly the same byte total as before the
    /// conversion, for both shard parts and for a plain single file.
    func testHealthyShardLayoutKeepsItsExactTotalSize() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 11).write(to: dir.appendingPathComponent("split-00001-of-00002.gguf"))
        try Data(repeating: 2, count: 13).write(to: dir.appendingPathComponent("split-00002-of-00002.gguf"))
        try Data(repeating: 3, count: 7).write(to: dir.appendingPathComponent("solo-Q4_K_M.gguf"))
        try Data(repeating: 4, count: 5).write(to: dir.appendingPathComponent("mmproj-F16.gguf"))
        try Data(repeating: 5, count: 3).write(to: dir.appendingPathComponent("notes.txt"))

        let first = dir.appendingPathComponent("split-00001-of-00002.gguf").path
        let second = dir.appendingPathComponent("split-00002-of-00002.gguf").path
        XCTAssertEqual(GGUFFile.totalSize(at: first), 24,
                       "the sharded total must stay the exact byte sum")
        XCTAssertEqual(GGUFFile.totalSize(at: second), 24,
                       "the second shard must resolve to the same exact total")
        XCTAssertEqual(GGUFFile.totalSize(at: dir.appendingPathComponent("solo-Q4_K_M.gguf").path), 7,
                       "a single-file model keeps its exact size")
    }

    /// A shard whose size cannot be read (a dangling symlink stands in for a
    /// real read failure) must leave the total UNKNOWN — the incomplete set
    /// stays hidden, nil as before — never a partial sum the solver would
    /// trust, and never 0.
    func testUnreadableShardLeavesTheTotalUnknownInsteadOfAWrongSum() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("split-00001-of-00002.gguf")
        try Data(repeating: 1, count: 11).write(to: first)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("split-00002-of-00002.gguf").path,
            withDestinationPath: "gone-into-the-void.gguf")

        XCTAssertNil(GGUFFile.totalSize(at: first.path),
                     "an incomplete shard set must read as unknown, not as a partial or zero total")
    }

    /// The sibling-read failure is named: the line must identify the shard
    /// and say the total became unknown (the surfacing that used to vanish).
    func testShardSizeFailureNoticeNamesTheShardAndTheReason() {
        XCTAssertEqual(
            GGUFFile.shardSizeFailureNotice(shard: "split-00002-of-00002.gguf",
                                            reason: "No such file or directory"),
            "Could not read the size of shard split-00002-of-00002.gguf; it is excluded, so the model's total size stays unknown: No such file or directory",
            "the sibling-read failure must name the shard and the unknown-total outcome")
    }

    /// The directory-scan failure is its own named case, distinct from a
    /// sibling-read failure and from a healthy no-shards layout.
    func testShardScanFailureNoticeNamesTheDirectoryAndTheReason() {
        XCTAssertEqual(
            GGUFFile.shardScanFailureNotice(directory: "/models/big", reason: "Not a directory"),
            "Could not scan /models/big for the model's shards; its total size is unknown: Not a directory",
            "the scan failure must name the directory and the unknown-total outcome")
        XCTAssertNotEqual(
            GGUFFile.shardScanFailureNotice(directory: "/m", reason: "x"),
            GGUFFile.shardSizeFailureNotice(shard: "s", reason: "x"),
            "a failed scan and an unreadable shard must stay distinguishable")
    }

    // MARK: - ModelFileIndex:37 — an unenumerable entry is named, the rest survive

    /// A dangling symlink inside the models tree cannot have its resource
    /// values read. It must be skipped (as before) while the entries the
    /// index COULD read are still returned — one bad path must not take down
    /// the inventory.
    func testUnenumerableEntryIsSkippedButReadableEntriesSurvive() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real-model-Q4_K_M.gguf")
        try Data([1]).write(to: real)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("haunted-gguf.gguf").path,
            withDestinationPath: "void.gguf")

        let index = ModelFileIndex.scan(in: dir)
        XCTAssertEqual(index.file(named: "real-model-Q4_K_M.gguf")?.path, real.path,
                       "the readable entry must survive the unenumerable sibling")
        XCTAssertNil(index.file(named: "haunted-gguf.gguf"),
                     "the unreadable entry stays skipped, not fabricated")
    }

    /// The skip is named: the line must identify the path that could not be
    /// enumerated (the "model silently undiscovered" census worry).
    func testScanSkipNoticeNamesTheSkippedPath() {
        XCTAssertEqual(
            ModelFileIndex.scanSkipNotice(path: "/models/haunted-gguf.gguf",
                                          reason: "No such file or directory"),
            "Could not read /models/haunted-gguf.gguf while scanning the model folders; the entry is skipped and may stay undiscovered: No such file or directory",
            "the scan skip must name the path and the undiscovered risk")
    }

    // MARK: - Models:39 — an unreadable model size counts as 0, loudly

    /// The documented keep-0 decision: a file whose size cannot be read (here:
    /// a file that vanishes between the inventory scan and the size read — the
    /// real race the old try? covered) still yields its entry (0 bytes, the
    /// long-standing shape) while a healthy sibling keeps its true size — the
    /// scan survives, nothing is invented.
    func testUnreadableModelSizeStillCountsAsZeroAndSurvivesTheScan() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real-model-Q4_K_M.gguf")
        try Data(repeating: 1, count: 9).write(to: real)
        let vanished = dir.appendingPathComponent("vanished-model-Q4_K_M.gguf")
        try Data(repeating: 2, count: 5).write(to: vanished)
        let vanishedURL = vanished
        try FileManager.default.removeItem(at: vanished)

        let models = LocalModel.models(from: [real, vanishedURL])
        XCTAssertEqual(models.count, 2, "both entries keep their long-standing shapes")
        XCTAssertEqual(models.first { $0.name == real.lastPathComponent }?.sizeBytes, 9,
                       "the healthy file keeps its true size")
        XCTAssertEqual(models.first { $0.name == vanished.lastPathComponent }?.sizeBytes, 0,
                       "the unreadable size counts as 0 (documented), never invented")
    }

    /// The keep-0 has a name: the line must identify the file and say it
    /// counts as 0 until a scan reads it.
    func testModelSizeFailureNoticeNamesTheFileAndTheZero() {
        XCTAssertEqual(
            LocalModel.modelSizeFailureNotice(file: "ghost.gguf", reason: "Operation not permitted"),
            "Could not read the size of ghost.gguf; it counts as 0 bytes until a scan reads it: Operation not permitted",
            "the size failure must name the file and the 0-byte outcome")
    }

    // MARK: - ModelUpdates:24/:25 — a skipped update check is visible

    /// A failed tree fetch must name the repo and say the update check was
    /// skipped — distinct from a real no-update (which stays quiet).
    func testUpdateFetchFailureNoticeNamesTheSkippedUpdateCheck() {
        XCTAssertEqual(
            HuggingFaceAPI.updateFetchFailureNotice(repo: "ggml-org/vision", reason: "offline"),
            "Could not fetch the Hugging Face tree of ggml-org/vision; the update check for its files is skipped: offline",
            "a skipped update check must name the repo and the skip")
    }

    /// An unreadable tree response is its own case, distinct from a fetch
    /// failure — so a silently stalled check says which leg failed.
    func testUpdateParseFailureNoticeIsDistinctFromFetchFailure() {
        XCTAssertEqual(
            HuggingFaceAPI.updateParseFailureNotice(repo: "ggml-org/vision", reason: "bad json"),
            "Could not parse the Hugging Face tree response of ggml-org/vision; the update check for its files is skipped: bad json",
            "the parse failure must name the repo and the skip")
        XCTAssertNotEqual(
            HuggingFaceAPI.updateFetchFailureNotice(repo: "r", reason: "x"),
            HuggingFaceAPI.updateParseFailureNotice(repo: "r", reason: "x"),
            "fetch and parse failures must stay distinguishable")
    }

    // MARK: - Models:33/:411/:449/:494 — a folder that cannot be created is named

    /// All four directory-creation sites share one English line: it must name
    /// the purpose, the path, and the fact that the caller continues without
    /// it (the unchanged behavior).
    func testDirectoryCreationFailureNoticeNamesThePurposeAndDirectory() {
        XCTAssertEqual(
            ModelStore.directoryCreationFailureNotice(directory: "/models", purpose: "the models folder",
                                                      reason: "Read-only file system"),
            "Could not create the models folder at /models; continuing without it: Read-only file system",
            "the dir-create failure must name the purpose, the path, and the continue")
    }

    // MARK: - Models:193 — unknown capacity proceeds (the documented direction)

    /// A tight volume still blocks, naming the free space the failure message
    /// embeds (value unchanged from the pre-conversion gate).
    func testCapacityShortfallNamesTheFreeSpaceWhenTight() {
        let free = DownloadItem.capacityShortfall(available: 5_000_000_000, remaining: 4_500_000_000)
        XCTAssertEqual(free, 5_000_000_000,
                       "a genuinely short volume must still block and report its free space")
        XCTAssertNil(DownloadItem.capacityShortfall(available: 500_000_000_000, remaining: 10_000_000_000),
                     "plenty of space must not block")
    }

    /// The safe direction the conversion preserves: unknown capacity (0 —
    /// what a failed read or a foreign volume reports) must NOT read as
    /// "no space" and stall the download; the gate proceeds without a
    /// pre-check, and the skip is named in the log.
    func testUnknownCapacityProceedsWithoutThePreCheck() {
        XCTAssertNil(DownloadItem.capacityShortfall(available: 0, remaining: 10_000_000_000),
                     "unknown capacity must proceed (the documented exFAT behavior), never read as no-space")
        XCTAssertNil(DownloadItem.capacityShortfall(available: -1, remaining: 0),
                     "a nonsensical reading must not fabricate a block either")
    }

    // MARK: - Models:329 — a blocked finalize names the destination

    /// The finalize may only be blocked when a destination is actually
    /// present (the removal genuinely failed); an absent destination — the
    /// normal first download — stays benign even though the removal
    /// "failed" with no-such-file.
    func testFinalizeBlockerFiresOnlyWhenTheDestinationIsPresent() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [:])
        XCTAssertTrue(DownloadItem.finalizeBlocked(by: error, destinationExists: true),
                      "a removal failure with the old file still present must block the finalize")
        XCTAssertFalse(DownloadItem.finalizeBlocked(by: error, destinationExists: false),
                       "an absent destination is the normal first download and stays benign")
        XCTAssertFalse(DownloadItem.finalizeBlocked(by: nil as Error?, destinationExists: true),
                       "no removal failure must never block")
    }

    /// The block is named: the line must identify the file the download could
    /// not replace.
    func testFinalizeBlockerMessageNamesTheDestinationAndTheReason() {
        XCTAssertEqual(
            DownloadItem.finalizeBlockerMessage(destination: "model.gguf", reason: "locked"),
            "Could not replace the existing file model.gguf to finish the download: locked",
            "the finalize blocker must name the destination and the reason")
    }

    // MARK: - Models:131 — a failed transfer close is named

    /// The close is the download's results channel: its failure line must
    /// identify the file and the incomplete risk (surfaced via the existing
    /// .failed phase in finishTransfer).
    func testCloseFailureMessageNamesTheFileAndTheIncompleteRisk() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
                            userInfo: [NSLocalizedDescriptionKey: "No space left on device"])
        let message = DownloadItem.closeFailureMessage(error, fileName: "big-model.gguf")
        XCTAssertTrue(message.contains("big-model.gguf"),
                      "the close failure must name the file: \(message)")
        XCTAssertTrue(message.contains("may be incomplete"),
                      "the close failure must name the risk: \(message)")
        XCTAssertTrue(message.contains("No space left on device"),
                      "the close failure must carry the error: \(message)")
    }

    // MARK: - Models:622/:623 — a failed projector lookup is named

    /// A failed mmproj lookup must say that no projector will be auto-paired
    /// and name the repo — so vision availability is visible instead of
    /// reading as "this repo has no projector".
    func testProjectorLookupFailureNoticeNamesTheRepoAndTheSkip() {
        XCTAssertEqual(
            ModelStore.projectorLookupFailureNotice(repo: "ggml-org/vision", reason: "offline"),
            "Could not look up a vision projector in the ggml-org/vision repo; no projector will be auto-paired: offline",
            "the projector lookup failure must name the repo and the no-pairing outcome")
    }
}

// MARK: - Generated registration (port from XCTest)
extension ModelScanSurfacingTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ModelScanSurfacingTests",
        instance: { ModelScanSurfacingTests() },
        checks: [
            .init(name: "testCapacityShortfallNamesTheFreeSpaceWhenTight") { $0.testCapacityShortfallNamesTheFreeSpaceWhenTight() },
            .init(name: "testCloseFailureMessageNamesTheFileAndTheIncompleteRisk") { $0.testCloseFailureMessageNamesTheFileAndTheIncompleteRisk() },
            .init(name: "testDirectoryCreationFailureNoticeNamesThePurposeAndDirectory") { $0.testDirectoryCreationFailureNoticeNamesThePurposeAndDirectory() },
            .init(name: "testFinalizeBlockerFiresOnlyWhenTheDestinationIsPresent") { $0.testFinalizeBlockerFiresOnlyWhenTheDestinationIsPresent() },
            .init(name: "testFinalizeBlockerMessageNamesTheDestinationAndTheReason") { $0.testFinalizeBlockerMessageNamesTheDestinationAndTheReason() },
            .init(name: "testHealthyShardLayoutKeepsItsExactTotalSize") { try $0.testHealthyShardLayoutKeepsItsExactTotalSize() },
            .init(name: "testModelSizeFailureNoticeNamesTheFileAndTheZero") { $0.testModelSizeFailureNoticeNamesTheFileAndTheZero() },
            .init(name: "testProjectorLookupFailureNoticeNamesTheRepoAndTheSkip") { $0.testProjectorLookupFailureNoticeNamesTheRepoAndTheSkip() },
            .init(name: "testScanSkipNoticeNamesTheSkippedPath") { $0.testScanSkipNoticeNamesTheSkippedPath() },
            .init(name: "testShardScanFailureNoticeNamesTheDirectoryAndTheReason") { $0.testShardScanFailureNoticeNamesTheDirectoryAndTheReason() },
            .init(name: "testShardSizeFailureNoticeNamesTheShardAndTheReason") { $0.testShardSizeFailureNoticeNamesTheShardAndTheReason() },
            .init(name: "testUnenumerableEntryIsSkippedButReadableEntriesSurvive") { try $0.testUnenumerableEntryIsSkippedButReadableEntriesSurvive() },
            .init(name: "testUnknownCapacityProceedsWithoutThePreCheck") { $0.testUnknownCapacityProceedsWithoutThePreCheck() },
            .init(name: "testUnreadableModelSizeStillCountsAsZeroAndSurvivesTheScan") { try $0.testUnreadableModelSizeStillCountsAsZeroAndSurvivesTheScan() },
            .init(name: "testUnreadableShardLeavesTheTotalUnknownInsteadOfAWrongSum") { try $0.testUnreadableShardLeavesTheTotalUnknownInsteadOfAWrongSum() },
            .init(name: "testUpdateFetchFailureNoticeNamesTheSkippedUpdateCheck") { $0.testUpdateFetchFailureNoticeNamesTheSkippedUpdateCheck() },
            .init(name: "testUpdateParseFailureNoticeIsDistinctFromFetchFailure") { $0.testUpdateParseFailureNoticeIsDistinctFromFetchFailure() },
        ])
}
