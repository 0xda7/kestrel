// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The M1 constrained actor against the bundled llama-server's
/// OpenAI-compatible endpoint.
///
/// Implements the three-rung ladder from MODEL-PROFILES-EVIDENCE.md, rung
/// chosen by the family profile (M8):
/// 1. **nativeTools** — POST `/v1/chat/completions` with `tools[]` +
///    `tool_choice:"required"`; the server grammar-constrains the call, so
///    a malformed call is unemittable. Parse `message.tool_calls`.
/// 2. **jsonEnvelope** — the same endpoint with `response_format
///    json_schema` over the ten-tool envelope; parse `content` as JSON and
///    translate to calls. GLM-4 rides this rung (its native channel emits
///    null tool_calls plus hallucinated narration). On rung-2 content that
///    names a known tool but fails envelope parse, the thrown error flags
///    `suspected_result_hallucination` (M4 tie-in, binding rule 4).
/// 3. **rescue** — plain completion, content scanned leniently for call
///    syntax (the APPROACH of Chat/ChatToolsService.swift `ToolCallRescue`,
///    reimplemented here small and Merlin-local; no Chat code is imported
///    or modified). Unprofiled families start here and auto-promote after
///    clean parses.
///
/// The actor also owns the wire transcript: the kernel spine prompt is the
/// system message, and user/assistant/tool turns roll underneath it, so
/// each `toolCalls(prompt:turn:)` is one completion over a coherent
/// conversation rather than a stateless one-shot.
///
/// All networking goes through `MerlinActorSession`: live runs use an
/// ephemeral URLSession; check runs hand the actor `scriptedResponses` and
/// every request is answered from that FIFO queue through a registered
/// `URLProtocol` — no check ever opens a real socket.
public struct LlamaServerActor: MerlinActor, MerlinActorWithFeedback {
    /// Loud configuration failure: a profile whose think floor exceeds the
    /// configured completion budget (a starved R1 silently doing nothing is
    /// worse than refusing to start), or a malformed server URL.
    public struct ProfileError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// A response-shaped failure from the server (bad status, unparsable
    /// body, rung parse failure). Carries the rung and — for content that
    /// narrates a tool call instead of emitting one — the
    /// `suspected_result_hallucination` flag (M4 tie-in).
    ///
    /// `parseFailure` splits the failure classes the kernel treats
    /// differently (2026-11-16 gate evidence: 6/14 Spark cells died to the
    /// first content-only completion): true means the server ANSWERED with
    /// a well-formed completion the rung could not turn into a tool call —
    /// model behavior, correctable with a disciplinary turn. False means
    /// transport/malformed-response trouble (HTTP error, dead socket,
    /// missing choices) — no in-loop nudge fixes a dead server, so the
    /// kernel ends the run and the host's restart policy owns recovery.
    public struct ActorError: Error, CustomStringConvertible {
        public let rung: String
        public let suspectedResultHallucination: Bool
        public let message: String
        /// The server answered but the completion yielded no usable tool
        /// call (parse class). See the type discussion above.
        public let parseFailure: Bool
        /// The model's own words (≤200 chars) when a completion was
        /// received — the corrective turn shows the model its narration so
        /// it recognizes the reply being corrected.
        public let responseExcerpt: String?
        /// The completion's `finish_reason` when known ("stop", "length",
        /// …). "length" means the completion budget truncated the reply —
        /// often mid-tool-call — which the correction must address by
        /// demanding terse, call-only replies.
        public let finishReason: String?

        public init(rung: String, suspectedResultHallucination: Bool, message: String,
                    parseFailure: Bool = false, responseExcerpt: String? = nil,
                    finishReason: String? = nil) {
            self.rung = rung
            self.suspectedResultHallucination = suspectedResultHallucination
            self.message = message
            self.parseFailure = parseFailure
            self.responseExcerpt = responseExcerpt
            self.finishReason = finishReason
        }

        public var description: String {
            if suspectedResultHallucination {
                return "[\(rung)] suspected_result_hallucination: \(message)"
            }
            return "[\(rung)] \(message)"
        }
    }

