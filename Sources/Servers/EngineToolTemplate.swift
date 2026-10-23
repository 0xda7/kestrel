// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Bridges the engine's chat-template detection to re-authored LFM2-family
/// templates, so Agent Tools requests never hit the broken generic grammar
/// path (the 2026-10-14 outage: every tools-carrying chat request failed with
/// `error parsing grammar: expecting newline or end at ::= |`).
///
/// Why it breaks: with `--jinja --tools all`, the engine synthesizes the
/// tool-call grammar from the model's chat template. It first tries
/// specialized handlers, matched by STATIC substrings of the template source
/// (LFM2: `<|tool_list_start|>`; LFM2.5: the literal `List of tools: [`).
/// The stock LFM2.5 template builds its tool list at render time
/// (`"List of tools: " + tools|tojson`), so finetunes that keep the family's
/// tool-call syntax but re-author the template — DavidAU-style LFM2.5 builds
/// like TBrilliance-NEO — match NEITHER detector and fall through to the
/// generic diff analyzer. That analyzer derives a degenerate format (its
/// probe sentinels leak into the rules, and argument suffixes come out
/// empty), and the generator emits GBNF rules with a trailing empty
/// alternative (`ac-N ::= |`, `until-N ::= |`) which the engine's own grammar
/// parser rejects — reproduced and proven against the vendored engine code
/// (llama-grammar.cpp parse_alternates cannot accept a trailing `|`; the
/// newline after the pipe is skipped and the next rule's name is slurped in
/// as a reference).
///
/// The app-side fix: when the embedded template speaks the LFM2 tool-call
/// syntax (`<|tool_call_start|>` … `<|tool_call_end|>`) but carries no
/// detectable LFM2 marker, append an inert Jinja comment that carries the
/// LFM2.5 marker and hand the engine `--chat-template-file`. The specialized
/// LFM2.5 handler then drives parsing and the grammar (verified: the
/// generated grammar parses, and the rendered prompt is unchanged because a
/// Jinja comment renders nothing and the specialized handler renders the
/// prompt through the model's own template).
enum EngineToolTemplate {
    /// The inert comment whose substring engages the engine's specialized
    /// LFM2.5 handler (`common_chat_params_init_lfm2_5`: requires
    /// `List of tools: [` in the source and no `<|tool_list_start|>`).
    static let lfm25MarkerComment = "{#- List of tools: [ -#}"

    static let templateKey = "tokenizer.chat_template"
    static let toolUseTemplateKey = "tokenizer.chat_template.tool_use"

    /// True when the template speaks the LFM2 tool-call syntax but the
    /// engine's static detectors cannot see it, so the marker comment must
    /// carry it into the specialized handler.
    ///
    /// `toolUseTemplate` must be nil: an override replaces the default
    /// template only, and the engine reads the `tool_use` variant from the
    /// GGUF solely when NO override is given — overriding a model that ships
    /// one would silently drop it.
    static func needsLFM25Marker(template: String, toolUseTemplate: String?) -> Bool {
        guard toolUseTemplate == nil else { return false }
        // The family's call syntax, from the template's own render_tool_calls.
        guard template.contains("<|tool_call_start|>"), template.contains("<|tool_call_end|>") else { return false }
        // The engine's LFM2 detector (is_lfm2_template) and LFM2.5 detector
        // both already match — nothing to carry.
        return !template.contains("<|tool_list_start|>")
            && !template.contains("List of tools: [")
            && !template.contains(lfm25MarkerComment)
    }

    /// The template plus the inert marker comment, on its own line.
    static func annotated(_ template: String) -> String {
        template + "\n" + lfm25MarkerComment + "\n"
    }

    /// True when the template speaks a tool-call syntax the bundled engine
    /// drives with its own specialized grammar (the LFM2 family's
    /// `<|tool_call_start|>`/`<|tool_call_end|>`, markers or not). The
    /// engine turns any `response_format json_schema` into a
    /// whole-completion grammar that OVERRIDES those handlers — verified
    /// 2026-10-23 against LFM2.5-8B on port 8081: with the C1 envelope
    /// riding the turn the model looped inside `<|channel>thought` and never
    /// emitted the call, while the same request without the envelope
    /// returned a clean `tool_calls` channel. Tool-carrying turns for these
    /// templates must therefore ride the native channel with no envelope.
    static func speaksNativeToolCalls(template: String) -> Bool {
        template.contains("<|tool_call_start|>")
    }

    /// The active model's template speaks a native tool-call syntax. Never
    /// throws: unreadable metadata means "unknown", and unknown keeps the
    /// envelope — the conservative path for GLM-class prose emitters, which
    /// are the templates the envelope was built for.
    static func activeModelSpeaksNativeToolCalls(_ modelPath: String) -> Bool {
        guard let (template, _) = chatTemplates(at: modelPath) else { return false }
        return speaksNativeToolCalls(template: template)
    }

