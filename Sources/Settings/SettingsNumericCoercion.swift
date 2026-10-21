// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// The typed-settings registry: the one place that knows which UserDefaults
/// keys carry numbers, Bool states, or string collections, and what happens
/// when a stored value does not match that kind.
///
/// The disease it cures (census §2.4 W4): a legacy or imported String under
/// a numeric/Bool key is non-nil, so `object == nil ? default : .integer/
/// .bool(forKey:)` readers sail past their nil-check and Foundation silently
/// coerces what it recognizes ("4096" reads 4096, "true" reads true — the
/// engine runs a value the @AppStorage UI never shows) and silently zeroes
/// what it does not ("on"/"garbage" read false/0 — the declared default is
/// bypassed without a trace). Worst case: Foundation's Bool reader recognizes
/// only true/yes/1, so a stored "on" under `apiKeyEnabled` silently un-arms
/// the KES-01 key requirement for LAN binds.
///
/// The cure: every registered key reads through here. Drift (a String under
/// a numeric/Bool kind, a non-collection under a collection kind) is
/// REPORTED once per key per process, and the declared default applies at
/// read time — never a silent coercion, never silent garbage. The launch
/// migration rewrites parseable legacy strings typed and removes garbage; the
/// archive import never stores a String for a registered key. One kind is
/// special: `boolFailSafe` (the API-key gate), where drift fails SAFE —
/// protection stays armed — because corruption is never consent to un-arm.
enum SettingsNumericCoercion {
    enum Kind {
        /// Stored as Double; parsed with Double(String).
        case double
        /// Stored as Int; parsed with Int(String), falling through Double(String)
        /// so "0.5"-style values round instead of being discarded.
        case int
        /// Stored as Bool. Drift -> declared default at read time.
        case bool
        /// Stored as Bool, and drift must fail SAFE: an unreadable value keeps
        /// the protection it gates ON (the API-key gate, KES-01). The operator
        /// armed it; corruption is not consent to un-arm it.
        case boolFailSafe
        /// Stored as [String]. Drift (any non-array) -> reported + empty.
        case stringArray
        /// Stored as a property-list dictionary. Drift -> reported + empty.
        case stringDictionary
    }

