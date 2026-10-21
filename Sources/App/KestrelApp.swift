// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Anything the archive hook could not deliver last run is still on disk.
        MemoryArchiveHook.resume()
        // The system default tooltip delay (~1.5 s) makes the bilingual .help
        // hints feel broken; show them promptly.
        UserDefaults.standard.set(400, forKey: "NSInitialToolTipDelay")

        // Shut the engine down cleanly on SIGTERM (pkill, logout, system
        // shutdown); otherwise the child would be orphaned holding VRAM.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            ServerManager.shared.stopAllImmediately()
            SpeechDictationController.shared.shutdown()
            AppleSpeechDictationController.shared.shutdown()
            AudioStudioController.shared.shutdown()
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        ServerManager.shared.stopAllImmediately()
        SpeechDictationController.shared.shutdown()
        AppleSpeechDictationController.shared.shutdown()
        AudioStudioController.shared.shutdown()
        ImageGenPool.cleanupOutputsIfEnabled()
    }
}

/// The legacy launch heals (census W6-3, T4-3 H4): one-shot per install,
/// recorded like the KES-05 tool-permission sweep, so a second launch
/// performs none of them — the record short-circuits before any heal
/// reads a key. Injectable so the record is checked against a suite, not
/// the operator's real defaults. The whole heal is the one-shot
/// migration, including the missing-binary arm: a custom engine deleted
/// after the sweep is no longer silently rewritten to the bundled binary
/// at launch — Server.start's fileExists guard surfaces it as an
/// actionable failure instead.
enum LegacyLaunchHeals {
    static func run(in defaults: UserDefaults) {
        if defaults.bool(forKey: SettingsKeys.legacyLaunchHealsSwept) { return }
        defaults.set(true, forKey: SettingsKeys.legacyLaunchHealsSwept)

        // Remove the legacy raw flag; MTP is selected automatically per model.
        if var extra = defaults.string(forKey: SettingsKeys.extraArgs),
           extra.contains("--spec-type draft-mtp") {
            extra = extra.replacingOccurrences(of: "--spec-type draft-mtp", with: "")
                .trimmingCharacters(in: .whitespaces)
            defaults.set(extra, forKey: SettingsKeys.extraArgs)
        }

        // A legacy writer stored the chat sampling numbers as strings, which
        // @AppStorage(Double/Int) silently replaces with the declared default:
        // rewrite them typed so tuned values actually apply.
        SettingsNumericCoercion.migrateMistypedNumerics(in: defaults)

        // A "lang" stored by the removed Settings picker must not leak Spanish
        // into an English-only product; nothing reads it anymore, so clear it.
        SettingsKeys.clearStaleLanguage(in: defaults)

        // Heal the stored engine path: legacy builds or paths from another machine
        // fall back to the bundled engine.
        let legacyDefaults = ["llama.cpp-b7833", "llama.cpp/build/bin/llama-server"]
        if let bin = defaults.string(forKey: "serverBinary"),
           legacyDefaults.contains(where: bin.contains) || !FileManager.default.fileExists(atPath: bin) {
            defaults.set(ServerSettings.defaultBinary, forKey: "serverBinary")
        }
    }
}