    /// Derives the override file for a model, or nil when the engine should
    /// keep reading the template from the GGUF. Never throws: every failure
    /// degrades to today's behavior rather than blocking the launch.
    /// `directory` is where derived templates live; nil means the app's
    /// Application Support folder (tests inject a temporary one).
    static func derivedTemplateFile(forModel modelPath: String, directory: URL? = nil) -> String? {
        guard let (template, toolUseTemplate) = chatTemplates(at: modelPath),
              needsLFM25Marker(template: template, toolUseTemplate: toolUseTemplate) else { return nil }
        let content = annotated(template)

        let target = (directory ?? applicationSupportDirectory)
            .appendingPathComponent("tool-templates", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let url = target.appendingPathComponent(fileName(for: modelPath, content: content))
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data(content.utf8).write(to: url, options: .atomic)
            } else {
                // The name embeds a content hash, so an existing file with
                // this name is this content.
            }
            return url.path
        } catch {
            return nil
        }
    }

    /// `chat_template` and (if present) `chat_template.tool_use` from the
    /// GGUF header. The prefix is mmapped read-only; arrays (the multi-MB
    /// tokenizer tables that can sit before the template key) are skipped
    /// element-wise without decoding.
    static func chatTemplates(at path: String) -> (template: String, toolUse: String?)? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let descriptor = standardized.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size > 0 else { return nil }
        let count = min(32 * 1024 * 1024, Int(status.st_size))
        guard let pointer = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0), pointer != MAP_FAILED else {
            return nil
        }
        defer { munmap(pointer, count) }

        let data = Data(bytesNoCopy: pointer, count: count, deallocator: .custom { _, _ in })
        var cursor = Cursor(data: data)
        guard cursor.readBytes(count: 4) == Data([0x47, 0x47, 0x55, 0x46]),
              let version = cursor.readUInt32(), version >= 2,
              cursor.readUInt64() != nil,
              let metadataCount = cursor.readUInt64(), metadataCount <= 1_000_000 else { return nil }

        var template: String?
        var toolUse: String?
        for _ in 0..<metadataCount {
            guard let key = cursor.readString(maxLength: 1 << 20),
                  let valueType = cursor.readUInt32() else { return nil }
            if (key == templateKey || key == toolUseTemplateKey), valueType == 8,
               let value = cursor.readString(maxLength: 8 << 20) {
                if key == templateKey { template = value } else { toolUse = value }
                if template != nil && toolUse != nil { break }
                continue
            }
            guard cursor.skipValue(type: valueType) else { return nil }
        }
        guard let found = template else { return nil }
        return (found, toolUse)
    }

    /// Set once by the check harness before any check runs (nil in
    /// production): derived templates then land beside the isolated store
    /// instead of the operator's real tool-templates folder, so a crashed
    /// check cannot leave `lfm-args-*` artifacts in Application Support.
    /// Unsafe-by-contract: written only at startup, single-threaded.
    nonisolated(unsafe) static var directoryOverride: URL?

    private static var applicationSupportDirectory: URL {
        if let override = Self.directoryOverride { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kestrel", isDirectory: true)
    }

    /// `<model stem>-<8 hex content hash>.jinja`: unique per model file and
    /// per template content, so a rewritten model never reuses a stale file.
    private static func fileName(for modelPath: String, content: String) -> String {
        let stem = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        return "\(stem)-\(contentHash(content)).jinja"
    }

    /// FNV-1a, enough to disambiguate template text; not security.
    private static func contentHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Data(text.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private struct Cursor {
        let data: Data
        var offset = 0

        mutating func readBytes(count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func readUInt32() -> UInt32? {
            guard let raw = readBytes(count: 4) else { return nil }
            return raw.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        }

        mutating func readUInt64() -> UInt64? {
            guard let raw = readBytes(count: 8) else { return nil }
            return raw.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
        }

        mutating func readString(maxLength: Int) -> String? {
            guard let rawLength = readUInt64(), rawLength <= UInt64(maxLength) else { return nil }
            let length = Int(rawLength)
            guard let raw = readBytes(count: length) else { return nil }
            return String(data: raw, encoding: .utf8)
        }

        mutating func skipValue(type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7: return readBytes(count: 1) != nil
            case 2, 3: return readBytes(count: 2) != nil
            case 4, 5, 6: return readBytes(count: 4) != nil
            case 10, 11, 12: return readBytes(count: 8) != nil
            case 8: return readString(maxLength: 32 << 20) != nil
            case 9:
                guard let elementType = readUInt32(), let rawCount = readUInt64() else { return false }
                let count = Int(clamping: rawCount)
                switch elementType {
                case 8:
                    // String arrays (tokenizer tables) are length-prefixed
                    // elements; skip them one by one.
                    for _ in 0..<count where readString(maxLength: 32 << 20) == nil { return false }
                    return true
                case 0, 1, 7: return readBytes(count: count) != nil
                case 2, 3: return readBytes(count: count * 2) != nil
                case 4, 5, 6: return readBytes(count: count * 4) != nil
                case 10, 11, 12: return readBytes(count: count * 8) != nil
                default: return false
                }
            default: return false
            }
        }
    }
}
