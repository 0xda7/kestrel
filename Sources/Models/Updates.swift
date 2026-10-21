// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import SwiftUI

struct UpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ReleaseNote: Identifiable {
    let version: String
    let body: String
    var id: String { version }
}

/// Checks GitHub Releases for a newer published version and installs it:
/// verified download, mount, copy into /Applications and relaunch.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var releaseURL: URL?
    @Published var checking = false
    @Published var installing = false
    @Published var installError: String?

    private var dmgURL: URL?
    private var checksumsURL: URL?
    private var periodicTask: Task<Void, Never>?

    static let releasesAPI = "https://api.github.com/repos/0xda7/kestrel/releases/latest"

    /// Re-checks every hour while the app stays open, for people who never
    /// relaunch. Silent: it only lights up the existing update badge.
    func startPeriodicChecks(interval: TimeInterval = 3600) {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Tri-state absent-means-true, registry-typed (W4-5).
                let enabled = SettingsNumericCoercion.bool(SettingsKeys.updateAutoCheck, default: true)
                if enabled { await self?.check() }
            }
        }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        guard let url = URL(string: Self.releasesAPI),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return }

        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isVersion(remote, newerThan: AppInfo.version) {
            latestVersion = remote
            releaseURL = (obj["html_url"] as? String).flatMap(URL.init(string:))
            if let assets = obj["assets"] as? [[String: Any]] {
                // A release carries both DMGs (AVX2 + no-AVX2, suffix "-noavx2").
                // Each build stays on its own channel: pick the asset matching this
                // bundle's variant so a no-AVX2 install never grabs an AVX2 DMG.
                for asset in assets {
                    guard let name = asset["name"] as? String,
                          let urlString = asset["browser_download_url"] as? String,
                          let url = URL(string: urlString) else { continue }
                    if name.hasSuffix(".dmg"),
                       name.contains("-noavx2") == AppInfo.isNoAVX2 { dmgURL = url }
                    if name == "checksums.txt" { checksumsURL = url }
                }
            }
        }
    }

    /// Downloads the release DMG to ~/Downloads, verifies it against the
    /// published checksums, installs the app into place and relaunches it.
    func downloadAndInstall() async {
        guard !installing else { return }
        // The DMG asset may not have been uploaded yet when the release was
        // first detected (CI uploads it after creating the release); refresh
        // before giving up and sending the user to the website.
        if dmgURL == nil { await check() }
        guard let dmgURL else {
            if let releaseURL { NSWorkspace.shared.open(releaseURL) }
            return
        }
        installing = true
        installError = nil
        defer { installing = false }

        do {
            let (temp, _) = try await URLSession.shared.download(from: dmgURL)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dest = downloads.appendingPathComponent(dmgURL.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)

            // KES-09: fail closed. A missing checksums listing, an entry that
            // doesn't cover this asset, or an unavailable actual hash all
            // abort the install — an unverifiable download never replaces
            // the running app.
            guard let checksumsURL else {
                try? FileManager.default.removeItem(at: dest)
                installError = "La release no publica checksums; descarga descartada / release publishes no checksums; download discarded"
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: checksumsURL),
                  let listing = String(data: data, encoding: .utf8),
                  let expected = listing.split(separator: "\n")
                      .first { $0.contains(dmgURL.lastPathComponent) }?
                      .split(separator: " ").first.map(String.init),
                  let actual = await Task.detached { FileHash.sha256(of: dest) }.value,
                  expected.lowercased() == actual.lowercased() else {
                try? FileManager.default.removeItem(at: dest)
                installError = "Verificación de integridad no disponible o fallida: descarga descartada / integrity verification unavailable or failed: download discarded"
                return
            }

            let installed = try await Task.detached { try Self.install(dmgAt: dest) }.value
            // Installed OK: drop the downloaded DMG so it doesn't pile up in Downloads.
            // Any failure above leaves it in place (the catch keeps it for retry/inspection).
            try? FileManager.default.removeItem(at: dest)
            relaunch(installed)
        } catch {
            installError = error.localizedDescription
        }
    }

    /// Mounts the DMG, copies the app bundle into place (the running bundle's
    /// location when it lives in /Applications, /Applications otherwise) and
    /// unmounts. The old copy is moved aside first so the running process is
    /// never half-overwritten, and restored if the copy fails.
    nonisolated private static func install(dmgAt dmg: URL) throws -> URL {
        let plist = try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
        guard let data = plist.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = obj["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError(message: "No se pudo montar el DMG / could not mount the DMG")
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let fm = FileManager.default
        guard let appName = try fm.contentsOfDirectory(atPath: mount).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError(message: "El DMG no contiene una app / the DMG contains no app")
        }
        let source = mount + "/" + appName
        // KES-09: the mounted app must carry a valid code signature, and a
        // Developer-ID build must come from the same team as the running
        // app — a DMG that swapped publishers mid-flight stops here.
        try Self.verifySignature(ofAppAt: source)


        let bundle = Bundle.main.bundleURL
        let target = bundle.path.hasPrefix("/Applications/")
            ? bundle
            : URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)

        if fm.fileExists(atPath: target.path) {
            let aside = target.deletingPathExtension().appendingPathExtension("old.app")
            try? fm.removeItem(at: aside)
            try fm.moveItem(at: target, to: aside)
            do {
                try copyApp(source: source, target: target)
            } catch {
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: aside, to: target)
                throw error
            }
            try? fm.removeItem(at: aside)
        } else {
            try copyApp(source: source, target: target)
        }
        return target
    }

    nonisolated private static func copyApp(source: String, target: URL) throws {
        _ = try run("/usr/bin/ditto", [source, target.path])
        // KES-09: the quarantine attribute is NOT stripped. Self-downloads
        // carry none anyway, and stripping would only remove defense-in-depth
        // from a copy whose provenance Gatekeeper should re-evaluate.
    }

    nonisolated private static func verifySignature(ofAppAt path: String) throws {
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        guard let running = teamIdentifier(ofAppAt: Bundle.main.bundleURL.path),
              !running.isEmpty, running != "not set" else { return }
        guard teamIdentifier(ofAppAt: path) == running else {
            throw UpdateError(message: "La firma del código no coincide con la app instalada / the code signature does not match the installed app")
        }
    }

    nonisolated private static func teamIdentifier(ofAppAt path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { return nil }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .first { $0.contains("TeamIdentifier=") }?
            .split(separator: "=").last.map(String.init)
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            throw UpdateError(message: URL(fileURLWithPath: tool).lastPathComponent + ": "
                + (output.isEmpty ? "error \(p.terminationStatus)" : String(output.suffix(300))))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Launches the freshly installed copy and quits this one. The engine is
    /// stopped by applicationWillTerminate on the way out. No shell: the path
    /// rides as a direct argv element (a bundle path containing quotes or
    /// `$(…)` must never reach an interpreter).
    private func relaunch(_ url: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [url.path]
            try? p.run()
        }
        NSApp.terminate(nil)
    }

    // MARK: release notes

    @Published var releaseNotes: [ReleaseNote]?
    @Published var loadingNotes = false

    /// Notes from the running version up to the newest release; when already
    /// up to date, just the running version's notes.
    func fetchReleaseNotes() async {
        guard !loadingNotes else { return }
        loadingNotes = true
        defer { loadingNotes = false }
        guard let url = URL(string: "https://api.github.com/repos/0xda7/kestrel/releases?per_page=30"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let all = list.compactMap { obj -> (String, String)? in
            guard let tag = obj["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return (version, obj["body"] as? String ?? "")
        }
        releaseNotes = Self.notesToDisplay(all: all, current: AppInfo.version)
            .map { ReleaseNote(version: $0.0, body: $0.1) }
    }

    nonisolated static func notesToDisplay(all: [(String, String)], current: String) -> [(String, String)] {
        let newer = all.filter { isVersion($0.0, newerThan: current) }
            .sorted { isVersion($0.0, newerThan: $1.0) }
        if !newer.isEmpty { return newer }
        return all.filter { $0.0 == current }
    }

    /// Numeric per-component comparison (0.81.1 < 0.82 < 1.0).
    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Popup with the release notes covered by `fetchReleaseNotes`.
struct ReleaseNotesPopover: View {
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc.t("Notas de la versión", "Release notes"), systemImage: "doc.text")
                .font(.headline)
            if updates.loadingNotes {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .frame(minHeight: 80)
            } else if let notes = updates.releaseNotes, !notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(notes) { note in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("v\(note.version)").font(.subheadline.weight(.semibold))
                                    if note.version == AppInfo.version {
                                        Text(loc.t("actual", "current"))
                                            .font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                RichText(text: note.body)
                                    .font(.callout)
                            }
                            if note.id != notes.last?.id { Divider() }
                        }
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: 420)
            } else {
                Text(loc.t("No se pudieron cargar las notas.", "Could not load the notes."))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(minHeight: 60)
            }
            Divider()
            Button(loc.t("Ver en GitHub", "View on GitHub")) {
                let tag = updates.releaseNotes?.first.map { "v\($0.version)" } ?? "v\(AppInfo.version)"
                NSWorkspace.shared.open(URL(string: "https://github.com/0xda7/kestrel/releases/tag/\(tag)")!)
            }
            .buttonStyle(.link).font(.caption)
        }
        .padding(14)
        .frame(width: 480)
        .task { await updates.fetchReleaseNotes() }
    }
}
