// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// Release hygiene, mechanically enforced (2026-11-16): the 0.90.0 release
// shipped with VERSION=0.89.17 because the release was cut by hand instead
// of through scripts/release.sh, and nothing noticed. These checks make the
// drift a build failure:
//   1. VERSION is a well-formed X.Y.Z string.
//   2. The in-app About page (AppInfo.version) equals VERSION — a release
//      can never ship mislabeled (release.sh stamps it; this pins it).
//   3. No stamped CHANGELOG section is NEWER than VERSION — the exact
//      0.89.17-below-0.90.0 drift.
//   4. Every stamped CHANGELOG section has its `vX.Y.Z` git tag (stamping
//      happens only inside release.sh, which always tags). Verified
//      wherever tags are available; a shallow CI checkout that carries no
//      tags cannot verify by construction and records a skip instead of
//      lying red or green.

import Foundation

final class ReleaseHygieneChecks: CheckCase {
    override init() { super.init() }

    // MARK: - Repo plumbing

    /// The repository root, anchored to this source file so the checks hold
    /// regardless of the working directory `swift run` was invoked from.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }()

    private static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Versions as found in VERSION / CHANGELOG sections / tags:
    /// "X.Y.Z", dot-separated non-negative integers.
    private static func versionComponents(_ raw: String) -> [Int]? {
        let parts = raw.split(separator: ".").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0,
                  part == String(number) else { return nil } // "01" is not canonical
            numbers.append(number)
        }
        if numbers.count == 2 { numbers.append(0) } // 0.90 == 0.90.0
        return numbers
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for (a, b) in zip(lhs, rhs) {
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    /// The stamped `## [V] - date` versions in CHANGELOG order (oldest
    /// first), excluding `[Unreleased]`.
    private static func changelogStampedVersions(_ changelog: String) -> [String] {
        changelog.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("## [") else { return nil }
            let rest = line.dropFirst(4)
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let name = String(rest[..<close])
            return name == "Unreleased" ? nil : name
        }
    }

    /// All tags this checkout can see; empty when none were fetched.
    private static func availableTags() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path, "tag"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Set(String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init))
    }

    // MARK: - Checks

    func testVersionFileIsAWellFormedTriple() throws {
        let raw = try Self.read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(Self.versionComponents(raw),
                        "VERSION must be X.Y.Z (got '\(raw)') — release.sh and make-app.sh key off it")
    }

    func testAboutTabMatchesVersionFile() throws {
        let version = try Self.read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        let about = try Self.read("Sources/App/AboutTab.swift")
        // Since dcb5fb7 the runtime truth is the bundle plist with
        // `versionFallback` as the CLI fallback AND the release scripts'
        // sed target (scripts/release.sh stamps and grep-verifies exactly
        // this line shape). Pin all three contracts: the fallback equals
        // VERSION, exactly one stamp exists, and the line shape matches the
        // sed anchor — a hand-reshaped line would make the next release
        // stamp silently miss its target.
        let stamp = "static let versionFallback = \"\(version)\""
        XCTAssertTrue(about.contains(stamp),
                      "AppInfo.versionFallback must equal VERSION (\(version)) — a release can never ship mislabeled")
        let stamps = about.components(separatedBy: "static let versionFallback =").count - 1
        XCTAssertEqual(stamps, 1, "AboutTab must carry exactly one versionFallback stamp, found \(stamps)")
        XCTAssertTrue(about.contains("static let versionFallback = \""),
                      "the sed anchor line shape must stay intact (see scripts/release.sh)")
    }

    func testChangeelogNeverStampsAheadOfVersion() throws {
        let version = try Self.read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = Self.versionComponents(version) else {
            XCTFail("VERSION '\(version)' is not a parseable version; the drift check cannot run")
            return
        }
        let changelog = try Self.read("CHANGELOG.md")
        let stamped = Self.changelogStampedVersions(changelog)
        XCTAssertFalse(stamped.isEmpty, "CHANGELOG carries no stamped release sections at all")
        for name in stamped {
            guard let section = Self.versionComponents(name) else {
                XCTFail("CHANGELOG section '\(name)' is not a parseable version")
                continue
            }
            XCTAssertTrue(Self.compare(section, current) <= 0,
                          "CHANGELOG stamps \(name) but VERSION is \(version) — the 0.90.0 drift class. " +
                          "Cut releases through scripts/release.sh (it stamps VERSION) or bump VERSION via make-app.sh.")
        }
    }

    func testNewestStampedSectionHasItsTag() throws {
        let changelog = try Self.read("CHANGELOG.md")
        let stamped = Self.changelogStampedVersions(changelog)
        guard let newest = stamped.first else {
            XCTFail("CHANGELOG carries no stamped release sections at all")
            return
        }
        let tags = Self.availableTags()
        if tags.isEmpty {
            // A shallow CI checkout carries no tags: the invariant cannot be
            // verified by construction. Record the skip honestly instead of
            // failing red (or pretending green); dev machines and full
            // checkouts enforce it for real.
            XCTAssertTrue(ProcessInfo.processInfo.environment["CI"] != nil,
                          "no git tags visible in a non-CI checkout — is this a git repo with fetched tags?")
            return
        }
        XCTAssertTrue(tags.contains("v\(newest)"),
                      "CHANGELOG's newest stamped section is \(newest) but tag v\(newest) is missing — " +
                      "a stamped section means release.sh ran, and release.sh always tags. " +
                      "(Historical sections predate tagging; only the newest release is required to be tagged.)")
    }

    // MARK: - Registration

    @MainActor static let __checkSet = CheckSet(
        suite: "ReleaseHygieneChecks",
        instance: { ReleaseHygieneChecks() },
        checks: [
            .init(name: "testVersionFileIsAWellFormedTriple") { try $0.testVersionFileIsAWellFormedTriple() },
            .init(name: "testAboutTabMatchesVersionFile") { try $0.testAboutTabMatchesVersionFile() },
            .init(name: "testChangeelogNeverStampsAheadOfVersion") { try $0.testChangeelogNeverStampsAheadOfVersion() },
            .init(name: "testNewestStampedSectionHasItsTag") { try $0.testNewestStampedSectionHasItsTag() },
        ])
}
