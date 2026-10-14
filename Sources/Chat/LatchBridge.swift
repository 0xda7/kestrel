// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Owns the provider half of the latch harness's configuration
/// (`~/.latch/v2/provider_config.json`). Before this bridge, latch's
/// provider config was authored by latch's own onboarding outside the app:
/// a model aimed at whatever endpoint that setup chose, while Kestrel's
/// Settings → Providers knew nothing about it — the delegate's tool
/// description had to warn that delegation "may run on remote cloud
/// endpoints, and Kestrel does not route or constrain it". Kestrel's
/// settings are now the single source of truth: every configured
/// remote route becomes a latch provider, the local engine is always
/// available as `kestrel-local` and is the default, and the file is
/// regenerated at launch and whenever routes or keys change. A hand-authored
/// file is imported once into real settings; after that the marker file
/// records ownership so the import never re-imports our own output.
enum LatchBridge {
    static let generationMarkerName = "provider_config.generated-by-kestrel"
    static let migrationDefaultsKey = "latchBridgeSidecarMigrated"

    static var sidecarDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.latch/v2")
    }

    static var configFileURL: URL {
        sidecarDirectory.appendingPathComponent("provider_config.json")
    }

    static var markerFileURL: URL {
        sidecarDirectory.appendingPathComponent(generationMarkerName)
    }

    // MARK: Slugs

    /// Provider ids ride latch's config file, so they must be key-safe.
    /// "z.ai" → "z-ai".
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        var out = String(lowered)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        while out.first == "-" { out.removeFirst() }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "provider" : out
    }
    // MARK: Config generation

    struct ProviderEntry {
        let id: String
        let baseURL: String
        let apiKey: String
        let models: [String]
    }

    /// Pure builder so tests can run it without touching the real sidecar.
    /// Shape mirrors latch's own v2 schema (schemaVersion 1) exactly: the
    /// rule list, the order arrays, and the default selection all name the
    /// same providers so latch never sees a dangling reference.
    static func generateJSON(entries: [ProviderEntry], defaultEntryID: String?) -> String {
        let rules: [[String: Any]] = entries.map { entry in
            [
                "providerId": entry.id,
                "config": [
                    "group": "standard-personal",
                    "access": ["type": "api-key", "apiKey": entry.apiKey],
                    "api": ["type": "openai-chat-completions", "baseUrl": entry.baseURL],
                    "personalModelIds": entry.models,
                    "modelOrder": entry.models,
                    "visibility": "visible",
                ] as [String: Any],
            ]
        }
        let fallback = entries.first.map { entry in
            ["providerId": entry.id, "modelId": entry.models.first ?? ""] as [String: Any]
        }
        let selection: [String: Any]
        if let defaultEntryID,
           let entry = entries.first(where: { $0.id == defaultEntryID }),
           let model = entry.models.first {
            selection = ["providerId": entry.id, "modelId": model]
        } else if let fallback {
            selection = fallback
        } else {
            selection = [:]
        }
        let object: [String: Any] = [
            "schemaVersion": 1,
            "config": [
                "providerOrder": entries.map(\.id),
                "providerConfigRules": ["providerRules": rules],
                "modelConfigRules": [
                    "providerModelRules": [],
                    "manualProviderModelRules": [],
                ],
                "defaultModelSelection": selection,
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Provider entries derived from Kestrel's own settings: every configured
    /// remote route, plus `kestrel-local` from the engine defaults.
    static func currentEntries() -> (entries: [ProviderEntry], defaultEntryID: String?) {
        var entries: [ProviderEntry] = []
        var seenIDs: Set<String> = []
        var activeID: String?
        let activeRoute = InferenceRoutes.active()
        for route in InferenceRoutes.load() {
            guard route.isConfigured, let url = route.normalizedURL else { continue }
            let host = url.host ?? ""
            guard !InferenceRoute.insecureHosts.contains(host) else { continue } // engine is emitted separately
            let key = InferenceRoutes.apiKey(for: route)
            guard !key.isEmpty else { continue } // a route without a key cannot work; do not emit a broken entry
            var id = slug(route.name)
            while seenIDs.contains(id) { id += "-2" }
            seenIDs.insert(id)
            let model = route.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            if route.id == activeRoute?.id { activeID = id }
            entries.append(ProviderEntry(id: id, baseURL: url.absoluteString,
                                         apiKey: key, models: [model]))
        }
        if let local = localEntry() {
            entries.append(local)
        }
        // Default stays on this machine's engine unless an active route says
        // otherwise — delegation of machine-private work must be a choice.
        return (entries, activeID)
    }

    /// The engine itself as a latch provider, so the delegate runs locally
    /// by default. The model names the file that is about to load.
    static func localEntry() -> ProviderEntry? {
        let modelPath = UserDefaults.standard.string(forKey: SettingsKeys.modelPath) ?? ""
        let model = (modelPath as NSString).lastPathComponent
        guard !model.isEmpty else { return nil }
        let port = UserDefaults.standard.integer(forKey: SettingsKeys.port)
        let effectivePort = port > 0 ? port : 8080
        let key = Keychain.apiKey()
        return ProviderEntry(id: "kestrel-local",
                             baseURL: "http://127.0.0.1:\(effectivePort)/v1",
                             apiKey: key, models: [model])
    }

    // MARK: Sync (write the file when it differs)

    /// Regenerates `~/.latch/v2/provider_config.json` from Kestrel's
    /// settings. The write only happens when the content actually differs;
    /// the marker file records ownership so the one-time import never
    /// re-imports our own output.
    @discardableResult
    static func sync() -> Bool {
        let (entries, defaultEntryID) = currentEntries()
        guard !entries.isEmpty else { return false }
        let json = generateJSON(entries: entries, defaultEntryID: defaultEntryID)
        let dir = sidecarDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(atPath: dir.path, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        let changed = (try? String(contentsOf: configFileURL, encoding: .utf8)) != json
        guard changed else { return true }
        do {
            try json.write(to: configFileURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFileURL.path)
            if !fm.fileExists(atPath: markerFileURL.path) {
                try? Data().write(to: markerFileURL)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: One-time import of a hand-authored config

    /// Parses a pre-bridge, hand-authored provider_config.json into route
    /// candidates. Loopback endpoints are the engine and do not become
    /// routes; anything else becomes a real Kestrel route with its key in
    /// the local secret store. Pure half of the import, testable in
    /// isolation.
    static func importableRoutes(from data: Data) -> [(route: InferenceRoute, apiKey: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["config"] as? [String: Any],
              let rules = config["providerConfigRules"] as? [String: Any],
              let providerRules = rules["providerRules"] as? [[String: Any]] else { return [] }
        var out: [(InferenceRoute, String)] = []
        for rule in providerRules {
            guard let id = rule["providerId"] as? String,
                  let entry = rule["config"] as? [String: Any],
                  let api = entry["api"] as? [String: Any],
                  let base = api["baseUrl"] as? String,
                  let url = URL(string: base), let host = url.host else { continue }
            guard !InferenceRoute.insecureHosts.contains(host) else { continue }
            let models = (entry["personalModelIds"] as? [String]) ?? []
            let key = ((entry["access"] as? [String: Any])?["apiKey"] as? String) ?? ""
            let route = InferenceRoute(name: id, dialect: .openAI,
                                       baseURL: base, modelID: models.first ?? "")
            out.append((route, key))
        }
        return out
    }

    /// Runs once, guarded by a defaults flag: imports providers from a
    /// hand-authored config into real settings, then takes ownership by
    /// regenerating the file from those settings.
    static func migrateLegacySidecarConfigIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationDefaultsKey) else {
            sync()
            return
        }
        defaults.set(true, forKey: migrationDefaultsKey)
        guard !FileManager.default.fileExists(atPath: markerFileURL.path),
              let data = try? Data(contentsOf: configFileURL) else {
            sync()
            return
        }
        let imported = importableRoutes(from: data)
        if !imported.isEmpty {
            var routes = InferenceRoutes.load()
            for (route, key) in imported {
                routes.append(route)
                if !key.isEmpty {
                    LocalSecretStore.store("route-key-\(route.id.uuidString)", key)
                }
            }
            InferenceRoutes.save(routes)
        }
        sync()
    }
}
