// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// Zero-dependency check harness. Replaces XCTest so the suite runs on bare
// Command Line Tools (`swift run kestrel-checks`) — no Xcode required. The
// assert functions deliberately keep the XCTest names and signatures so test
// bodies port without touching their call sites.

import Foundation
@testable import KestrelCore
// MARK: - Recorder

/// Collects failures across all checks. Process-global because the assert
/// functions are free functions that must report from anywhere.
final class CheckRecorder: @unchecked Sendable {
    static let shared = CheckRecorder()
    private let lock = NSLock()
    private(set) var failures: [String] = []
    private(set) var checksRun = 0
    var currentCheck = ""

    func record(_ message: String) {
        lock.lock()
        failures.append("[\(currentCheck)] \(message)")
        lock.unlock()
    }
    func begin() {
        lock.lock()
        checksRun += 1
        lock.unlock()
    }
}

// MARK: - Case base

/// Base class for check suites. Test classes keep their structure
/// (`final class FooTests: CheckCase { func testBar() {...} }`); each file
/// appends one `__checkSet` registration listing its test methods.
class CheckCase {
    /// Runs before each check when the suite overrides it.
    func setUpWithError() throws {}
    /// Runs after each check when the suite overrides it.
    func tearDownWithError() throws {}
    /// XCTest-spelling aliases, honored in the same order XCTest ran them.
    func setUp() {}
    func tearDown() {}
    init() {}

    // MARK: Expectations (XCTest-shape stand-ins)

    func expectation(description: String) -> CheckExpectation {
        CheckExpectation(description: description)
    }

