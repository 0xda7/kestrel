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

    /// English-only agent path (operator directive 2026-10-14): the raw
    /// strings that reach the chat transcript — stream defaults, the context
    /// guard, tool rejection — must never carry a second language. The
    /// bilingual "es / en" pairs through loc.t() resolve to English at
    /// runtime and are fine; these bypass the localizer, so they are pinned
    /// directly.
    func testAgentPathStringsAreEnglishOnly() {
        let texts = [
            ChatStore.streamedError(from: ["error": ""]) ?? "",
            ChatStore.emptyResponseMessage(finishReason: "length"),
            ChatStore.emptyResponseMessage(finishReason: nil),
            ChatStore.contextOverflowNotice(estimated: 71_000, window: 65_536),
            ChatStore.toolsRejectedMessage,
        ]
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(" / "), "bilingual pair marker in: \(text.prefix(60))")
            for accent in "áéíóúñ¿¡" {
                XCTAssertFalse(text.contains(accent), "Spanish text in: \(text.prefix(60))")
            }
        }
        XCTAssertEqual(ChatStore.streamedError(from: ["error": "engine said no"]), "engine said no",
                       "the engine's own message passes through verbatim")
    }

    /// The native tool surface after the sidecar removals: the statically
    /// shipped app tools are exactly the JavaScript sandbox and the
    /// conversation-memory tools (the engine's exec/file tools arrive from
    /// the engine's own /tools list, MCP tools from discovery). A stray
    /// re-registration would double-advertise a name and shadow the real
    /// dispatch branch.
    func testNativeToolSurfaceIsExactlySandboxAndMemory() {
        let names = ([JavaScriptSandboxService.tool] + ChatMemoryService.tools).map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "no duplicated tool names")
        XCTAssertEqual(names.first, JavaScriptSandboxService.toolName)
        XCTAssertTrue(ChatMemoryService.toolNames.allSatisfy(names.contains))
        XCTAssertEqual(names.filter { $0 == JavaScriptSandboxService.toolName }.count, 1)
    }

    /// Tool discovery is cached per MCP configuration: an agent turn and the
    /// tools popover must not reopen every MCP server each time, and any
    /// change to the saved server list must invalidate the cache. Pin: the
    /// second identical call is a cache hit; after the stored list changes,
    /// discovery runs again.
    @MainActor func testMCPDiscoveryIsCachedUntilTheServerListChanges() async throws {
        let prior = UserDefaults.standard.data(forKey: SettingsKeys.mcpServers)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: SettingsKeys.mcpServers) }
            else { UserDefaults.standard.removeObject(forKey: SettingsKeys.mcpServers) }
        }

        // A stable (empty) configuration: first call populates, second hits.
        UserDefaults.standard.removeObject(forKey: SettingsKeys.mcpServers)
        let service = KestrelMCPService.shared
        let first = await service.discoverTools(force: true)
        XCTAssertTrue(first.isEmpty)
        let hitsAfterFirst = await service.discoveryCacheHits
        let second = await service.discoverTools()
        XCTAssertEqual(second.map(\.name), first.map(\.name))
        let hitsAfterSecond = await service.discoveryCacheHits
        XCTAssertEqual(hitsAfterSecond, hitsAfterFirst + 1,
                       "an unchanged server list must be served from the cache")

        // Changed configuration (a saved server list): the signature moves,
        // so the next call rediscovers instead of replaying the empty cache.
        if let data = try? JSONEncoder().encode([MCPServer]()) {
            UserDefaults.standard.set(data, forKey: SettingsKeys.mcpServers)
        } else {
            UserDefaults.standard.set(Data("[{}]".utf8), forKey: SettingsKeys.mcpServers)
        }
        let third = await service.discoverTools()
        let hitsAfterThird = await service.discoveryCacheHits
        XCTAssertEqual(hitsAfterThird, hitsAfterSecond,
                       "a changed server list must bypass the cache")
        _ = third
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
            .init(name: "testNativeToolSurfaceIsExactlySandboxAndMemory") { $0.testNativeToolSurfaceIsExactlySandboxAndMemory() },
            .init(name: "testAgentPathStringsAreEnglishOnly") { $0.testAgentPathStringsAreEnglishOnly() },
            .init(name: "testMCPDiscoveryIsCachedUntilTheServerListChanges") { try await $0.testMCPDiscoveryIsCachedUntilTheServerListChanges() },
        ])
}
