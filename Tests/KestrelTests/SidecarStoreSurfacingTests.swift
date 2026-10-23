// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
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

    /// Custody pin: the queue directory is created owner-only (0700), and a
    /// legacy-loose 0755 directory is tightened on resolve — the 0600
    /// payloads must not sit behind a world-readable folder.
    @MainActor func testQueueDirectoryIsCreatedOwnerOnlyAndTightened() throws {
        let base = try tempDirectory()
        let fm = FileManager.default
        let fresh = base.appendingPathComponent("memory-archive-hook", isDirectory: true)

        XCTAssertTrue(MemoryArchiveHook.ensureQueueDirectory(fresh))
        XCTAssertEqual(try fm.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? Int,
                       0o700, "the queue directory must be created owner-only (0700)")

        let legacy = base.appendingPathComponent("legacy-queue", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacy.path)
        XCTAssertTrue(MemoryArchiveHook.ensureQueueDirectory(legacy))
        XCTAssertEqual(try fm.attributesOfItem(atPath: legacy.path)[.posixPermissions] as? Int,
                       0o700, "a legacy 0755 queue directory is tightened to 0700, not left loose")
    }

    /// Hot-spin pin: a rejected payload whose queue file cannot be removed is
    /// skipped for the rest of the pass — the receiver sees it exactly once
    /// per pass, never a full-speed re-POST loop. The warning rides AppLog
    /// (not capturable in a check); the deterministic halves — one POST, file
    /// retained, one more POST on a later pass — are pinned here against a
    /// real loopback receiver answering 400.
    @MainActor func testRejectedDeliveryThatCannotBeRemovedIsPostedOncePerPass() async throws {
        guard AppSupport.directoryOverride != nil else {
            return XCTFail("ChecksMain must set AppSupport.directoryOverride before any check runs — without it the drain pass aims at the operator's live queue")
        }
        let fm = FileManager.default
        let queue = AppSupport.directory.appendingPathComponent("memory-archive-hook", isDirectory: true)
        // Earlier checks left queued fixtures in the per-run queue; this pass
        // must see exactly one pending event.
        for stale in MemoryArchiveHook.pending(in: queue) { try? fm.removeItem(at: stale) }

        let payload = MemoryArchiveHook.Payload(
            delivery_id: "drain-rej-\(UUID().uuidString)",
            sent_at: "2026-10-23T00:00:00Z",
            conversation: .init(id: "custody", title: "custody"),
            range: .init(from: 0, to: 1, note: "drain pin"),
            messages: [.init(index: 0, role: "user", content: "refuse me")])
        let file = queue.appendingPathComponent(
            String(format: "%013.0f-%@.json", 1.0, payload.delivery_id))
        try JSONEncoder().encode(payload).write(to: file)
        // The user-immutable flag makes unlink fail (EPERM) while the file
        // stays readable and POSTable — failure injection the queue
        // directory's own idempotent 0700 tighten cannot repair away (a
        // read-only directory would be chmod'd writable again mid-pass).
        try fm.setAttributes([.immutable: true], ofItemAtPath: file.path)

        let receiver = try LoopbackReceiver(status: 400)
        let hookKey = SettingsKeys.memoryArchiveHookURL
        let priorHook = UserDefaults.standard.string(forKey: hookKey)
        UserDefaults.standard.set("http://127.0.0.1:\(receiver.port)/hook", forKey: hookKey)
        defer {
            if let priorHook {
                UserDefaults.standard.set(priorHook, forKey: hookKey)
            } else {
                UserDefaults.standard.removeObject(forKey: hookKey)
            }
            receiver.stop()
            try? fm.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? fm.removeItem(at: file)
        }

        // A fresh instance: the pass under test owns its drain state, not
        // whatever a background resume() left running.
        let hook = MemoryArchiveHook()
        await hook.drain()
        XCTAssertEqual(receiver.requestCount, 1,
                       "the refused event is POSTed exactly once per pass — an undeletable file must not be respun at full speed")
        XCTAssertEqual(receiver.deliveries, [payload.delivery_id],
                       "the POST the receiver saw is the pinned payload")
        XCTAssertTrue(fm.fileExists(atPath: file.path),
                      "the undeletable rejected file stays queued — surfaced, never deleted")

        await hook.drain()
        XCTAssertEqual(receiver.requestCount, 2,
                       "a later pass attempts it exactly once more — the skip is per-pass, not a silent drop")
        XCTAssertTrue(fm.fileExists(atPath: file.path),
                      "the file survives every pass until it can be removed")
    }

    /// Custody pin: a genuine send() lands its durable queue file owner-only
    /// (0600) inside the per-run override — a full-turn body must never sit
    /// world-readable at the 0644 `.atomic` default.
    @MainActor func testQueuedDeliveryFileLandsOwnerOnly() throws {
        guard AppSupport.directoryOverride != nil else {
            return XCTFail("ChecksMain must set AppSupport.directoryOverride before any check runs — without it the durable queue write aims at the operator's live queue")
        }
        // Unbound loopback port: the drain retry backs off, re-checks the
        // key, finds it restored, and returns — no receiver is ever polled.
        let hookKey = SettingsKeys.memoryArchiveHookURL
        let priorHook = UserDefaults.standard.string(forKey: hookKey)
        UserDefaults.standard.set("http://127.0.0.1:1/hook", forKey: hookKey)
        let queue = AppSupport.directory.appendingPathComponent("memory-archive-hook", isDirectory: true)
        defer {
            if let priorHook {
                UserDefaults.standard.set(priorHook, forKey: hookKey)
            } else {
                UserDefaults.standard.removeObject(forKey: hookKey)
            }
            for stale in MemoryArchiveHook.pending(in: queue) {
                try? FileManager.default.removeItem(at: stale)
            }
        }

        MemoryArchiveHook.send(conversationID: "custody", title: "custody",
                               from: 0, to: 1, note: "owner-only pin",
                               messages: [(index: 0, role: "user", content: "fixture")])
        var landed: URL?
        let deadline = Date().addingTimeInterval(3)
        while landed == nil && Date() < deadline {
            landed = MemoryArchiveHook.pending(in: queue).last
            if landed == nil { Thread.sleep(forTimeInterval: 0.005) }
        }
        let file = try XCTUnwrap(landed, "the durable queue write must land inside the per-run override")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int,
                       0o600,
                       "a queued full-turn body must land owner-only (0600), never the 0644 `.atomic` default")
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