    /// One scripted turn for checks: the HTTP status and raw JSON body the
    /// next request receives.
    public struct MockResponse: Sendable {
        public let status: Int
        public let body: String
        public init(status: Int, body: String) {
            self.status = status
            self.body = body
        }
    }

    public let serverURL: URL
    public let modelPath: String
    public let profile: MerlinModelProfile
    /// The requested completion budget, as passed to init.
    public let requestedMaxTokens: Int
    public let temperature: Double
    /// Context budget recorded on requests (small models, flat context).
    public let contextTokens: Int
    /// Check-only response queue; nil on live runs.
    public let scriptedResponses: [MockResponse]?

    /// The effective completion budget sent to the server:
    /// `max(profile floor + headroom, requested)`. Construction with a
    /// requested budget below the floor is a LOUD `ProfileError`
    /// (think-budget rule), so the lazy clamp only ever raises a
    /// legal request, never papers over a starved one.
    public var maxTokens: Int {
        max(profile.minCompletionTokens + MerlinModelProfile.actionHeadroom, requestedMaxTokens)
    }

    private let session: MerlinActorSession

    /// - Parameters:
    ///   - serverURL: llama-server base (e.g. `http://127.0.0.1:8151`); the
    ///     actor posts to `<base>/v1/chat/completions`.
    ///   - modelPath: GGUF path or name; drives family detection upstream.
    ///   - profile: the M8 profile (from `MerlinProfileStore`).
    ///   - maxTokens: requested completion budget; must cover the think
    ///     floor or init throws.
    ///   - scriptedResponses: check-only request→response queue.
    public init(serverURL: URL, modelPath: String, profile: MerlinModelProfile,
                maxTokens: Int = 2048, temperature: Double = 0,
                contextTokens: Int = 8192, scriptedResponses: [MockResponse]? = nil) throws {
        guard let host = serverURL.host, !host.isEmpty,
              serverURL.scheme == "http" || serverURL.scheme == "https" else {
            throw ProfileError("invalid llama-server URL: \(serverURL)")
        }
        let floor = profile.minCompletionTokens + MerlinModelProfile.actionHeadroom
        guard maxTokens >= floor else {
            throw ProfileError(
                "profile '\(profile.family)' requires max_tokens >= \(floor) " +
                "(think floor \(profile.minCompletionTokens) + \(MerlinModelProfile.actionHeadroom) headroom); " +
                "configured max_tokens is \(maxTokens). A starved thinking model acts on nothing — " +
                "raise the budget instead of starving it.")
        }
        self.serverURL = serverURL
        self.modelPath = modelPath
        self.profile = profile
        self.requestedMaxTokens = maxTokens
        self.temperature = temperature
        self.contextTokens = contextTokens
        self.scriptedResponses = scriptedResponses
        self.session = MerlinActorSession(scriptedResponses: scriptedResponses)
    }

    // MARK: - Transcript (state lives on the session; the struct stays a
    // value type conforming to the non-mutating MerlinActor seam)

    /// The current transcript (system first). Exposed for checks.
    public var transcriptMessages: [[String: Any]] { session.currentMessages }

    /// The current system message text, if any. Exposed for checks.
    public var systemMessage: String? {
        transcriptMessages.first?["content"] as? String
    }

    /// Appends the model-visible user turn (tool results / instructions).
    public mutating func addUserMessage(_ text: String) {
        session.append(["role": "user", "content": text])
    }

    /// Appends an assistant turn as the model produced it, keeping the
    /// transcript coherent after a successful batch.
    public mutating func addAssistantMessage(content: String, toolCalls: [[String: Any]]) {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
        session.append(message)
    }

    /// Appends a tool-result turn keyed to a prior assistant tool_call id.
    public mutating func addToolResult(callID: String, tool: String, result: String) {
        session.append([
            "role": "tool",
            "tool_call_id": callID,
            "content": result,
            "name": tool,
        ])
    }

    // MARK: - MerlinActor

