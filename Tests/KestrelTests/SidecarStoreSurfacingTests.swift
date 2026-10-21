// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission T2-1 chunk D: the sidecar-store silent catches (durable memory
/// archive queue, prompt library, skills discovery, inference routes) are
/// surfaced failures now. The surfacing itself rides AppLog, which is not
/// capturable in a check, so each pin asserts the deterministic file/key
/// state the surfaced failure leaves behind.
final class SidecarStoreSurfacingTests: CheckCase {
    // MARK: - MemoryArchiveHook dead-letter (census W8 :135/:136/:113/:44)

    /// An unreadable queue file is moved to `<name>.dead` — never deleted —
    /// and the drain list ignores dead letters.
    func testUnreadableQueueFileIsQuarantinedNotDeleted() throws {
        let dir = try tempDirectory()
        let file = dir.appendingPathComponent("0001-ABC.json")
        let original = Data("the durable event's bytes".utf8)
        try original.write(to: file)

        XCTAssertTrue(MemoryArchiveHook.quarantineUnreadable(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the unreadable file must not stay in the drain list")
        let dead = file.appendingPathExtension("dead")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dead.path),
                      "the event is dead-lettered, not destroyed")
        XCTAssertEqual(try Data(contentsOf: dead), original,
                       "the durable event's bytes survive in the dead-letter file")
        XCTAssertEqual(MemoryArchiveHook.pending(in: dir), [],
                       "a dead letter is never re-drunk")
    }

    /// Healthy .json files still list next to dead letters, and a file
    /// recorded as skipped ends the drain pass instead of spinning forever.
    func testHealthyQueueFilesStillListAndSkippedFilesEndThePass() throws {
        let dir = try tempDirectory()
        let healthy = dir.appendingPathComponent("0002-DEF.json")
        try Data("{}".utf8).write(to: healthy)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("0001-ABC.json.dead"))