// MARK: - Loopback receiver (drain pins)

/// Minimal loopback HTTP responder for the drain pin: counts requests,
/// captures the X-Kestrel-Delivery header, and answers every request with
/// the configured status. Plain POSIX sockets because the hook posts via
/// URLSession.shared — a per-session URLProtocol stub cannot intercept it —
/// and 127.0.0.1 plain-http is the exemption MemoryArchiveHook.url itself
/// grants (no network exposure; nothing leaves the machine).
private final class LoopbackReceiver: @unchecked Sendable {
    private struct BindFailed: Error { let step: String }

    private let lock = NSLock()
    private var served: [(path: String, delivery: String?)] = []
    private let status: Int
    private let serverFD: Int32
    let port: UInt16

    init(status: Int) throws {
        self.status = status
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BindFailed(step: "socket") }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let binded = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard binded == 0 else { close(fd); throw BindFailed(step: "bind") }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0, bound.sin_port != 0 else { close(fd); throw BindFailed(step: "getsockname") }
        guard listen(fd, 8) == 0 else { close(fd); throw BindFailed(step: "listen") }
        port = UInt16(bigEndian: bound.sin_port)
        serverFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served.count
    }

    var deliveries: [String?] {
        lock.lock(); defer { lock.unlock() }
        return served.map(\.delivery)
    }

    func stop() { close(serverFD) }

    private func acceptLoop() {
        while true {
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else { return }   // stop() closed the listener
            respond(to: client)
        }
    }

    /// Reads one request (headers plus the Content-Length body), records it,
    /// and answers with the configured status on a closing connection.
    private func respond(to client: Int32) {
        var nosig: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var received = Data()
        var headerEnd: Int?
        var contentLength = 0
        var path = ""
        var delivery: String?
        while true {
            var chunk = [UInt8](repeating: 0, count: 16384)
            let n = recv(client, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            received.append(contentsOf: chunk[0..<n])
            if headerEnd == nil, let terminator = received.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = terminator.lowerBound
                var firstLine = true
                for line in String(decoding: received[0..<terminator.lowerBound], as: UTF8.self)
                    .components(separatedBy: "\r\n") {
                    if firstLine {
                        path = line.components(separatedBy: " ").dropFirst().first ?? ""
                        firstLine = false
                        continue
                    }
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        contentLength = Int(String(line.dropFirst("content-length:".count))
                            .trimmingCharacters(in: .whitespaces)) ?? 0
                    } else if lower.hasPrefix("x-kestrel-delivery:") {
                        delivery = String(line.dropFirst("x-kestrel-delivery:".count))
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            if let end = headerEnd, received.count - end >= contentLength + 4 { break }
        }
        lock.lock()
        served.append((path, delivery))
        lock.unlock()
        let response = "HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let bytes = Data(response.utf8)
        _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
        close(client)
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
            .init(name: "testQueueDirectoryIsCreatedOwnerOnlyAndTightened") { try $0.testQueueDirectoryIsCreatedOwnerOnlyAndTightened() },
            .init(name: "testRejectedDeliveryThatCannotBeRemovedIsPostedOncePerPass") { try await $0.testRejectedDeliveryThatCannotBeRemovedIsPostedOncePerPass() },
            .init(name: "testQueuedDeliveryFileLandsOwnerOnly") { try $0.testQueuedDeliveryFileLandsOwnerOnly() },
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
