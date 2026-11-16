// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Model-family profile (M8): the per-family configuration that picks the
/// actor rung and completion budget. Every default below is grounded in the
/// live probe matrix (mission doc MODEL-PROFILES-EVIDENCE.md, 2026-11-15):
/// rung flips happen only on captured evidence, never on a guess.
public struct MerlinModelProfile: Equatable, Sendable {
    /// Which rung of the M1 ladder this family rides.
    ///
    /// - `nativeTools`: POST `tools[]` + `tool_choice:"required"`, parse
    ///   `message.tool_calls` (rung 1).
    /// - `jsonEnvelope`: `response_format json_schema` envelope, parse
    ///   `content` as JSON (rung 2 — GLM-4).
    /// - `rescue`: lenient parse of `content` for call syntax (rung 3 —
    ///   unprofiled families until they earn a promotion).
    public enum ToolCallMode: String, Equatable, Sendable, CaseIterable {
        case nativeTools
        case jsonEnvelope
        case rescue
    }

    public let family: String
    public let toolCallMode: ToolCallMode
    /// Floor on `max_tokens` for any completion this family runs (think
    /// budget). R1-0528-Qwen3 exhausts a 200-token budget thinking and
    /// never acts; ≥3000 acts (journal, M8 matrix round 2). Other families
    /// get the 512 action floor. The actor refuses to run below floor +
    /// headroom — loudly, at configuration time.
    public let minCompletionTokens: Int
    /// Headroom added on top of the think floor (binding rule 3).
    public static let actionHeadroom = 512
    /// How strongly the rung-2 envelope grammar binds argument keys
    /// (slice 6): `sharedShape` is the probe-verbatim grammar (shape-only
    /// constraint); `perToolSchemas` compiles one `oneOf` branch per tool
    /// carrying its registry schema (the C1 pattern), so schema-sloppy
    /// argument keys become unemittable. Evidence for glm-4's value:
    /// kernel-2's live soak caught GLM-4-9B emitting `{"report_file": …}`
    /// against fs_write's `{path, content}` under the shared shape —
    /// grammar-legal, executor-rejected. Default stays `.sharedShape`
    /// (rung-2 is per-family opt-in; other families re-verify before
    /// tightening).
    public enum EnvelopeMode: String, Equatable, Sendable, CaseIterable {
        case sharedShape
        case perToolSchemas
    }
    /// Template/handling notes surfaced for operators and the soak log.
    public let templateNotes: String
    /// The envelope grammar strength this family requests (rung-2 only).
    public let envelopeMode: EnvelopeMode

    public init(family: String, toolCallMode: ToolCallMode,
                minCompletionTokens: Int, templateNotes: String,
                envelopeMode: EnvelopeMode = .sharedShape) {
        self.family = family
        self.toolCallMode = toolCallMode
        self.minCompletionTokens = minCompletionTokens
        self.templateNotes = templateNotes
        self.envelopeMode = envelopeMode
    }

    /// The matrix rows, keyed by detected family.
    public static let known: [String: MerlinModelProfile] = [
        "spark-x2.5": MerlinModelProfile(
            family: "spark-x2.5",
            toolCallMode: .nativeTools,
            minCompletionTokens: sparkReasoningFloor,
            templateNotes: "Rung 1 verified byte-perfect on 1.7B and 4B (Q8_0/Q4_K_M); envelope also clean on 4B (dual-capable fallback). THINK BUDGET: emits reasoning_content on chat completions — slice-6 live probe on Spark-X2.5-1.7B-Q8_0 (:8199) returned a reasoning_content field on every tool-calling completion (222 and 493 chars across two prompts), and usage.completion_tokens (89, 143) COUNT those reasoning tokens, so reasoning eats the max_tokens budget; the earlier 'no think budget' note was wrong. Floor raised 512 → 768 so a reasoning burst cannot starve the action tokens."
        ),
        "lfm2.5": MerlinModelProfile(
            family: "lfm2.5",
            toolCallMode: .nativeTools,
            minCompletionTokens: defaultMinCompletionTokens,
            templateNotes: "Rung 1 verified on 2.6b-fable5 (picked fs_read over fs_write, exact args). Engine flags the family grammar-sensitive (ChatToolsService.swift:678): never ride the json_schema envelope here; re-verify rung 1 per engine release."
        ),
        "deepseek-r1": MerlinModelProfile(
            family: "deepseek-r1",
            toolCallMode: .nativeTools,
            minCompletionTokens: r1ThinkBudgetFloor,
            templateNotes: "Rung 1 with reasoning_content; requires max_tokens >= ~3000 or thinking eats the budget and no action happens (R1-0528-Qwen3-8B probe). Kernel refuses completions below floor + headroom."
        ),
        "qwen3.5": MerlinModelProfile(
            family: "qwen3.5",
            toolCallMode: .nativeTools,
            minCompletionTokens: defaultMinCompletionTokens,
            templateNotes: "Rung 1 byte-perfect on 9B-distilled; envelope also clean (dual-capable fallback)."
        ),
        "glm-4": MerlinModelProfile(
            family: "glm-4",
            toolCallMode: .jsonEnvelope,
            minCompletionTokens: defaultMinCompletionTokens,
            templateNotes: "Rung 1 FAILS on 9B-0414: tool_calls null, raw call syntax inline in content, hallucinated fake results (tool_choice required and --jinja do not fix it). Rung 2 envelope is byte-perfect and grammar-locked. Suspected-hallucination flag armed on rung-2 content. Slice 6: envelope grammar tightened to perToolSchemas — the shared shape let schema-sloppy argument keys through (kernel-2 soak: {\"report_file\": …} against fs_write's {path, content}).",
            envelopeMode: .perToolSchemas
        ),
        "unknown": MerlinModelProfile(
            family: "unknown",
            toolCallMode: .rescue,
            minCompletionTokens: defaultMinCompletionTokens,
            templateNotes: "Unprofiled GGUF: starts on the rescue ladder and auto-promotes to nativeTools after 3 clean native parses (per-family promotion persisted to ~/.kestrel/merlin/profiles.json)."
        ),
    ]