// Not @main: the executable target is a two-line launcher (Sources/Main)
// that calls KestrelApp.main(), so the app compiles as a library the check
// suite can @testable-import. Public so the launcher can name it.
public struct KestrelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let obj = AppObjects.shared
    @ObservedObject private var loc = AppObjects.shared.loc
    @AppStorage(SettingsKeys.menuBarIcon) private var menuBarIcon = true

    public init() {
        // Release VRAM held by an engine orphaned by a previous force-quit.
        EngineLock.reapOrphans()

        // Census W6-3 legacy launch heals (T4-3 H4): --spec-type strip,
        // mistyped-numeric rewrite, stale-language clear and engine-path
        // heal — once per install, so later launches perform none of them.
        LegacyLaunchHeals.run(in: UserDefaults.standard)

        // Census W6-6/W7-3 (T4-2): the legacy per-model DFlash "disabled"
        // list becomes "off" entries in the live dflashModes map, then the
        // key retires. Runs after the numeric coercion inside the heals so
        // a string-typed legacy list is already clean when the migration
        // reads it. Deliberately outside the one-shot record: this
        // migration is self-retiring (it deletes its own key) and cheap.
        DflashLegacyMigration.run(in: UserDefaults.standard)
    }

    @AppStorage(SettingsKeys.appAccent) private var appAccentRaw = AppTheme.defaultKey
    @AppStorage(SettingsKeys.chatFontScale) private var chatFontScale = 1.0
    @Environment(\.openWindow) private var openWindow

    /// The chat font shortcuts already existed on hidden buttons, which made them
    /// undiscoverable and scene-local; they are AppStorage, so a command reaches them.
    @CommandsBuilder private var appCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button(loc.t("Aumentar el texto del chat", "Increase chat text")) {
                setFontScale(chatFontScale + ChatFont.step)
            }
            .keyboardShortcut("+", modifiers: .command)
            Button(loc.t("Reducir el texto del chat", "Decrease chat text")) {
                setFontScale(chatFontScale - ChatFont.step)
            }
            .keyboardShortcut("-", modifiers: .command)
            Button(loc.t("Tamaño original del texto", "Actual chat text size")) {
                setFontScale(1)
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button(loc.t("Documentación de Kestrel", "Kestrel documentation")) {
                obj.control.section = .docs
                openWindow(id: "control")
            }
            Button(loc.t("Reportar un problema", "Report an issue")) {
                NSWorkspace.shared.open(URL(string: "https://github.com/0xda7/kestrel/issues")!)
            }
        }
    }

    private func setFontScale(_ value: Double) {
        chatFontScale = ChatFont.clamp(value)
    }

    public var body: some Scene {
        // Main window: the chat. A single Window (not WindowGroup) keeps ⌘N
        // for "new conversation" instead of "new window".
        Window("Kestrel", id: "chat") {
            ChatMainView()
                .environmentObject(obj.server)
                .environmentObject(obj.manager)
                .environmentObject(obj.models)
                .environmentObject(obj.vram)
                .environmentObject(loc)
                .environmentObject(obj.bench)
                .environmentObject(obj.search)
                .environmentObject(obj.profiles)
                .environmentObject(obj.updates)
                .environmentObject(obj.modelUpdates)
                .environmentObject(obj.control)
                .tint(AppTheme.accent(appAccentRaw))
                .frame(minWidth: 760, minHeight: 540)
                .task {
                    await obj.updates.check()
                    obj.updates.startPeriodicChecks()
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { appCommands }

        Window(loc.t("Configuración", "Configuration"), id: "control") {
            ControlPanelView()
                .tint(AppTheme.accent(appAccentRaw))
                .environmentObject(obj.server)
                .environmentObject(obj.manager)
                .environmentObject(obj.models)
                .environmentObject(obj.vram)
                .environmentObject(loc)
                .environmentObject(obj.bench)
                .environmentObject(obj.search)
                .environmentObject(obj.profiles)
                .environmentObject(obj.updates)
                .environmentObject(obj.modelUpdates)
                .environmentObject(obj.control)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1080, height: 700)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra(isInserted: $menuBarIcon) {
            MenuBarView()
                .environmentObject(obj.server)
                .environmentObject(obj.manager)
                .environmentObject(loc)
                .environmentObject(obj.vram)
        } label: {
            MenuBarLabel(server: obj.server, vram: obj.vram, loc: obj.loc)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Window-style menu bar panel: a real SwiftUI surface so it can draw per-GPU
/// VRAM bars and per-server controls (a native menu only renders text/buttons).
struct MenuBarView: View {
    @EnvironmentObject var manager: ServerManager
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var vram: VRAMMonitor
    @AppStorage(SettingsKeys.menuBarGPU) private var menuBarGPU = "panel"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Every server, primary first, each with its own start/stop + networking.
            ForEach(Array(manager.servers.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider() }
                MenuServerRow(c: c, isPrimary: i == 0).environmentObject(manager).environmentObject(loc)
            }

            if menuBarGPU == "panel" && !vram.gpus.isEmpty {
                Divider()
                gpuSection
            }

            Divider()

            HStack {
                Button(loc.t("Abrir Kestrel", "Open Kestrel")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
                Spacer()
                Button(loc.t("Salir", "Quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("GPUs", "GPUs")).font(.caption).foregroundStyle(.secondary)
            ForEach(vram.gpus) { g in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(g.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(Int(g.fraction * 100))%")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    ProgressView(value: g.fraction)
                        .tint(g.fraction > 0.9 ? .red : g.fraction > 0.75 ? .orange : .accentColor)
                }
            }
        }
    }
}

struct MenuServerRow: View {
    @ObservedObject var c: ServerController
    let isPrimary: Bool
    @EnvironmentObject var manager: ServerManager
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.localNetworkDiscovery) private var globalDiscover = false

    private var running: Bool { c.state == .running || c.state == .starting }
    private var hasModel: Bool {
        isPrimary ? !((UserDefaults.standard.string(forKey: SettingsKeys.modelPath) ?? "").isEmpty)
                  : !((c.profile?.modelPath ?? "").isEmpty)
    }
    private var dotColor: Color {
        switch c.state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(isPrimary ? loc.t("Servidor", "Server") : c.name)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                if c.state == .running, let tg = c.genSpeed {
                    Text(String(format: "%.1f t/s", tg))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                actions
            }
            HStack(spacing: 6) {
                Image(systemName: "wifi").font(.caption2).foregroundStyle(.secondary)
                Text(loc.t("Descubrible en red", "Discoverable")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle(loc.t("Descubrible en red", "Discoverable"), isOn: discoverBinding)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if running {
            ServerWebUIButton(server: c).controlSize(.small)
            Button(loc.t("Detener", "Stop")) { c.stop() }.controlSize(.small)
        } else {
            ServerWebUIButton(server: c).controlSize(.small)
            Button(loc.t("Iniciar", "Start")) {
                c.start(isPrimary ? .fromDefaults() : c.effectiveSettings())
            }
            .controlSize(.small).disabled(!hasModel)
        }
    }

    // Networking is a launch flag, so restart the server if it's up to apply it now.
    private var discoverBinding: Binding<Bool> {
        if isPrimary {
            return Binding(get: { globalDiscover }, set: { v in
                globalDiscover = v
                if running { c.restart(.fromDefaults()) }
            })
        }
        return Binding(get: { c.profile?.localNetworkDiscovery ?? false }, set: { v in
            c.profile?.localNetworkDiscovery = v
            manager.persist()
            if running { c.restart(c.effectiveSettings()) }
        })
    }
}
