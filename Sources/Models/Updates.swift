// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
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

        // Census W8 Updates:57/:59 (T2-3 chunk F): a failed fetch or an
        // unreadable response used to return here indistinguishable from a
        // quiet "no newer release". The nil/no-update result stays (callers
        // have no failure surface — the badge only lights on success), but
        // the skip is named; a successful check that finds nothing newer
        // still emits nothing.
        guard let url = URL(string: Self.releasesAPI) else { return }
        let data: Data
        do {
            let (fetched, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode
                let notice = Self.updateCheckFetchFailureNotice(
                    reason: status.map { "HTTP \($0)" } ?? "not an HTTP response")
                AppLog.app.error("\(notice, privacy: .public)")
                return
            }
            data = fetched
        } catch {
            let notice = Self.updateCheckFetchFailureNotice(reason: error.localizedDescription)
            AppLog.app.error("\(notice, privacy: .public)")
            return
        }
        let obj: [String: Any]
        let tag: String
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parsedTag = parsed["tag_name"] as? String else {
                let notice = Self.updateCheckParseFailureNotice(
                    reason: "the response was not a release object with a version tag")
                AppLog.app.error("\(notice, privacy: .public)")
                return
            }
            obj = parsed
            tag = parsedTag
        } catch {
            let notice = Self.updateCheckParseFailureNotice(reason: error.localizedDescription)
            AppLog.app.error("\(notice, privacy: .public)")
            return
        }

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
            do {
                try FileManager.default.removeItem(at: dest)
            } catch {
                // Census W8 Updates:102 (T2-3 chunk F): the pre-clean keeps
                // its fail-closed follow-up (the typed move below decides),
                // but the step is no longer silent.
                AppLog.app.error("Could not remove the previous \(dest.lastPathComponent, privacy: .public) from Downloads before replacing it: \(error.localizedDescription, privacy: .public)")
            }
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
            let checksumsData: Data?
            do {
                let (fetched, _) = try await URLSession.shared.data(from: checksumsURL)
                checksumsData = fetched
            } catch {
                // Census W8 Updates:114 (T2-3 chunk F): KES-09 stays
                // fail-closed — the discard below and its installError are
                // the surfaced outcome — but the failed step is named.
                AppLog.app.error("Could not fetch the checksums listing; the download is discarded (KES-09 fail-closed): \(error.localizedDescription, privacy: .public)")
                checksumsData = nil
            }
            guard let data = checksumsData,
                  let listing = String(data: data, encoding: .utf8),
                  let expected = listing.split(separator: "\n")
                      .first { $0.contains(dmgURL.lastPathComponent) }?
                      .split(separator: " ").first.map(String.init),
                  let actual = await Task.detached { FileHash.sha256(of: dest) }.value,
                  expected.lowercased() == actual.lowercased() else {
                // Census W8 Updates:121 (T2-3 chunk F): a download that
                // failed verification and could not be discarded stays on
                // disk — security-relevant. The installError is the primary
                // surface; the leftover is named by the discard attempt.
                installError = "Verificación de integridad no disponible o fallida: descarga descartada / integrity verification unavailable or failed: download discarded"
                do {
                    try FileManager.default.removeItem(at: dest)
                } catch {
                    AppLog.app.error("Could not discard the unverified download \(dest.lastPathComponent, privacy: .public); remove it manually: \(error.localizedDescription, privacy: .public)")
                }
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
        // Census W8 Updates:143 (T2-3 chunk F): compliant — the parse miss
        // cannot hide: a nil here falls to the typed UpdateError("could not
        // mount the DMG") below.
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
            // Census W8 Updates:168 (T2-3 chunk F): pre-clean only — a stale
            // aside must not block the swap (the set-aside move replaces
            // whatever is there). The failed pre-clean is named so a
            // leftover old aside is traceable.
            do {
                try fm.removeItem(at: aside)
            } catch {
                AppLog.app.error("Could not remove the stale \(aside.lastPathComponent, privacy: .public) before setting the current app aside: \(error.localizedDescription, privacy: .public)")
            }
            try Self.performAppSwap(
                setAside: { try fm.moveItem(at: target, to: aside) },
                copy: { try copyApp(source: source, target: target) },
                restore: {
                    // Census W8 Updates:173 (T2-3 chunk F): a half-installed
                    // target that cannot be removed used to fall through
                    // silently to the move's own failure. A genuinely blocked
                    // removal (failed AND still present) throws here — the
                    // typed escalation in performAppSwap names the aside —
                    // while an absent target (the copy never landed) stays
                    // benign and lets the move below restore.
                    var removalError: Error?
                    do { try fm.removeItem(at: target) } catch { removalError = error }
                    if let removalError,
                       Self.swapRestoreBlocked(by: removalError,
                                               targetStillPresent: fm.fileExists(atPath: target.path)) {
                        let notice = Self.swapRestoreBlockerMessage(
                            target: target.lastPathComponent,
                            reason: removalError.localizedDescription)
                        AppLog.app.error("\(notice, privacy: .public)")
                        throw removalError
                    }
                    // Census W8 Updates:174 (T2-3 chunk F): the restore move
                    // itself is typed; a failure escalates through
                    // performAppSwap naming the aside's exact location.
                    try fm.moveItem(at: aside, to: target)
                },
                asidePath: aside.path)
            do {
                try fm.removeItem(at: aside)
            } catch {
                // Census W8 Updates:177 (T2-3 chunk F): the swap itself
                // succeeded — only the replaced version's cleanup failed.
                // The leftover aside is named, not swallowed.
                AppLog.app.error("Could not remove the replaced app set aside at \(aside.path, privacy: .public); delete it manually: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            try copyApp(source: source, target: target)
        }
        return target
    }

    /// The DMG swap as a decision core the checks can inject failures into,
    /// with the never-leave-no-app contract: a failed set-aside stops before
    /// touching anything; a failed copy ALWAYS attempts restore, and a failed
    /// restore escalates naming the aside's exact location instead of dying
    /// silently with no app in /Applications.
    nonisolated static func performAppSwap(setAside: () throws -> Void,
                                           copy: () throws -> Void,
                                           restore: () throws -> Void,
                                           asidePath: String) throws {
        do {
            try setAside()
        } catch {
            throw UpdateError(message: "No se pudo apartar la app actual; la instalación se detuvo sin tocar nada / could not set the current app aside; the install stopped without touching anything")
        }
        do {
            try copy()
        } catch {
            do {
                try restore()
            } catch {
                throw UpdateError(message: "La instalación falló y la restauración también: la app anterior quedó en \(asidePath); arrástrala de vuelta a /Applications / the install failed and so did the restore: the previous app is at \(asidePath); drag it back to /Applications")
            }
            throw error
        }
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
            let launchError: Error?
            do {
                try p.run()
                launchError = nil
            } catch {
                launchError = error
            }
            // Census W8 Updates:243 (T2-3 chunk F; the no-quit abort landed
            // in 422ef5a, here census-citing and pinned): terminating with
            // the relaunch dead would leave no app running at all. The seam
            // decides: .launched terminates exactly as before; .launchFailed
            // surfaces on installError and returns WITHOUT terminating.
            switch Self.relaunchOutcome(runError: launchError) {
            case .launched:
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            case .launchFailed(let message):
                Task { @MainActor in
                    self.installError = message
                }
            }
        }
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
        // Census W8 Updates:260/:262 (T2-3 chunk F): a failed fetch or an
        // unreadable response left notes nil — the popover already answers
        // that with its could-not-load line, which stays the user surface —
        // but the skip was invisible in the log. Same nil result, now named;
        // a successful fetch keeps its existing display untouched.
        guard let url = URL(string: "https://api.github.com/repos/0xda7/kestrel/releases?per_page=30") else { return }
        let data: Data
        do {
            let (fetched, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode
                let notice = Self.notesFetchFailureNotice(
                    reason: status.map { "HTTP \($0)" } ?? "not an HTTP response")
                AppLog.app.error("\(notice, privacy: .public)")
                return
            }
            data = fetched
        } catch {
            let notice = Self.notesFetchFailureNotice(reason: error.localizedDescription)
            AppLog.app.error("\(notice, privacy: .public)")
            return
        }
        let list: [[String: Any]]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                let notice = Self.notesParseFailureNotice(
                    reason: "the response was not a list of releases")
                AppLog.app.error("\(notice, privacy: .public)")
                return
            }
            list = parsed
        } catch {
            let notice = Self.notesParseFailureNotice(reason: error.localizedDescription)
            AppLog.app.error("\(notice, privacy: .public)")
            return
        }
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

    // MARK: Surfacing seams (census W8, T2-3 chunk F)

    /// Census W8 Updates:57 (T2-3 chunk F): the English line naming an
    /// update check skipped because the releases list could not be fetched —
    /// distinct from a parse failure and from a quiet real no-update. The
    /// check flow has no failure surface in the UI (the badge only lights on
    /// success), so this log is the surfaced status. Pure so checks can pin
    /// it (D3).
    nonisolated static func updateCheckFetchFailureNotice(reason: String) -> String {
        "Could not fetch the releases list to check for updates; the check is skipped: \(reason)"
    }

    /// Census W8 Updates:59 (T2-3 chunk F): the line for a fetched but
    /// unreadable releases response — a different skip than a fetch failure.
    /// Pure so checks can pin it (D3).
    nonisolated static func updateCheckParseFailureNotice(reason: String) -> String {
        "Could not read the releases response to check for updates; the check is skipped: \(reason)"
    }

    /// Census W8 Updates:260 (T2-3 chunk F): the line for release notes that
    /// could not be fetched; the popover's could-not-load note is the user
    /// surface, this names the skip in the log. Pure so checks can pin it (D3).
    nonisolated static func notesFetchFailureNotice(reason: String) -> String {
        "Could not fetch the release notes; the popover shows its could-not-load note: \(reason)"
    }

    /// Census W8 Updates:262 (T2-3 chunk F): the line for a releases
    /// response the notes reader could not parse. Pure so checks can pin it (D3).
    nonisolated static func notesParseFailureNotice(reason: String) -> String {
        "Could not read the releases response for the release notes; the popover shows its could-not-load note: \(reason)"
    }

    /// Census W8 Updates:173 (T2-3 chunk F): whether a failed removal of the
    /// half-installed target blocks the restore. It blocks only when the
    /// target is actually still present (the removal genuinely failed); an
    /// absent target (the copy never landed) is benign and lets the restore
    /// move proceed — mirroring the finalize gate's blocked/benign split.
    /// Pure so checks can pin the safe direction (D3).
    nonisolated static func swapRestoreBlocked(by removalError: Error?, targetStillPresent: Bool) -> Bool {
        removalError != nil && targetStillPresent
    }

    /// Census W8 Updates:173 (T2-3 chunk F): the English line naming a
    /// half-installed app that could not be removed to make room for the
    /// restore. The typed escalation in performAppSwap stays the user
    /// surface; this names the exact failing step. Pure so checks can pin
    /// the wording (D3).
    nonisolated static func swapRestoreBlockerMessage(target: String, reason: String) -> String {
        "Could not remove the half-installed \(target) to restore the previous app: \(reason)"
    }

    /// Census W8 Updates:243 (T2-3 chunk F; the abort itself landed in
    /// 422ef5a, here census-citing and pinned): what the app does after
    /// trying to launch the installed copy. `.launched` quits this app
    /// exactly as before; `.launchFailed` surfaces the message on
    /// installError and the app STAYS ALIVE — quitting then would leave no
    /// app running at all. Pure so checks can pin both directions (D3).
    enum RelaunchOutcome: Equatable {
        case launched
        case launchFailed(message: String)
    }

    nonisolated static func relaunchOutcome(runError: Error?) -> RelaunchOutcome {
        guard let runError else { return .launched }
        return .launchFailed(message: "La nueva versión está instalada pero no arrancó: ábrela desde /Applications (\(runError.localizedDescription)) / the new version is installed but did not launch: open it from /Applications")
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