        // Compare by name: contentsOfDirectory resolves /var → /private/var,
        // so full-URL equality against the unresolved temp path would lie.
        let listed = MemoryArchiveHook.pending(in: dir)
        XCTAssertEqual(listed.map(\.lastPathComponent), ["0002-DEF.json"],
                       "only .json deliveries drain; the dead letter is invisible")
        XCTAssertEqual(MemoryArchiveHook.nextPending(in: dir, skipping: [])?.lastPathComponent,
                       "0002-DEF.json")
        XCTAssertNil(MemoryArchiveHook.nextPending(in: dir, skipping: Set(listed)),
                     "an immovable file recorded as skipped terminates the pass")
    }

    /// When even the move-aside fails, the durable file is left in place —
    /// surfaced, never deleted.
    func testImmovableQueueFileIsLeftInPlace() throws {
        let dir = try tempDirectory()
        let file = dir.appendingPathComponent("0003-GHI.json")
        try Data("{}".utf8).write(to: file)
        let fm = FileManager.default
        // A read-only queue directory cannot accept the move-aside.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        XCTAssertFalse(MemoryArchiveHook.quarantineUnreadable(file),
                       "a failed move must be reported so the file is skipped, not deleted")
        XCTAssertTrue(fm.fileExists(atPath: file.path),
                      "the durable file is never deleted, even when it cannot be moved")
    }

    /// A queue directory that cannot be created is reported (the check drives
    /// the same seam the computed property uses).
    func testQueueDirectoryCreationFailureIsReportedNotSilent() throws {
        let dir = try tempDirectory()
        let blocked = dir.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: blocked)

        XCTAssertFalse(MemoryArchiveHook.ensureQueueDirectory(blocked),
                       "creating under a regular file cannot succeed and must say so")
        XCTAssertTrue(MemoryArchiveHook.ensureQueueDirectory(dir),
                      "an existing directory is a no-op success")
    }

    // MARK: - PromptLibrary corrupt recovery (census W8 :93/:94)

    /// A corrupt library is moved aside before the reseed can overwrite it:
    /// the user's original bytes stay recoverable next to the store.
    func testCorruptPromptLibraryIsPreservedAndReseeded() throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("prompt-library.json")
        let original = Data("[{ this is not valid json".utf8)
        try original.write(to: url)

        let loaded = PromptLibrary.load(from: url)
        XCTAssertEqual(loaded, PromptLibrary.seedTemplates,
                       "a corrupt store reseeds the defaults")
        let aside = url.appendingPathExtension("unreadable")
        XCTAssertEqual(try Data(contentsOf: aside), original,
                       "the user's original bytes are recoverable next to the store")
        do {
            _ = try JSONDecoder().decode([PromptTemplate].self, from: Data(contentsOf: url))
        } catch {
            XCTFail("the reseeded store is healthy again: \(error)")
        }
    }

    /// A file that exists but cannot be READ serves seeds in memory and is
    /// left untouched — one bad read must never destroy the library.
    func testUnreadablePromptLibraryIsServedInMemoryAndUntouched() throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("prompt-library.json")
        let original = Data("[]".utf8)
        try original.write(to: url)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let loaded = PromptLibrary.load(from: url)
        XCTAssertEqual(loaded, PromptLibrary.seedTemplates)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original,
                       "the read failure must not overwrite or move the file")
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathExtension("unreadable").path),
                       "no recovery marker: the file itself is intact")
    }

    /// A missing file is the benign first run: seeds, saved, no marker.
    func testMissingPromptLibrarySeedsSilently() throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("prompt-library.json")

        XCTAssertEqual(PromptLibrary.load(from: url), PromptLibrary.seedTemplates)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "first run seeds and persists the defaults")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
    }

    /// The healthy round trip is byte-stable through the same seams.
    func testPromptLibrarySaveRoundTrips() throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("prompt-library.json")
        let templates = [PromptTemplate(name: "mía", body: "hola {{name}}")]

        PromptLibrary.save(templates, to: url)
        XCTAssertEqual(PromptLibrary.load(from: url), templates)
    }

    // MARK: - InferenceRoutes decode preservation (census W8 :61)

    /// An undecodable routes payload reads empty AND is preserved under the
    /// sibling key, so the next save cannot silently destroy the config.
    func testUndecodableRoutesArePreservedAndReadEmpty() {
        let suite = "t21-sidecar-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("[{\"dialect\":\"nope\"}".utf8)
        defaults.set(original, forKey: InferenceRoutes.storageKey)

        XCTAssertEqual(InferenceRoutes.load(from: defaults), [],
                       "an undecodable payload reads empty (typed settings IO)")
        XCTAssertEqual(defaults.data(forKey: InferenceRoutes.unreadableKey), original,
                       "the undecodable payload is preserved for recovery")
    }

    /// The healthy typed round trip is unchanged.
    func testHealthyRoutesRoundTripThroughTypedIO() {
        let suite = "t21-sidecar-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = InferenceRoute(name: "prueba", dialect: .anthropic,
                                   baseURL: "https://api.example.com",
                                   modelID: "claude-x", maxTokensCap: nil)

        InferenceRoutes.save([route], defaults: defaults)
        XCTAssertEqual(InferenceRoutes.load(from: defaults), [route])
        XCTAssertNil(defaults.data(forKey: InferenceRoutes.unreadableKey))
    }

    // MARK: - Anthropic args parse surfacing (census W8 :299)

    /// Benign defaults stay silent and empty; a real payload parses through.
    func testAnthropicInputBenignDefaultsStaySilentAndHealthyArgsParse() {
        XCTAssertEqual(RouteWire.parsedAnthropicInput("", tool: "t") as? [String: String], [:])
        XCTAssertEqual(RouteWire.parsedAnthropicInput("{}", tool: "t") as? [String: String], [:])
        let parsed = RouteWire.parsedAnthropicInput(#"{"path":"a.txt"}"#, tool: "t")
        XCTAssertEqual(parsed["path"] as? String, "a.txt")
    }

    /// A non-empty payload that does not parse into a JSON object still sends
    /// an empty input (the turn survives the wire seam) — this pin holds the
    /// deterministic half of the contract.
    func testAnthropicInputUnparseablePayloadFallsBackToEmpty() {
        for broken in ["not json {", "[1, 2]", #""0.9""#] {
            XCTAssertEqual(RouteWire.parsedAnthropicInput(broken, tool: "t") as? [String: String], [:],
                           "\(broken) must not crash the wire transform")
        }
    }

    // MARK: - SkillsDiscovery surfacing (census W8 :56/:64)

    /// A SKILL.md that exists but cannot be read is skipped while healthy
    /// skills still scan; a folder without SKILL.md is simply not a skill.
    func testUnreadableSkillIsSkippedWhileHealthySkillsScan() throws {
        let root = try tempDirectory()
        let fm = FileManager.default
        let good = root.appendingPathComponent("good")
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        try "---\nname: goodone\ndescription: healthy\n---\nBody\n"
            .write(to: good.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let broken = root.appendingPathComponent("broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        let brokenSkill = broken.appendingPathComponent("SKILL.md")
        try "---\nname: brokenone\n---\n".write(to: brokenSkill, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: brokenSkill.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: brokenSkill.path) }
        let notASkill = root.appendingPathComponent("notaskill")
        try fm.createDirectory(at: notASkill, withIntermediateDirectories: true)

        var seen = Set<String>()
        let skills = SkillsDiscovery.scan(root: root.path, seenNames: &seen)
        XCTAssertEqual(skills.map(\.name), ["goodone"],
                       "the unreadable skill is surfaced and skipped; the healthy one scans")
    }

    /// A missing discovery root is a normal empty scan — silent, no error.
    func testMissingRootScansEmptyWithoutError() {
        var seen = Set<String>()
        XCTAssertEqual(SkillsDiscovery.scan(root: "/nonexistent-t21/none", seenNames: &seen), [])
    }

    // MARK: - Helpers

    /// Resolves symlinks (/var → /private/var) so URLs built here match what
    /// contentsOfDirectory hands back.
    private func tempDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("t21-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Generated registration (port from XCTest)
extension SidecarStoreSurfacingTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SidecarStoreSurfacingTests",
        instance: { SidecarStoreSurfacingTests() },
        checks: [
            .init(name: "testUnreadableQueueFileIsQuarantinedNotDeleted") { try $0.testUnreadableQueueFileIsQuarantinedNotDeleted() },
            .init(name: "testHealthyQueueFilesStillListAndSkippedFilesEndThePass") { try $0.testHealthyQueueFilesStillListAndSkippedFilesEndThePass() },
            .init(name: "testImmovableQueueFileIsLeftInPlace") { try $0.testImmovableQueueFileIsLeftInPlace() },
            .init(name: "testQueueDirectoryCreationFailureIsReportedNotSilent") { try $0.testQueueDirectoryCreationFailureIsReportedNotSilent() },
            .init(name: "testCorruptPromptLibraryIsPreservedAndReseeded") { try $0.testCorruptPromptLibraryIsPreservedAndReseeded() },
            .init(name: "testUnreadablePromptLibraryIsServedInMemoryAndUntouched") { try $0.testUnreadablePromptLibraryIsServedInMemoryAndUntouched() },
            .init(name: "testMissingPromptLibrarySeedsSilently") { try $0.testMissingPromptLibrarySeedsSilently() },
            .init(name: "testPromptLibrarySaveRoundTrips") { try $0.testPromptLibrarySaveRoundTrips() },
            .init(name: "testUndecodableRoutesArePreservedAndReadEmpty") { $0.testUndecodableRoutesArePreservedAndReadEmpty() },
            .init(name: "testHealthyRoutesRoundTripThroughTypedIO") { $0.testHealthyRoutesRoundTripThroughTypedIO() },
            .init(name: "testAnthropicInputBenignDefaultsStaySilentAndHealthyArgsParse") { $0.testAnthropicInputBenignDefaultsStaySilentAndHealthyArgsParse() },
            .init(name: "testAnthropicInputUnparseablePayloadFallsBackToEmpty") { $0.testAnthropicInputUnparseablePayloadFallsBackToEmpty() },
            .init(name: "testUnreadableSkillIsSkippedWhileHealthySkillsScan") { try $0.testUnreadableSkillIsSkippedWhileHealthySkillsScan() },
            .init(name: "testMissingRootScansEmptyWithoutError") { $0.testMissingRootScansEmptyWithoutError() },
        ])
}
