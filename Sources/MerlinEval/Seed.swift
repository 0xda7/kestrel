// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit

/// Per-task fresh sandbox: `~/.kestrel/merlin-eval/runs/<ts>/<task-id>/`.
///
/// Seeding (TASKS.md §2: fresh dir, seeded before turn 1) and immutable-seed
/// bookkeeping (SCORING.md §1: SHA-256 at boot, re-verified at scoring, any
/// drift fails the task outright) both live here so the hash evidence can be
/// embedded in `report.json`.
struct EvalWorkspace {
    /// Canonical absolute root of this task's sandbox.
    let rootURL: URL
    let rootPath: String
    let taskID: String
    /// relative path → SHA-256 hex digest, captured at boot.
    let bootHashes: [String: String]
    /// The run directory that contains this task dir (`.../<ts>/`).
    let runRootURL: URL

    // MARK: - Construction

    /// Creates the run root `<runsRoot>/<timestamp>/` and returns it. When
    /// the timestamp directory already exists (two invocations within the
    /// same second — the batch case), a `-N` suffix is appended until the
    /// path is fresh, so back-to-back runs never collide.
    static func makeRunRoot(runsRoot: URL, timestamp: String) throws -> URL {
        var candidate = runsRoot.appendingPathComponent(timestamp, isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            suffix += 1
            candidate = runsRoot.appendingPathComponent("\(timestamp)-\(suffix)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    /// Creates a fresh sandbox for `task`, writes its seed files, and hashes
    /// its immutable seeds. Any pre-existing directory at that path is a
    /// harness bug (fresh run roots are timestamped); refuse loudly rather
    /// than run against stale state.
    static func seed(task: TaskSpec, runRoot: URL) throws -> EvalWorkspace {
        let taskDir = runRoot.appendingPathComponent(task.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: taskDir.path) {
            throw EvalFatalError(message: "workspace for \(task.id) already exists at \(taskDir.path) — run roots must be fresh")
        }
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let canonicalURL = taskDir.resolvingSymlinksInPath()
        let canonical = canonicalURL.path

        for seed in task.seedFiles.sorted(by: { $0.path < $1.path }) {
            let target = try EvalWorkspace.resolvedPath(canonical, seed.path, forWriting: true)
            let parent = target.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try seed.content.write(to: target, atomically: true, encoding: .utf8)
        }

        var hashes: [String: String] = [:]
        for path in task.immutableSeeds {
            hashes[path] = try Self.hashFile(root: canonical, relativePath: path)
        }

        return EvalWorkspace(rootURL: canonicalURL,
                             rootPath: canonical,
                             taskID: task.id,
                             bootHashes: hashes,
                             runRootURL: runRoot)
    }

    // MARK: - Path confinement

    /// Resolves a workspace-relative path the way every harness-side file
    /// operation must: refused when empty, absolute, or containing a `..`
    /// segment; canonicalized (symlinks resolved) so a planted link cannot
    /// launder an outside target; re-checked against the root afterward.
    func resolve(_ relativePath: String, forWriting: Bool = false) throws -> URL {
        try Self.resolvedPath(rootPath, relativePath, forWriting: forWriting)
    }

    static func resolvedPath(_ rootPath: String, _ relativePath: String, forWriting: Bool) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty path means the workspace root itself (list/grep "." or ""),
        // mirroring the kernel's MerlinWorkspace semantics.
        guard !trimmed.isEmpty else {
            return URL(fileURLWithPath: rootPath, isDirectory: true)
        }
        guard !trimmed.hasPrefix("/") else {
            throw EvalFatalError(message: "path must be workspace-relative: \(relativePath)")
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else {
            return URL(fileURLWithPath: rootPath, isDirectory: true)
        }
        guard !segments.contains(".") && !segments.contains("..") else {
            throw EvalFatalError(message: "path must stay inside the workspace: \(relativePath)")
        }
        var url = URL(fileURLWithPath: rootPath, isDirectory: true)
        for segment in segments {
            url.appendPathComponent(segment)
        }
        let canonical = url.resolvingSymlinksInPath()
        guard canonical.path == rootPath || canonical.path.hasPrefix(rootPath + "/") else {
            throw EvalFatalError(message: "path escapes the workspace: \(relativePath)")
        }
        if forWriting {
            let parent = canonical.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
        }
        return canonical
    }

    // MARK: - Immutable seeds

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of one file under the workspace, or an error naming the
    /// missing path (a deleted immutable seed is drift).
    static func hashFile(root: String, relativePath: String) throws -> String {
        let url = try resolvedPath(root, relativePath, forWriting: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvalFatalError(message: "immutable seed missing at boot: \(relativePath)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EvalFatalError(message: "cannot read \(relativePath) for hashing: \(error)")
        }
        return sha256Hex(of: data)
    }

    /// The relative paths hashed at boot, in stable (sorted) order.
    var hashedSeedPaths: [String] { bootHashes.keys.sorted() }

    enum SeedVerdict: Equatable {
        case intact
        case drifted(path: String, bootHash: String, currentHash: String)
        case missing(path: String, bootHash: String)
    }

    /// Re-verifies every immutable seed against its boot hash (the boot hash
    /// dictionary keys are the recorded list). One drifted or missing file
    /// fails the whole task (SCORING.md §1).
    func verifySeeds() -> [SeedVerdict] {
        hashedSeedPaths.map { path in
            let bootHash = bootHashes[path] ?? "(unrecorded)"
            let url = try? resolve(path)
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                return .missing(path: path, bootHash: bootHash)
            }
            let current = (try? Data(contentsOf: url)).map(Self.sha256Hex(of:))
            guard let current else {
                return .missing(path: path, bootHash: bootHash)
            }
            return current == bootHash ? .intact : .drifted(path: path, bootHash: bootHash, currentHash: current)
        }
    }
}

// MARK: - Stored property note
//
// TaskSpec is deliberately not stored on EvalWorkspace: the workspace is a
// filesystem-scoped handle and outlives scoring scope. `verifySeeds()` reads
// the recorded list from its own boot-hash dictionary, which is the hash
// evidence report.json embeds.
