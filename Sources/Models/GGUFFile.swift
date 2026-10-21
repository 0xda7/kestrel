// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

struct GGUFFileEntry: Sendable {
    let path: String
    let sizeBytes: Int64
}

struct GGUFModelFiles: Sendable {
    let primaryPath: String
    let sizeBytes: Int64
    let paths: [String]
}

enum GGUFFile {
    private struct Shard {
        let index: Int
        let total: Int
        let groupKey: String
    }

    private static let shardRegex = NSRegularExpression.literal(
        pattern: #"-(\d{5})-of-(\d{5})(?=\.gguf$)"#,
        options: [.caseInsensitive]
    )

    static func models(from entries: [GGUFFileEntry]) -> [GGUFModelFiles] {
        var singles: [GGUFModelFiles] = []
        var shards: [String: [(entry: GGUFFileEntry, shard: Shard)]] = [:]

        for entry in entries where isModelFile(entry.path) {
            guard let shard = shardInfo(entry.path) else {
                singles.append(GGUFModelFiles(
                    primaryPath: entry.path,
                    sizeBytes: entry.sizeBytes,
                    paths: [entry.path]
                ))
                continue
            }
            shards[shard.groupKey, default: []].append((entry, shard))
        }

        for group in shards.values {
            guard let first = group.first,
                  group.count == first.shard.total,
                  Set(group.map { $0.shard.index }) == Set(1...first.shard.total),
                  group.allSatisfy({ $0.shard.total == first.shard.total }),
                  let primary = group.first(where: { $0.shard.index == 1 }) else { continue }
            let ordered = group.sorted { $0.shard.index < $1.shard.index }
            singles.append(GGUFModelFiles(
                primaryPath: primary.entry.path,
                sizeBytes: ordered.reduce(0) { $0 + $1.entry.sizeBytes },
                paths: ordered.map { $0.entry.path }
            ))
        }

        return singles
    }

    /// Total bytes of a model, including every sibling shard when `path` is the
    /// first `-00001-of-N` file. Falls back to the single file for normal GGUFs.
    /// Census W8 GGUFFile:72/:78 (T2-3 chunk E): a shard directory that cannot
    /// be scanned, or a sibling whose size cannot be read, used to make the
    /// sharded model silently vanish (nil) with no trace. The callers' existing
    /// contract is kept — nil means "size unknown" and the ctx solver treats it
    /// as such, never as a trusted 0 — while both failures now surface through
    /// AppLog. A healthy layout produces byte-identical sizes as before.
    static func totalSize(at path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if shardInfo(url.path) == nil {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
            return size
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: url.deletingLastPathComponent(),
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles])
        } catch {
            let notice = Self.shardScanFailureNotice(
                directory: url.deletingLastPathComponent().path,
                reason: error.localizedDescription)
            AppLog.app.error("\(notice, privacy: .public)")
            return nil
        }
        var entries: [GGUFFileEntry] = []
        for file in files {
            guard file.pathExtension.lowercased() == "gguf" else { continue }
            let size: Int?
            do {
                size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            } catch {
                let notice = Self.shardSizeFailureNotice(
                    shard: file.lastPathComponent, reason: error.localizedDescription)
                AppLog.app.error("\(notice, privacy: .public)")
                continue
            }
            guard let size else {
                let notice = Self.shardSizeFailureNotice(
                    shard: file.lastPathComponent, reason: "the file reported no size")
                AppLog.app.error("\(notice, privacy: .public)")
                continue
            }
            entries.append(GGUFFileEntry(path: file.standardizedFileURL.path, sizeBytes: Int64(size)))
        }
        if let model = models(from: entries).first(where: {
            $0.primaryPath == url.path || $0.paths.contains(url.path)
        }) {
            return UInt64(max(0, model.sizeBytes))
        }
        return nil
    }

    /// Census W8 GGUFFile:72 (T2-3 chunk E): the English line for a shard
    /// directory that could not be scanned — the model size becomes unknown
    /// (nil, which callers already treat as unknown), never a trusted 0. Pure
    /// so checks can pin how a failed scan is distinguished from a healthy
    /// "no shards" layout (D3).
    static func shardScanFailureNotice(directory: String, reason: String) -> String {
        "Could not scan \(directory) for the model's shards; its total size is unknown: \(reason)"
    }

    /// Census W8 GGUFFile:78 (T2-3 chunk E): the English line for a shard whose
    /// size could not be read. The shard stays excluded — an incomplete shard
    /// set must not sum to a quietly wrong total the VRAM math trusts — but the
    /// exclusion is named. Pure so checks can pin it (D3).
    static func shardSizeFailureNotice(shard: String, reason: String) -> String {
        "Could not read the size of shard \(shard); it is excluded, so the model's total size stays unknown: \(reason)"
    }

    static func isProjector(_ path: String) -> Bool {
        path.lowercased().contains("mmproj")
    }

    /// A DFlash, DSpark or MTP speculative-decoding draft. DSpark is DFlash with
    /// `dsv4_hc_mult > 0`, so the architecture catches it, but not if the header
    /// cannot be read.
    static func isDraft(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name.contains("dflash") || name.contains("dspark")
            || name.hasPrefix("mtp-") || name.hasSuffix(".mtp.gguf")
            || name.contains("-mtp-") || name.hasSuffix("-mtp.gguf") {
            return true
        }
        // A head packaged under its own name only differs from a model in the header: it
        // borrows the target's embeddings and output instead of carrying its own.
        if GGUFMetadataCache.metadata(at: path)?.string(for: "nextn_shared_target_tensors") != nil {
            return true
        }
        // Drafts ship under many names, so the name alone lets them into the picker.
        // The architecture is what says it is one.
        return GGUFMetadataCache.metadata(at: path)?.string(for: "general.architecture") == "dflash"
    }

    private static func isModelFile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "gguf"
            && !isProjector(path) && !isDraft(path)
    }

    private static func shardInfo(_ path: String) -> Shard? {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = shardRegex.firstMatch(in: path, range: range),
              let matchRange = Range(match.range, in: path),
              let indexRange = Range(match.range(at: 1), in: path),
              let totalRange = Range(match.range(at: 2), in: path),
              let index = Int(path[indexRange]),
              let total = Int(path[totalRange]), total > 1 else { return nil }
        var groupKey = path
        groupKey.removeSubrange(matchRange)
        return Shard(index: index, total: total, groupKey: groupKey)
    }
}
