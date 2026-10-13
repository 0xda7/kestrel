// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Owns the provider half of the pi sidecar's configuration
/// (`~/.pi/agent/models.json`). Before this bridge existed that file was
/// hand-authored outside the app: a provider hardcode with an embedded key
/// that silently disagreed with Kestrel's own provider settings — change the
/// provider here and the sidecar never followed, and a stale model name made
/// pi fall back to its built-in default provider (dead key → empty reply,
/// exit 0, nothing in stderr). Kestrel settings are now the single source of
/// truth: every configured remote route becomes a pi provider entry, the
/// local engine is always available as `kestrel-local`, and the file is
/// regenerated at launch and whenever routes or keys change.
///
/// Credentials live in Kestrel's local secret store (0600 files) — the
/// system Keychain is no longer written for provider keys, because on ad-hoc
/// builds every rebuild invalidates the item's ACL and raises the macOS
/// password dialog (never requested, removed by design).
enum PiBridge {
    static let generationMarkerName = "models.json.generated-by-kestrel"
    /// Keychain is not used for provider keys anymore; this store is.
    static let migrationDefaultsKey = "piBridgeSidecarMigrated"

    static var sidecarDirectory: URL {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory,
                                                       .userDomainMask, true).first
            ?? NSHomeDirectory() + "/Library/Application Support"
        return URL(fileURLWithPath: NSHomeDirectory() + "/.pi/agent")
    }

    static var modelsFileURL: URL {
        sidecarDirectory.appendingPathComponent("models.json")
    }

    static var markerFileURL: URL {
        sidecarDirectory.appendingPathComponent(generationMarkerName)
    }

    // MARK: Slugs

    /// pi provider names ride the `provider/model` argv and the JSON config,
    /// so they must be key-safe. "z.ai" → "z-ai".
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
        let slug: String
        let baseURL: String
        let apiKey: String
        let models: [String]
    }

    /// Pure builder so tests can run it without touching the real sidecar.
    static func generateJSON(entries: [ProviderEntry]) -> String {
        var providers: [String: Any] = [:]
        for entry in entries {
            providers[entry.slug] = [
                "baseUrl": entry.baseURL,
                "api": "openai-completions",
                "apiKey": entry.apiKey,
                "models": entry.models.map { ["id": $0] },
            ]
        }
        let object: [String: Any] = ["providers": providers]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Provider entries derived from Kestrel's own settings: every configured
    /// remote route, plus `kestrel-local` from the engine defaults.
    static func currentEntries() -> [ProviderEntry] {
        var entries: [ProviderEntry] = []
        var seenSlugs: Set<String> = []
        for route in InferenceRoutes.load() {
            guard route.isConfigured, let url = route.normalizedURL else { continue }
            let host = url.host ?? ""
            guard !InferenceRoute.insecureHosts.contains(host) else { continue } // engine is emitted separately
            let key = InferenceRoutes.apiKey(for: route)
            guard !key.isEmpty else { continue } // a route without a key cannot work; do not emit a broken entry
            var name = slug(route.name)
            while seenSlugs.contains(name) { name += "-2" }
            seenSlugs.insert(name)
            let model = route.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            entries.append(ProviderEntry(slug: name, baseURL: url.absoluteString,
                                         apiKey: key, models: [model]))
        }
        if let local = localEntry() {
            entries.append(local)
        }
        return entries
    }

    /// The engine itself as a pi provider, so pi can drive the local model.
    static func localEntry() -> ProviderEntry? {
        let modelPath = UserDefaults.standard.string(forKey: SettingsKeys.modelPath) ?? ""
        let model = (modelPath as NSString).lastPathComponent
        guard !model.isEmpty else { return nil }
        let port = UserDefaults.standard.integer(forKey: SettingsKeys.port)
        let effectivePort = port > 0 ? port : 8080
        let key = Keychain.apiKey()
        return ProviderEntry(slug: "kestrel-local",
                             baseURL: "http://127.0.0.1:\(effectivePort)/v1",
                             apiKey: key, models: [model])
    }

    // MARK: Sync (write the file when it differs)

    /// Regenerates `~/.pi/agent/models.json` from Kestrel's settings. Cheap:
    /// the write only happens when the content actually differs. A marker
    /// file records ownership so the one-time import never re-imports our own
    /// output.
    @discardableResult
    static func sync() -> Bool {
        let entries = currentEntries()
        guard !entries.isEmpty else { return false }
        let json = generateJSON(entries: entries)
        let dir = sidecarDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(atPath: dir.path, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        let changed = (try? String(contentsOf: modelsFileURL, encoding: .utf8)) != json
        guard changed else { return true }
        do {
            try json.write(to: modelsFileURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: modelsFileURL.path)
            if !fm.fileExists(atPath: markerFileURL.path) {
                try? Data().write(to: markerFileURL)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Validation (never strand silently again)

    /// Nil when the `provider/model` pair exists in the generated sidecar
    /// config; otherwise a bilingual, actionable message. Skips validation
    /// when the provider is empty (pi's own configuration decides — that is a
    /// documented choice) or when the file is not Kestrel-generated (a
    /// pi-native setup Kestrel must not second-guess).
    static func validate(provider: String, model: String) -> String? {
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProvider.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: markerFileURL.path) else { return nil }
        return validate(provider: trimmedProvider, model: model,
                        configData: try? Data(contentsOf: modelsFileURL))
    }

    /// Injectable core of validate() for tests.
    static func validate(provider: String, model: String, configData: Data?) -> String? {
        guard let data = configData,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = object["providers"] as? [String: Any] else { return nil }
        guard let entry = providers[provider] as? [String: Any] else {
            let known = providers.keys.sorted().joined(separator: ", ")
            return loc("El proveedor «\(provider)» no está configurado para pi (configurados: \(known)). Añádelo en Ajustes → Proveedores; el envío se detuvo en vez de dejar una respuesta vacía.",
                       "The provider “\(provider)” is not configured for pi (configured: \(known)). Add it in Settings → Providers; the send stopped instead of leaving an empty reply.")
        }
        let models = (entry["models"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        guard models.contains(model) else {
            let known = models.isEmpty ? "—" : models.joined(separator: ", ")
            return loc("El modelo «\(model)» no existe para el proveedor «\(provider)» en la configuración de pi (válidos: \(known)). Corrígelo en Ajustes → Proveedores o en Chat → Agentes.",
                       "The model “\(model)” does not exist for provider “\(provider)” in pi's configuration (valid: \(known)). Fix it in Settings → Providers or Chat → Agents.")
        }
        return nil
    }

    /// The provider/model pairs the generated config offers — the chat
    /// settings picker is built from this so a model that cannot run is never
    /// selectable in the first place.
    static func configuredPairs() -> [(provider: String, model: String)] {
        guard let data = try? Data(contentsOf: modelsFileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = object["providers"] as? [String: Any] else { return [] }
        var pairs: [(String, String)] = []
        for (name, value) in providers.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any],
                  let models = entry["models"] as? [[String: Any]] else { continue }
            for model in models.compactMap({ $0["id"] as? String }) {
                pairs.append((name, model))
            }
        }
        return pairs
    }

    // MARK: One-time import of the hand-authored config

    /// Imports providers from a pre-bridge, hand-authored models.json (the
    /// z.ai hardcode): each entry becomes a real Kestrel route with its key
    /// in the local secret store, stale pi model/provider settings are
    /// repaired to a pair that actually exists, and the file is regenerated
    /// under Kestrel's ownership. Runs once, guarded by a defaults flag.
    static func migrateLegacySidecarConfigIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationDefaultsKey) else {
            sync()
            return
        }
        defaults.set(true, forKey: migrationDefaultsKey)
        guard !FileManager.default.fileExists(atPath: markerFileURL.path),
              let data = try? Data(contentsOf: modelsFileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = object["providers"] as? [String: Any] else {
            sync()
            return
        }
        var routes = InferenceRoutes.load()
        var imported: [(provider: String, model: String)] = []
        for (name, value) in providers.sorted(by: { $0.key < $1.key }) {
            guard name != "kestrel-local",
                  let entry = value as? [String: Any],
                  let base = entry["baseUrl"] as? String else { continue }
            let models = (entry["models"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            let key = entry["apiKey"] as? String ?? ""
            let route = InferenceRoute(name: name, dialect: .openAI,
                                       baseURL: base, modelID: models.first ?? "")
            routes.append(route)
            if !key.isEmpty {
                LocalSecretStore.store("route-key-\(route.id.uuidString)", key)
            }
            for model in models {
                imported.append((name, model))
            }
        }
        if !imported.isEmpty {
            InferenceRoutes.save(routes)
            // Repair the stale free-text pair (the silent-strand cause): the
            // stored model must exist for the stored provider, else adopt the
            // first imported pair.
            let storedProvider = PiDelegateService.configuredProvider
            let storedModel = PiDelegateService.configuredModel
            let valid = imported.contains { $0.provider == storedProvider && $0.model == storedModel }
            if !valid, let first = imported.first {
                defaults.set(first.provider, forKey: SettingsKeys.piProvider)
                defaults.set(first.model, forKey: SettingsKeys.piModel)
            }
        }
        sync()
    }

    private static func loc(_ es: String, _ en: String) -> String {
        // Bilingual by convention, matching the delegate's failure strings:
        // Spanish first, English second, one line each — no localization
        // object needed off the main thread.
        return es + " / " + en
    }
}
