// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import Kestrel

/// PiBridge pure logic: provider slugs, generated config shape, and the
/// send-time validation that keeps a missing provider/model pair from
/// silently stranding a chat turn (pi would fall back to a dead default and
/// answer with an empty reply, exit 0).
final class PiBridgeTests: XCTestCase {
    func testSlugIsKeySafe() {
        XCTAssertEqual(PiBridge.slug("z.ai"), "z-ai")
        XCTAssertEqual(PiBridge.slug("OpenRouter"), "openrouter")
        XCTAssertEqual(PiBridge.slug("  Mi_Proveedor  "), "mi-proveedor")
        XCTAssertEqual(PiBridge.slug("mañana"), "ma-ana")
        XCTAssertEqual(PiBridge.slug("---"), "provider")
        XCTAssertEqual(PiBridge.slug(""), "provider")
    }

    func testGeneratedJSONShape() throws {
        let json = PiBridge.generateJSON(entries: [
            PiBridge.ProviderEntry(slug: "z-ai", baseURL: "https://api.z.ai/api/coding/paas/v4",
                                   apiKey: "sk-test", models: ["Glm-5.3-Flash"]),
            PiBridge.ProviderEntry(slug: "kestrel-local", baseURL: "http://127.0.0.1:8080/v1",
                                   apiKey: "engine", models: ["model.gguf"]),
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let providers = try XCTUnwrap(object["providers"] as? [String: [String: Any]])
        let zai = try XCTUnwrap(providers["z-ai"])
        XCTAssertEqual(zai["api"] as? String, "openai-completions")
        XCTAssertEqual(zai["baseUrl"] as? String, "https://api.z.ai/api/coding/paas/v4")
        let models = try XCTUnwrap(zai["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["id"] as? String, "Glm-5.3-Flash")
        XCTAssertEqual(providers["kestrel-local"]?["apiKey"] as? String, "engine")
    }

    func testValidateAcceptsConfiguredPair() {
        let config = PiBridge.generateJSON(entries: [
            PiBridge.ProviderEntry(slug: "z-ai", baseURL: "https://x", apiKey: "k",
                                   models: ["Glm-5.3-Flash"]),
        ])
        XCTAssertNil(PiBridge.validate(provider: "z-ai", model: "Glm-5.3-Flash",
                                       configData: Data(config.utf8)))
    }

    func testValidateNamesUnknownProvider() {
        let config = PiBridge.generateJSON(entries: [
            PiBridge.ProviderEntry(slug: "z-ai", baseURL: "https://x", apiKey: "k",
                                   models: ["Glm-5.3-Flash"]),
        ])
        let problem = PiBridge.validate(provider: "nope", model: "m",
                                        configData: Data(config.utf8))
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("nope") ?? false)
        // The message must name what IS configured, so the fix is actionable.
        XCTAssertTrue(problem?.contains("z-ai") ?? false)
    }

    func testValidateNamesUnknownModelWithValidAlternatives() {
        let config = PiBridge.generateJSON(entries: [
            PiBridge.ProviderEntry(slug: "z-ai", baseURL: "https://x", apiKey: "k",
                                   models: ["Glm-5.3-Flash"]),
        ])
        let problem = PiBridge.validate(provider: "z-ai", model: "Glm-5.2",
                                        configData: Data(config.utf8))
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("Glm-5.3-Flash") ?? false,
                      "the error must list the models that actually exist")
    }

    func testValidateSkipsWhenProviderEmpty() {
        // Empty provider = "pi's own configuration decides" — a documented
        // choice Kestrel must not second-guess.
        XCTAssertNil(PiBridge.validate(provider: "", model: "", configData: nil))
    }

    func testValidateSkipsUnparseableOrForeignConfig() {
        // No marker / unreadable file: not Kestrel's config to judge.
        XCTAssertNil(PiBridge.validate(provider: "x", model: "y", configData: nil))
        XCTAssertNil(PiBridge.validate(provider: "x", model: "y", configData: Data("{}".utf8)))
    }

    func testModelIDsWithSlashesSurvivePairRoundTrip() {
        // openrouter-style ids carry a slash; the settings picker's split
        // must keep the full model intact.
        let combined = "openrouter/moonshotai/kimi-k2.6"
        let parts = combined.split(separator: "/", maxSplits: 1).map(String.init)
        XCTAssertEqual(parts.first, "openrouter")
        XCTAssertEqual(parts.last, "moonshotai/kimi-k2.6")
    }
}
