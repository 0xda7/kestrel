// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The structured memory of a Merlin run (M2 + M3).
///
/// A run's ground truth lives here and only here: an append-only JSONL
/// ledger whose entries carry a turn number, an entry kind, and a text
/// payload. The file on disk is the durable record; the in-memory copy is a
/// projection of it. Nothing is ever mutated or removed after the fact —
/// corrections are appended as new entries, which keeps the run auditable
/// after the fact and makes digest generation a pure function of the entry
/// list.
///
/// `@unchecked Sendable`: the class is shared across the kernel loop and the
/// tool handlers (which run in `@Sendable` closures), and every access to
/// the in-memory entry list — reads included — goes through one serial
/// queue, so the unchecked conformance is honest.
public final class MerlinLedger: @unchecked Sendable {
    /// The kinds of entries the kernel and its tools write.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        /// A fact learned from the workspace or a tool result.
        case fact
        /// A decision about how the task will proceed.
        case decision
        /// Something currently preventing progress.
        case blocker
        /// A file the task produced (key = its workspace path).
        case artifact
        /// The summarized outcome of one tool call or turn.
        case result
    }

    /// One append-only ledger entry.
    public struct Entry: Equatable, Codable, Sendable {
        /// The task-spine turn the entry was written in (0 = pre-loop setup).
        public let turn: Int
        public let kind: Kind
        /// Optional short key (an artifact path, a memory key) for grouping.
        public let key: String?
        public let text: String

        public init(turn: Int, kind: Kind, key: String? = nil, text: String) {
            self.turn = turn
            self.kind = kind
            self.key = key
            self.text = text
        }

        enum CodingKeys: String, CodingKey {
            case turn, kind, key, text
        }
    }

    /// Decode failure for one line of the ledger file.
    public struct LedgerError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Reserved file name at the workspace root. `fs_*` tools refuse direct
    /// access so the memory of the run cannot be corrupted through the very
    /// tools the model drives.
    public static let fileName = "merlin-ledger.jsonl"
    /// Renderer used by the digest for the "results" section.
    public static let digestResultCount = 3

    /// The JSONL file backing this ledger.
    public let url: URL
    private let queue = DispatchQueue(label: "northlatchlabs.kestrel.merlin.ledger")
    private var entries: [Entry] = []

    /// Creates a ledger over `url`, loading any existing JSONL content.
    /// Used with a fresh workspace path at run start; loading existing bytes
    /// keeps `task_done`-time digest and CLI re-render correct across
    /// process restarts.
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            entries = try Self.parse(data: try Data(contentsOf: url))
        }
    }

    // MARK: - Appending

    /// Appends one entry to the in-memory list and flushes it to disk.
    /// Disk append is atomic per entry; the ledger is the run's only
    /// structured state, so a crash may lose the final entry but never
    /// corrupt earlier ones.
    public func append(turn: Int, kind: Kind, key: String? = nil, text: String) throws {
        let entry = Entry(turn: turn, kind: kind, key: key, text: text)
        let line = try Self.encodeLine(entry)
        try queue.sync {
            entries.append(entry)
            let folder = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                try line.write(to: url, atomically: true, encoding: .utf8)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            }
        }
    }

    /// All entries, oldest first.
    public var allEntries: [Entry] { queue.sync { entries } }

    // MARK: - Parsing / encoding (pure, deterministic)

    /// Parses JSONL bytes into entries. Deterministic: line order is entry
    /// order; a malformed line is a hard error because a torn ledger would
    /// otherwise silently rewrite the run's history.
    public static func parse(data: Data) throws -> [Entry] {
        let decoded = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var result: [Entry] = []
        for (index, rawLine) in decoded.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            do {
                result.append(try decodeLine(line))
            } catch {
                throw LedgerError(description: "ledger line \(index + 1) is not a valid entry: \(error)")
            }
        }
        return result
    }

    private static func decodeLine(_ line: String) throws -> Entry {
        guard let data = line.data(using: .utf8) else {
            throw LedgerError(description: "line is not UTF-8")
        }
        let decoder = JSONDecoder()
        return try decoder.decode(Entry.self, from: data)
    }

    /// One entry as a single JSON line ending in `\n`.
    public static func encodeLine(_ entry: Entry) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        guard let line = String(data: data, encoding: .utf8) else {
            throw LedgerError(description: "encoded entry is not UTF-8")
        }
        return line + "\n"
    }

    // MARK: - State digest (M0's injected payload)

    /// The ≤`maxLines`-line state digest re-injected every turn: the goal,
    /// open blockers, the last few results, and the artifact list, in that
    /// order. Pure and deterministic — same entries in, same bytes out — so
    /// it can be pinned by checks and its line count is the context budget
    /// the task spine promises the model.
    public static func digest(goal: String, entries: [Entry], maxLines: Int = 24) -> String {
        var lines: [String] = []
        lines.append("GOAL: \(goal)")

        let blockers = entries.filter { $0.kind == .blocker }
        if blockers.isEmpty {
            lines.append("BLOCKERS: none")
        } else {
            lines.append("BLOCKERS:")
            for entry in blockers.suffix(max(0, maxLines - lines.count - 1)) {
                lines.append("- \(digestLine(entry))")
            }
        }

        let results = entries.filter { $0.kind == .result }.suffix(digestResultCount)
        if results.isEmpty {
            lines.append("RECENT RESULTS: none yet")
        } else {
            lines.append("RECENT RESULTS:")
            for entry in results {
                lines.append("- \(digestLine(entry))")
            }
        }

        let artifacts = entries.filter { $0.kind == .artifact }
        if artifacts.isEmpty {
            lines.append("ARTIFACTS: none yet")
        } else {
            lines.append("ARTIFACTS:")
            for entry in artifacts.suffix(max(0, maxLines - lines.count - 1)) {
                lines.append("- \(digestLine(entry))")
            }
        }

        if maxLines > 0 && lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
        }
        return lines.joined(separator: "\n")
    }

    /// One entry rendered as a digest bullet: `key: text` with whitespace
    /// collapsed and text truncated, so a bloated tool result can never blow
    /// the digest's line budget.
    public static func digestLine(_ entry: Entry) -> String {
        let collapsed = entry.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let keyPrefix = entry.key.map { "\($0): " } ?? ""
        let rendered = "\(keyPrefix)\(collapsed)"
        return rendered.count > 160 ? rendered.prefix(157) + "…" : rendered
    }

    /// Convenience: the digest for this ledger's entries.
    public func digest(goal: String, maxLines: Int = 24) -> String {
        Self.digest(goal: goal, entries: queue.sync { entries }, maxLines: maxLines)
    }
}
