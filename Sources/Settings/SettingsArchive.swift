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
            else { defaults.set(restoredValue(value), forKey: key) }
            count += 1
        }
        return count
    }

    /// KES-06: everything an import would restore that can spawn a process
    /// or change what gets spawned — engine and sidecar binary paths, MCP
    /// server commands, and extra engine arguments. The import UI shows this
    /// list and requires explicit approval before any of it is applied: a
    /// settings file handed to the user is otherwise one-click arbitrary
    /// process execution.
    static func processSpawningSummary(for data: Data, defaults: UserDefaults = .standard) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else { return [] }
        var rows: [String] = []
        let binaryKeys: [(String, String)] = [
            (SettingsKeys.serverBinary, "engine"),
            (SettingsKeys.latchBinaryPath, "latch"),
            (SettingsKeys.piBinaryPath, "pi"),
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
        if let raw = config[SettingsKeys.mcpServers], let blob = restoredValue(raw) as? Data,
           let servers = try? JSONDecoder().decode([MCPServer].self, from: blob) {
            for server in servers where server.transport.isLocal && server.isConfigured {
                rows.append("MCP '\(server.name)': \(([server.command] + server.arguments).joined(separator: " "))")
            }
        }
        return rows
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
}