    /// The registered keys. Sampling numerics were the first cured class
    /// (6f7478b); Bool states join with the API-key gate (W4-7) and the rest
    /// of the numeric keys read by the app follow. Every numeric/Bool/
    /// collection `SettingsKeys` constant the app reads must appear here —
    /// `TypedSettingsRegistryTests.testRegistryIsComplete` pins that contract,
    /// so removing an entry fails the check.
    static let registry: [String: Kind] = [
        // Engine/server numerics read by fromDefaults() and its inline
        // copies (W4-1/W4-2/W4-3/W4-4/W4-10).
        SettingsKeys.benchDepth: .int,
        SettingsKeys.benchPP: .int,
        SettingsKeys.benchTG: .int,
        SettingsKeys.cacheRAM: .int,
        SettingsKeys.cacheReuseWindowSize: .int,
        SettingsKeys.ctx: .int,
        SettingsKeys.dynamicMoePrefetch: .int,
        SettingsKeys.dynamicMoeSlots: .int,
        SettingsKeys.gpuIndex: .int,
        SettingsKeys.gpusCardCollapsed: .int,
        SettingsKeys.imageMaxTokens: .int,
        // Legacy-window keys (census W7-2/W7-3, T4-2): the typed
        // declarations retired behind their green one-shot migrations
        // (ImageGenLegacyMigration / DflashLegacyMigration), but the
        // registry keeps coercing a legacy string-typed value at launch so
        // the migrations read it typed — raw strings, same shape as the
        // migrations themselves. The window dies with them.
        "imagenBaseSize": .int,
        "imagenGPU": .int,
        "imagenSeed": .int,
        "imagenSteps": .int,
        SettingsKeys.multiGPUCount: .int,
        SettingsKeys.ncmoe: .int,
        SettingsKeys.ngl: .int,
        SettingsKeys.parallelSlots: .int,
        SettingsKeys.port: .int,
        SettingsKeys.engineControlTimeoutSeconds: .int,
        SettingsKeys.routerModelsMax: .int,
        SettingsKeys.splitGroupSize: .int,
        SettingsKeys.threads: .int,
        SettingsKeys.ubatch: .int,
        SettingsKeys.vramReserve: .int,
        SettingsKeys.videoFrames: .int,
        SettingsKeys.videoGPU: .int,
        SettingsKeys.videoRecipeVersion: .int,
        SettingsKeys.videoSteps: .int,
        SettingsKeys.audioVADMaxSpeechSeconds: .double,
        SettingsKeys.audioVADMinSilenceMS: .double,
        SettingsKeys.audioVADMinSpeechMS: .double,
        SettingsKeys.audioVADSpeechPadMS: .double,
        SettingsKeys.audioVADThreshold: .double,
        SettingsKeys.chatFontScale: .double,
        SettingsKeys.chatMaxImageMegapixels: .double,
        "imagenCustomCfg": .double,
        "imagenStrength": .double,
        // The engine's secret-run constants become settings (T3-1, census
        // W3-1/W3-2): the compaction trigger and keep-tail fraction.
        SettingsKeys.chatCompactionKeepTailFraction: .double,
        SettingsKeys.chatCompactionTrigger: .double,
        // Chat sampling numerics (@AppStorage(Double/Int)) — the first
        // cured class (6f7478b).
        SettingsKeys.chatTemp: .double,
        SettingsKeys.chatTopP: .double,
        SettingsKeys.chatMinP: .double,
        SettingsKeys.chatTypicalP: .double,
        SettingsKeys.chatXTCProbability: .double,
        SettingsKeys.chatXTCThreshold: .double,
        SettingsKeys.chatDynatempRange: .double,
        SettingsKeys.chatDynatempExponent: .double,
        SettingsKeys.chatPresencePenalty: .double,
        SettingsKeys.chatFrequencyPenalty: .double,
        SettingsKeys.chatRepeatPenalty: .double,
        SettingsKeys.chatDryMultiplier: .double,
        SettingsKeys.chatDryBase: .double,
        SettingsKeys.chatTopK: .int,
        SettingsKeys.chatRepeatLastN: .int,
        SettingsKeys.chatSeed: .int,
        SettingsKeys.chatDryAllowedLength: .int,
        SettingsKeys.chatDryPenaltyLastN: .int,
        SettingsKeys.chatMaxTokens: .int,
        SettingsKeys.chatAgenticMaxTurns: .int,
        SettingsKeys.chatPasteLongTextLength: .int,
        // Response-token window headroom (T3-1, census W3-3; one setting,
        // three sites).
        SettingsKeys.chatResponseMarginTokens: .int,
        // The compaction family's remaining secretly-run constants (T3-1,
        // census W3-7..W3-12): summarize budget/temperature, minimum tail,
        // memory-recall limits, and the tool-result caps.
        SettingsKeys.chatCompactionSummaryMaxTokens: .int,
        SettingsKeys.chatCompactionSummarizeTemp: .double,
        SettingsKeys.chatCompactionMinTailMessages: .int,
        SettingsKeys.chatRecallMaxResults: .int,
        SettingsKeys.chatRecallMaxCharacters: .int,
        SettingsKeys.chatToolResultMaxTokens: .int,
        SettingsKeys.chatToolResultMinTokens: .int,
        // Agent-tool resource limits (T3-1, census W3-13/W3-14): the
        // JavaScript sandbox and the memory-archive hook delivery policy.
        SettingsKeys.jsSandboxDefaultTimeoutMS: .int,
        SettingsKeys.jsSandboxMaxTimeoutMS: .int,
        SettingsKeys.jsSandboxMaxOutputCharacters: .int,
        SettingsKeys.memoryArchiveHookQueueLimit: .int,
        SettingsKeys.memoryArchiveHookTimeout: .double,
        // Bool states, read directly (fromDefaults, bare bool(forKey:), or
        // `as? Bool ?? default`).
        SettingsKeys.agentToolsEnabled: .bool,
        SettingsKeys.audioFollowTranscript: .bool,
        SettingsKeys.autoStart: .bool,
        SettingsKeys.cacheReuse: .bool,
        SettingsKeys.chatAutoCompact: .bool,
        SettingsKeys.chatBackendSampling: .bool,
        SettingsKeys.chatPDFAsImages: .bool,
        SettingsKeys.chatShowSystemMessage: .bool,
        SettingsKeys.chatThinking: .bool,
        SettingsKeys.contextAutomatic: .bool,
        SettingsKeys.dynamicMoe: .bool,
        SettingsKeys.embeddings: .bool,
        SettingsKeys.faAmd: .bool,
        SettingsKeys.forcePrivateBuffers: .bool,
        SettingsKeys.imagenCanvasGrid: .bool,
        SettingsKeys.imagenCleanupOnClose: .bool,
        "imagenCustomIsDiffusion": .bool,
        "imagenOffloadCPU": .bool,
        SettingsKeys.imagenQueueGrid: .bool,
        SettingsKeys.jinja: .bool,
        SettingsKeys.jsSandboxEnabled: .bool,
        SettingsKeys.loadVision: .bool,
        SettingsKeys.localNetworkDiscovery: .bool,
        SettingsKeys.memoryToolsEnabled: .bool,
        SettingsKeys.menuBarIcon: .bool,
        SettingsKeys.mgpuEvents: .bool,
        SettingsKeys.mgpuPeer: .bool,
        SettingsKeys.mlock: .bool,
        SettingsKeys.multiGPU: .bool,
        SettingsKeys.noMmap: .bool,
        SettingsKeys.onboardingDone: .bool,
        SettingsKeys.persistCache: .bool,
        SettingsKeys.prefetchExperts: .bool,
        SettingsKeys.reasoningInline: .bool,
        SettingsKeys.routerMode: .bool,
        SettingsKeys.serverConfigurationAdvanced: .bool,
        SettingsKeys.smoothTyping: .bool,
        SettingsKeys.specMTP: .bool,
        SettingsKeys.uiMcpProxy: .bool,
        SettingsKeys.updateAutoCheck: .bool,
        SettingsKeys.videoNegativeSeeded: .bool,
        SettingsKeys.videoVAETiling: .bool,
        // The KES-01 gate: drift fails SAFE (armed).
        SettingsKeys.apiKeyEnabled: .boolFailSafe,
        // String collections (W4-11): per-model maps and model lists read
        // via stringArray/dictionary; drift surfaces instead of silently
        // reading empty.
        "dflashDisabled": .stringArray,   // legacy window (see the int block)
        SettingsKeys.dflashWarningAcknowledged: .stringArray,
        SettingsKeys.incompatibleMmproj: .stringArray,
        SettingsKeys.mtpDisabledModels: .stringArray,
        SettingsKeys.toolsUnsupportedModels: .stringArray,
        SettingsKeys.dflashModes: .stringDictionary,
        SettingsKeys.extraArgsByModel: .stringDictionary,
        SettingsKeys.mmprojOverride: .stringDictionary,
        SettingsKeys.modelDigest: .stringDictionary,
        SettingsKeys.modelSource: .stringDictionary,
        SettingsKeys.ncmoeByModel: .stringDictionary,
        SettingsKeys.prefetchCliffByModel: .stringDictionary,
    ]