    /// The completion floor for families with no think budget.
    public static let defaultMinCompletionTokens = 512
    /// R1 think budget: measured acting floor from the live probe.
    public static let r1ThinkBudgetFloor = 3000
    /// Spark-X2.5 think budget (slice 6): live probe on Spark-X2.5-1.7B-Q8_0
    /// port 8199 showed reasoning_content emitted on every tool-calling
    /// completion (222 and 493 chars across two prompts), with
    /// usage.completion_tokens counting those reasoning tokens — reasoning
    /// eats the max_tokens budget, so the floor rises 512 → 768: room for a
    /// reasoning burst plus the action tokens, without padding to R1's 3000.
    public static let sparkReasoningFloor = 768

    /// The unknown-family profile, with the promotion mode applied.
    public static func unknownProfile(mode: ToolCallMode) -> MerlinModelProfile {
        MerlinModelProfile(
            family: "unknown",
            toolCallMode: mode,
            minCompletionTokens: defaultMinCompletionTokens,
            templateNotes: known["unknown"]!.templateNotes
        )
    }
}

/// The profile store (M8): detects the family from a GGUF filename, hands
/// out the profile, and runs the unknown-family auto-promotion protocol.
///
/// Promotions (unknown → rung 1 after 3 clean native parses) persist to
/// `~/.kestrel/merlin/profiles.json` keyed by family name. Persistence is
/// best-effort BY DESIGN: a read-only HOME or a corrupt file degrades the
/// store to session-only memory with the detection and promotion machinery
/// fully intact — a profile cache must never take the kernel down.
///
/// Named `MerlinProfileStore` (not `ProfileStore`) because an unrelated
/// server-profile `ProfileStore` already exists in this module
/// (Sources/Servers/Profiles.swift).
public final class MerlinProfileStore: @unchecked Sendable {
    /// Thrown when a profile cannot satisfy the requested completion
    /// budget (think-budget refusal, binding rule 3). Loud, never silent.
    public struct ProfileError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Clean native parses an unknown family must bank before promoting to
    /// rung 1 (binding rule 5).
    public static let promotionThreshold = 3
    /// Persistence location, overridable for checks (sandboxed temp dirs).
    public static var storeURL: URL {
        overrides.storeURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kestrel", isDirectory: true)
            .appendingPathComponent("merlin", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    /// Per-run override set by checks; `nil` in production.
    struct Overrides {
        var storeURL: URL?
    }
    nonisolated(unsafe) static var overrides = Overrides()

    private let lock = NSLock()
    private var profiles: [String: MerlinModelProfile]
    private var cleanNativeParses: [String: Int]
    private var persistenceAvailable = true

    /// Builds the store over the known matrix plus the persisted unknown-
    /// family promotions (when the store file is readable and valid).
    /// A read failure leaves promotions empty, marks persistence
    /// unavailable for this session, and otherwise constructs normally.
    public init(storeURL: URL? = nil) {
        self.profiles = MerlinModelProfile.known
        self.cleanNativeParses = [:]
        if let storeURL {
            Self.overrides.storeURL = storeURL
        }
        loadPersistedPromotions()
    }

    /// Detaches the persistence file (session-only mode) — used after a
    /// write failure and by checks that pin the degrade path.
    public func disablePersistence() {
        lock.lock()
        defer { lock.unlock() }
        persistenceAvailable = false
    }

    /// True while the profiles.json read/write path is believed healthy.
    public var isPersistenceAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return persistenceAvailable
    }

    /// Detects the model family from a GGUF filename (case-insensitive,
    /// full-path tolerant). Returns the matrix family on match, "unknown"
    /// otherwise. The known markers are ordered longest-first so specific
    /// markers (e.g. "deepseek-r1") win over generic ones.
    public static func detectFamily(modelName: String) -> String {
        let lowered = modelName.lowercased()
        // Longest-first so e.g. "lfm2.5-8b" and "lfm2.5-2.6b" both hit
        // lfm2.5, and "deepseek-r1" wins over a bare "deepseek" marker.
        let markers: [(marker: String, family: String)] = [
            ("deepseek-r1", "deepseek-r1"),
            ("glm-4", "glm-4"),
            ("qwen3.5", "qwen3.5"),
            ("spark-x2.5", "spark-x2.5"),
            ("lfm2.5", "lfm2.5"),
        ]
        for (marker, family) in markers where lowered.contains(marker) {
            return family
        }
        return "unknown"
    }

    /// The effective profile for a model path/name: the family matrix row,
    /// with an unknown family upgraded to rung 1 when a previous session
    /// already banked its promotion.
    public func profile(for modelName: String) -> MerlinModelProfile {
        let family = Self.detectFamily(modelName: modelName)
        lock.lock()
        defer { lock.unlock() }
        if let profile = profiles[family] {
            return profile
        }
        return MerlinModelProfile.unknownProfile(mode: .rescue)
    }

    /// Records one clean native-tools parse for a family and promotes it
    /// to rung 1 at the threshold. Returns the family's mode AFTER the
    /// banked parse. Non-unknown families ignore promotions (their rung is
    /// evidence-locked); the return value still reports the current mode.
    @discardableResult
    public func recordCleanNativeParse(modelName: String) -> MerlinModelProfile.ToolCallMode {
        let family = Self.detectFamily(modelName: modelName)
        lock.lock()
        defer { lock.unlock() }
        guard profiles[family]?.toolCallMode == .rescue else {
            return profiles[family]?.toolCallMode ?? .rescue
        }
        let count = (cleanNativeParses[family] ?? 0) + 1
        cleanNativeParses[family] = count
        guard count >= Self.promotionThreshold else {
            return .rescue
        }
        profiles[family] = MerlinModelProfile.unknownProfile(mode: .nativeTools)
        persistLocked()
        return .nativeTools
    }

    /// The promotion counter for a family (exposed for checks; unknown
    /// families only).
    public func cleanNativeParseCount(forModel modelName: String) -> Int {
        let family = Self.detectFamily(modelName: modelName)
        lock.lock()
        defer { lock.unlock() }
        return cleanNativeParses[family] ?? 0
    }

    /// The think-budget gate: the minimum `max_tokens` a completion for
    /// this model may run with. Floor + action headroom, per binding rule 3.
    public func requiredCompletionTokens(for modelName: String) -> Int {
        profile(for: modelName).minCompletionTokens + MerlinModelProfile.actionHeadroom
    }

    // MARK: - Persistence (best-effort, degrade gracefully)

    private func loadPersistedPromotions() {
        let url = Self.storeURL
        guard let data = try? Data(contentsOf: url) else {
            // Missing file is normal (first run); unreadable file is the
            // degrade case. Both leave the store fully functional.
            if FileManager.default.fileExists(atPath: url.path) {
                persistenceAvailable = false
            }
            return
        }
        // Corrupt JSON: same degrade-to-session-memory path.
        guard let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            persistenceAvailable = false
            return
        }
        lock.lock()
        defer { lock.unlock() }
        for (family, count) in decoded where count >= Self.promotionThreshold {
            // Only unknown-family rows are meaningful here; known families
            // keep their evidence-locked rungs regardless of the file.
            if profiles[family]?.toolCallMode == .rescue {
                profiles[family] = MerlinModelProfile.unknownProfile(mode: .nativeTools)
            }
        }
    }

    /// Writes the promotion ledger. Called with `lock` held. Any failure
    /// (mkdir on a read-only HOME, encode, write) permanently downgrades
    /// this store to session-only memory rather than throwing: callers of
    /// `recordCleanNativeParse` must not inherit an I/O error from a cache.
    private func persistLocked() {
        guard persistenceAvailable else { return }
        let payload = cleanNativeParses.filter { $0.value >= Self.promotionThreshold }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else {
            persistenceAvailable = false
            return
        }
        let url = Self.storeURL
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            persistenceAvailable = false
        }
    }
}
