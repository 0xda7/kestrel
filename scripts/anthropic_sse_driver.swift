// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// Standalone verification harness for ChatStreamAccumulator's Anthropic
// translation. Compiled against the REAL ChatStreamProtocol.swift and
// ChatParityModels.swift (unmodified) with minimal shims, because the
// command-line toolchain here ships no XCTest module (the app's gate is
// plain `swift build`). Usage:
//   scripts/gate_anthropic_stream.sh

#if canImport(Foundation)
import Foundation

// Shims for names the real files resolve elsewhere in the app target.
struct ChatAttachment: Codable, Equatable {}
struct Conversation: Codable, Equatable {}
struct ChatProject: Codable, Equatable {}
struct StreamError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}
enum ChatStore {
    static func streamedError(from object: [String: Any]) -> String? {
        guard let error = object["error"] else { return nil }
        if let details = error as? [String: Any],
           let message = details["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = error as? String, !message.isEmpty { return message }
        return "El motor interrumpió la respuesta / the engine interrupted the response"
    }
}

@main
enum AnthropicSSEDriver {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1, FileManager.default.fileExists(atPath: args[1]) else {
            fputs("usage: anthropic_sse_driver <sse-fixture>\n", stderr)
            exit(2)
        }
        var failures = 0
        func check(_ cond: Bool, _ label: String) {
            print((cond ? "PASS " : "FAIL ") + label)
            if !cond { failures += 1 }
        }
        func consume(_ acc: inout ChatStreamAccumulator, _ lines: [String],
                     completed: inout Bool, threw: inout String?) {
            for line in lines {
                do {
                    if let event = try acc.consume(line), event.completed { completed = true }
                } catch { threw = error.localizedDescription }
            }
        }

        // 1) The recorded live stream (gateway /v1/messages, sanitized id).
        let fixture = (try! String(contentsOfFile: args[1], encoding: .utf8))
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var acc = ChatStreamAccumulator()
        var completed = false
        var threw: String?
        consume(&acc, fixture, completed: &completed, threw: &threw)
        check(threw == nil, "fixture replay throws nothing (got: \(threw ?? "nil"))")
        check(acc.visible == "ANTHROPIC WIRE OK.", "visible (got: '\(acc.visible)')")
        check(!acc.reasoning.isEmpty, "reasoning captured")
        check(acc.usage?.prompt == 10, "usage.prompt == 10")
        check(acc.usage?.completion == 28, "usage.completion == 28")
        check(acc.finishReason == "stop", "end_turn → stop (got: \(acc.finishReason ?? "nil"))")
        check(completed, "message_stop → completed")
        check(acc.toolCalls.isEmpty, "no phantom tool calls")

        // 2) tool_use block → tool call shape (synthetic, spec-shaped).
        var toolAcc = ChatStreamAccumulator()
        var toolDone = false
        var toolThrew: String?
        consume(&toolAcc, [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"Madrid\"}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":17}}"#,
            #"data: {"type":"message_stop"}"#,
        ], completed: &toolDone, threw: &toolThrew)
        check(toolAcc.toolCalls.count == 1, "one tool call")
        check(toolAcc.toolCalls.first?.serverID == "toolu_1", "serverID")
        check(toolAcc.toolCalls.first?.name == "get_weather", "tool name")
        check(toolAcc.toolCalls.first?.arguments == #"{"city":"Madrid"}"#, "arguments assembled from input_json_delta")
        check(toolAcc.finishReason == "tool_calls", "tool_use → tool_calls")

        // 3) OpenAI chunk path unchanged (local engine regression).
        var oai = ChatStreamAccumulator()
        var oaiDone = false
        var oaiThrew: String?
        consume(&oai, [
            #"data: {"choices":[{"delta":{"reasoning":"why "}}]}"#,
            #"data: {"choices":[{"delta":{"content":"hello"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"data: [DONE]"#,
        ], completed: &oaiDone, threw: &oaiThrew)
        check(oai.reasoning == "why " && oai.visible == "hello", "OpenAI text+reasoning unchanged")
        check(oai.usage?.prompt == 3 && oai.usage?.completion == 2, "OpenAI usage unchanged")
        check(oai.finishReason == "stop" && oaiDone, "OpenAI finish + [DONE] unchanged")

        // 4) Anthropic error event surfaces as a StreamError.
        var errAcc = ChatStreamAccumulator()
        var errMsg: String?
        do { _ = try errAcc.consume(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) }
        catch { errMsg = error.localizedDescription }
        check(errMsg == "Overloaded", "error event → StreamError")

        print(failures == 0 ? "GATE GREEN" : "GATE RED: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