    /// One completion; returns the tool-call batch (1...4 by contract —
    /// the kernel clamps anyway, and this actor caps its own parses at 4).
    public func toolCalls(prompt: String, turn: Int) async throws -> [MerlinToolCall] {
        // Re-seat the spine as the system message (M0: no turn starts
        // amnesiac), then append THIS turn's user cue. Always appending —
        // rather than seeding once — keeps the template shape valid after
        // tool turns (assistant -> tool -> user) and carries the turn
        // counter into the visible context.
        session.upsertSystemMessage(prompt)
        session.append(["role": "user",
                        "content": "Begin turn \(turn). Use the tool contract above."])
        return try await complete()
    }

    // MARK: - MerlinActorWithFeedback (slice 3b)

    /// Appends the executed turn as real conversation BEFORE the next
    /// completion: an assistant turn carrying this batch's `tool_calls`
    /// wire block (stable ids `call_<turn>_<i>`), then one `role: "tool"`
    /// turn per call with the kernel-summarized result. This is the fix
    /// for the live-evidence transcript bug (eval-live T01 probes: without
    /// feedback turns the model re-issued the identical failing call 6/6
    /// turns — it could not see its own history; the actor's header always
    /// declared this shape, but no caller ever fed it). Rung-agnostic: an
    /// assistant-tool_calls + tool-result sequence is valid across the
    /// native/envelope/rescue chat templates. Stop-authority instructions
    /// ride as explicit user turns so the model reads the wrap-up demand as
    /// conversation, not only as a digest line inside the re-seated system
    /// message.
    public func receive(feedback: MerlinTurnFeedback) async {
        let toolCallsWire: [[String: Any]] = feedback.outcomes.enumerated().map { index, outcome in
            [
                "id": "call_\(feedback.turn)_\(index)",
                "type": "function",
                "function": ["name": outcome.call.name,
                             "arguments": outcome.call.argumentsJSON],
            ]
        }
        session.appendAssistantWithToolCalls(content: "", toolCalls: toolCallsWire)
        for (index, outcome) in feedback.outcomes.enumerated() {
            session.append([
                "role": "tool",
                "tool_call_id": "call_\(feedback.turn)_\(index)",
                "content": outcome.resultText,
                "name": outcome.call.name,
            ])
        }
        for instruction in feedback.stopAuthorityInstructions {
            session.append(["role": "user",
                            "content": "RUNTIME: \(instruction)"])
        }
    }

    /// Recoverable actor-failure seam (parse class): the kernel hands back
    /// what the model actually said plus the corrective instruction. The
    /// offending narration is appended as a plain assistant turn — it
    /// already happened on the wire, and hiding it would make the
    /// transcript lie about the conversation the server template must stay
    /// coherent with — then the instruction lands as an explicit user
    /// turn, the same conversational shape stop-authority instructions
    /// ride. The next `toolCalls` completion happens over a transcript
    /// where the model can see its own contract violation.
    public func receiveActorFailure(_ feedback: MerlinActorFailureFeedback) async {
        if let excerpt = feedback.responseExcerpt, !excerpt.isEmpty {
            session.append(["role": "assistant", "content": excerpt])
        }
        session.append(["role": "user", "content": "RUNTIME: \(feedback.instruction)"])
    }

    // MARK: - Wire

    private func complete() async throws -> [MerlinToolCall] {
        let endpoint = serverURL.appendingPathComponent("v1/chat/completions")
        switch profile.toolCallMode {
        case .nativeTools:
            let object = try await session.transmit(requestPayload(includeTools: true),
                                                    to: endpoint, rung: "nativeTools")
            return try Self.parseNativeTools(object)
        case .jsonEnvelope:
            let object = try await session.transmit(requestPayload(includeTools: false),
                                                    to: endpoint, rung: "jsonEnvelope")
            return try Self.parseEnvelope(object)
        case .rescue:
            let object = try await session.transmit(requestPayload(includeTools: false),
                                                    to: endpoint, rung: "rescue")
            return try Self.parseRescue(object)
        }
    }

