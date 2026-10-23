// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum MCPTransport: String, Codable, CaseIterable, Identifiable {
    case automatic
    case stdio
    case streamableHTTP
    case serverSentEvents
    case webSocket

    var id: String { rawValue }
    /// A local server is launched by the app and speaks over its pipes; the rest
    /// are reached at a URL.
    var isLocal: Bool { self == .stdio }
}

struct MCPServer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
    var transport = MCPTransport.automatic
    var timeoutSeconds = 60
    /// stdio only: the executable to launch, its arguments, its environment and
    /// the directory to run it in.
    var command = ""
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var workingDirectory = ""

    var credentialAccount: String { "mcp-headers-\(id.uuidString)" }

    /// What the row shows as the server's address.
    var addressLabel: String {
        transport.isLocal
            ? ([command] + arguments).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            : url
    }

    var isConfigured: Bool {
        transport.isLocal ? !command.trimmingCharacters(in: .whitespaces).isEmpty : !url.isEmpty
    }
}

/// The `mcpServers` object every other MCP client uses, so a configuration can be
/// pasted in rather than retyped field by field.
enum MCPConfigImport {
    static func servers(fromJSON text: String) throws -> [MCPServer] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidConfig("The text is not valid JSON.")
        }
        // Accept both the wrapper and the bare map of servers.
        let entries = (root["mcpServers"] as? [String: Any]) ?? (root["servers"] as? [String: Any]) ?? root
        guard !entries.isEmpty else { throw MCPError.invalidConfig("No servers found in the configuration.") }

        var output: [MCPServer] = []
        for name in entries.keys.sorted() {
            guard let entry = entries[name] as? [String: Any] else { continue }
            var server = MCPServer(name: name, url: "")
            if let disabled = entry["disabled"] as? Bool { server.enabled = !disabled }
            let declared = (entry["type"] as? String) ?? (entry["transport"] as? String)
            let command = (entry["command"] as? String) ?? ""

            if !command.isEmpty || declared == "stdio" {
                server.transport = .stdio
                server.command = command
                server.arguments = (entry["args"] as? [String]) ?? []
                server.environment = (entry["env"] as? [String: String]) ?? [:]
                server.workingDirectory = (entry["cwd"] as? String) ?? ""
            } else if let url = entry["url"] as? String, !url.isEmpty {
                server.url = url
                switch declared {
                case "sse": server.transport = .serverSentEvents
                case "websocket", "ws": server.transport = .webSocket
                case "http", "streamable-http", "streamableHttp": server.transport = .streamableHTTP
                default: server.transport = .automatic
                }
            } else {
                continue
            }
            output.append(server)
        }
        guard !output.isEmpty else {
            throw MCPError.invalidConfig("No entry had a command or a url.")
        }
        return output
    }
}

enum MCPServerStore {
    /// The raw stored bytes, the cache key for tool discovery: any edit,
    /// addition or removal changes it.
    static func savedData() -> Data? {
        UserDefaults.standard.data(forKey: SettingsKeys.mcpServers)
    }

    static func load() -> [MCPServer] {
        guard let data = savedData(),
              let servers = try? JSONDecoder().decode([MCPServer].self, from: data) else { return [] }
        return servers
    }

    static func save(_ servers: [MCPServer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: SettingsKeys.mcpServers)
    }

    static func deleteCredentials(for server: MCPServer) {
        Keychain.delete(server.credentialAccount)
    }
}

enum MCPError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidConfig(String)
    case launchFailed(String)
    case remote(String)
    /// Guardian slice (2026-10-23): stored credential headers were about to
    /// ride a cleartext transport to a remote host.
    case cleartextCredentials(host: String, scheme: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid MCP server URL."
        case .invalidConfig(let reason): return reason
        case .launchFailed(let reason): return reason
        case .invalidResponse: return "The MCP server returned an invalid JSON-RPC response."
        case let .remote(message): return message
        case let .cleartextCredentials(host, scheme):
            return "Refusing to send MCP credentials to \(host) over \(scheme): remote MCP servers must use https or wss; loopback hosts (127.0.0.1, localhost, ::1) may keep http or ws."
        }
    }
}

