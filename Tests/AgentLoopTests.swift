// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Agentic-core slice: transient-only retry classification (read-only tools
/// retry; deterministic failures and side-effecting tools never do) and the
/// per-conversation usage rollup.
final class AgentLoopTests: CheckCase {
    func testTransportHiccupsAreTransient() {
        XCTAssertTrue(ChatToolsService.isTransient(URLError(.timedOut)))
        XCTAssertTrue(ChatToolsService.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(ChatToolsService.isTransient(URLError(.cannotConnectToHost)))
    }

    func testDeterministicFailuresAreNotTransient() {
        XCTAssertFalse(ChatToolsService.isTransient(URLError(.badURL)))
        XCTAssertFalse(ChatToolsService.isTransient(ChatToolsError.server(status: 404, message: "no such tool")))
        XCTAssertFalse(ChatToolsService.isTransient(ChatToolsError.invalidResponse))
    }

    func testServerSide5xxIsTransient() {
        XCTAssertTrue(ChatToolsService.isTransient(ChatToolsError.server(status: 502, message: "bad gateway")))
        XCTAssertTrue(ChatToolsService.isTransient(ChatToolsError.server(status: 503, message: "busy")))
    }

    func testUsageRollupSumsGeneratedAndCountsTurns() {
        var first = ChatMessage(role: "assistant", content: "a")
        first.timings = ChatTimings(promptTokens: 100, generatedTokens: 50)
        var second = ChatMessage(role: "assistant", content: "b")
        second.timings = ChatTimings(promptTokens: 300, generatedTokens: 120)

        let plain = ChatMessage(role: "user", content: "hi")
        let rollup = ChatStore.usageRollup(messages: [first, second, plain])
        XCTAssertEqual(rollup?.turns, 2)
        XCTAssertEqual(rollup?.generatedTokens, 170)
        XCTAssertEqual(rollup?.peakWindow, 420)
    }

    func testDynamicToolResultCapShrinksNearAFullWindow() {
        // Roomy window: the static ceiling applies.
        XCTAssertEqual(ChatToolsService.dynamicToolResultCap(windowTokens: 32_768, usedTokens: 0),
                       ChatToolsService.toolResultContextLimit)
        // Half full: a quarter of the remaining headroom, in characters.
        XCTAssertEqual(ChatToolsService.dynamicToolResultCap(windowTokens: 16_384, usedTokens: 8_192),
                       (16_384 - 8_192) / 4 * 4)
        // Nearly full: floored so a tool result is never uselessly tiny.
        XCTAssertEqual(ChatToolsService.dynamicToolResultCap(windowTokens: 16_384, usedTokens: 16_000), 2_000)
        // Over the line (estimate drift): still the floor, never zero or negative.
        XCTAssertEqual(ChatToolsService.dynamicToolResultCap(windowTokens: 16_384, usedTokens: 20_000), 2_000)
    }

    /// Every statically shipped tool must pass schema validation — a broken
    /// definition would be dropped at registration, silently disabling the
    /// tool; this pins the definitions themselves.
    func testAllShippedToolSchemasValidate() {
        for info in [JavaScriptSandboxService.tool] + ChatMemoryService.tools {
            XCTAssertEqual(ChatToolsService.schemaProblems(for: info), [],
                           "\(info.name): \(ChatToolsService.schemaProblems(for: info).joined(separator: "; "))")
        }
    }

    func testSchemaValidationCatchesBrokenDefinitions() {
        let broken = BuiltinToolInfo(
            displayName: "Broken", name: "", writesData: false,
            definition: [
                "type": "function",
                "function": [
                    "name": "broken",
                    "description": "",
                    "parameters": [
                        "type": "object",
                        "properties": ["task": ["type": "string"]],
                        "required": ["missing"],
                    ],
                ],
            ])
        let problems = ChatToolsService.schemaProblems(for: broken)
        XCTAssertTrue(problems.contains { $0.contains("name is empty") })
        XCTAssertTrue(problems.contains { $0.contains("description is empty") })
        XCTAssertTrue(problems.contains { $0.contains("required property \"missing\"") })
    }


    func testUsageRollupNilWithoutTimings() {
        XCTAssertNil(ChatStore.usageRollup(messages: [ChatMessage(role: "user", content: "hi")]))
    }
}

// MARK: - Generated registration (port from XCTest)
extension AgentLoopTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "AgentLoopTests",
        instance: { AgentLoopTests() },
        checks: [
            .init(name: "testTransportHiccupsAreTransient") { $0.testTransportHiccupsAreTransient() },
            .init(name: "testDeterministicFailuresAreNotTransient") { $0.testDeterministicFailuresAreNotTransient() },
            .init(name: "testServerSide5xxIsTransient") { $0.testServerSide5xxIsTransient() },
            .init(name: "testUsageRollupSumsGeneratedAndCountsTurns") { $0.testUsageRollupSumsGeneratedAndCountsTurns() },
            .init(name: "testDynamicToolResultCapShrinksNearAFullWindow") { $0.testDynamicToolResultCapShrinksNearAFullWindow() },
            .init(name: "testAllShippedToolSchemasValidate") { $0.testAllShippedToolSchemasValidate() },
            .init(name: "testSchemaValidationCatchesBrokenDefinitions") { $0.testSchemaValidationCatchesBrokenDefinitions() },
            .init(name: "testUsageRollupNilWithoutTimings") { $0.testUsageRollupNilWithoutTimings() },
        ])
}
