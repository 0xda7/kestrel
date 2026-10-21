// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One URLSession + one request builder for the engine's loopback control
/// plane: health probes, slot save/restore, stream stop, and the compaction
/// summarize call. These used to be ad-hoc `URLRequest`s scattered over
/// `URLSession.shared`, whose 60 s default timeout is sized for none of them
/// (a health poll that hangs blocks its 2 s loop for a minute). They now
/// share one session with the timeout a control request wants: fail fast
/// when the engine is wedged. The token stream keeps its own session
/// (`ChatStore.streamingSession`) — a byte stream must idle minutes between
/// tokens, which would be a pathological timeout for a probe. Paths that
/// legitimately run longer (a slot save flushing GiB of KV, a summarize
/// prefill) pass an explicit per-request timeout, which overrides the
/// session default.
enum EngineHTTP {
    /// 10 s with no bytes is a wedged engine, not a slow one.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// The shared request shape: method, JSON content type, and the optional
    /// bearer key protecting the engine. Every control-plane call site builds
    /// its request through this so method/headers cannot drift apart again.
    static func request(url: URL, method: String, timeout: TimeInterval? = nil,
                        apiKey: String?) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        return req
    }

    /// POST /slots/0?action=save|restore with the slot filename — the exact
    /// request the server controller (prewarm across restarts) and the chat
    /// store (KV persistence around turns) both issue, built once instead of
    /// once per file. Best-effort by contract: a failed save/restore means a
    /// cold prefill, never a failed turn.
    static func slotRequest(port: Int, action: String, filename: String,
                            timeout: TimeInterval) -> URLRequest? {
        guard var comps = URLComponents(string: "http://127.0.0.1:\(port)/slots/0") else { return nil }
        comps.queryItems = [URLQueryItem(name: "action", value: action)]
        guard let url = comps.url else { return nil }
        var req = request(url: url, method: "POST", timeout: timeout,
                          apiKey: ServerSettings.activeAPIKey())
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": filename])
        return req
    }
}
