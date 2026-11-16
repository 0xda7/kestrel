// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// Merlin slice-2 checks (M1 actor + M8 profiles). All HTTP is scripted
// through MerlinMockURLProtocol — no check touches a real socket. Profile
// persistence runs against per-check temp directories, never the
// operator's ~/.kestrel/merlin/profiles.json.

import Foundation
@testable import KestrelCore

final class MerlinChecks2: CheckCase {
    // MARK: - ToolSchema

    func testToolCatalogMatchesRegistryNamesExactly() {
        XCTAssertEqual(MerlinToolSchema.definitions.map(\.name),
                       MerlinToolRegistry.reservedNames)
    }

    func testToolCatalogDescriptionsMatchRegistry() throws {
        let workspace = try MerlinWorkspace(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("merlin-checks2-\(UUID().uuidString)", isDirectory: true),
            taskID: "checks2-schema")
        let ledger = try MerlinLedger(url: workspace.rootURL
            .appendingPathComponent(MerlinLedger.fileName))
        let registry = MerlinToolRegistry(workspace: workspace, ledger: ledger)
        for tool in registry.orderedTools {
            let definition = MerlinToolSchema.definitions.first { $0.name == tool.name }
            XCTAssertNotNil(definition, "catalog missing \(tool.name)")
            XCTAssertEqual(definition?.description, tool.description,
                           "catalog description drifted from registry for \(tool.name)")
        }
    }

