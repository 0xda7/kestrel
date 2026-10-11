import Foundation
import os

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
    /// Legacy pre-route shared credential; still read as a fallback so an
    /// upgrade never silently drops a working provider key.
    static let legacyKeychainAccount = "remote-api-key"

    static func load() -> [InferenceRoute] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let routes = try? JSONDecoder().decode([InferenceRoute].self, from: data) else { return [] }
        return routes
    }

    static func save(_ routes: [InferenceRoute]) {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        // A route re-created in the editor keeps its name but gets a new id.
        // Re-bind the active selection by name before giving up on it: an
        // edit must never silently strand the chat on the local engine while
        // Settings still lists the provider as configured.
        if let active = activeID, !routes.contains(where: { $0.id.uuidString == active }) {
            let previous = load().first(where: { $0.id.uuidString == active })
            let rebound = previous?.name.isEmpty == false
                ? routes.first(where: { $0.name == previous?.name })
                : nil
            if let rebound {
                UserDefaults.standard.set(rebound.id.uuidString, forKey: activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeKey)
            }
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

    // MARK: Per-provider credentials (Keychain, one item per route)

    /// Session cache of resolved credentials. Every uncached Keychain READ
    /// decrypts the secret and evaluates the item's ACL — on ad-hoc local
    /// builds that raises the password dialog once per item per launch. The
    /// chat send path resolves the active route's key on EVERY message, so
    /// this cache is what turns a per-message prompt into at most one per
    /// launch. setAPIKey/delete keep it coherent.
    private static let keyCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private static func keychainAccount(for routeID: UUID) -> String {
        "remote-api-key-\(routeID.uuidString)"
    }

    /// The credential for one route: its own Keychain item when set, else the
    /// legacy shared item (migration happens when the user saves a new key).
    /// Cached in-process after the first successful read.
    static func apiKey(for route: InferenceRoute) -> String {
        let account = keychainAccount(for: route.id)
        if let cached = keyCache.withLock({ $0[account] }) {
            return cached
        }
        let scoped = Keychain.get(account) ?? ""
        if !scoped.isEmpty {
            keyCache.withLock { $0[account] = scoped }
            return scoped
        }
        let legacy = Keychain.get(legacyKeychainAccount) ?? ""
        if !legacy.isEmpty {
            keyCache.withLock { $0[account] = legacy }
        }
        return legacy
    }

    /// Existence check WITHOUT decrypting: settings UI and migration logic
    /// only need to know whether a key is present, and a metadata probe never
    /// evaluates the item's ACL, so this never raises the access dialog.
    static func hasAPIKey(for route: InferenceRoute) -> Bool {
        let account = keychainAccount(for: route.id)
        if keyCache.withLock({ $0[account] }) != nil { return true }
        return Keychain.exists(account) || Keychain.exists(legacyKeychainAccount)
    }

    /// Stores (or clears with an empty string) the route's credential. Saving
    /// a scoped key removes the legacy shared item only when every configured
    /// route now carries its own, so nothing loses access mid-migration.
    static func setAPIKey(_ key: String, for route: InferenceRoute) {
        let account = keychainAccount(for: route.id)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account)
        } else {
            Keychain.setThisDeviceOnly(trimmed, account: account)
        }
        if trimmed.isEmpty {
            _ = keyCache.withLock { $0.removeValue(forKey: account) }
        } else {
            keyCache.withLock { $0[account] = trimmed }
        }
        let unscoped = load().filter { $0.isConfigured }.allSatisfy {
            hasAPIKey(for: $0)
        }
        if unscoped { Keychain.delete(legacyKeychainAccount) }
    }

    /// True when the legacy shared item still exists (shown in settings so the
    /// user can see which providers are on migrated vs inherited credentials).
    static var legacySharedKeyPresent: Bool {
        Keychain.exists(legacyKeychainAccount)
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
    /// `remoteAPIKey` is the route's credential, resolved by the caller from
    /// `InferenceRoutes.apiKey(for:)` — RouteWire stays a pure transform.
    static func wire(body: [String: Any], port: Int, route: InferenceRoute?,
                     localAPIKey: String?, remoteAPIKey: String? = nil) -> RouteWire {
        guard let route else {
            var headers: [(String, String)] = [("Content-Type", "application/json")]
            if let localAPIKey { headers.append(("Authorization", "Bearer " + localAPIKey)) }
            // Component-based construction: an out-of-range settings port
            // yields nil here, and the request fails with a normal connection
            // error instead of crashing on a force-unwrap.
            var comps = URLComponents()
            comps.scheme = "http"
            comps.host = "127.0.0.1"
            comps.port = port
            comps.path = "/v1/chat/completions"
            let url = comps.url ?? URL(fileURLWithPath: "/dev/null")
            return RouteWire(url: url, headers: headers, body: body)
        }
        switch route.dialect {
        case .localLlama, .openAI:
            return openAI(body: body, route: route, apiKey: remoteAPIKey)
        case .anthropic:
            return anthropic(body: body, route: route, apiKey: remoteAPIKey)
        }
    }

    private static func openAI(body: [String: Any], route: InferenceRoute,
                               apiKey: String?) -> RouteWire {
        var wire = body
        for key in llamaOnlyFields { wire.removeValue(forKey: key) }
        wire["model"] = route.modelID
        var headers: [(String, String)] = [("Content-Type", "application/json")]
        if let apiKey, !apiKey.isEmpty {
            headers.append(("Authorization", "Bearer " + apiKey))
        }
        let base = route.normalizedURL ?? URL(fileURLWithPath: "/dev/null")
        let url = URL(string: base.absoluteString + "/chat/completions") ?? base
        return RouteWire(url: url, headers: headers, body: wire)
    }

    private static func anthropic(body: [String: Any], route: InferenceRoute,
                                  apiKey: String?) -> RouteWire {
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
                if role == "tool" {
                    // Anthropic has no "tool" role: a tool result becomes a
                    // user message carrying one tool_result block, paired to
                    // the call by tool_use_id (Messages API shape).
                    var block: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": (message["tool_call_id"] as? String) ?? "",
                        "content": Self.textContent(of: message["content"] ?? ""),
                    ]
                    if let error = message["error"] as? Bool, error {
                        block["is_error"] = true
                    }
                    remapped.append(["role": "user", "content": [block]])
                    continue
                }
                if role == "assistant", let calls = message["tool_calls"] as? [[String: Any]],
                   !calls.isEmpty {
                    // Assistant tool calls become tool_use content blocks; any
                    // accompanying text is preserved as the first text block.
                    var blocks: [[String: Any]] = []
                    let text = Self.textContent(of: message["content"] ?? "")
                    if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                    for call in calls {
                        guard let fn = call["function"] as? [String: Any],
                              let name = fn["name"] as? String else { continue }
                        let rawArgs = (fn["arguments"] as? String) ?? "{}"
                        let input = (try? JSONSerialization.jsonObject(
                            with: Data(rawArgs.utf8))) as? [String: Any] ?? [:]
                        blocks.append(["type": "tool_use",
                                       "id": (call["id"] as? String) ?? "",
                                       "name": name,
                                       "input": input])
                    }
                    remapped.append(["role": "assistant", "content": blocks])
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
        if let apiKey, !apiKey.isEmpty {
            headers.append(("x-api-key", apiKey))
        }
        let base = route.normalizedURL ?? URL(fileURLWithPath: "/dev/null")
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
