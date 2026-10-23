// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The one way every save-panel export lands on disk (image saves, mp4
/// writes, subtitle burn-in): the payload is written to a fresh staging
/// file BESIDE the destination — same directory, so the final swap is one
/// atomic rename — and only then does FileManager.replaceItemAt swap it
/// in. The destination is never removed first, so a failure anywhere
/// before the swap leaves the operator's existing file byte-identical,
/// and a crash mid-write can never leave a half-written file behind (the
/// class of loss commit f436aef closed for the Markdown export).
enum AtomicFileSave {
    /// The failure every save-panel export surfaces: names the destination
    /// path and states that the file there was left untouched, with the
    /// underlying reason carried along.
    struct SaveError: Error {
        let destinationPath: String
        let reason: String
    }

    /// A fresh, never-before-used staging URL beside `destination` (same
    /// directory => same volume => the commit is a rename, not a copy).
    static func stagingURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".kestrel-stage-\(UUID().uuidString)-\(destination.lastPathComponent)")
    }

    /// Copies `source` to a staging file beside `destination`, then
    /// commits. `destination` is untouched unless the whole copy and the
    /// swap both succeed; any failure cleans the staging file and throws
    /// SaveError.
    static func copy(from source: URL, to destination: URL) throws {
        let staged = stagingURL(beside: destination)
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            try commit(staged, to: destination)
        } catch let saved as SaveError {
            throw saved
        } catch {
            discard(staged)
            throw SaveError(destinationPath: destination.path, reason: error.localizedDescription)
        }
    }

    /// Swaps a fully-written staging file into place: replaceItemAt when
    /// the destination exists (the overwrite the save panel confirmed),
    /// one moveItem rename when it does not (the normal first save —
    /// replaceItemAt requires an existing original). Both are atomic, so
    /// the destination never holds a half-written payload. A failed swap
    /// cleans the staging file and throws SaveError.
    static func commit(_ staged: URL, to destination: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
        } catch {
            discard(staged)
            throw SaveError(destinationPath: destination.path, reason: error.localizedDescription)
        }
    }

    /// Removes a staging file a failed write left behind. Never throws:
    /// cleanup after a failure must not mask the real error.
    static func discard(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged)
    }

    /// The one English line every failed export surfaces — the alert text,
    /// the exporter error, and SaveError's localizedDescription all read
    /// exactly this. Pure so checks can pin it.
    static func failureMessage(destinationPath: String, reason: String) -> String {
        "Export to \(destinationPath) failed; the file at that path was left unchanged. (\(reason))"
    }
}

extension AtomicFileSave.SaveError: LocalizedError {
    var errorDescription: String? {
        AtomicFileSave.failureMessage(destinationPath: destinationPath, reason: reason)
    }
}
