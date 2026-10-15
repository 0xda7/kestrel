// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Pins the 2026-10-14 Agent Tools grammar fix. With `--jinja --tools all`,
/// the engine derives the tool-call grammar from the model's chat template.
/// LFM2-family finetunes that keep the family tool-call syntax but re-author
/// the template match none of the engine's static format detectors, and the
/// generic fallback then emits a grammar the engine's own parser rejects
/// (`error parsing grammar: expecting newline or end at ::= |` — every
/// tools-carrying request 500s). The fix detects that template shape app-side
/// and hands the engine a copy carrying an inert marker comment so its
/// specialized LFM2.5 parser/grammar drives the tools instead.
final class EngineToolTemplateTests: CheckCase {
    /// The TBrilliance-NEO shape (verified against the operator's GGUF):
    /// tool calls render as `<|tool_call_start|>[name(arg='v')]` via
    /// render_tool_calls, and the tool list is built at render time
    /// (`"List of tools: " + tools|tojson`) so the engine's static
    /// `List of tools: [` substring never appears in the source.
    private let reauthoredLFM25 =
        "{{- macro render_tool_calls(tool_calls) -}}" +
        "{{- \"<|tool_call_start|>[\" + tool_call[\"function\"][\"name\"] + \"]<|tool_call_end|>\" -}}" +
        "{%- endmacro -%}" +
        "{%- if tools -%}" +
        "{{- \"List of tools: \" + (tools | tojson) -}}" +
        "{%- endif -%}"

    func testMarkerNeededOnlyForUndetectableLFM2Syntax() {
        XCTAssertTrue(EngineToolTemplate.needsLFM25Marker(template: reauthoredLFM25, toolUseTemplate: nil),
                      "the re-authored LFM2.5 shape is exactly the broken case")

        // The engine's own LFM2 detector matches: no override may be derived.
        let withListTokens = reauthoredLFM25 + "{{- \"<|tool_list_start|>\" + (tools|tojson) + \"<|tool_list_end|>\" -}}"
        XCTAssertFalse(EngineToolTemplate.needsLFM25Marker(template: withListTokens, toolUseTemplate: nil))

        // Static LFM2.5 detector matches.
        let staticList = reauthoredLFM25 + "{#- List of tools: [ -#}"
        XCTAssertFalse(EngineToolTemplate.needsLFM25Marker(template: staticList, toolUseTemplate: nil))

        // No LFM2 call syntax at all (hermes/qwen/glm templates): untouched.
        XCTAssertFalse(EngineToolTemplate.needsLFM25Marker(
            template: "{{- '<tool_call>' + (tool_calls|tojson) + '</tool_call>' -}}",
            toolUseTemplate: nil))

        // A GGUF tool_use variant must never be shadowed by an override.
        XCTAssertFalse(EngineToolTemplate.needsLFM25Marker(template: reauthoredLFM25,
                                                           toolUseTemplate: "{{- tools -}}"))
    }

    func testAnnotatedTemplateCarriesTheInertMarkerComment() {
        let annotated = EngineToolTemplate.annotated(reauthoredLFM25)
        XCTAssertTrue(annotated.hasPrefix(reauthoredLFM25), "the model's own template is passed through verbatim")
        XCTAssertTrue(annotated.contains(EngineToolTemplate.lfm25MarkerComment))
        // Own line so it cannot join the template's last line.
        XCTAssertTrue(annotated.hasSuffix("\n" + EngineToolTemplate.lfm25MarkerComment + "\n"))
        // Idempotent: annotating twice still passes the marker decision gate.
        XCTAssertFalse(EngineToolTemplate.needsLFM25Marker(template: annotated, toolUseTemplate: nil))
    }

    func testChatTemplateIsReadPastTokenizerArrays() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Key order mirrors a real LFM2.5 GGUF: the 128k-string tokenizer
        // table sits between the scalars and tokenizer.chat_template. The
        // walker must skip it element-wise and still find the template.
        let model = dir.appendingPathComponent("lfm-mock.gguf")
        try writeTemplateGGUF(to: model, template: reauthoredLFM25, tokens: ["<pad>", "hello", "▁of"])

        let read = EngineToolTemplate.chatTemplates(at: model.path)
        XCTAssertEqual(read?.template, reauthoredLFM25)
        XCTAssertNil(read?.toolUse)