    /// What one mistyped string becomes.
    enum Coerced {
        case double(Double)
        case int(Int)
        /// Unparseable garbage: remove the key so @AppStorage applies its
        /// declared default.
        case fallBackToDefault
    }

    static func coerce(string raw: String, as kind: Kind) -> Coerced {
        switch kind {
        case .double:
            if let value = Double(raw) { return .double(value) }
        case .int:
            if let value = Int(raw) { return .int(value) }
            if let value = Double(raw) { return .int(Int(value)) }
        case .bool, .boolFailSafe, .stringArray, .stringDictionary:
            break
        }
        return .fallBackToDefault
    }

    /// Bool spelling the migration accepts (case-insensitive). Foundation's
    /// own reader also takes yes/no, but a migration should honor exactly the
    /// spellings this app's writers produce; anything else is garbage.
    static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    // MARK: Drift reporting

    /// One log line per drifted key per process: read sites are hot (every
    /// turn reads several), and the message is the same every time.
    private static let reportedDrift = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Keys drift has been reported for this process. Exposed so checks can
    /// assert that drift is REPORTED, never silent.
    static var reportedDriftKeys: Set<String> {
        reportedDrift.withLock { $0 }
    }

    static func resetDriftReportingForChecks() {
        reportedDrift.withLock { $0.removeAll() }
    }

