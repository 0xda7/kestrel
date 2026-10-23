// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SettingsArchiveError: LocalizedError {
    case invalidFormat

    var errorDescription: String? { "The settings file is not valid." }
}

enum SettingsArchive {
    static func exportData(defaults: UserDefaults = .standard) throws -> Data {
        let all = defaults.dictionaryRepresentation()
        let config = Dictionary(uniqueKeysWithValues: SettingsKeys.resettableOptionKeys.compactMap { key in
            all[key].map { (key, archiveValue($0)) }
        })
        return try JSONSerialization.data(withJSONObject: [
            "format": "kestrel-settings",
            "version": 1,
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "config": config
        ], options: [.prettyPrinted, .sortedKeys])
    }

    @discardableResult
    static func importData(_ data: Data, defaults: UserDefaults = .standard) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else {
            throw SettingsArchiveError.invalidFormat
        }
        let allowed = Set(SettingsKeys.resettableOptionKeys)
        var count = 0
        for (key, value) in config where allowed.contains(key) {
            if value is NSNull { defaults.removeObject(forKey: key) }
            // Numeric keys never land as String: a mistyped import value is
            // coerced, and garbage drops to the declared default.
            else if let typed = SettingsNumericCoercion.typedImportValue(restoredValue(value), forKey: key) {
                defaults.set(typed, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            count += 1
        }
        return count
    }

    /// Census W8 (T2-2 chunk D): the KES-06 consent summary must
    /// distinguish "nothing in this archive would spawn a process" from
    /// "the archive could not be summarized" — the caller fails safe on the
    /// latter instead of reading silence as consent.
    enum ProcessSpawnSummary {
        case none                      // parses; nothing in it would spawn a process
        case rows([String])            // parses; these entries would spawn processes
        case unavailable(String)       // cannot be summarized; consent cannot be computed
    }

    /// The consent decision for importing `data` (KES-06). Pure and
    /// check-pinned: an unsummarizable archive is declined, never silently
    /// applied.
    enum ImportDecision {
        case applyNow
        case needsApproval([String])
        case declined(String)
    }

    static func importDecision(for data: Data, defaults: UserDefaults = .standard) -> ImportDecision {
        switch processSpawningSummary(for: data, defaults: defaults) {
        case .none: return .applyNow
        case .rows(let risks): return .needsApproval(risks)
        case .unavailable(let reason):
            return .declined("Import declined: \(reason). Fix or re-export the file and try again.")
        }
    }

    /// KES-06: everything an import would restore that can spawn a process
    /// or change what gets spawned — engine and sidecar binary paths, MCP
    /// server commands, extra engine arguments, the memory-archive delivery
    /// endpoint (KES-08/M-1: it exfiltrates turn content to wherever it
    /// points), and the agent-tool switches that arm the engine's tool
    /// endpoints. The import UI shows this list and requires explicit
    /// approval before any of it is applied: a settings file handed to the
    /// user is otherwise one-click arbitrary process execution.
    static func processSpawningSummary(for data: Data, defaults: UserDefaults = .standard) -> ProcessSpawnSummary {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else {
            return .unavailable("the file is not a readable Kestrel settings archive")
        }
        var rows: [String] = []
        let binaryKeys: [(String, String)] = [
            (SettingsKeys.serverBinary, "engine"),
        ]
        for (key, label) in binaryKeys {
            if let raw = config[key], let path = restoredValue(raw) as? String,
               !path.isEmpty, path != (defaults.string(forKey: key) ?? "") {
                rows.append("\(label) binary: \(path)")
            }
        }
        if let raw = config[SettingsKeys.extraArgs], let extra = restoredValue(raw) as? String,
           !extra.isEmpty, extra != (defaults.string(forKey: SettingsKeys.extraArgs) ?? "") {
            rows.append("engine extraArgs: \(extra)")
        }
        // M-1 (KES-06/KES-08): the memory-archive delivery endpoint and the
        // tool-spawning switches ride resettableOptionKeys, so an import
        // could restore them silently — repointing the exfiltration hook or
        // arming POST /tools with no consent round-trip. They surface like
        // the binary rows: only a value the import would actually change.
        let changedStringKeys: [(String, String)] = [
            (SettingsKeys.memoryArchiveHookURL, "memory archive hook"),
            (SettingsKeys.toolsRuntime, "tools runtime"),
        ]
        for (key, label) in changedStringKeys {
            if let raw = config[key], let value = restoredValue(raw) as? String,
               !value.isEmpty, value != (defaults.string(forKey: key) ?? "") {
                rows.append("\(label): \(value)")
            }
        }
        let toolSwitches: [(String, String)] = [
            (SettingsKeys.agentToolsEnabled, "agent tools"),
            (SettingsKeys.uiMcpProxy, "web MCP proxy"),
        ]
        for (key, label) in toolSwitches {
            guard let raw = config[key] else { continue }
            let imported = importedToolSwitchValue(restoredValue(raw)) ?? false
            if imported != SettingsNumericCoercion.bool(key, default: false, in: defaults) {
                rows.append("\(label): \(imported ? "on" : "off")")
            }
        }
        if let raw = config[SettingsKeys.mcpServers], let blob = restoredValue(raw) as? Data {
            do {
                let servers = try JSONDecoder().decode([MCPServer].self, from: blob)
                for server in servers where server.transport.isLocal && server.isConfigured {
                    rows.append("MCP '\(server.name)': \(([server.command] + server.arguments).joined(separator: " "))")
                }
            } catch {
                // A present-but-undecodable MCP blob used to read as "no MCP
                // risk". The consent surface cannot be computed, so the
                // import must fail safe rather than summarize partially.
                // Foundation error strings carry typographic quotes; the
                // user-visible reason stays ASCII (product doctrine).
                let detail = error.localizedDescription
                    .replacingOccurrences(of: "\u{201C}", with: "\"")
                    .replacingOccurrences(of: "\u{201D}", with: "\"")
                    .replacingOccurrences(of: "\u{2019}", with: "'")
                let ascii = String(detail.unicodeScalars.filter { $0.isASCII })
                return .unavailable("the MCP server list cannot be decoded (\(ascii))")
            }
        }
        return rows.isEmpty ? .none : .rows(rows)
    }

    private static func archiveValue(_ value: Any) -> Any {
        if let data = value as? Data { return ["$data": data.base64EncodedString()] }
        if let array = value as? [Any] { return array.map(archiveValue) }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(archiveValue)
        }
        return value
    }

    private static func restoredValue(_ value: Any) -> Any {
        if let tagged = value as? [String: Any], tagged.count == 1,
           let encoded = tagged["$data"] as? String, let data = Data(base64Encoded: encoded) {
            return data
        }
        if let array = value as? [Any] { return array.map(restoredValue) }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(restoredValue)
        }
        return value
    }

    /// What a Bool tool switch becomes after import: a typed Bool or number
    /// reads as itself, a String only through the registry's parseBool
    /// spellings (the import never stores a String for a registered key),
    /// and anything else (NSNull, garbage) is the declared off state the
    /// import leaves behind.
    private static func importedToolSwitchValue(_ value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let text = value as? String { return SettingsNumericCoercion.parseBool(text) }
        return nil
    }
}
