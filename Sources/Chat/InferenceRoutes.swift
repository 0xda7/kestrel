import Foundation

// Remote inference routes: chat can run through a user-configured provider
// speaking the OpenAI or Anthropic dialect instead of the local patched
// llama-server. The engine path stays the default and is untouched; the
// provider model id is always user-entered, never a code constant.

enum InferenceDialect: String, Codable, CaseIterable, Identifiable {
    case localLlama
    case openAI
    case anthropic

    var id: String { rawValue }

    var title: (String, String) {
        switch self {
        case .localLlama: return ("Motor local", "Local engine")
        case .openAI: return ("Compatible OpenAI", "OpenAI-compatible")
        case .anthropic: return ("Compatible Anthropic", "Anthropic-compatible")
        }
    }
}

struct InferenceRoute: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var dialect: InferenceDialect = .openAI
    var baseURL: String = ""
    var modelID: String = ""
    /// Optional cap shown alongside the chat token control; nil = chat default.
    var maxTokensCap: Int?

    /// Hosts allowed to keep plain http. Everything else requires https.
    static let insecureHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    var normalizedURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
            ? trimmed : "https://" + trimmed
        guard var comps = URLComponents(string: withScheme),
              let host = comps.host, !host.isEmpty else { return nil }
        if comps.scheme?.lowercased() != "https", !Self.insecureHosts.contains(host) { return nil }
        if comps.path.isEmpty || comps.path == "/" { comps.path = "/v1" }
        return comps.url
    }

    var isConfigured: Bool { normalizedURL != nil && !modelID.trimmingCharacters(in: .whitespaces).isEmpty }
}

enum InferenceRoutes {
    static let storageKey = "inferenceRoutes"
    static let activeKey = "activeInferenceRoute"

    static func load() -> [InferenceRoute] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let routes = try? JSONDecoder().decode([InferenceRoute].self, from: data) else { return [] }
        return routes
    }

    static func save(_ routes: [InferenceRoute]) {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        // Dropping the active route with it gone keeps the resolver honest.
        if let active = activeID, !routes.contains(where: { $0.id.uuidString == active }) {
            UserDefaults.standard.removeObject(forKey: activeKey)
        }
    }

    static var activeID: String? { UserDefaults.standard.string(forKey: activeKey) }

    static func setActive(_ id: String?) {
        if let id { UserDefaults.standard.set(id, forKey: activeKey) }
        else { UserDefaults.standard.removeObject(forKey: activeKey) }
    }

    static func active() -> InferenceRoute? {
        guard let id = activeID,
              let route = load().first(where: { $0.id.uuidString == id }),
              route.isConfigured else { return nil }
        return route
    }
}

// MARK: - Wire transform (the single request-boundary seam)

struct RouteWire {
    let url: URL
    let headers: [(String, String)]
    let body: [String: Any]

    /// llama-server extensions that strict OpenAI endpoints reject.
    static let llamaOnlyFields: Set<String> = [
        "cache_prompt", "id_slot", "timings_per_token", "return_progress",
        "chat_template_kwargs", "thinking_budget_tokens", "reasoning_control",
        "min_p", "top_k", "repeat_penalty", "repeat_last_n",
        "dynatemp_range", "dynatemp_exponent", "xtc_probability", "xtc_threshold",
        "typ_p", "dry_multiplier", "dry_base", "dry_allowed_length",
        "dry_penalty_last_n", "backend_sampling", "samplers",
    ]

    /// Builds the wire form for a chat request. `route == nil` is the local
    /// engine passthrough: same URL, same headers, byte-identical body.
    static func wire(body: [String: Any], port: Int, route: InferenceRoute?,
                     localAPIKey: String?) -> RouteWire {
        guard let route else {
            var headers: [(String, String)] = [("Content-Type", "application/json")]
            if let localAPIKey { headers.append(("Authorization", "Bearer " + localAPIKey)) }
            return RouteWire(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
                             headers: headers, body: body)
        }
        switch route.dialect {
        case .localLlama, .openAI: return openAI(body: body, route: route)
        case .anthropic: return anthropic(body: body, route: route)
        }
    }

    private static func openAI(body: [String: Any], route: InferenceRoute) -> RouteWire {
        var wire = body
        for key in llamaOnlyFields { wire.removeValue(forKey: key) }
        wire["model"] = route.modelID
        var headers: [(String, String)] = [("Content-Type", "application/json")]
        if let key = Keychain.get("remote-api-key"), !key.isEmpty {
            headers.append(("Authorization", "Bearer " + key))
        }
        let base = route.normalizedURL!
        let url = URL(string: base.absoluteString + "/chat/completions") ?? base
        return RouteWire(url: url, headers: headers, body: wire)
    }

    private static func anthropic(body: [String: Any], route: InferenceRoute) -> RouteWire {
        var wire: [String: Any] = [
            "model": route.modelID,
            "max_tokens": (body["max_tokens"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? 4096,
            "stream": true,
        ]
        var systemParts: [String] = []
        if let messages = body["messages"] as? [[String: Any]] {
            var remapped: [[String: Any]] = []
            for message in messages {
                guard let role = message["role"] as? String else { continue }
                if role == "system" {
                    if let content = message["content"] {
                        systemParts.append(Self.textContent(of: content))
                    }
                    continue
                }
                remapped.append(["role": role, "content": message["content"] ?? ""])
            }
            wire["messages"] = remapped
        }
        if !systemParts.isEmpty { wire["system"] = systemParts.joined(separator: "\n\n") }
        if let temperature = body["temperature"] as? Double { wire["temperature"] = temperature }
        if let topP = body["top_p"] as? Double { wire["top_p"] = topP }
        if let stop = body["stop"] { wire["stop_sequences"] = stop }
        if let tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            wire["tools"] = tools.compactMap { tool -> [String: Any]? in
                guard let name = (tool["function"] as? [String: Any])?["name"] as? String,
                      let fn = tool["function"] as? [String: Any] else { return nil }
                var schema = fn["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]]
                if (schema["type"] as? String) == nil { schema["type"] = "object" }
                var out: [String: Any] = ["name": name, "input_schema": schema]
                if let desc = fn["description"] as? String { out["description"] = desc }
                return out
            }
            wire["tool_choice"] = ["type": "auto"]
        }
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("anthropic-version", "2023-06-01"),
        ]
        if let key = Keychain.get("remote-api-key"), !key.isEmpty {
            headers.append(("x-api-key", key))
        }
        let base = route.normalizedURL!
        // Accept a bare host (path forced to /v1 by normalization) and a
        // base already ending in /v1: the Messages API lives at /v1/messages.
        let path = base.path.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        let url = URL(string: base.absoluteString + path) ?? base
        return RouteWire(url: url, headers: headers, body: wire)
    }

    private static func textContent(of content: Any) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