    private static func reportDrift(_ key: String, stored: Any, policy: String) {
        let first = reportedDrift.withLock {
            if $0.contains(key) { return false }
            $0.insert(key)
            return true
        }
        guard first else { return }
        AppLog.settings.error("""
        settings drift: '\(key, privacy: .public)' holds \(String(describing: stored), privacy: .public) \
        where its registered kind expects a typed value; \(policy, privacy: .public)
        """)
    }

    // MARK: Typed reads

    /// Typed Int read: absent -> `def`; a stored String under a registered key
    /// is drift — reported, and the DECLARED default applies at read time (the
    /// launch migration is what rewrites parseable legacy strings typed); any
    /// other stored value converts exactly as `UserDefaults.integer` always
    /// did. Unregistered keys keep the legacy behavior untouched.
    static func int(_ key: String, default def: Int, in defaults: UserDefaults = .standard) -> Int {
        guard let raw = defaults.object(forKey: key) else { return def }
        guard registry[key] != nil, raw is String else { return defaults.integer(forKey: key) }
        reportDrift(key, stored: raw,
                    policy: "declared default \(def) applies at read; migration rewrites or removes it")
        return def
    }

    /// Typed Double read; same contract as `int(_:default:in:)`.
    static func double(_ key: String, default def: Double, in defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) else { return def }
        guard registry[key] != nil, raw is String else { return defaults.double(forKey: key) }
        reportDrift(key, stored: raw,
                    policy: "declared default \(def) applies at read; migration rewrites or removes it")
        return def
    }

    /// Typed Bool read: absent -> `def`; a stored Bool or number converts as
    /// `UserDefaults.bool` always did; a stored String under a registered key
    /// is drift — reported, and either the declared default applies or, for a
    /// `boolFailSafe` key, the gate stays ARMED. Unregistered keys keep the
    /// legacy behavior untouched.
    static func bool(_ key: String, default def: Bool, in defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.object(forKey: key) else { return def }
        guard registry[key] != nil, raw is String else { return defaults.bool(forKey: key) }
        if registry[key] == .boolFailSafe {
            reportDrift(key, stored: raw, policy: "failing SAFE (gate armed)")
            return true
        }
        reportDrift(key, stored: raw,
                    policy: "declared default \(def) applies at read; migration rewrites or removes it")
        return def
    }

    /// Typed Int read where the caller's own declared default lives elsewhere
    /// (a struct's member default): nil means absent (or drift — reported —
    /// so the caller keeps its default); a present typed value converts as
    /// `UserDefaults.integer` always did.
    static func intIfPresent(_ key: String, in defaults: UserDefaults = .standard) -> Int? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        guard registry[key] != nil, raw is String else { return defaults.integer(forKey: key) }
        reportDrift(key, stored: raw,
                    policy: "caller keeps its declared default; migration rewrites or removes it")
        return nil
    }

    /// Typed Double read; same contract as `intIfPresent(_:in:)`.
    static func doubleIfPresent(_ key: String, in defaults: UserDefaults = .standard) -> Double? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        guard registry[key] != nil, raw is String else { return defaults.double(forKey: key) }
        reportDrift(key, stored: raw,
                    policy: "caller keeps its declared default; migration rewrites or removes it")
        return nil
    }

    /// Typed Bool read; same contract as `intIfPresent(_:in:)`.
    static func boolIfPresent(_ key: String, in defaults: UserDefaults = .standard) -> Bool? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        guard registry[key] != nil, raw is String else { return defaults.bool(forKey: key) }
        reportDrift(key, stored: raw,
                    policy: "caller keeps its declared default; migration rewrites or removes it")
        return nil
    }

    /// Typed [String] read (W4-11): a stored value that is not a string
    /// array is drift — reported, and the caller reads [] instead of the
    /// silently empty list the old `?? []` shape returned. Writers are
    /// same-process typed, so an absent key is legitimately empty and stays
    /// silent.
    static func stringArray(_ key: String, in defaults: UserDefaults = .standard) -> [String] {
        guard let raw = defaults.object(forKey: key) else { return [] }
        guard let array = defaults.stringArray(forKey: key) else {
            if registry[key] != nil {
                reportDrift(key, stored: raw,
                            policy: "not a string array; reading empty; migration removes it")
            }
            return []
        }
        return array
    }

    /// Typed dictionary read (W4-11): a stored value that is not a
    /// property-list dictionary is drift — reported, and the caller's own
    /// `as? [String: T] ?? [:]` falls to empty instead of silently losing
    /// per-model overrides. Absent is legitimately empty and stays silent.
    static func dictionary(_ key: String, in defaults: UserDefaults = .standard) -> [String: Any]? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        guard let dict = defaults.dictionary(forKey: key) else {
            if registry[key] != nil {
                reportDrift(key, stored: raw,
                            policy: "not a dictionary; reading empty; migration removes it")
            }
            return nil
        }
        return dict
    }

    /// The kind registered for `key`, for the completeness contract checks.
    static func kind(forKey key: String) -> Kind? { registry[key] }

    /// True when `key` is in the registry.
    static func isRegistered(_ key: String) -> Bool { registry[key] != nil }

    /// One-time migration: any registered key whose stored value is a String
    /// is rewritten typed. Parseable strings survive (bit-for-bit for Double,
    /// rounded for Int, parsed for Bool); unparseable garbage is removed so
    /// the declared default applies — EXCEPT under a fail-safe gate key,
    /// where garbage keeps the gate ARMED instead of dropping it to the
    /// off-by-default state. Returns the keys touched.
    @discardableResult
    static func migrateMistypedNumerics(in defaults: UserDefaults = .standard) -> [String] {
        var touched: [String] = []
        for (key, kind) in registry {
            guard let raw = defaults.object(forKey: key) as? String else { continue }
            switch kind {
            case .double, .int:
                switch coerce(string: raw, as: kind) {
                case .double(let value): defaults.set(value, forKey: key)
                case .int(let value): defaults.set(value, forKey: key)
                case .fallBackToDefault: defaults.removeObject(forKey: key)
                }
            case .bool, .boolFailSafe:
                if let value = parseBool(raw) {
                    defaults.set(value, forKey: key)
                } else if kind == .boolFailSafe {
                    reportDrift(key, stored: raw, policy: "unparseable; keeping the gate ARMED (fail-safe)")
                    defaults.set(true, forKey: key)
                } else {
                    reportDrift(key, stored: raw,
                                policy: "unparseable; removed so the declared default applies")
                    defaults.removeObject(forKey: key)
                }
            case .stringArray, .stringDictionary:
                reportDrift(key, stored: raw,
                            policy: "unusable as a collection; removed so the default applies")
                defaults.removeObject(forKey: key)
            }
            touched.append(key)
        }
        return touched
    }

    /// Import path: a value for a registered key must never be stored as
    /// String. Returns the value to store, or nil when the value is an
    /// unparseable string for the key's kind (the caller drops it so the
    /// declared default applies) — except under a fail-safe gate key, where
    /// garbage imports as ARMED rather than dropping to off.
    static func typedImportValue(_ value: Any, forKey key: String) -> Any? {
        guard let kind = registry[key], let raw = value as? String else { return value }
        switch kind {
        case .double, .int:
            switch coerce(string: raw, as: kind) {
            case .double(let value): return value
            case .int(let value): return value
            case .fallBackToDefault: return nil
            }
        case .bool, .boolFailSafe:
            if let parsed = parseBool(raw) { return parsed }
            if kind == .boolFailSafe {
                reportDrift(key, stored: raw, policy: "unparseable import; storing ARMED (fail-safe)")
                return true
            }
            return nil
        case .stringArray, .stringDictionary:
            reportDrift(key, stored: raw, policy: "a String cannot restore a collection; dropped")
            return nil
        }
    }
}
