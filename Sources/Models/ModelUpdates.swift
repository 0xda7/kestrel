// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

struct HFFileMetadata {
    let sha256: String?
    let sizeBytes: Int64?
}

enum HuggingFaceAPI {
    /// repo + file path -> sha256/size from the Hugging Face tree API (LFS oid).
    /// Census W8 ModelUpdates:24/:25 (T2-3 chunk E): a failed fetch or parse
    /// still returns nil — indistinguishable from "no update found" — so a
    /// stalled update check used to be invisible. The nil stays (the checker's
    /// contract), but the skip is named; a successful lookup whose tree simply
    /// does not contain the file stays quiet (a real no-update).
    static func fileMetadata(for url: URL) async -> HFFileMetadata? {
        guard url.host?.contains("huggingface.co") == true else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let resolve = parts.firstIndex(of: "resolve"), resolve >= 2, parts.count > resolve + 1 else { return nil }
        let repo = parts[0] + "/" + parts[1]
        let rev = parts[resolve + 1]
        let filePath = parts[(resolve + 2)...].joined(separator: "/")
        let dir = filePath.contains("/") ? "/" + filePath.split(separator: "/").dropLast().joined(separator: "/") : ""

        guard let api = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(rev)\(dir)") else { return nil }
        let data: Data
        do {
            let (fetched, _) = try await URLSession.shared.data(from: api)
            data = fetched
        } catch {
            let notice = Self.updateFetchFailureNotice(
                repo: repo, reason: error.localizedDescription)
            AppLog.app.error("\(notice, privacy: .public)")
            return nil
        }
        let entries: [[String: Any]]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                let notice = Self.updateParseFailureNotice(
                    repo: repo, reason: "the response was not a file list")
                AppLog.app.error("\(notice, privacy: .public)")
                return nil
            }
            entries = parsed
        } catch {
            let notice = Self.updateParseFailureNotice(
                repo: repo, reason: error.localizedDescription)
            AppLog.app.error("\(notice, privacy: .public)")
            return nil
        }

        guard let entry = entries.first(where: { ($0["path"] as? String) == filePath }) else { return nil }
        return HFFileMetadata(sha256: (entry["lfs"] as? [String: Any])?["oid"] as? String,
                              sizeBytes: (entry["size"] as? NSNumber)?.int64Value)
    }

    /// Census W8 ModelUpdates:24 (T2-3 chunk E): the English line naming an
    /// update check skipped because the Hugging Face tree could not be
    /// fetched. Pure so checks can pin it (D3).
    static func updateFetchFailureNotice(repo: String, reason: String) -> String {
        "Could not fetch the Hugging Face tree of \(repo); the update check for its files is skipped: \(reason)"
    }

    /// Census W8 ModelUpdates:25 (T2-3 chunk E): the English line for an
    /// unreadable Hugging Face tree response — distinct from a fetch failure
    /// and from a real no-update. Pure so checks can pin it (D3).
    static func updateParseFailureNotice(repo: String, reason: String) -> String {
        "Could not parse the Hugging Face tree response of \(repo); the update check for its files is skipped: \(reason)"
    }
}

enum ModelUpdateState: Equatable {
    case upToDate
    case available(sizeBytes: Int64?)
    /// No recorded source, no published checksum, or same size with no local digest.
    case unknown

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Compares each local model against the file its recorded download URL points at.
@MainActor
final class ModelUpdateChecker: ObservableObject {
    @Published private(set) var remote: [String: HFFileMetadata] = [:]
    @Published private(set) var checking = false
    private var lastCheck: Date?

    /// Compared on read, so a finished re-download clears the flag without another lookup.
    func state(for model: LocalModel) -> ModelUpdateState {
        guard let meta = remote[model.name] else { return .unknown }
        // A split model sums every shard, which no single remote entry matches.
        let localSize = model.partURLs.count == 1 ? model.sizeBytes : nil
        return Self.compare(localDigest: ModelStore.digest(forFile: model.name),
                            localSize: localSize, remote: meta)
    }

    func check(_ models: [LocalModel]) async {
        guard !checking else { return }
        checking = true
        var found: [String: HFFileMetadata] = [:]
        for model in models {
            guard let source = ModelStore.source(forFile: model.name),
                  let url = URL(string: source),
                  let meta = await HuggingFaceAPI.fileMetadata(for: url) else { continue }
            found[model.name] = meta
        }
        remote = found
        lastCheck = Date()
        checking = false
    }

    func checkIfStale(_ models: [LocalModel], interval: TimeInterval = 6 * 3600) async {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < interval { return }
        await check(models)
    }

    /// Without a recorded digest only a size change distinguishes a re-upload.
    static func compare(localDigest: String?, localSize: Int64?, remote: HFFileMetadata) -> ModelUpdateState {
        if let localDigest, let remoteDigest = remote.sha256 {
            return localDigest.caseInsensitiveCompare(remoteDigest) == .orderedSame
                ? .upToDate : .available(sizeBytes: remote.sizeBytes)
        }
        guard let localSize, let remoteSize = remote.sizeBytes else { return .unknown }
        return remoteSize == localSize ? .unknown : .available(sizeBytes: remoteSize)
    }
}
