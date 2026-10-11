// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct ChatStreamEvent {
    var receivedContent = false
    var receivedToolCall = false
    var progress: Double?
    var completed = false
}

struct ChatStreamAccumulator {
    var reasoning = ""
    var visible = ""
    var usage: (prompt: Int, completion: Int)?
    var timings: ChatTimings?
    var mtpAccept: Double?
    var finishReason: String?
    private(set) var toolCalls: [ChatToolCall] = []
    // Anthropic streams key deltas by content-block index; tool_use blocks
    // map to positions in `toolCalls` through this table.
    private var anthropicToolBlocks: [Int: Int] = [:]
    private var anthropicPromptTokens: Int?
    private var anthropicCompletionTokens: Int?

    mutating func consume(_ line: String) throws -> ChatStreamEvent? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" { return ChatStreamEvent(completed: true) }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let message = ChatStore.streamedError(from: object) {
            throw StreamError(message: message)
        }

        // Anthropic dialect: every event carries a top-level "type"
        // (message_start, content_block_delta, ...). Translated here so the
        // UI and the tool loop read the same accumulator state for both
        // dialects; OpenAI chunks have no such "type" and fall through.
        if let type = object["type"] as? String {
            return try consumeAnthropic(type, object)
        }

        if let value = object["usage"] as? [String: Any],
           let prompt = (value["prompt_tokens"] as? NSNumber)?.intValue,
           let completion = (value["completion_tokens"] as? NSNumber)?.intValue {
            usage = (prompt, completion)
        }

        if let value = object["timings"] as? [String: Any] {
            if let parsed = ChatTimings(json: value) { timings = parsed }
            if let drafted = (value["draft_n"] as? NSNumber)?.intValue, drafted > 0,
               let accepted = (value["draft_n_accepted"] as? NSNumber)?.intValue {
                mtpAccept = Double(accepted) / Double(drafted)
            }
        }

        var event = ChatStreamEvent()
        if let value = object["prompt_progress"] as? [String: Any],
           let processed = (value["processed"] as? NSNumber)?.intValue,
           let total = (value["total"] as? NSNumber)?.intValue, total > 0 {
            event.progress = min(1, Double(processed) / Double(total))
        }

        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return event }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            finishReason = reason
        }
        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["reasoning_content"] as? String, !text.isEmpty {
                reasoning += text
                event.receivedContent = true
            }
            // OpenRouter-style gateways (and the XLaunch gateway) send reasoning
            // as `reasoning` with an optional `reasoning_details` sidecar.
            if let text = (delta["reasoning"] as? String) ?? (delta["reasoning_details"] as? [String: Any]).flatMap({ $0["text"] as? String }), !text.isEmpty {
                reasoning += text
                event.receivedContent = true
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                visible += text
                event.receivedContent = true
            }
            if let fragments = delta["tool_calls"] as? [[String: Any]] {
                mergeToolCalls(fragments)
                event.receivedToolCall = !fragments.isEmpty
            }
        }
        return event
    }

    private mutating func mergeToolCalls(_ fragments: [[String: Any]]) {
        for fragment in fragments {
            let index = (fragment["index"] as? NSNumber)?.intValue ?? toolCalls.count
            // A malformed or hostile chunk can carry a negative index: the
            // grow-loop below never runs for it and the subscript would trap,
            // killing the app mid-generation. Skip the fragment instead.
            guard index >= 0 else { continue }
            while toolCalls.count <= index {
                toolCalls.append(ChatToolCall(name: "", arguments: ""))
            }
            if let id = fragment["id"] as? String, !id.isEmpty { toolCalls[index].serverID = id }
            guard let function = fragment["function"] as? [String: Any] else { continue }
            if let name = function["name"] as? String { toolCalls[index].name += name }
            if let arguments = function["arguments"] as? String { toolCalls[index].arguments += arguments }
        }
    }

    // MARK: Anthropic SSE translation

    /// Translates Anthropic Messages-API events into the same accumulator
    /// state the OpenAI path fills: message_start → usage seed,
    /// content_block_delta (text_delta / thinking_delta) → visible/reasoning,
    /// content_block_start (tool_use) → tool call, message_delta →
    /// finish_reason, message_stop → completion. Errors arrive as
    /// {"type":"error",...} and surface as a thrown StreamError.
    private mutating func consumeAnthropic(_ type: String, _ object: [String: Any]) throws -> ChatStreamEvent {
        switch type {
        case "message_start":
            let usage = object["message"] as? [String: Any]
            anthropicPromptTokens = (usage?["usage"] as? [String: Any])
                .flatMap { ($0["input_tokens"] as? NSNumber)?.intValue }
            return ChatStreamEvent()

        case "content_block_start":
            if let block = object["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use" {
                mergeAnthropicToolBlock(block, index: (object["index"] as? NSNumber)?.intValue ?? 0)
            }
            return ChatStreamEvent()

        case "content_block_delta":
            var event = ChatStreamEvent()
            guard let delta = object["delta"] as? [String: Any] else { return event }
            switch delta["type"] as? String {
            case "thinking_delta":
                if let text = delta["thinking"] as? String, !text.isEmpty {
                    reasoning += text
                    event.receivedContent = true
                }
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty {
                    visible += text
                    event.receivedContent = true
                }
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String, !partial.isEmpty,
                   let index = (object["index"] as? NSNumber)?.intValue,
                   let callIndex = anthropicToolBlocks[index] {
                    toolCalls[callIndex].arguments += partial
                    event.receivedToolCall = true
                }
            default:
                break
            }
            return event

        case "message_delta":
            let event = ChatStreamEvent()
            if let delta = object["delta"] as? [String: Any],
               let stop = delta["stop_reason"] as? String, !stop.isEmpty {
                finishReason = Self.anthropicFinish(stop)
            }
            if let usageBlock = object["usage"] as? [String: Any] {
                if let out = (usageBlock["output_tokens"] as? NSNumber)?.intValue {
                    anthropicCompletionTokens = out
                }
                // Final usage row for the metrics card, matching the OpenAI shape.
                if let pin = anthropicPromptTokens, let pout = anthropicCompletionTokens {
                    usage = (pin, pout)
                }
            }
            return event

        case "message_stop":
            return ChatStreamEvent(completed: true)

        case "ping":
            return ChatStreamEvent()

        case "error":
            let detail = (object["error"] as? [String: Any])?["message"] as? String
            throw StreamError(message: detail ?? "The provider reported a stream error")

        default:
            return ChatStreamEvent()
        }
    }

    private mutating func mergeAnthropicToolBlock(_ block: [String: Any], index: Int) {
        let callIndex = toolCalls.count
        anthropicToolBlocks[index] = callIndex
        var call = ChatToolCall(name: block["name"] as? String ?? "",
                                arguments: block["input"] as? String ?? "")
        if let id = block["id"] as? String, !id.isEmpty { call.serverID = id }
        toolCalls.append(call)
    }

    /// Maps Anthropic stop reasons onto the finish_reason vocabulary the
    /// transcript/metrics code already handles.
    static func anthropicFinish(_ stopReason: String) -> String {
        switch stopReason {
        case "end_turn", "stop_sequence": return "stop"
        case "max_tokens": return "length"
        case "tool_use": return "tool_calls"
        default: return stopReason
        }
    }
}

enum ChatStreamIdentity {
    static func value(conversationID: UUID, model: String?) -> String {
        guard let model, !model.isEmpty else { return conversationID.uuidString }
        return "\(conversationID.uuidString)::\(model)"
    }

    /// The engine keys a session by the conv_id query parameter, not by a path segment.
    static func resumeURL(port: Int, identity: String, from offset: Int) -> URL? {
        var comps = URLComponents(string: "http://127.0.0.1:\(port)/v1/stream")
        comps?.percentEncodedQueryItems = [URLQueryItem(name: "conv_id", value: encode(identity)),
                                           URLQueryItem(name: "from", value: String(offset))]
        return comps?.url
    }

    /// DELETE here cancels the generation. Closing the connection does not: the engine
    /// keeps a keyed stream running so a dropped client can pick it up again.
    static func stopURL(port: Int, identity: String) -> URL? {
        var comps = URLComponents(string: "http://127.0.0.1:\(port)/v1/stream")
        comps?.percentEncodedQueryItems = [URLQueryItem(name: "conv_id", value: encode(identity))]
        return comps?.url
    }

    private static func encode(_ identity: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "/&=+?#")
        return identity.addingPercentEncoding(withAllowedCharacters: allowed) ?? identity
    }
}
