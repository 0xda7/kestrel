// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The model-facing tool-surface catalog (M1 input).
///
/// The actor compiles both wire payloads from this catalog: the OpenAI
/// `tools[]` array for the native-tools rung and the `response_format`
/// json_schema envelope for the rung-2 families (GLM-4). Names and
/// parameter schemas are pulled LIVE from `MerlinToolRegistry` (the same
/// module), so the advertised surface can never drift from what actually
/// executes; only the one-line tool descriptions are restated here, because
/// registry descriptions live on tool instances bound to a workspace.
/// `MerlinChecks2` pins those descriptions against a real registry so a
/// wording change on either side fails a check, not a probe.
public enum MerlinToolSchema {
    /// One advertised tool: canonical name + model-facing description.
    /// Parameters are `MerlinToolRegistry.schema(for:)` by construction.
    public struct Definition: Sendable, Equatable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }

        /// The tool's parameter schema, sourced from the registry at call
        /// time so the catalog and the executor share one definition.
        public var parameters: [String: Any] { MerlinToolRegistry.schema(for: name) }
    }

    /// Descriptions mirror `MerlinToolRegistry.makeTools` verbatim (pinned
    /// by MerlinChecks2). Ordered canonically.
    ///
    /// SECURITY wave 2 (2026-11-15): `shell_run` / `js_eval` no longer
    /// carry hardcoded claims. Both descriptions are sourced from the
    /// kernel's honest boundary text (`MerlinShell.modelFacingDescription`
    /// / `MerlinJS.modelFacingDescription`), which states what is actually
    /// enforced in THIS process — the seatbelt boundary when the host
    /// allows it, the screening fallback (and a refusal claim) when the
    /// probe fails. The registry's tool instances read the same source at
    /// construction, so catalog and registry can never drift apart on this
    /// claim again (the pre-hardening "network disabled" lie shipped from
    /// exactly this kind of duplicated literal).
    public static let definitions: [Definition] = [
        Definition(name: "fs_read", description: "Read a text file from the workspace."),
        Definition(name: "fs_write", description: "Create or replace a text file in the workspace; intermediate folders are created for you."),
        Definition(name: "fs_list", description: "List a directory in the workspace, one entry per line."),
        Definition(name: "fs_grep", description: "Find lines containing literal text, reported as path:line: matches."),
        Definition(name: "shell_run", description: MerlinShell.modelFacingDescription()),
        Definition(name: "js_eval", description: MerlinJS.modelFacingDescription()),
        Definition(name: "todo_write", description: "Replace the task todo list; the digest shows open items every turn."),
        Definition(name: "todo_read", description: "Read the current todo list (the latest todo_write)."),
        Definition(name: "note_add", description: "Record a fact, decision, blocker, or artifact in the structured memory."),
        Definition(name: "task_done", description: "File the completion contract: end the task with a final summary that cites artifact paths."),
    ]

    /// True when `name` is one of the ten advertised tools.
    public static func isKnownTool(_ name: String) -> Bool {
        definitions.contains { $0.name == name }
    }

    /// The known tool names as a set (rescue-ladder gate).
    public static var knownToolNames: Set<String> {
        Set(definitions.map(\.name))
    }

    /// The OpenAI `tools` array for the native-tools rung: one function
    /// definition per catalog tool, parameters verbatim from the registry.
    public static func openAIToolsPayload() -> [[String: Any]] {
        definitions.map { definition in
            [
                "type": "function",
                "function": [
                    "name": definition.name,
                    "description": definition.description,
                    "parameters": definition.parameters,
                ],
            ]
        }
    }

    /// How much of the per-tool argument schema the rung-2 envelope grammar
    /// enforces (slice 6, kernel-2's flagged deviation). The MODE TYPE lives
    /// on `MerlinModelProfile.EnvelopeMode` (the policy owner); this builder
    /// consumes it:
    ///
    /// - `sharedShape`: the probe-verbatim envelope — `name` is enum-gated
    ///   but `arguments` is ANY object. The grammar constrains the call
    ///   SHAPE only. Live evidence (kernel-2 soak, mission journal round
    ///   13): GLM-4-9B under this grammar emitted envelope calls whose
    ///   ARGUMENT KEYS did not match the tool schemas (`{"report_file": …}`
    ///   against fs_write's `{path, content}`) — legal per the grammar,
    ///   rejected by the executor.
    /// - `perToolSchemas`: one `oneOf` branch per tool —
    ///   `{name: const <tool>, arguments: <that tool's registry schema>}`
    ///   — the C1 pattern (ChatToolsService.swift `ToolTurnEnvelope`
    ///   .responseFormat, read-not-modified). Argument keys outside a
    ///   tool's schema become unemittable, so the executor can no longer
    ///   receive schema-sloppy arguments on this rung.
    public typealias EnvelopeMode = MerlinModelProfile.EnvelopeMode

    /// The rung-2 `response_format` value: the byte-shape of the envelope
    /// probe that GLM-4-9B answered byte-perfectly (ACTOR-CONTRACT-PROBES.md,
    /// "body-glm-schema.json"), widened from the probe's 3-tool enum to the
    /// full ten-tool surface. The grammar admits exactly one object shape —
    /// `{"name": <known tool>, "arguments": <object>}` — so malformed,
    /// fenced, or narrated blobs are unemittable on this rung.
    public static func envelopeResponseFormat() -> [String: Any] {
        envelopeResponseFormat(mode: .sharedShape)
    }

    /// The rung-2 `response_format` for a given envelope mode. The
    /// `.sharedShape` branch is byte-identical to the original probe shape;
    /// `.perToolSchemas` swaps the enum-gated `name` + free `arguments`
    /// pair for one `oneOf` branch per tool carrying its registry schema.
    public static func envelopeResponseFormat(mode: EnvelopeMode) -> [String: Any] {
        let schema: [String: Any]
        switch mode {
        case .sharedShape:
            schema = [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "enum": MerlinToolRegistry.reservedNames],
                    "arguments": ["type": "object"],
                ],
                "required": ["name", "arguments"],
                "additionalProperties": false,
            ]
        case .perToolSchemas:
            schema = [
                "oneOf": perToolBranches(),
            ]
        }
        return [
            "type": "json_schema",
            "json_schema": [
                "strict": true,
                "name": "tool_envelope",
                "schema": schema,
            ],
        ]
    }

    /// One branch per catalog tool: `{"name": {"const": <tool>},
    /// "arguments": <registry schema>}`. A tool whose registry schema is
    /// empty falls back to a bare object (C1's lenient branch rule).
    /// Schemas are pulled LIVE from `MerlinToolRegistry.schema(for:)`, the
    /// same source the rung-1 payload and the executor decode against —
    /// the advertised grammar can never drift from what executes.
    public static func perToolBranches() -> [[String: Any]] {
        definitions.map { definition in
            let arguments = definition.parameters.isEmpty
                ? ["type": "object"]
                : definition.parameters
            return [
                "type": "object",
                "properties": [
                    "name": ["const": definition.name],
                    "arguments": arguments,
                ],
                "required": ["name", "arguments"],
            ]
        }
    }
}