    private func requestPayload(includeTools: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "model": (modelPath as NSString).lastPathComponent,
            "messages": session.currentMessages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "cache_prompt": true,
        ]
        if contextTokens > 0 { payload["n_ctx"] = contextTokens }
        if includeTools {
            payload["tools"] = MerlinToolSchema.openAIToolsPayload()
            payload["tool_choice"] = "required"
        } else {
            // Rung-2 grammar strength follows the profile (slice 6): the
            // shared shape enforces call SHAPE only; .perToolSchemas adds
            // one branch per tool carrying its registry schema, so
            // schema-sloppy argument keys (the GLM-4-9B soak finding)
            // become unemittable.
            payload["response_format"] = MerlinToolSchema.envelopeResponseFormat(
                mode: profile.envelopeMode)
        }
        return payload
    }

    // MARK: - Rung 1: native tools (parse exposed for checks)

    /// Parses the OpenAI tool_calls shape into Merlin calls. Throws with
    /// the hallucination flag when the rung-1 response narrates a tool in
    /// content while `tool_calls` came back empty. Every parse-class throw
    /// carries the finish reason and the model's own words so the kernel's
    /// corrective turn can quote them back.
    public static func parseNativeTools(_ object: [String: Any]) throws -> [MerlinToolCall] {
        guard let choices = object["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw ActorError(rung: "nativeTools", suspectedResultHallucination: false,
                             message: "response carries no choices")
        }
        let message = (choices[0]["message"] as? [String: Any]) ?? [:]
        let content = (message["content"] as? String) ?? ""
        let rawCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
        let finishReason = (choices[0]["finish_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let excerpt = content.isEmpty ? nil : String(content.prefix(200))

        var calls: [MerlinToolCall] = []
        for raw in rawCalls.prefix(4) {
            let function = (raw["function"] as? [String: Any]) ?? [:]
            guard let name = function["name"] as? String,
                  MerlinToolSchema.isKnownTool(name) else { continue }
            let arguments: String
            switch function["arguments"] {
            case let text as String:
                arguments = text
            case let dict as [String: Any]:
                arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8), as: UTF8.self)
            default:
                arguments = "{}"
            }
            calls.append(MerlinToolCall(name: name, argumentsJSON: arguments.isEmpty ? "{}" : arguments))
        }
        if calls.isEmpty {
            let flagged = MerlinToolSchema.definitions.contains { content.contains($0.name) }
            let finishNote = finishReason.map { " (finish_reason \($0))" } ?? ""
            throw ActorError(rung: "nativeTools", suspectedResultHallucination: flagged,
                             message: flagged
                                 ? "tool_calls empty but content narrates a tool call\(finishNote): \(content.prefix(200))"
                                 : "response carried no parseable tool calls\(finishNote); content: \"\(excerpt ?? "")\"",
                             parseFailure: true,
                             responseExcerpt: excerpt,
                             finishReason: finishReason)
        }
        return calls
    }

    // MARK: - Rung 2: json envelope (parse exposed for checks)

    /// Parses the rung-2 envelope: `content` is the grammar-locked JSON
    /// object `{"name": …, "arguments": …}`. Throws with
    /// `suspected_result_hallucination` when content names a known tool but
    /// fails envelope parse (binding rule 4) or names an unknown tool.
    public static func parseEnvelope(_ object: [String: Any]) throws -> [MerlinToolCall] {
        guard let choices = object["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw ActorError(rung: "jsonEnvelope", suspectedResultHallucination: false,
                             message: "response carries no choices")
        }
        let message = (choices[0]["message"] as? [String: Any]) ?? [:]
        let content = ((message["content"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = content.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = envelope["name"] as? String else {
            let flagged = MerlinToolSchema.definitions.contains { content.contains($0.name) }
            let finishReason = (choices[0]["finish_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            throw ActorError(rung: "jsonEnvelope", suspectedResultHallucination: flagged,
                             message: flagged
                                 ? "content names a tool but fails envelope parse: \(content.prefix(200))"
                                 : "envelope content is not a tool-call object: \(content.prefix(200))",
                             parseFailure: true,
                             responseExcerpt: content.isEmpty ? nil : String(content.prefix(200)),
                             finishReason: finishReason)
        }
        guard MerlinToolSchema.isKnownTool(name) else {
            throw ActorError(rung: "jsonEnvelope", suspectedResultHallucination: true,
                             message: "envelope names an unknown tool: \(name)",
                             parseFailure: true,
                             responseExcerpt: content.isEmpty ? nil : String(content.prefix(200)),
                             finishReason: (choices[0]["finish_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        let arguments = (envelope["arguments"] as? [String: Any]) ?? [:]
        let argumentsData: Data
        do {
            argumentsData = try JSONSerialization.data(withJSONObject: arguments)
        } catch {
            throw ActorError(rung: "jsonEnvelope", suspectedResultHallucination: false,
                             message: "arguments are not serializable JSON: \(error)")
        }
        return [MerlinToolCall(name: name, argumentsJSON: String(decoding: argumentsData, as: UTF8.self))]
    }

    // MARK: - Rung 3: rescue (parse exposed for checks)

    /// Lenient content parse (rung 3) on the APPROACH of ChatToolsService's
    /// ToolCallRescue: balanced `{...}` spans (bare, fenced, or
    /// `<tool_call>`-tagged), name-gated on the ten Merlin tools. Own small
    /// implementation — no Chat code imported.
    public static func parseRescue(_ object: [String: Any]) throws -> [MerlinToolCall] {
        guard let choices = object["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw ActorError(rung: "rescue", suspectedResultHallucination: false,
                             message: "response carries no choices")
        }
        let message = (choices[0]["message"] as? [String: Any]) ?? [:]
        let content = ((message["content"] as? String) ?? "")
        let calls = MerlinRescueCalls.parse(content: content,
                                            toolNames: MerlinToolSchema.knownToolNames,
                                            maxCalls: 4)
        if calls.isEmpty {
            let flagged = MerlinToolSchema.definitions.contains { content.contains($0.name) }
            let finishReason = (choices[0]["finish_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            throw ActorError(rung: "rescue", suspectedResultHallucination: flagged,
                             message: flagged
                                 ? "content names a tool but no call could be rescued: \(content.prefix(200))"
                                 : "content carries no rescuable tool call: \(content.prefix(200))",
                             parseFailure: true,
                             responseExcerpt: content.isEmpty ? nil : String(content.prefix(200)),
                             finishReason: finishReason)
        }
        return calls
    }
}

/// Rung-3 lenient parser. Deliberately small: balanced-brace span scan over
/// `<tool_call>`-tagged or whole content, name-gated on the known tools,
/// arguments re-serialized canonically. Mirrors the APPROACH of the engine's
/// ToolCallRescue without importing it.
public enum MerlinRescueCalls {
    /// Most calls rescued from one completion.
    public static let maxPerTurn = 4

    public static func parse(content: String, toolNames: Set<String>, maxCalls: Int = maxPerTurn) -> [MerlinToolCall] {
        guard !content.isEmpty else { return [] }
        var calls: [MerlinToolCall] = []
        for blob in candidateBlobs(in: content) {
            guard calls.count < maxCalls else { break }
            guard let data = blob.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rawName = (object["name"] ?? object["tool"] ?? object["tool_name"]) as? String,
                  toolNames.contains(rawName)
            else { continue }
            let arguments = (object["arguments"] ?? object["parameters"] ?? object["params"]) as? [String: Any] ?? [:]
            guard JSONSerialization.isValidJSONObject(arguments),
                  let argumentsData = try? JSONSerialization.data(withJSONObject: arguments)
            else { continue }
            calls.append(MerlinToolCall(name: rawName,
                                        argumentsJSON: String(decoding: argumentsData, as: UTF8.self)))
        }
        return calls
    }

    /// Balanced `{...}` spans that look like tool-call objects: bare,
    /// fenced (```…```), or `<tool_call>`-tagged. String-aware brace
    /// counting, so braces inside quoted values cannot break balancing.
    static func candidateBlobs(in text: String) -> [String] {
        var spans: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "<tool_call>", range: searchStart..<text.endIndex) {
            if let close = text.range(of: "</tool_call>", range: open.upperBound..<text.endIndex) {
                spans.append(open.upperBound..<close.lowerBound)
                searchStart = close.upperBound
            } else {
                break
            }
        }
        if spans.isEmpty { spans = [text.startIndex..<text.endIndex] }
        let chunks = spans.map { String(text[$0]) }
        var blobs: [String] = []
        for chunk in chunks {
            var depth = 0
            var start: String.Index?
            var inString = false
            var escaped = false
            for index in chunk.indices {
                let character = chunk[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                    continue
                }
                if character == "\"" {
                    inString = true
                    continue
                }
                if character == "{" {
                    if depth == 0 { start = index }
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0, let begin = start {
                        blobs.append(String(chunk[begin...index]))
                        start = nil
                        if blobs.count >= maxPerTurn { return blobs }
                    }
                }
            }
        }
        return blobs
    }
}

/// The actor's networking seam. Live runs POST through an ephemeral
/// URLSession; scripted runs (checks / soak replay) answer from a FIFO
/// queue through a registered URLProtocol, so no check ever opens a socket.
final class MerlinActorSession: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private let scripted: Bool

    /// Live transport: generous timeouts, CPU llama-server pace.
    static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    /// Scripted transport: every request is served by `MerlinMockURLProtocol`.
    static let mockSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MerlinMockURLProtocol.self]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    init(scriptedResponses: [LlamaServerActor.MockResponse]?) {
        self.scripted = scriptedResponses != nil
        if let responses = scriptedResponses {
            MerlinMockURLProtocol.reset(with: responses)
        }
    }

    // MARK: transcript (guarded)

    var currentMessages: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    func append(_ message: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    /// Appends an assistant message WITH a tool_calls wire block (slice 3b
    /// feedback path). Distinct from the struct-level `addAssistantMessage`
    /// so the kernel's feedback hand-back can append the turn directly on
    /// the session without the caller holding a mutable copy of the actor.
    func appendAssistantWithToolCalls(content: String, toolCalls: [[String: Any]]) {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
        append(message)
    }

    func upsertSystemMessage(_ prompt: String) {
        lock.lock()
        defer { lock.unlock() }
        if let first = messages.first, first["role"] as? String == "system" {
            messages[0] = ["role": "system", "content": prompt]
        } else {
            messages.insert(["role": "system", "content": prompt], at: 0)
        }
    }

    // MARK: transport

    /// POSTs the payload on the session's transport and returns the parsed
    /// top-level response object. Scripted sessions route through the mock
    /// protocol (which serves the FIFO queue); live sessions hit `url`
    /// directly.
    func transmit(_ payload: [String: Any], to url: URL, rung: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let session = scripted ? Self.mockSession : Self.urlSession
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LlamaServerActor.ActorError(rung: rung, suspectedResultHallucination: false,
                                              message: "server returned HTTP \(status): " +
                                                  String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LlamaServerActor.ActorError(rung: rung, suspectedResultHallucination: false,
                                              message: "response is not a JSON object: " +
                                                  String(decoding: data.prefix(300), as: UTF8.self))
        }
        return object
    }
}

/// The scripted transport: serves the queued responses FIFO to any request
/// and records each request body (read defensively — under URLProtocol the
/// body may arrive as a stream rather than `httpBody`).
final class MerlinMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [LlamaServerActor.MockResponse] = []
    nonisolated(unsafe) private static var observedRequests: [[String: Any]] = []

    static func reset(with responses: [LlamaServerActor.MockResponse]) {
        lock.lock()
        queue = responses
        observedRequests = []
        lock.unlock()
    }

    static func recordedRequests() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return observedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.queue.isEmpty
            ? LlamaServerActor.MockResponse(status: 500, body: "{\"error\":\"scripted queue empty\"}")
            : Self.queue.removeFirst()
        if let body = Self.requestBody(request),
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            Self.observedRequests.append(object)
        }
        Self.lock.unlock()
        let http = HTTPURLResponse(url: request.url ?? URL(string: "http://mock.invalid")!,
                                   statusCode: response.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