    func testToolCatalogParametersComeFromTheRegistry() {
        for definition in MerlinToolSchema.definitions {
            let advertised = definition.parameters
            let registry = MerlinToolRegistry.schema(for: definition.name)
            let advertisedData = try? JSONSerialization.data(withJSONObject: advertised, options: [.sortedKeys])
            let registryData = try? JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys])
            XCTAssertEqual(String(decoding: advertisedData ?? Data(), as: UTF8.self),
                           String(decoding: registryData ?? Data(), as: UTF8.self),
                           "parameters for \(definition.name) drifted from the registry")
        }
    }

    func testOpenAIToolsPayloadShapeIsProbeVerbatim() throws {
        let tools = MerlinToolSchema.openAIToolsPayload()
        XCTAssertEqual(tools.count, 10)
        let first = try XCTUnwrap(tools.first as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "function")
        let function = try XCTUnwrap(first["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "fs_read")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        let required = try XCTUnwrap(parameters["required"] as? [String])
        XCTAssertEqual(required, ["path"])
    }

    func testEnvelopeResponseFormatMatchesProbeSchema() throws {
        let format = MerlinToolSchema.envelopeResponseFormat()
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let wrapper = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(wrapper["name"] as? String, "tool_envelope")
        XCTAssertEqual(wrapper["strict"] as? Bool, true)
        let schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let name = try XCTUnwrap(properties["name"] as? [String: Any])
        XCTAssertEqual(name["enum"] as? [String], MerlinToolRegistry.reservedNames)
        let arguments = try XCTUnwrap(properties["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["type"] as? String, "object")
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(required, ["name", "arguments"])
    }

    func testIsKnownToolGatesOnTheTenNames() {
        XCTAssertTrue(MerlinToolSchema.isKnownTool("task_done"))
        XCTAssertTrue(MerlinToolSchema.isKnownTool("fs_grep"))
        XCTAssertFalse(MerlinToolSchema.isKnownTool("calc"))
        XCTAssertFalse(MerlinToolSchema.isKnownTool(""))
        XCTAssertEqual(MerlinToolSchema.knownToolNames.count, 10)
    }

    // MARK: - Profile detection

    func testFamilyDetectionFromGGUFFilenames() {
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "Spark-X2.5-1.7B-Q8_0.gguf"), "spark-x2.5")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "/models/Spark-X2.5-4B-Q4_K_M.gguf"), "spark-x2.5")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "lfm2.5-2.6b-fable5-coding-agent-heretic-Q4_K_M.gguf"), "lfm2.5")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "LFM2.5-8B-A1B-Q3.8-TBrilliance-NEO-IQ4_XS.gguf"), "lfm2.5")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "DeepSeek-R1-0528-Qwen3-8B-Q4_K_S.gguf"), "deepseek-r1")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "Qwen3.5-9B-distilled-IQ4_NL.gguf"), "qwen3.5")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "GLM-4-9B-0414-Q4_K_M.gguf"), "glm-4")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf"), "unknown")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "totally-unrelated-model.gguf"), "unknown")
        XCTAssertEqual(MerlinProfileStore.detectFamily(modelName: ""), "unknown")
    }

    func testDetectionIsCaseAndPathInsensitive() {
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "/HD/Users/x/glm-4-9b-q4_k_m.GGUF"), "glm-4")
        XCTAssertEqual(MerlinProfileStore.detectFamily(
            modelName: "SPARK-X2.5-4B-UNCENSORED-Q4_K_M.gguf"), "spark-x2.5")
    }

    func testProfileMatrixRungsMatchTheEvidence() {
        let spark = MerlinModelProfile.known["spark-x2.5"]
        XCTAssertEqual(spark?.toolCallMode, .nativeTools)
        // Slice 6: the floor left the 512 no-think default — Spark emits
        // reasoning_content (live probe) and now carries its measured floor.
        XCTAssertEqual(spark?.minCompletionTokens, MerlinModelProfile.sparkReasoningFloor)
        XCTAssertGreaterThan(MerlinModelProfile.sparkReasoningFloor, MerlinModelProfile.defaultMinCompletionTokens)
        let lfm = MerlinModelProfile.known["lfm2.5"]
        XCTAssertEqual(lfm?.toolCallMode, .nativeTools)
        let r1 = MerlinModelProfile.known["deepseek-r1"]
        XCTAssertEqual(r1?.toolCallMode, .nativeTools)
        XCTAssertEqual(r1?.minCompletionTokens, MerlinModelProfile.r1ThinkBudgetFloor)
        XCTAssertGreaterThanOrEqual(MerlinModelProfile.r1ThinkBudgetFloor, 3000)
        let qwen = MerlinModelProfile.known["qwen3.5"]
        XCTAssertEqual(qwen?.toolCallMode, .nativeTools)
        let glm = MerlinModelProfile.known["glm-4"]
        XCTAssertEqual(glm?.toolCallMode, .jsonEnvelope)
        let unknown = MerlinModelProfile.unknownProfile(mode: .rescue)
        XCTAssertEqual(unknown.toolCallMode, .rescue)
        XCTAssertEqual(unknown.minCompletionTokens, MerlinModelProfile.defaultMinCompletionTokens)
        // Every profile carries a note (operator-facing, evidence-cited).
        for (_, profile) in MerlinModelProfile.known {
            XCTAssertFalse(profile.templateNotes.isEmpty, "profile \(profile.family) has no notes")
        }
    }

    // MARK: - Profile persistence (temp dirs only)

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("merlin-checks2-profiles-\(UUID().uuidString).json")
    }

    func testUnknownFamilyPromotesAfterThreeCleanParses() {
        let store = MerlinProfileStore(storeURL: tempStoreURL())
        let model = "Mystery-7B-Instruct-Q4_K_M.gguf"
        XCTAssertEqual(store.profile(for: model).toolCallMode, .rescue)
        XCTAssertEqual(store.recordCleanNativeParse(modelName: model), .rescue)
        XCTAssertEqual(store.recordCleanNativeParse(modelName: model), .rescue)
        XCTAssertEqual(store.cleanNativeParseCount(forModel: model), 2)
        XCTAssertEqual(store.recordCleanNativeParse(modelName: model), .nativeTools,
                       "third clean parse must promote the unknown family")
        XCTAssertEqual(store.profile(for: model).toolCallMode, .nativeTools)
    }

    func testPromotionPersistsAcrossStoreRebuilds() throws {
        let url = tempStoreURL()
        let store = MerlinProfileStore(storeURL: url)
        let model = "Obscure-3B-chat.gguf"
        for _ in 0..<MerlinProfileStore.promotionThreshold {
            store.recordCleanNativeParse(modelName: model)
        }
        XCTAssertTrue(store.isPersistenceAvailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "promotion must be written to profiles.json")
        let decoded = try JSONDecoder().decode([String: Int].self,
                                               from: Data(contentsOf: url))
        XCTAssertEqual(decoded["unknown"], MerlinProfileStore.promotionThreshold)
        // A rebuilt store (new session) picks the promotion up.
        let reloaded = MerlinProfileStore(storeURL: url)
        XCTAssertEqual(reloaded.profile(for: model).toolCallMode, .nativeTools,
                       "promoted unknown family must survive a store rebuild")
    }

    func testKnownFamiliesNeverPromote() {
        let store = MerlinProfileStore(storeURL: tempStoreURL())
        // GLM-4's rung is evidence-locked (envelope); clean parses on it
        // must not flip anything.
        XCTAssertEqual(store.recordCleanNativeParse(modelName: "GLM-4-9B-0414-Q4_K_M.gguf"),
                       .jsonEnvelope)
        XCTAssertEqual(store.cleanNativeParseCount(forModel: "GLM-4-9B-0414-Q4_K_M.gguf"), 0)
        XCTAssertEqual(store.profile(for: "GLM-4-9B-0414-Q4_K_M.gguf").toolCallMode,
                       .jsonEnvelope)
    }

    func testReadOnlyHomeDegradesToSessionOnlyMemory() {
        // A store URL inside a path that cannot exist (a "file" used as a
        // directory) forces every mkdir/write to fail: the store must keep
        // working in memory and report persistence as unavailable.
        let blocker = tempStoreURL()
        try? Data("not a directory".utf8).write(to: blocker)
        let store = MerlinProfileStore(storeURL: blocker
            .appendingPathComponent("profiles.json"))
        let model = "Readonly-1B.gguf"
        for _ in 0..<MerlinProfileStore.promotionThreshold {
            store.recordCleanNativeParse(modelName: model)
        }
        XCTAssertFalse(store.isPersistenceAvailable,
                       "failed writes must flag persistence unavailable")
        XCTAssertEqual(store.profile(for: model).toolCallMode, .nativeTools,
                       "session-only memory must still hold the promotion")
    }

    func testCorruptStoreFileDegradesGracefully() throws {
        let url = tempStoreURL()
        try Data("}{ not json".utf8).write(to: url)
        let store = MerlinProfileStore(storeURL: url)
        XCTAssertFalse(store.isPersistenceAvailable)
        // Detection and default rungs stay fully intact.
        XCTAssertEqual(store.profile(for: "GLM-4-9B-0414-Q4_K_M.gguf").toolCallMode,
                       .jsonEnvelope)
        XCTAssertEqual(store.profile(for: "Whatever-7B.gguf").toolCallMode, .rescue)
    }

    // MARK: - Think budget

    func testR1ThinkBudgetRefusalIsLoud() throws {
        let profile = try XCTUnwrap(MerlinModelProfile.known["deepseek-r1"])
        XCTAssertThrowsError(
            try LlamaServerActor(serverURL: URL(string: "http://127.0.0.1:8151")!,
                                 modelPath: "DeepSeek-R1-0528-Qwen3-8B-Q4_K_S.gguf",
                                 profile: profile, maxTokens: 200),
            "a starved R1 must be refused at configuration time"
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("max_tokens"),
                          "refusal must name the budget: \(text)")
            XCTAssertTrue(text.contains("think") || text.contains("floor"),
                          "refusal must name the think floor: \(text)")
        }
    }

    func testR1ThinkBudgetAcceptsFloorPlusHeadroom() throws {
        let profile = try XCTUnwrap(MerlinModelProfile.known["deepseek-r1"])
        let floor = profile.minCompletionTokens + MerlinModelProfile.actionHeadroom
        let actor = try LlamaServerActor(serverURL: URL(string: "http://127.0.0.1:8151")!,
                                         modelPath: "DeepSeek-R1-0528-Qwen3-8B-Q4_K_S.gguf",
                                         profile: profile, maxTokens: floor)
        XCTAssertEqual(actor.maxTokens, floor)
        XCTAssertEqual(actor.maxTokens, MerlinModelProfile.r1ThinkBudgetFloor + 512)
    }

    func testRequestedBudgetBelowFloorIsRefusedLoudly() throws {
        let profile = MerlinModelProfile.unknownProfile(mode: .rescue)
        XCTAssertThrowsError(
            try LlamaServerActor(serverURL: URL(string: "http://127.0.0.1:8151")!,
                                 modelPath: "Whatever-7B.gguf",
                                 profile: profile, maxTokens: 64)
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("requires max_tokens >= 1024"), text)
            XCTAssertTrue(text.contains("raise the budget"), text)
        }
    }

    func testMalformedServerURLIsAProfileError() {
        let profile = MerlinModelProfile.unknownProfile(mode: .rescue)
        XCTAssertThrowsError(try LlamaServerActor(serverURL: URL(string: "not a url")!,
                                                  modelPath: "m.gguf", profile: profile)) { error in
            XCTAssertTrue(String(describing: error).contains("invalid llama-server URL"))
        }
    }

    // MARK: - Envelope (rung 2) round-trip

    private func response(content: Any, toolCalls: Any? = nil) -> [String: Any] {
        var message: [String: Any] = ["content": content]
        if let toolCalls { message["tool_calls"] = toolCalls }
        return ["choices": [["message": message]]]
    }

    func testEnvelopeParseTranslateRoundTrip() throws {
        let actor = try scriptedActor(mode: .jsonEnvelope, responses: [])
        let arguments = ["path": "docs"]
        let content = "{\"name\": \"fs_list\", \"arguments\": {\"path\": \"docs\"}}"
        let calls = try LlamaServerActor.parseEnvelope(
            response(content: content))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "fs_list")
        // Arguments must survive as the JSON object the handler decodes.
        let decoded = try MerlinToolRegistry.decodeArguments(calls[0].argumentsJSON)
        XCTAssertEqual(decoded["path"] as? String, "docs")
        XCTAssertEqual(calls[0].argumentsJSON,
                       String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
        _ = actor
    }

    func testEnvelopeEmptyArgumentsDefaultToEmptyObject() throws {
        let calls = try LlamaServerActor.parseEnvelope(
            response(content: "{\"name\": \"todo_read\", \"arguments\": {}}"))
        XCTAssertEqual(try MerlinToolRegistry.decodeArguments(calls[0].argumentsJSON) as? [String: String], [:])
    }

    func testEnvelopeUnknownToolNameIsFlaggedAsHallucination() {
        XCTAssertThrowsError(try LlamaServerActor.parseEnvelope(
            response(content: "{\"name\": \"calc\", \"arguments\": {\"a\": 2}}")
        )) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("suspected_result_hallucination"), text)
            XCTAssertTrue(text.contains("unknown tool"), text)
        }
    }

    func testEnvelopeNarrationNamingKnownToolFlagsHallucination() {
        // The GLM failure mode: prose announcing a call that never ran.
        XCTAssertThrowsError(try LlamaServerActor.parseEnvelope(
            response(content: "Sure! I called fs_list on docs and it returned notes.md, todo.txt.")
        )) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("suspected_result_hallucination"), text)
            XCTAssertTrue(text.contains("fails envelope parse"), text)
        }
    }

    func testEnvelopePlainProseWithoutToolNamesDoesNotFlag() {
        XCTAssertThrowsError(try LlamaServerActor.parseEnvelope(
            response(content: "The docs folder looks organized; shall I continue?")
        )) { error in
            XCTAssertFalse(String(describing: error).contains("suspected_result_hallucination"),
                           String(describing: error))
        }
    }

    // MARK: - Native tools (rung 1)

    func testNativeToolsParseOpenAIShape() throws {
        let call = [
            "id": "call_1",
            "type": "function",
            "function": [
                "name": "fs_list",
                "arguments": "{\"path\": \"docs\"}",
            ],
        ] as [String: Any]
        let calls = try LlamaServerActor.parseNativeTools(response(content: "", toolCalls: [call]))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "fs_list")
        XCTAssertEqual(try MerlinToolRegistry.decodeArguments(calls[0].argumentsJSON)["path"] as? String, "docs")
    }

    func testNativeToolsParseDictionaryArgumentsAndClampToFour() throws {
        var rawCalls: [[String: Any]] = []
        for index in 0..<6 {
            rawCalls.append([
                "id": "call_\(index)",
                "type": "function",
                "function": [
                    "name": "note_add",
                    "arguments": ["kind": "fact", "text": "call \(index)"],
                ],
            ])
        }
        let calls = try LlamaServerActor.parseNativeTools(
            response(content: "", toolCalls: rawCalls))
        XCTAssertEqual(calls.count, 4, "batch must clamp to the 4-call contract")
        XCTAssertEqual(calls.allSatisfy { $0.name == "note_add" }, true)
    }

    func testNativeToolsUnknownToolNamesAreDropped() throws {
        let call = [
            "type": "function",
            "function": ["name": "calc", "arguments": "{}"],
        ] as [String: Any]
        XCTAssertThrowsError(try LlamaServerActor.parseNativeTools(
            response(content: "", toolCalls: [call])))
    }

    func testNativeToolsEmptyWithNarrationFlagsHallucination() {
        XCTAssertThrowsError(try LlamaServerActor.parseNativeTools(
            response(content: "I will now use fs_read on notes.txt to check it.")
        )) { error in
            XCTAssertTrue(String(describing: error).contains("suspected_result_hallucination"),
                          String(describing: error))
        }
    }

    // MARK: - Rescue (rung 3)

    func testRescueParsesBareJSONCall() throws {
        let calls = try LlamaServerActor.parseRescue(
            response(content: #"{"name": "fs_list", "arguments": {"path": "."}}"#))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "fs_list")
    }

    func testRescueParsesFencedCall() throws {
        let content = """
        Let me look at the workspace.
        ```json
        {"name": "fs_read", "arguments": {"path": "notes.txt"}}
        ```
        """
        let calls = try LlamaServerActor.parseRescue(response(content: content))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "fs_read")
        XCTAssertEqual(try MerlinToolRegistry.decodeArguments(calls[0].argumentsJSON)["path"] as? String,
                       "notes.txt")
    }

    func testRescueParsesToolCallTagsAndAlternates() throws {
        let content = """
        <tool_call>{"tool": "fs_grep", "params": {"pattern": "TODO"}}</tool_call>
        <tool_call>{"tool_name": "todo_read"}</tool_call>
        """
        let calls = try LlamaServerActor.parseRescue(response(content: content))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "fs_grep")
        XCTAssertEqual(calls[1].name, "todo_read")
        XCTAssertEqual(calls[1].argumentsJSON, "{}")
    }

    func testRescueIgnoresUnknownToolNames() throws {
        let content = #"{"name": "calc", "arguments": {"a": 2}} then {"name": "task_done", "arguments": {"summary": "did it"}}"#
        let calls = try LlamaServerActor.parseRescue(response(content: content))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "task_done")
    }

    func testRescueSurvivesBracesInsideStrings() throws {
        let content = #"I'd write {"with": "braces"} but the real call is {"name": "fs_write", "arguments": {"path": "out.json", "content": "{\"a\": 1}"}}"#
        let calls = try LlamaServerActor.parseRescue(response(content: content))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "fs_write")
        XCTAssertEqual(try MerlinToolRegistry.decodeArguments(calls[0].argumentsJSON)["content"] as? String,
                       "{\"a\": 1}")
    }

    func testRescueCappedAtFourCalls() throws {
        let blob = #"{"name": "note_add", "arguments": {"kind": "fact", "text": "n"}}"#
        let content = (0..<7).map { _ in blob }.joined(separator: " ")
        let calls = try LlamaServerActor.parseRescue(response(content: content))
        XCTAssertEqual(calls.count, 4)
    }

    func testRescueNoCallThrowsWithoutFlagOnPlainProse() {
        XCTAssertThrowsError(try LlamaServerActor.parseRescue(
            response(content: "Everything looks fine to me."))) { error in
            XCTAssertFalse(String(describing: error).contains("suspected_result_hallucination"))
        }
    }

    // MARK: - End-to-end actor via scripted HTTP (mock protocol, no socket)

    private func scriptedActor(mode: MerlinModelProfile.ToolCallMode,
                               responses: [LlamaServerActor.MockResponse]) throws -> LlamaServerActor {
        let profile: MerlinModelProfile
        switch mode {
        case .nativeTools: profile = MerlinModelProfile.known["spark-x2.5"]!
        case .jsonEnvelope: profile = MerlinModelProfile.known["glm-4"]!
        case .rescue: profile = MerlinModelProfile.unknownProfile(mode: .rescue)
        }
        return try LlamaServerActor(serverURL: URL(string: "http://127.0.0.1:8151")!,
                                    modelPath: "Mock-7B-Instruct.gguf",
                                    profile: profile,
                                    scriptedResponses: responses)
    }

    private func chatBody(content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        {"choices":[{"message":{"role":"assistant","content":"\(escaped)"}}]}
        """
    }

    @MainActor func testActorNativeToolsEndToEndViaScriptedHTTP() async throws {
        let body = """
        {"choices":[{"message":{"role":"assistant","content":"","tool_calls":[
            {"id":"c1","type":"function","function":{"name":"fs_list","arguments":"{\\"path\\": \\"docs\\"}"}},
            {"id":"c2","type":"function","function":{"name":"task_done","arguments":"{\\"summary\\": \\"listed docs\\"}"}}]}}]}
        """
        var actor = try scriptedActor(mode: .nativeTools,
                                      responses: [.init(status: 200, body: body)])
        let calls = try await actor.toolCalls(prompt: "You are Merlin. GOAL: list docs.", turn: 1)
        XCTAssertEqual(calls.map(\.name), ["fs_list", "task_done"])
        XCTAssertEqual(try MerlinToolRegistry.decodeArguments(calls[0].argumentsJSON)["path"] as? String,
                       "docs")
        // Transcript carries the spine as system + the seeded user turn.
        XCTAssertEqual(actor.systemMessage, "You are Merlin. GOAL: list docs.")
        XCTAssertGreaterThanOrEqual(actor.transcriptMessages.count, 2)
    }

    @MainActor func testActorEnvelopeEndToEndViaScriptedHTTP() async throws {
        var actor = try scriptedActor(
            mode: .jsonEnvelope,
            responses: [.init(status: 200, body: chatBody(
                content: "{\"name\": \"fs_list\", \"arguments\": {\"path\": \"docs\"}}"))])
        let calls = try await actor.toolCalls(prompt: "GOAL: list docs.", turn: 1)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "fs_list")
    }

    @MainActor func testActorRescueEndToEndViaScriptedHTTP() async throws {
        var actor = try scriptedActor(
            mode: .rescue,
            responses: [.init(status: 200, body: chatBody(
                content: "Working on it.\n```json\n{\"name\": \"fs_read\", \"arguments\": {\"path\": \"a.md\"}}\n```"))])
        let calls = try await actor.toolCalls(prompt: "GOAL: read a.md.", turn: 1)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "fs_read")
    }

    @MainActor func testActorScriptedRequestsCarryToolsAndRequiredChoice() async throws {
        var actor = try scriptedActor(mode: .nativeTools,
                                      responses: [.init(status: 200, body: chatBody(content: "x"))])
        // The stub body is not a parseable tool call; this probe inspects
        // the REQUEST shape only, so the expected parse throw is fine.
        _ = try? await actor.toolCalls(prompt: "GOAL: probe wire.", turn: 1)
        let request = try XCTUnwrap(MerlinMockURLProtocol.recordedRequests().last)
        XCTAssertEqual(request["tool_choice"] as? String, "required")
        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 10)
        XCTAssertNil(request["response_format"], "rung 1 must not send an envelope")
    }

    @MainActor func testActorScriptedEnvelopeRequestCarriesResponseFormat() async throws {
        var actor = try scriptedActor(mode: .jsonEnvelope,
                                      responses: [.init(status: 200, body: chatBody(content: "x"))])
        // Same as above: request-shape probe; parse throw expected.
        _ = try? await actor.toolCalls(prompt: "GOAL: probe wire.", turn: 1)
        let request = try XCTUnwrap(MerlinMockURLProtocol.recordedRequests().last)
        let format = try XCTUnwrap(request["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNil(request["tools"], "rung 2 must not carry a tools array")
    }

    @MainActor func testActorTranscriptRollsAcrossTurnsWithToolResults() async throws {
        var actor = try scriptedActor(mode: .jsonEnvelope, responses: [
            .init(status: 200, body: chatBody(content: "{\"name\": \"fs_list\", \"arguments\": {\"path\": \".\"}}")),
            .init(status: 200, body: chatBody(content: "{\"name\": \"task_done\", \"arguments\": {\"summary\": \"done\"}}")),
        ])
        _ = try await actor.toolCalls(prompt: "GOAL: t1.", turn: 1)
        actor.addAssistantMessage(content: "",
                                  toolCalls: [["id": "c1", "function": ["name": "fs_list"]]])
        actor.addToolResult(callID: "c1", tool: "fs_list", result: "notes.md")
        _ = try await actor.toolCalls(prompt: "GOAL: t2 (updated digest).", turn: 2)
        let transcript = actor.transcriptMessages
        let roles = transcript.compactMap { $0["role"] as? String }
        XCTAssertEqual(roles, ["system", "user", "assistant", "tool", "user"],
                       "transcript must roll: system first, tool results in order, each turn ends on a user cue")
        // The spine prompt (system) is refreshed each turn.
        XCTAssertTrue((transcript.first?["content"] as? String ?? "").contains("GOAL: t2"))
    }

    @MainActor func testActorHTTPErrorSurfacesAsActorError() async throws {
        let actor = try scriptedActor(mode: .jsonEnvelope,
                                      responses: [.init(status: 500, body: "boom")])
        do {
            _ = try await actor.toolCalls(prompt: "GOAL: x", turn: 1)
            XCTFail("an HTTP 500 must end the turn as an actor error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("HTTP 500"), String(describing: error))
        }
    }

    @MainActor func testActorScriptedQueueEmptySurfacesAsServerError() async throws {
        // One response, two turns: the second request drains the queue and
        // must fail loudly rather than fabricate a result.
        var actor = try scriptedActor(
            mode: .jsonEnvelope,
            responses: [.init(status: 200, body: chatBody(
                content: "{\"name\": \"todo_read\", \"arguments\": {}}"))])
        _ = try await actor.toolCalls(prompt: "GOAL: t1", turn: 1)
        do {
            _ = try await actor.toolCalls(prompt: "GOAL: t2", turn: 2)
            XCTFail("a drained scripted queue must fail loudly, not fabricate a result")
        } catch {
            // Expected: the queue is empty and the mock serves an explicit 500.
        }
    }

    // MARK: - Kernel integration seam (batch clamping, actor side)

    @MainActor func testActorBatchFeedsKernelAndKernelClamps() async throws {
        // A scripted rung-1 response advertising 6 calls: the actor clamps
        // its own parse to 4 (the kernel's contract) and the kernel would
        // ledger anything beyond that as a blocker.
        let note = #"{"id":"c\(#","type":"function","function":{"name":"note_add","arguments":"{\"kind\": \"fact\", \"text\": \"n\"}"}}"#
        let body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[" +
            (0..<6).map { #"{"id":"c\#($0)","type":"function","function":{"name":"note_add","arguments":"{\"kind\": \"fact\", \"text\": \"\#($0)\"}"}}"# }
                .joined(separator: ",") + "]}}]}"
        let actor = try scriptedActor(mode: .nativeTools, responses: [.init(status: 200, body: body)])
        let batch = try await actor.toolCalls(prompt: "GOAL: clamp probe.", turn: 1)
        XCTAssertEqual(batch.count, 4, "actor-side clamp: only 4 calls leave the actor")
        XCTAssertEqual(batch.allSatisfy { $0.name == "note_add" }, true)
        let workspace = try MerlinWorkspace(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("merlin-checks2-\(UUID().uuidString)", isDirectory: true),
            taskID: "checks2-clamp")
        let ledger = try MerlinLedger(url: workspace.rootURL
            .appendingPathComponent(MerlinLedger.fileName))
        _ = MerlinKernel(workspace: workspace, ledger: ledger,
                         spine: MerlinTaskSpine(goal: "clamp probe", maxTurns: 1))
    }

    // MARK: - Slice 6: per-tool envelope grammar (envelopeMode profile option)

    func testEnvelopePerToolBranchesCarryRegistrySchemas() throws {
        let branches = MerlinToolSchema.perToolBranches()
        XCTAssertEqual(branches.count, 10, "one branch per catalog tool")
        for (index, definition) in MerlinToolSchema.definitions.enumerated() {
            let branch = try XCTUnwrap(branches[index])
            let properties = try XCTUnwrap(branch["properties"] as? [String: Any])
            let name = try XCTUnwrap(properties["name"] as? [String: Any])
            XCTAssertEqual(name["const"] as? String, definition.name,
                           "branch \(index) must const-pin its own tool name")
            let arguments = try XCTUnwrap(properties["arguments"] as? [String: Any])
            let branchData = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            let registryData = try JSONSerialization.data(
                withJSONObject: MerlinToolRegistry.schema(for: definition.name), options: [.sortedKeys])
            XCTAssertEqual(String(decoding: branchData, as: UTF8.self),
                           String(decoding: registryData, as: UTF8.self),
                           "branch arguments for \(definition.name) must be the registry schema verbatim")
            XCTAssertEqual(branch["required"] as? [String], ["name", "arguments"])
        }
    }

    func testEnvelopePerToolSchemasModeEmbedsOneOfAndSharedShapeStaysProbeVerbatim() throws {
        // perToolSchemas: oneOf over the per-tool branches.
        let perTool = MerlinToolSchema.envelopeResponseFormat(mode: .perToolSchemas)
        XCTAssertEqual(perTool["type"] as? String, "json_schema")
        let perToolWrapper = try XCTUnwrap(perTool["json_schema"] as? [String: Any])
        XCTAssertEqual(perToolWrapper["name"] as? String, "tool_envelope")
        XCTAssertEqual(perToolWrapper["strict"] as? Bool, true)
        let perToolSchema = try XCTUnwrap(perToolWrapper["schema"] as? [String: Any])
        XCTAssertNotNil(perToolSchema["oneOf"], "per-tool mode must compile to oneOf branches")
        XCTAssertEqual((perToolSchema["oneOf"] as? [[String: Any]])?.count, 10)

        // sharedShape: byte-shape of the original probe schema (regression
        // pin — the default must not have drifted).
        let shared = MerlinToolSchema.envelopeResponseFormat()
        let sharedWrapper = try XCTUnwrap(shared["json_schema"] as? [String: Any])
        let sharedSchema = try XCTUnwrap(sharedWrapper["schema"] as? [String: Any])
        let properties = try XCTUnwrap(sharedSchema["properties"] as? [String: Any])
        XCTAssertEqual((properties["name"] as? [String: Any])?["enum"] as? [String],
                       MerlinToolRegistry.reservedNames)
        XCTAssertEqual((properties["arguments"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertEqual(sharedSchema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(sharedSchema["required"] as? [String], ["name", "arguments"])
    }

    func testEnvelopeModeIsAProfileOptionAndGLMRidesPerToolSchemas() throws {
        // The mode exists on every profile; glm-4 carries the tightened
        // grammar (kernel-2's schema-sloppy soak finding), all others keep
        // the probe-verbatim shared shape until their own evidence lands.
        XCTAssertEqual(MerlinModelProfile.known["glm-4"]?.envelopeMode, .perToolSchemas)
        for (family, profile) in MerlinModelProfile.known where family != "glm-4" {
            XCTAssertEqual(profile.envelopeMode, .sharedShape,
                           "family \(family) must keep the shared shape absent rung-2 drift evidence")
        }
        // The unknown-family factory keeps the default too.
        XCTAssertEqual(MerlinModelProfile.unknownProfile(mode: .jsonEnvelope).envelopeMode, .sharedShape)
        // Profile-mode round-trips through the payload builder: an actor
        // on the glm-4 profile requests the per-tool grammar.
        let glm = MerlinModelProfile.known["glm-4"]!
        let perToolWrapper = try XCTUnwrap(
            MerlinToolSchema.envelopeResponseFormat(mode: glm.envelopeMode)["json_schema"] as? [String: Any])
        let expectedWrapper = try XCTUnwrap(
            MerlinToolSchema.envelopeResponseFormat(mode: .perToolSchemas)["json_schema"] as? [String: Any])
        let perToolData = try JSONSerialization.data(withJSONObject: perToolWrapper, options: [.sortedKeys])
        let expectedData = try JSONSerialization.data(withJSONObject: expectedWrapper, options: [.sortedKeys])
        XCTAssertEqual(String(decoding: perToolData, as: UTF8.self),
                       String(decoding: expectedData, as: UTF8.self))
    }

    @MainActor func testActorSendsProfileEnvelopeModeInResponseFormat() async throws {
        // Wire pin: the rung-2 request's response_format follows the
        // profile's envelopeMode (this is the hole the GLM soak slipped
        // through — the grammar was one shared shape for every family).
        let glm = MerlinModelProfile.known["glm-4"]!
        var actor = try LlamaServerActor(
            serverURL: URL(string: "http://127.0.0.1:8151")!,
            modelPath: "GLM-4-9B-0414-Q4_K_M.gguf",
            profile: glm,
            scriptedResponses: [.init(status: 200, body: chatBody(content: "x"))])
        _ = try? await actor.toolCalls(prompt: "GOAL: probe grammar.", turn: 1)
        let request = try XCTUnwrap(MerlinMockURLProtocol.recordedRequests().last)
        let wrapper = try XCTUnwrap((request["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        XCTAssertNotNil((wrapper["schema"] as? [String: Any])?["oneOf"],
                        "glm-4 profile must put the per-tool oneOf grammar on the wire")

        // And a shared-shape family must still get the probe-verbatim shape.
        let sparkLike = MerlinModelProfile(family: "spark-x2.5",
                                           toolCallMode: .jsonEnvelope,
                                           minCompletionTokens: MerlinModelProfile.defaultMinCompletionTokens,
                                           templateNotes: "check fixture")
        var sharedActor = try LlamaServerActor(
            serverURL: URL(string: "http://127.0.0.1:8151")!,
            modelPath: "Mock-7B-Instruct.gguf",
            profile: sparkLike,
            scriptedResponses: [.init(status: 200, body: chatBody(content: "x"))])
        _ = try? await sharedActor.toolCalls(prompt: "GOAL: probe grammar.", turn: 1)
        let sharedRequest = try XCTUnwrap(MerlinMockURLProtocol.recordedRequests().last)
        let sharedWrapper = try XCTUnwrap((sharedRequest["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        XCTAssertNil((sharedWrapper["schema"] as? [String: Any])?["oneOf"],
                     "sharedShape families must not carry oneOf")
        XCTAssertEqual((sharedWrapper["schema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
    }

    // MARK: - Slice 6: Spark think budget (reasoning_content evidence)

    func testSparkProfileCarriesReasoningFloorAndCorrectedNotes() throws {
        let spark = MerlinModelProfile.known["spark-x2.5"]
        XCTAssertEqual(spark?.minCompletionTokens, MerlinModelProfile.sparkReasoningFloor)
        XCTAssertEqual(MerlinModelProfile.sparkReasoningFloor, 768)
        XCTAssertGreaterThan(MerlinModelProfile.sparkReasoningFloor,
                             MerlinModelProfile.defaultMinCompletionTokens,
                             "the floor must sit above the no-think default (reasoning_content measured)")
        // The corrected note states the emission (the old text said "No
        // think budget" — that was wrong and must never come back).
        let notes = try XCTUnwrap(spark?.templateNotes)
        XCTAssertTrue(notes.contains("reasoning_content"),
                      "notes must state the measured reasoning_content emission")
        XCTAssertFalse(notes.contains("No think budget."),
                       "the retracted claim must be gone (quoted corrections like 'no think budget' inside the explanation are fine)")
        // The floor flows through the store's completion gate.
        let store = MerlinProfileStore(storeURL: tempStoreURL())
        XCTAssertEqual(store.requiredCompletionTokens(for: "Spark-X2.5-1.7B-Q8_0.gguf"),
                       MerlinModelProfile.sparkReasoningFloor + MerlinModelProfile.actionHeadroom)
    }

    func testSparkFloorRefusalAndAcceptanceStayLoud() throws {
        // The raised floor participates in the loud think-budget gate.
        let spark = MerlinModelProfile.known["spark-x2.5"]!
        XCTAssertThrowsError(
            try LlamaServerActor(serverURL: URL(string: "http://127.0.0.1:8151")!,
                                 modelPath: "Spark-X2.5-1.7B-Q8_0.gguf",
                                 profile: spark, maxTokens: 512),
            "a 512-token Spark budget must now be refused (reasoning eats the budget)"
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("requires max_tokens >= 1280"), text)
        }
        let actor = try LlamaServerActor(serverURL: URL(string: "http://127.0.0.1:8151")!,
                                         modelPath: "Spark-X2.5-1.7B-Q8_0.gguf",
                                         profile: spark, maxTokens: 1280)
        XCTAssertEqual(actor.maxTokens, 1280)
    }

    // MARK: - Registration

    @MainActor static let __checkSet = CheckSet(
        suite: "MerlinChecks2",
        instance: { MerlinChecks2() },
        checks: [
        .init(name: "testToolCatalogMatchesRegistryNamesExactly") { $0.testToolCatalogMatchesRegistryNamesExactly() },
        .init(name: "testToolCatalogDescriptionsMatchRegistry") { try $0.testToolCatalogDescriptionsMatchRegistry() },
        .init(name: "testToolCatalogParametersComeFromTheRegistry") { $0.testToolCatalogParametersComeFromTheRegistry() },
        .init(name: "testOpenAIToolsPayloadShapeIsProbeVerbatim") { try $0.testOpenAIToolsPayloadShapeIsProbeVerbatim() },
        .init(name: "testEnvelopeResponseFormatMatchesProbeSchema") { try $0.testEnvelopeResponseFormatMatchesProbeSchema() },
        .init(name: "testIsKnownToolGatesOnTheTenNames") { $0.testIsKnownToolGatesOnTheTenNames() },
        .init(name: "testFamilyDetectionFromGGUFFilenames") { $0.testFamilyDetectionFromGGUFFilenames() },
        .init(name: "testDetectionIsCaseAndPathInsensitive") { $0.testDetectionIsCaseAndPathInsensitive() },
        .init(name: "testProfileMatrixRungsMatchTheEvidence") { $0.testProfileMatrixRungsMatchTheEvidence() },
        .init(name: "testUnknownFamilyPromotesAfterThreeCleanParses") { $0.testUnknownFamilyPromotesAfterThreeCleanParses() },
        .init(name: "testPromotionPersistsAcrossStoreRebuilds") { try $0.testPromotionPersistsAcrossStoreRebuilds() },
        .init(name: "testKnownFamiliesNeverPromote") { $0.testKnownFamiliesNeverPromote() },
        .init(name: "testReadOnlyHomeDegradesToSessionOnlyMemory") { $0.testReadOnlyHomeDegradesToSessionOnlyMemory() },
        .init(name: "testCorruptStoreFileDegradesGracefully") { try $0.testCorruptStoreFileDegradesGracefully() },
        .init(name: "testR1ThinkBudgetRefusalIsLoud") { try $0.testR1ThinkBudgetRefusalIsLoud() },
        .init(name: "testR1ThinkBudgetAcceptsFloorPlusHeadroom") { try $0.testR1ThinkBudgetAcceptsFloorPlusHeadroom() },
        .init(name: "testRequestedBudgetBelowFloorIsRefusedLoudly") { try $0.testRequestedBudgetBelowFloorIsRefusedLoudly() },
        .init(name: "testMalformedServerURLIsAProfileError") { try $0.testMalformedServerURLIsAProfileError() },
        .init(name: "testEnvelopeParseTranslateRoundTrip") { try $0.testEnvelopeParseTranslateRoundTrip() },
        .init(name: "testEnvelopeEmptyArgumentsDefaultToEmptyObject") { try $0.testEnvelopeEmptyArgumentsDefaultToEmptyObject() },
        .init(name: "testEnvelopeUnknownToolNameIsFlaggedAsHallucination") { try $0.testEnvelopeUnknownToolNameIsFlaggedAsHallucination() },
        .init(name: "testEnvelopeNarrationNamingKnownToolFlagsHallucination") { try $0.testEnvelopeNarrationNamingKnownToolFlagsHallucination() },
        .init(name: "testEnvelopePlainProseWithoutToolNamesDoesNotFlag") { try $0.testEnvelopePlainProseWithoutToolNamesDoesNotFlag() },
        .init(name: "testNativeToolsParseOpenAIShape") { try $0.testNativeToolsParseOpenAIShape() },
        .init(name: "testNativeToolsParseDictionaryArgumentsAndClampToFour") { try $0.testNativeToolsParseDictionaryArgumentsAndClampToFour() },
        .init(name: "testNativeToolsUnknownToolNamesAreDropped") { try $0.testNativeToolsUnknownToolNamesAreDropped() },
        .init(name: "testNativeToolsEmptyWithNarrationFlagsHallucination") { try $0.testNativeToolsEmptyWithNarrationFlagsHallucination() },
        .init(name: "testRescueParsesBareJSONCall") { try $0.testRescueParsesBareJSONCall() },
        .init(name: "testRescueParsesFencedCall") { try $0.testRescueParsesFencedCall() },
        .init(name: "testRescueParsesToolCallTagsAndAlternates") { try $0.testRescueParsesToolCallTagsAndAlternates() },
        .init(name: "testRescueIgnoresUnknownToolNames") { try $0.testRescueIgnoresUnknownToolNames() },
        .init(name: "testRescueSurvivesBracesInsideStrings") { try $0.testRescueSurvivesBracesInsideStrings() },
        .init(name: "testRescueCappedAtFourCalls") { try $0.testRescueCappedAtFourCalls() },
        .init(name: "testRescueNoCallThrowsWithoutFlagOnPlainProse") { try $0.testRescueNoCallThrowsWithoutFlagOnPlainProse() },
        .init(name: "testActorNativeToolsEndToEndViaScriptedHTTP") { try await $0.testActorNativeToolsEndToEndViaScriptedHTTP() },
        .init(name: "testActorEnvelopeEndToEndViaScriptedHTTP") { try await $0.testActorEnvelopeEndToEndViaScriptedHTTP() },
        .init(name: "testActorRescueEndToEndViaScriptedHTTP") { try await $0.testActorRescueEndToEndViaScriptedHTTP() },
        .init(name: "testActorScriptedRequestsCarryToolsAndRequiredChoice") { try await $0.testActorScriptedRequestsCarryToolsAndRequiredChoice() },
        .init(name: "testActorScriptedEnvelopeRequestCarriesResponseFormat") { try await $0.testActorScriptedEnvelopeRequestCarriesResponseFormat() },
        .init(name: "testActorTranscriptRollsAcrossTurnsWithToolResults") { try await $0.testActorTranscriptRollsAcrossTurnsWithToolResults() },
        .init(name: "testActorHTTPErrorSurfacesAsActorError") { try await $0.testActorHTTPErrorSurfacesAsActorError() },
        .init(name: "testActorScriptedQueueEmptySurfacesAsServerError") { try await $0.testActorScriptedQueueEmptySurfacesAsServerError() },
        .init(name: "testActorBatchFeedsKernelAndKernelClamps") { try await $0.testActorBatchFeedsKernelAndKernelClamps() },
        .init(name: "testEnvelopePerToolBranchesCarryRegistrySchemas") { try $0.testEnvelopePerToolBranchesCarryRegistrySchemas() },
        .init(name: "testEnvelopePerToolSchemasModeEmbedsOneOfAndSharedShapeStaysProbeVerbatim") { try $0.testEnvelopePerToolSchemasModeEmbedsOneOfAndSharedShapeStaysProbeVerbatim() },
        .init(name: "testEnvelopeModeIsAProfileOptionAndGLMRidesPerToolSchemas") { try $0.testEnvelopeModeIsAProfileOptionAndGLMRidesPerToolSchemas() },
        .init(name: "testActorSendsProfileEnvelopeModeInResponseFormat") { try await $0.testActorSendsProfileEnvelopeModeInResponseFormat() },
        .init(name: "testSparkProfileCarriesReasoningFloorAndCorrectedNotes") { try $0.testSparkProfileCarriesReasoningFloorAndCorrectedNotes() },
        .init(name: "testSparkFloorRefusalAndAcceptanceStayLoud") { try $0.testSparkFloorRefusalAndAcceptanceStayLoud() },
    ])
}
