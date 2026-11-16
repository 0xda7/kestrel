// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Per-task sandboxed workspace for a Merlin run.
///
/// Every filesystem tool resolves its paths through this type and this type
/// only: a tool call can never read or write outside the task's root
/// directory, no matter how the model phrases the path. Three rejections
/// enforce that, in order:
///
/// 1. Relative paths containing a `..` segment are refused outright — the
///    sandbox never walks upward, even when the walk would happen to stay
///    inside the workspace.
/// 2. Absolute paths are accepted only when they canonicalize to a location
///    inside the root, so a model may restate a path it was shown but may
///    not reach elsewhere on disk.
/// 3. Every resolved path is canonicalized with symlinks resolved and
///    re-checked against the root, so a symlink planted inside the
///    workspace cannot launder an outside target through an innocent-looking
///    relative path.
///
/// The root itself is canonicalized at construction (macOS resolves `/tmp`
/// to `/private/tmp`, and a naive prefix comparison against the non-canonical
/// form would misjudge every path). A `.merlin-lock` marker pins the
/// workspace to one task id: adopting a workspace locked by a different task
/// fails loudly instead of silently sharing state between runs.
public final class MerlinWorkspace: Sendable {
    public enum WorkspaceError: Error, Equatable, CustomStringConvertible {
        /// The path is empty or otherwise unusable as a workspace-relative
        /// path. This is a model argument problem, not an environment fault.
        case invalidPath(String)
        /// The path escapes the sandbox by traversal, absolute location, or
        /// symlink resolution.
        case escapesWorkspace(String)
        /// The root directory is already claimed by a different task id.
        case lockedBy(otherTask: String, taskID: String)

        public var description: String {
            switch self {
            case .invalidPath(let path):
                return "invalid workspace path: \(path.isEmpty ? "(empty)" : path)"
            case .escapesWorkspace(let path):
                return "path escapes the task workspace: \(path)"
            case .lockedBy(let otherTask, let taskID):
                return "workspace is locked by task \(otherTask), refusing adoption for task \(taskID)"
            }
        }
    }

    /// Canonical root directory of this task's sandbox.
    public let rootURL: URL
    /// Absolute path of `rootURL` after symlink resolution; the prefix every
    /// resolved path is checked against.
    public let rootPath: String
    public let taskID: String

    /// Default root for a task: `~/.kestrel/merlin/workspaces/<task-id>/`.
    public static func defaultRoot(taskID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kestrel", isDirectory: true)
            .appendingPathComponent("merlin", isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
    }

    /// Creates (or adopts) the workspace directory and takes its lock.
    /// `root` is canonicalized before use, so callers may pass a `/tmp`-style
    /// path that the system will resolve elsewhere on disk.
    public init(root: URL, taskID: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = Self.canonicalize(root)
        self.rootURL = canonical
        self.rootPath = canonical.path
        self.taskID = taskID

        let lockURL = canonical.appendingPathComponent(".merlin-lock")
        if let existing = try? String(contentsOf: lockURL, encoding: .utf8) {
            let owner = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !owner.isEmpty && owner != taskID {
                throw WorkspaceError.lockedBy(otherTask: owner, taskID: taskID)
            }
        } else {
            try "\(taskID)\n".write(to: lockURL, atomically: true, encoding: .utf8)
        }
    }

    /// Convenience constructor over `defaultRoot(taskID:)`.
    public convenience init(taskID: String) throws {
        try self.init(root: MerlinWorkspace.defaultRoot(taskID: taskID), taskID: taskID)
    }

    // MARK: - Resolution

    /// Canonicalizes a URL with `realpath(3)`, which resolves symlinked
    /// components INCLUDING a symlinked final component — the property
    /// `URL.resolvingSymlinksInPath` lacks, and the one a sandbox needs:
    /// `root/laundered → /outside` must resolve to `/outside`, not stay
    /// `root/laundered`. `realpath` fails when the path does not exist, so a
    /// not-yet-existing leaf falls back to its canonicalized parent plus the
    /// leaf name (the parent always exists or the resolution below fails
    /// first on containment).
    private static func canonicalize(_ url: URL) -> URL {
        // NULL second argument: realpath allocates the result buffer with
        // malloc and hands ownership back; we free it after copying the
        // string out. (Passing any pre-sized buffer is the classic heap
        // corruption this interop invites.)
        guard let resolved = realpath(url.path, nil) else {
            // The path (or an intermediate directory) does not exist yet.
            // URL.resolvingSymlinksInPath is useless here — it returns the
            // input unchanged on ENOENT, silently skipping the /var →
            // /private/var rewrite — so walk up to the nearest EXISTING
            // ancestor, realpath that, and re-append the unresolved suffix
            // to keep the full relative chain.
            var ancestor = url.deletingLastPathComponent()
            var suffix = [url.lastPathComponent]
            while ancestor.path != "/" && ancestor.path.count > 1
                    && realpath(ancestor.path, nil) == nil {
                suffix.insert(ancestor.lastPathComponent, at: 0)
                ancestor = ancestor.deletingLastPathComponent()
            }
            guard let resolvedAncestor = realpath(ancestor.path, nil) else {
                return url.standardizedFileURL
            }
            defer { free(resolvedAncestor) }
            var result = URL(fileURLWithPath: String(cString: resolvedAncestor))
            for segment in suffix {
                result.appendPathComponent(segment)
            }
            return result
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Resolves a model-supplied path to a concrete file URL inside the
    /// sandbox, or throws. The returned URL is canonical: symlinks in the
    /// existing prefix are resolved, so downstream tools can treat the result
    /// as ground truth without re-checking containment.
    public func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.invalidPath(path) }

        // Absolute paths: accepted only if they land inside the root once
        // canonicalized (symlinks included).
        if trimmed.hasPrefix("/") {
            let candidate = Self.canonicalize(URL(fileURLWithPath: trimmed))
            guard isInside(candidate) else { throw WorkspaceError.escapesWorkspace(path) }
            return candidate
        }

        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        if segments.isEmpty { return rootURL }
        if segments.contains("..") {
            throw WorkspaceError.escapesWorkspace("\(path) — '..' never resolves inside the sandbox")
        }

        var url = rootURL
        for segment in segments {
            url.appendPathComponent(segment)
        }
        let canonical = Self.canonicalize(url)
        guard isInside(canonical) else { throw WorkspaceError.escapesWorkspace(path) }
        return canonical
    }

    /// Resolve-and-prepare for a write: additionally creates intermediate
    /// directories (inside the sandbox only) and re-canonicalizes after
    /// creation, so a write can never materialize a path the read-side check
    /// would have rejected.
    public func resolveForWriting(_ path: String) throws -> URL {
        let url = try resolve(path)
        guard url.path != rootPath else { throw WorkspaceError.invalidPath(path) }
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let canonical = Self.canonicalize(url)
        guard isInside(canonical) else { throw WorkspaceError.escapesWorkspace(path) }
        return canonical
    }

    private func isInside(_ url: URL) -> Bool {
        url.path == rootPath || url.path.hasPrefix(rootPath + "/")
    }

    // MARK: - Seeding

    /// Lays down the task's initial files (relative path → text). Paths are
    /// written in sorted order so seeding is deterministic; returns the
    /// written paths in that order.
    @discardableResult
    public func seed(_ contents: [String: String]) throws -> [String] {
        var written: [String] = []
        for path in contents.keys.sorted() {
            let url = try resolveForWriting(path)
            try contents[path]?.write(to: url, atomically: true, encoding: .utf8)
            written.append(path)
        }
        return written
    }
}