    func wait(for expectations: [CheckExpectation], timeout seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if expectations.allSatisfy(\.isFulfilled) { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

/// XCTestExpectation stand-in: fulfill() from any thread, polled by wait(for:).
final class CheckExpectation: @unchecked Sendable {
    private let lock = NSLock()
    private var fulfilled = false
    let description: String
    init(description: String) { self.description = description }
    func fulfill() {
        lock.lock()
        fulfilled = true
        lock.unlock()
    }
    var isFulfilled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fulfilled
    }
}

// MARK: - Check sets

struct CheckSet: @unchecked Sendable {
    /// An erased check: the body always receives the concrete instance.
    struct Check {
        let name: String
        let body: @MainActor (CheckCase) async throws -> Void
    }

    let suite: String
    let instance: () -> CheckCase
    let checks: [Check]

    /// Typed element the generated registrations build: bodies take the
    /// CONCRETE suite type, so `$0.testWhatever()` resolves and a method
    /// missing from its __checkSet is a compile error, never a silent drop.
    struct TypedCheck<T: CheckCase> {
        let name: String
        let body: @MainActor (T) async throws -> Void
    }

    init<T: CheckCase>(suite: String, instance: @escaping () -> T,
                       checks: [TypedCheck<T>]) {
        self.suite = suite
        self.instance = instance
        self.checks = checks.map { typed in
            Check(name: typed.name, body: { erased in try await typed.body(erased as! T) })
        }
    }
}

// MARK: - Asserts (XCTest-compatible names)

private func fail(_ file: StaticString, _ line: UInt, _ message: String) {
    CheckRecorder.shared.record("\(message) (file: \(file), line: \(line))")
}

func XCTFail(_ message: @autoclosure () -> String = "",
             file: StaticString = #filePath, line: UInt = #line) {
    fail(file, line, "XCTFail failed: \(message())")
}

func XCTAssertEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T,
                                  _ expression2: @autoclosure () throws -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try expression1(), try expression2())
        if a != b { fail(file, line, "XCTAssertEqual failed: \"\(a)\" is not equal to \"\(b)\" \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertEqual<T: FloatingPoint>(_ expression1: @autoclosure () throws -> T,
                                      _ expression2: @autoclosure () throws -> T,
                                      accuracy: T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try expression1(), try expression2())
        if abs(a - b) > accuracy {
            fail(file, line, "XCTAssertEqual failed: \"\(a)\" is not within \(accuracy) of \"\(b)\" \(message())")
        }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertNotEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T,
                                     _ expression2: @autoclosure () throws -> T,
                                     _ message: @autoclosure () -> String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try expression1(), try expression2())
        if a == b { fail(file, line, "XCTAssertNotEqual failed: \"\(a)\" is equal to \"\(b)\" \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool,
                   _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() != true { fail(file, line, "XCTAssertTrue failed \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() != false { fail(file, line, "XCTAssertFalse failed \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        if let value = try expression() { fail(file, line, "XCTAssertNil failed: \"\(value)\" \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertNotNil<T>(_ expression: @autoclosure () throws -> T?,
                        _ message: @autoclosure () -> String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() == nil { fail(file, line, "XCTAssertNotNil failed \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertGreaterThan<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                         _ expression2: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try expression1(), try expression2())
        if a <= b { fail(file, line, "XCTAssertGreaterThan failed: \"\(a)\" is not greater than \"\(b)\" \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                                _ expression2: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try expression1(), try expression2())
        if a < b { fail(file, line, "XCTAssertGreaterThanOrEqual failed: \"\(a)\" is less than \"\(b)\" \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertLessThan<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                      _ expression2: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try expression1(), try expression2())
        if a >= b { fail(file, line, "XCTAssertLessThan failed: \"\(a)\" is not less than \"\(b)\" \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                             _ expression2: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try expression1(), try expression2())
        if a > b { fail(file, line, "XCTAssertLessThanOrEqual failed: \"\(a)\" is greater than \"\(b)\" \(message())") }
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
    }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                             _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line,
                             _ errorHandler: (any Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        fail(file, line, "XCTAssertThrowsError failed: did not throw an error \(message())")
    } catch {
        errorHandler(error)
    }
}

/// Thrown by XCTUnwrap after the failure is recorded: aborts the check
/// without double-reporting (the runner recognizes it).
struct CheckAbort: Error {}

/// Thrown via `throw XCTSkip(...)`: the runner prints the check as skipped
/// and it counts as neither run nor failed.
struct CheckSkipped: Error {
    let reason: String
}

func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
    do {
        guard let value = try expression() else {
            fail(file, line, "XCTUnwrap failed: nil \(message())")
            throw CheckAbort()
        }
        return value
    } catch let error as CheckAbort {
        throw error
    } catch {
        fail(file, line, "threw error \"\(error)\" \(message())")
        throw CheckAbort()
    }
}

func XCTSkip(_ message: @autoclosure () -> String = "",
             file: StaticString = #filePath, line: UInt = #line) -> CheckSkipped {
    _ = file; _ = line
    return CheckSkipped(reason: message())
}

// MARK: - Runner

/// Per-check watchdog: a hung check kills the run with a loud exit instead of
/// a silent CI stall. Disarming bumps a generation counter that the armed
/// thread observes, so a stale thread can never fire on a later check.
private final class Watchdog {
    private let lock = NSLock()
    private var generation = 0

    func arm(_ name: String, seconds: Double = 120) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        let deadline = Date().addingTimeInterval(seconds)
        let t = Thread {
            while Date() < deadline {
                self.lock.lock()
                let current = self.generation
                self.lock.unlock()
                if current != gen { return }
                Thread.sleep(forTimeInterval: 1)
            }
            self.lock.lock()
            let stillArmed = self.generation == gen
            self.lock.unlock()
            guard stillArmed else { return }
            FileHandle.standardError.write(Data("HANG: check '\(name)' exceeded \(Int(seconds))s — exiting 3\n".utf8))
            exit(3)
        }
        t.name = "check-watchdog"
        t.start()
    }
    func disarm() {
        lock.lock()
        generation += 1
        lock.unlock()
    }
}

/// The operator's REAL Kestrel paths. Isolation pins read live bytes before
/// and after a check's exercise to prove the suite changed nothing — that is
/// the only permitted use. No check may use these paths to arrange or clean
/// up state; arrangement belongs under the per-run overrides set in ChecksMain.
enum CheckLivePaths {
    static let kestrelDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kestrel", isDirectory: true)

    static var conversationsJSON: URL { kestrelDirectory.appendingPathComponent("conversations.json") }
    static var slotsDirectory: URL { kestrelDirectory.appendingPathComponent("slots", isDirectory: true) }
    static var toolTemplatesDirectory: URL { kestrelDirectory.appendingPathComponent("tool-templates", isDirectory: true) }
    static var secretsDirectory: URL { kestrelDirectory.appendingPathComponent("secrets", isDirectory: true) }
    static var audioRecoveryJSON: URL { kestrelDirectory.appendingPathComponent("AudioRecovery.json") }
    static var logsDirectory: URL { kestrelDirectory.appendingPathComponent("logs", isDirectory: true) }
    static var memoryArchiveQueueDirectory: URL { kestrelDirectory.appendingPathComponent("memory-archive-hook", isDirectory: true) }
    static var dynamicMoeDirectory: URL { kestrelDirectory.appendingPathComponent("dynamic-moe", isDirectory: true) }
    static var promptLibraryJSON: URL { kestrelDirectory.appendingPathComponent("prompt-library.json") }
    static var enginePID: URL { kestrelDirectory.appendingPathComponent("engine.pid") }
}

@MainActor @main
struct ChecksMain {
    static func main() async {
        // One store directory per run: no check may touch the operator's
        // live chat history, KV slots, derived tool templates, secrets, or
        // audio recovery project. On 2026-10-21 the suite leaked 106 fixture
        // chats ("importado"/"Pregunta") into the live conversations.json,
        // and the orphan pruner in ChatStore.init could delete live slot
        // files the same way — both only possible because checks ran against
        // the real store paths.
        ChatStore.storeDirectoryOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-checks-\(UUID().uuidString)", isDirectory: true)
        EngineToolTemplate.directoryOverride = ChatStore.storeDirectoryOverride
        // Same doctrine for the remaining live-data writers: the local
        // secret store (engine/provider keys, archive token), the
        // audio-studio recovery project, the router preset folder (a
        // check building router argv resolves and creates it), and every
        // AppSupport-rooted store — the rotating server logs and their
        // retention prune, the engine PID lockfile, the memory-archive
        // delivery queue, the dynamic-MoE profiles, and the prompt
        // library — ride the per-run directory too, so no sentinel,
        // restore dance, or prune can ever reach the live files.
        LocalSecretStore.directoryOverride = ChatStore.storeDirectoryOverride
        ServerSettings.routerDirectoryOverride = ChatStore.storeDirectoryOverride
        AudioStudioController.recoveryURLOverride = ChatStore.storeDirectoryOverride?
            .appendingPathComponent("AudioRecovery.json")
        AppSupport.directoryOverride = ChatStore.storeDirectoryOverride
        // The keychain is live operator data too (and a check reading a
        // legacy item created by an older build could raise the ACL
        // password dialog mid-run): with itemsOverride set, every Keychain
        // get/set/delete/exists resolves against this dictionary, so
        // migration checks can seed legacy items and prove they survive a
        // failed secret-store write without ever touching the real one.
        Keychain.itemsOverride = [:]
        let registry: [(String, CheckSet)] = Self.generatedRegistry()
        let watchdog = Watchdog()
        var failed = 0
        for (suiteName, set) in registry {
            for check in set.checks {
                let label = "\(suiteName).\(check.name)"
                FileHandle.standardError.write(Data("start \(label)\n".utf8))
                CheckRecorder.shared.currentCheck = label
                CheckRecorder.shared.begin()
                watchdog.arm(label)
                let instance = set.instance()
                do {
                    instance.setUp()
                    try await instance.setUpWithError()
                    try await check.body(instance)
                    try await instance.tearDownWithError()
                    instance.tearDown()
                } catch let skipped as CheckSkipped {
                    watchdog.disarm()
                    print("skip \(label) (\(skipped.reason))")
                    continue
                } catch is CheckAbort {
                    // Failure already recorded at the assert site.
                } catch {
                    CheckRecorder.shared.record("threw \(error)")
                }
                watchdog.disarm()
                let failures = CheckRecorder.shared.failures.count
                if failures > failed {
                    print("FAIL \(label)")
                    for message in CheckRecorder.shared.failures.suffix(failures - failed) {
                        print("     \(message)")
                    }
                    failed = failures
                } else {
                    print("ok   \(label)")
                }
            }
        }
        let run = CheckRecorder.shared.checksRun
        print("\nExecuted \(run) check\(run == 1 ? "" : "s"), \(CheckRecorder.shared.failures.count) failure\(CheckRecorder.shared.failures.count == 1 ? "" : "s")")
        exit(CheckRecorder.shared.failures.isEmpty ? 0 : 1)
    }

    /// Generated by the port script: every suite with its fresh-instance
    /// factory, in deterministic file order.
    static func generatedRegistry() -> [(String, CheckSet)] { CheckRegistry.generated }
}