        // Unreadable or non-GGUF files degrade to nil, never a crash.
        let empty = dir.appendingPathComponent("empty.gguf")
        try Data().write(to: empty)
        XCTAssertNil(EngineToolTemplate.chatTemplates(at: empty.path))
        XCTAssertNil(EngineToolTemplate.chatTemplates(at: dir.appendingPathComponent("missing.gguf").path))
    }

    func testDerivedTemplateFileWrittenOnlyForTheBrokenShape() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let broken = dir.appendingPathComponent("tbrilliance-mock.gguf")
        try writeTemplateGGUF(to: broken, template: reauthoredLFM25, tokens: ["a"])
        let path = EngineToolTemplate.derivedTemplateFile(forModel: broken.path, directory: dir)
        let derived = try XCTUnwrap(path)
        let written = try String(contentsOfFile: derived, encoding: .utf8)
        XCTAssertEqual(written, EngineToolTemplate.annotated(reauthoredLFM25),
                       "the file is the model's template plus only the marker comment")

        // Second call is a no-rewrite returning the same path (name embeds a content hash).
        let again = EngineToolTemplate.derivedTemplateFile(forModel: broken.path, directory: dir)
        XCTAssertEqual(again, derived)

        // A model the engine already recognizes needs no override.
        let stock = dir.appendingPathComponent("stock.gguf")
        try writeTemplateGGUF(to: stock,
                              template: reauthoredLFM25 + "{{- \"<|tool_list_start|>\" -}}",
                              tokens: ["a"])
        XCTAssertNil(EngineToolTemplate.derivedTemplateFile(forModel: stock.path, directory: dir))

        // A GGUF carrying a tool_use variant keeps engine-side handling.
        let variant = dir.appendingPathComponent("variant.gguf")
        try writeTemplateGGUF(to: variant, template: reauthoredLFM25, tokens: ["a"],
                              toolUseTemplate: "{{- tools|tojson -}}")
        XCTAssertNil(EngineToolTemplate.derivedTemplateFile(forModel: variant.path, directory: dir))

        // Unreadable model: no override, no crash.
        XCTAssertNil(EngineToolTemplate.derivedTemplateFile(forModel: "", directory: dir))
    }

    func testAgentToolsLaunchCarriesDerivedTemplateFile() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = dir.appendingPathComponent("lfm-args.gguf")
        try writeTemplateGGUF(to: model, template: reauthoredLFM25, tokens: ["a"])
        var settings = minimalSettings(modelPath: model.path)
        settings.agentToolsEnabled = true

        let args = settings.arguments
        let derivedPath = try XCTUnwrap(zip(args, args.dropFirst())
            .first(where: { $0.0 == "--chat-template-file" })?.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: derivedPath),
                      "the referenced template file must exist for the engine to launch")
        XCTAssertTrue(args.contains("--tools") && args.contains("all"))

        // Without agent tools the engine keeps reading the GGUF's template.
        var plain = minimalSettings(modelPath: model.path)
        plain.agentToolsEnabled = false
        XCTAssertFalse(plain.arguments.contains("--chat-template-file"))

        // The launch writes into the real Application Support folder; remove
        // the artifacts this check created so the operator's folder stays clean.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kestrel/tool-templates", isDirectory: true)
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: support.path) {
            for name in leftovers where name.hasPrefix("lfm-args-") {
                try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Fixtures

    private func minimalSettings(modelPath: String) -> ServerSettings {
        ServerSettings(serverBinary: ServerSettings.defaultBinary, modelPath: modelPath, port: 8199,
                       ngl: 99, ncmoe: 0, ctx: 4096, threads: 4, flashAttn: "auto", noMmap: false,
                       jinja: true, vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                       cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
    }

    /// A minimal GGUF v3 whose metadata carries a tokenizer string array
    /// BEFORE `tokenizer.chat_template`, plus the optional tool_use variant.
    private func writeTemplateGGUF(to url: URL, template: String, tokens: [String],
                                   toolUseTemplate: String? = nil) throws {
        var data = Data("GGUF".utf8)
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendString(_ value: String) {
            appendUInt64(UInt64(value.utf8.count))
            data.append(contentsOf: value.utf8)
        }

        let keyCount = 3 + (toolUseTemplate == nil ? 0 : 1)
        appendUInt32(3)
        appendUInt64(0)  // tensor count
        appendUInt64(UInt64(keyCount))
        appendString("tokenizer.ggml.tokens")
        appendUInt32(9)  // array
        appendUInt32(8)  // of strings
        appendUInt64(UInt64(tokens.count))
        for token in tokens { appendString(token) }
        appendString(EngineToolTemplate.templateKey)
        appendUInt32(8)
        appendString(template)
        if let toolUseTemplate {
            appendString(EngineToolTemplate.toolUseTemplateKey)
            appendUInt32(8)
            appendString(toolUseTemplate)
        }
        appendString("general.file_type")
        appendUInt32(4)
        appendUInt32(15)
        try data.write(to: url)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension EngineToolTemplateTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "EngineToolTemplateTests",
        instance: { EngineToolTemplateTests() },
        checks: [
            .init(name: "testMarkerNeededOnlyForUndetectableLFM2Syntax") { $0.testMarkerNeededOnlyForUndetectableLFM2Syntax() },
            .init(name: "testAnnotatedTemplateCarriesTheInertMarkerComment") { $0.testAnnotatedTemplateCarriesTheInertMarkerComment() },
            .init(name: "testChatTemplateIsReadPastTokenizerArrays") { try $0.testChatTemplateIsReadPastTokenizerArrays() },
            .init(name: "testDerivedTemplateFileWrittenOnlyForTheBrokenShape") { try $0.testDerivedTemplateFileWrittenOnlyForTheBrokenShape() },
            .init(name: "testAgentToolsLaunchCarriesDerivedTemplateFile") { try $0.testAgentToolsLaunchCarriesDerivedTemplateFile() },
        ])
}