/// Guardian slice (2026-10-23): the InferenceRoute.insecureHosts TLS
/// doctrine applied to MCP transports. Stored credential headers ride
/// every network request applyHeaders builds, so a remote MCP server
/// must speak https/wss; loopback keeps plain http/ws, which is what
/// keeps the default settings row (http://127.0.0.1:3000/mcp)
/// connecting unchanged.
enum MCPTransportSecurity {
    /// Throws the typed cleartextCredentials error for a non-TLS scheme on
    /// a non-loopback host. Called on every network transport BEFORE any
    /// request is built, so credentials can never reach the wire in
    /// cleartext. Internal so the check suite can pin the rule.
    static func requireTLSCredentialTransport(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw MCPError.invalidURL
        }
        if scheme == "https" || scheme == "wss" { return }
        if !InferenceRoute.insecureHosts.contains(host) {
            throw MCPError.cleartextCredentials(host: host, scheme: scheme)
        }
    }
}

struct MCPResourceItem: Identifiable, Sendable {
    let serverID: UUID
    let serverName: String
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
    var id: String { "\(serverID.uuidString)::\(uri)" }
}

struct MCPPromptArgument: Sendable, Identifiable {
    let name: String
    let description: String?
    let required: Bool
    var id: String { name }
}

struct MCPPromptItem: Identifiable, Sendable {
    let serverID: UUID
    let serverName: String
    let name: String
    let title: String?
    let description: String?
    let arguments: [MCPPromptArgument]
    var id: String { "\(serverID.uuidString)::\(name)" }
}

struct MCPResourceTemplateItem: Identifiable, Sendable {
    let serverID: UUID
    let serverName: String
    let uriTemplate: String
    let name: String
    let description: String?
    let mimeType: String?
    var variables: [String] { MCPURITemplate.variables(in: uriTemplate) }
    var id: String { "\(serverID.uuidString)::template::\(uriTemplate)" }
}

enum MCPURITemplate {
    static func variables(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([^}]+)\}"#) else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        var seen = Set<String>()
        return regex.matches(in: template, range: range).flatMap { match -> [String] in
            guard let valueRange = Range(match.range(at: 1), in: template) else { return [] }
            return template[valueRange].drop(while: { "+#./;?&".contains($0) })
                .split(separator: ",")
                .map { String($0.split(separator: ":").first ?? $0).replacingOccurrences(of: "*", with: "") }
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func expand(_ template: String, values: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{([^}]+)\}"#) else { return template }
        var output = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let whole = Range(match.range(at: 0), in: template),
                  let expressionRange = Range(match.range(at: 1), in: template) else { continue }
            let expression = String(template[expressionRange])
            let operation = expression.first.map(String.init) ?? ""
            let hasOperator = "+#./;?&".contains(operation)
            let names = (hasOperator ? String(expression.dropFirst()) : expression)
                .split(separator: ",").map(String.init)
            let replacement: String
            if operation == "?" || operation == "&" {
                let pairs = names.compactMap { name -> String? in
                    guard let value = values[name], !value.isEmpty else { return nil }
                    return "\(encode(name))=\(encode(value))"
                }
                replacement = pairs.isEmpty ? "" : (operation == "?" ? "?" : "&") + pairs.joined(separator: "&")
            } else {
                let separator = operation == "/" ? "/" : operation == "." ? "." : ","
                let prefix = operation == "/" || operation == "." ? operation : operation == "#" ? "#" : ""
                let expanded = names.compactMap { name in values[name] }.map {
                    operation == "+" || operation == "#" ? reservedEncode($0) : encode($0)
                }
                replacement = expanded.isEmpty ? "" : prefix + expanded.joined(separator: separator)
            }
            output.replaceSubrange(whole, with: replacement)
        }
        return output
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }

    private static func reservedEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? value
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/")
        return set
    }()
}

struct MCPCatalog: Sendable {
    var resources: [MCPResourceItem] = []
    var templates: [MCPResourceTemplateItem] = []
    var prompts: [MCPPromptItem] = []
}
