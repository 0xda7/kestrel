// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// LatchBridge pure logic: the generated config's internal consistency (every
/// id in providerOrder has a rule; the default selection names a real
/// provider), the local-engine default, and the one-time import that turns a
/// hand-authored latch config into real Kestrel routes — without importing
/// the loopback engine endpoint as a route.
final class LatchBridgeTests: CheckCase {
    private func entries() -> [LatchBridge.ProviderEntry] {
        [
            LatchBridge.ProviderEntry(id: "z-ai", baseURL: "https://api.z.ai/v1",
                                      apiKey: "sk-test", models: ["Glm-5.3-Flash"]),
            LatchBridge.ProviderEntry(id: "kestrel-local", baseURL: "http://127.0.0.1:8080/v1",
                                      apiKey: "engine", models: ["model.gguf"]),
        ]
    }

    func testSlugIsKeySafe() {
        XCTAssertEqual(LatchBridge.slug("z.ai"), "z-ai")
        XCTAssertEqual(LatchBridge.slug("OpenRouter"), "openrouter")
        XCTAssertEqual(LatchBridge.slug("  Mi_Proveedor  "), "mi-proveedor")
        XCTAssertEqual(LatchBridge.slug("mañana"), "ma-ana")
        XCTAssertEqual(LatchBridge.slug("---"), "provider")
        XCTAssertEqual(LatchBridge.slug(""), "provider")
    }

    func testGeneratedJSONIsInternallyConsistent() throws {
        let json = LatchBridge.generateJSON(entries: entries(), defaultEntryID: "kestrel-local")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let config = try XCTUnwrap(object["config"] as? [String: Any])
        let order = try XCTUnwrap(config["providerOrder"] as? [String])
        XCTAssertEqual(order, ["z-ai", "kestrel-local"])
        let rules = try XCTUnwrap((config["providerConfigRules"] as? [String: Any])?["providerRules"] as? [[String: Any]])
        XCTAssertEqual(rules.map { $0["providerId"] as? String }, order,
                       "every ordered id must have exactly one rule")
        let selection = try XCTUnwrap(config["defaultModelSelection"] as? [String: Any])
        XCTAssertEqual(selection["providerId"] as? String, "kestrel-local")
        XCTAssertEqual(selection["modelId"] as? String, "model.gguf")
        let local = try XCTUnwrap(rules.last?["config"] as? [String: Any])
        XCTAssertEqual((local["api"] as? [String: Any])?["baseUrl"] as? String, "http://127.0.0.1:8080/v1")
    }

    func testDefaultSelectionFallsBackToFirstEntry() throws {
        let json = LatchBridge.generateJSON(entries: entries(), defaultEntryID: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let selection = try XCTUnwrap((object["config"] as? [String: Any])?["defaultModelSelection"] as? [String: Any])
        XCTAssertEqual(selection["providerId"] as? String, "z-ai")
    }

    func testUnknownDefaultIDFallsBack() throws {
        let json = LatchBridge.generateJSON(entries: entries(), defaultEntryID: "nope")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let selection = try XCTUnwrap((object["config"] as? [String: Any])?["defaultModelSelection"] as? [String: Any])
        XCTAssertEqual(selection["providerId"] as? String, "z-ai",
                       "a dangling default would strand latch on a missing provider")
    }

    func testImportSkipsLoopbackAndKeepsRemote() throws {
        // The exact shape of a hand-authored v2 config: loopback gateway plus
        // one remote provider.
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "config": [
                "providerOrder": ["latch-gateway", "my-cloud"],
                "providerConfigRules": ["providerRules": [
                    [
                        "providerId": "latch-gateway",
                        "config": [
                            "access": ["type": "api-key", "apiKey": "local"],
                            "api": ["type": "openai-chat-completions", "baseUrl": "http://127.0.0.1:8080/v1"],
                            "personalModelIds": ["/Users/x/models/m.gguf"],
                        ],
                    ],
                    [
                        "providerId": "my-cloud",
                        "config": [
                            "access": ["type": "api-key", "apiKey": "sk-legacy"],
                            "api": ["type": "openai-chat-completions", "baseUrl": "https://api.example.com/v1"],
                            "personalModelIds": ["Big-Model"],
                        ],
                    ],
                ]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let imported = LatchBridge.importableRoutes(from: data)
        XCTAssertEqual(imported.count, 1, "the loopback engine is emitted separately and must not become a route")
        XCTAssertEqual(imported.first?.route.name, "my-cloud")
        XCTAssertEqual(imported.first?.route.modelID, "Big-Model")
        XCTAssertEqual(imported.first?.apiKey, "sk-legacy")
    }

    func testImportIgnoresGarbage() {
        XCTAssertTrue(LatchBridge.importableRoutes(from: Data("not json".utf8)).isEmpty)
    }
}

// MARK: - Generated registration (port from XCTest)
extension LatchBridgeTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "LatchBridgeTests",
        instance: { LatchBridgeTests() },
        checks: [
            .init(name: "testGeneratedJSONIsInternallyConsistent") { try $0.testGeneratedJSONIsInternallyConsistent() },
            .init(name: "testDefaultSelectionFallsBackToFirstEntry") { try $0.testDefaultSelectionFallsBackToFirstEntry() },
            .init(name: "testUnknownDefaultIDFallsBack") { try $0.testUnknownDefaultIDFallsBack() },
            .init(name: "testImportSkipsLoopbackAndKeepsRemote") { try $0.testImportSkipsLoopbackAndKeepsRemote() },
            .init(name: "testImportIgnoresGarbage") { $0.testImportIgnoresGarbage() },
            .init(name: "testSlugIsKeySafe") { $0.testSlugIsKeySafe() },
        ])
}
