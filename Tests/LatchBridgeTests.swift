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

    // MARK: Chat-capable local target (the 2026-10-14 routing incident)

    private func settings(port: Int, model: String, embeddings: Bool = false) -> ServerSettings {
        ServerSettings(serverBinary: "/usr/bin/true", modelPath: model, port: port,
                       ngl: 99, ncmoe: 0, ctx: 2048, threads: 6, flashAttn: "auto",
                       noMmap: true, jinja: false, vramReserveMB: 1024, gpuIndex: -1,
                       extraArgs: "", embeddings: embeddings,
                       cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
    }

    /// The agent's local provider must never point at an embeddings-dedicated
    /// or decision-model server: an embeddings context answers every chat
    /// request with the sampler 400, and the Laya card serves forced-choice
    /// JSON, not conversation. Given the incident's fixture list — the
    /// decision card's config applied as the primary, an embeddings card and
    /// a real chat card added — the target is the chat server, never 8098.
    func testLocalTargetExcludesEmbeddingsAndDecisionServers() {
        let chat = settings(port: 8080, model: "/Users/x/models/chat.gguf")
        XCTAssertEqual(LatchBridge.chatCapableLocalTarget(primary: chat, addedProfiles: [])?.port,
                       8080, "a chat-capable primary is the agent's target unchanged")

        let chatCard = settings(port: 8081, model: "/Users/x/models/chat2.gguf")
            .makeProfile(name: "Second")
        var embeddingsCard = settings(port: 8099, model: "/Users/x/models/embed.gguf")
            .makeProfile(name: "RAG")
        embeddingsCard.pinned = [Profile.Pin.model, Profile.Pin.embeddings]
        embeddingsCard.embeddings = true

        // The incident shape: the flat primary keys describe the embeddings-
        // mode decision card on 8098 (an applied card's port is written into
        // the primary port key), while a chat-capable server exists as a card.
        let incident = LatchBridge.chatCapableLocalTarget(
            primary: settings(port: 8098, model: "/Users/x/models/Laya-Q8_0.gguf", embeddings: true),
            addedProfiles: [embeddingsCard, chatCard])
        XCTAssertEqual(incident?.port, 8081,
                       "the agent routes to the chat-capable card, never the embeddings/decision primary")

        // The decision model alone (embeddings off) is still not a chat target.
        let decisionOnly = LatchBridge.chatCapableLocalTarget(
            primary: settings(port: 8098, model: "/Users/x/models/Laya-Q8_0.gguf"),
            addedProfiles: [embeddingsCard])
        XCTAssertNil(decisionOnly,
                     "with no chat-capable server there is no local provider target at all")

        XCTAssertFalse(LatchBridge.isChatCapableTarget(modelPath: "/m/Laya-Q8_0.gguf", embeddings: false),
                       "the decisions model does not generate conversational text")
        XCTAssertFalse(LatchBridge.isChatCapableTarget(modelPath: "/m/chat.gguf", embeddings: true),
                       "an embeddings-dedicated process has no sampler chain")
        XCTAssertTrue(LatchBridge.isChatCapableTarget(modelPath: "/m/chat.gguf", embeddings: false))
    }

    /// The generated config's default is the primary chat port, and no
    /// embeddings/decision server appears as a provider target.
    func testGeneratedConfigDefaultsToPrimaryChatPort() throws {
        let target = try XCTUnwrap(LatchBridge.chatCapableLocalTarget(
            primary: settings(port: 8080, model: "/Users/x/models/chat.gguf"),
            addedProfiles: []))
        XCTAssertEqual(target.port, 8080)
        let entry = LatchBridge.ProviderEntry(
            id: "kestrel-local",
            baseURL: "http://127.0.0.1:\(target.port)/v1",
            apiKey: "engine",
            models: [(target.modelPath as NSString).lastPathComponent])
        let json = LatchBridge.generateJSON(entries: [entry], defaultEntryID: entry.id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let config = try XCTUnwrap(object["config"] as? [String: Any])
        let selection = try XCTUnwrap(config["defaultModelSelection"] as? [String: Any])
        XCTAssertEqual(selection["providerId"] as? String, "kestrel-local")
        XCTAssertTrue(json.contains("8080"))
        XCTAssertFalse(json.contains("8098"), "the decision card's port must not appear as a provider target")
        XCTAssertFalse(json.contains("8099"), "the embeddings card's port must not appear as a provider target")
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
            .init(name: "testLocalTargetExcludesEmbeddingsAndDecisionServers") { $0.testLocalTargetExcludesEmbeddingsAndDecisionServers() },
            .init(name: "testGeneratedConfigDefaultsToPrimaryChatPort") { try $0.testGeneratedConfigDefaultsToPrimaryChatPort() },
            .init(name: "testSlugIsKeySafe") { $0.testSlugIsKeySafe() },
        ])
}
