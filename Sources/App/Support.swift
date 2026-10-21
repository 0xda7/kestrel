// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit
import Darwin
import os
import Security

// MARK: - Settings keys (single source of truth)

/// Every persisted setting key lives here. Views, `ServerSettings.fromDefaults`
/// and `ProfileStore` all reference these constants, so a typo is a compile
/// error instead of a silent bug.
enum SettingsKeys {
    /// "bundled" or "custom". Not a path: two installs share this domain.
    static let engineKind = "engineKind"
    /// Only read when engineKind is "custom".
    static let serverBinary = "serverBinary"
    static let modelPath = "modelPath"
    static let modelsDir = "modelsDir"
    static let whisperModel = "whisperModel"
    static let speechInputMethod = "speechInputMethod"
    static let whisperLoadPolicy = "whisperLoadPolicy"
    static let audioOperation = "audioOperation"
    static let audioLanguage = "audioLanguage"
    static let audioTargetLanguage = "audioTargetLanguage"
    static let audioExportFormat = "audioExportFormat"
    static let audioFollowTranscript = "audioFollowTranscript"
    static let audioTranscriptMode = "audioTranscriptMode"
    static let audioExportTrack = "audioExportTrack"
    static let subtitleStyle = "subtitleStyle"
    static let audioGlossary = "audioGlossary"
    static let audioTranslationModel = "audioTranslationModel"
    static let audioVADMode = "audioVADMode"
    static let audioVADProfile = "audioVADProfile"
    static let audioVADThreshold = "audioVADThreshold"
    static let audioVADMinSpeechMS = "audioVADMinSpeechMS"
    static let audioVADMinSilenceMS = "audioVADMinSilenceMS"
    static let audioVADMaxSpeechSeconds = "audioVADMaxSpeechSeconds"
    static let audioVADSpeechPadMS = "audioVADSpeechPadMS"
    /// Persisted (model, projector) pairs that failed to load, so a bad mmproj
    /// isn't auto-attached again.
    static let incompatibleMmproj = "incompatibleMmproj"
    /// Per-model manual projector override: a path pins that mmproj, "" disables
    /// vision, absent falls back to auto-pairing.
    static let mmprojOverride = "mmprojOverride"
    /// Per-file source URL a model was downloaded from, for sibling downloads
    /// (mmproj, dflash draft) and the model-update check.
    static let modelSource = "modelSource"
    /// Per-file SHA-256 verified at download time, compared against the remote
    /// digest to detect a re-uploaded model.
    static let modelDigest = "modelDigest"
    /// Legacy model paths whose downloaded DFlash draft was turned off.
    static let dflashDisabled = "dflashDisabled"
    static let dflashModes = "dflashModes"
    static let mtpDisabledModels = "mtpDisabledModels"
    static let dflashWarningAcknowledged = "dflashWarningAcknowledged"
    static let port = "port"
    /// Idle bound for the engine control plane's shared session (census
    /// W3-15): a request with no bytes for this long is a wedged engine.
    /// Applies when the session is built, i.e. on next launch.
    static let engineControlTimeoutSeconds = "engineControlTimeoutSeconds"
    static let ngl = "ngl"
    static let ncmoe = "ncmoe"
    /// Last user-set ncmoe per model file, restored when that model is re-selected.
    static let ncmoeByModel = "ncmoeByModel"
    /// Per-model ncmoe at which prompt processing collapses (expert-prefetch overlap
    /// stalls at/above it); the sweep measures it and prefetch is gated below it.
    static let prefetchCliffByModel = "prefetchCliffByModel"
    /// JSON archive ([String: MeasuredBench]) of completed per-model benchmarks,
    /// keyed by model path: the measured-best ncmoe/threads and the tok/s they
    /// delivered. Feeds selection pre-fill; survives settings reset like the
    /// other per-model maps.
    static let measuredBenchByModel = "measuredBenchByModel"
    static let ctx = "ctx"
    static let contextAutomatic = "contextAutomatic"
    static let threads = "threads"
    static let flashAttn = "flashAttn"
    static let noMmap = "noMmap"
    static let jinja = "jinja"
    static let vramReserve = "vramReserve"
    static let gpuIndex = "gpuIndex"
    /// Comma-separated physical GPU indices to split across (2+ entries).
    static let gpuList = "gpuList"
    static let gpusCardCollapsed = "gpusCardCollapsed"
    static let extraArgs = "extraArgs"

    /// Per-model extra arguments, keyed by model path. They are appended after the
    /// shared ones, so a model can override a flag the global field also sets.
    static let extraArgsByModel = "extraArgsByModel"

    /// Where to POST the turns memory_archive sets aside. Empty disables the hook.
    static let memoryArchiveHookURL = "memoryArchiveHookURL"

    /// Sent as a bearer token with each delivery, for receivers that want one.
    static let memoryArchiveHookSecret = "memoryArchiveHookSecret"
    /// Delivery policy for the memory-archive hook (census W3-14): the queue
    /// drops its oldest past this many pending files, and each delivery
    /// attempt gets this many seconds before it is treated as failed.
    static let memoryArchiveHookQueueLimit = "memoryArchiveHookQueueLimit"
    static let memoryArchiveHookTimeout = "memoryArchiveHookTimeout"
    static let embeddings = "embeddings"
    static let agentToolsEnabled = "agentToolsEnabled"
    static let toolsRuntime = "toolsRuntime"
    static let jsSandboxEnabled = "jsSandboxEnabled"
    /// Resource limits of the JavaScript sandbox tool (census W3-13).
    static let jsSandboxDefaultTimeoutMS = "jsSandboxDefaultTimeoutMS"
    static let jsSandboxMaxTimeoutMS = "jsSandboxMaxTimeoutMS"
    static let jsSandboxMaxOutputCharacters = "jsSandboxMaxOutputCharacters"
    /// Stop sequences for chat sampling, comma/newline separated.
    static let chatStopSequences = "chatStopSequences"
    /// memory_list / memory_archive / memory_recall. Off for setups where an
    /// external memory server already covers the job and the model mixes the two.
    static let memoryToolsEnabled = "memoryToolsEnabled"

    /// Models whose template accepts tools but that write the call in the wrong shape: the
    /// engine rejects it and the turn dies, so they stop being offered any tool.
    static let toolsUnsupportedModels = "toolsUnsupportedModels"
    static let mcpServers = "mcpServers"
    static let uiMcpProxy = "uiMcpProxy"
    static let cacheTypeK = "cacheTypeK"
    static let cacheTypeV = "cacheTypeV"
    static let mlock = "mlock"
    static let cacheRAM = "cacheRAM"
    static let parallelSlots = "parallelSlots"
    static let reasoningInline = "reasoningInline"
    static let specMTP = "specMTP"
    static let faAmd = "faAmd"
    static let prefetchExperts = "prefetchExperts"
    /// Micro-batch size (--ubatch-size). 0 keeps the engine default of 512.
    static let ubatch = "ubatch"
    static let dynamicMoe = "dynamicMoe"
    static let dynamicMoeSlots = "dynamicMoeSlots"
    static let dynamicMoePrefetch = "dynamicMoePrefetch"
    static let dynamicMoePolicy = "dynamicMoePolicy"
    static let routerMode = "routerMode"
    static let routerModelsMax = "routerModelsMax"
    static let serverConfigurationAdvanced = "serverConfigurationAdvanced"
    /// Alias of the model the native chat targets in router mode. A runtime
    /// pick, not a "setting", so it's excluded from resettableOptionKeys.
    static let chatSelectedModel = "chatSelectedModel"
    static let persistCache = "persistCache"
    static let multiGPU = "multiGPU"
    static let multiGPUCount = "multiGPUCount"
    static let splitMode = "splitMode"
    static let splitGroupSize = "splitGroupSize"
    static let mgpuEvents = "mgpuEvents"
    static let mgpuPeer = "mgpuPeer"
    static let forcePrivateBuffers = "forcePrivateBuffers"
    static let cacheReuse = "cacheReuse"
    /// The --cache-reuse chunk size passed when prompt-cache reuse is on
    /// (census W3-4): read by both writers, the single-model argv and the
    /// router preset, so the two can never drift apart again.
    static let cacheReuseWindowSize = "cacheReuseWindowSize"
    static let loadVision = "loadVision"
    static let imageMaxTokens = "imageMaxTokens"
    static let apiKeyEnabled = "apiKeyEnabled"
    static let localNetworkDiscovery = "localNetworkDiscovery"
    static let menuBarIcon = "menuBarIcon"
    /// Where to surface per-GPU VRAM in the menu bar: "off" | "icon" | "panel".
    static let menuBarGPU = "menuBarGPU"
    static let autoStart = "autoStart"
    /// Hourly silent update check while the app stays open (default on).
    static let updateAutoCheck = "updateAutoCheck"
    /// Brand accent for the whole UI (AppTheme palette key).
    static let appAccent = "appAccent"
    static let chatTemp = "chatTemp"
    static let chatMaxTokens = "chatMaxTokens"
    static let chatSystem = "chatSystem"
    static let chatThinking = "chatThinking"
    static let chatReasoningEffort = "chatReasoningEffort"
    static let chatTopP = "chatTopP"
    static let chatMinP = "chatMinP"
    static let chatTopK = "chatTopK"
    static let chatRepeatPenalty = "chatRepeatPenalty"
    static let chatRepeatLastN = "chatRepeatLastN"
    static let chatSeed = "chatSeed"
    static let chatDynatempRange = "chatDynatempRange"
    static let chatDynatempExponent = "chatDynatempExponent"
    static let chatXTCProbability = "chatXTCProbability"
    static let chatXTCThreshold = "chatXTCThreshold"
    static let chatTypicalP = "chatTypicalP"
    static let chatPresencePenalty = "chatPresencePenalty"
    static let chatFrequencyPenalty = "chatFrequencyPenalty"
    static let chatDryMultiplier = "chatDryMultiplier"
    static let chatDryBase = "chatDryBase"
    static let chatDryAllowedLength = "chatDryAllowedLength"
    static let chatDryPenaltyLastN = "chatDryPenaltyLastN"
    static let chatSamplers = "chatSamplers"
    static let chatBackendSampling = "chatBackendSampling"
    static let chatCustomJSON = "chatCustomJSON"
    static let chatAgenticMaxTurns = "chatAgenticMaxTurns"
    static let chatPasteLongTextLength = "chatPasteLongTextLength"
    static let chatMaxImageMegapixels = "chatMaxImageMegapixels"
    static let chatPDFAsImages = "chatPDFAsImages"
    /// Conversation list sort order. Like chatSelectedModel, a runtime UI
    /// preference excluded from resettableOptionKeys, not a real "setting".
    static let chatSortOrder = "chatSortOrder"
    static let chatAutoCompact = "chatAutoCompact"
    /// The context fraction consumed before auto-compaction fires
    /// (census W3-1; was a hardwired 0.7).
    static let chatCompactionTrigger = "chatCompactionTrigger"
    /// The fraction of the window auto-compaction must leave un-summarized
    /// (census W3-2; was limit/4).
    static let chatCompactionKeepTailFraction = "chatCompactionKeepTailFraction"
    /// Response-token headroom subtracted when clamping a turn to the window
    /// (census W3-3): one setting drives three sites — the context-trap turn
    /// guard, clampedResponseTokens, and the compaction-prompt budget.
    static let chatResponseMarginTokens = "chatResponseMarginTokens"
    /// Response budget of the compaction summarizer (census W3-7): the
    /// compaction prompt reserves this many tokens and the summarize request
    /// asks for the same — one setting keeps the two sides in lockstep.
    static let chatCompactionSummaryMaxTokens = "chatCompactionSummaryMaxTokens"
    /// Sampling temperature of the compaction summarizer (census W3-8).
    static let chatCompactionSummarizeTemp = "chatCompactionSummarizeTemp"
    /// Newest messages auto-compaction always leaves un-summarized
    /// (census W3-9; was a hardwired 4).
    static let chatCompactionMinTailMessages = "chatCompactionMinTailMessages"
    /// Cap on memory_recall results (census W3-10): the tool-contract
    /// default of 4 when the model passes no max_results stays a literal.
    static let chatRecallMaxResults = "chatRecallMaxResults"
    /// Character cap on one memory_recall reply (census W3-12).
    static let chatRecallMaxCharacters = "chatRecallMaxCharacters"
    /// Tool-result context caps (census W3-11): the static ceiling and the
    /// dynamic cap's floor.
    static let chatToolResultMaxTokens = "chatToolResultMaxTokens"
    static let chatToolResultMinTokens = "chatToolResultMinTokens"
    static let chatShowSystemMessage = "chatShowSystemMessage"
    static let smoothTyping = "smoothTyping"
    static let chatFontScale = "chatFontScale"
    static let onboardingDone = "onboardingDone"

    // Benchmark workload sizes (llama-bench -p / -n)
    static let benchPP = "benchPP"
    static let benchTG = "benchTG"
    static let benchDepth = "benchDepth"
    static let benchAdvanced = "benchAdvanced"

    // Signed benchmark sharing (public identity from the server; the private key
    // lives in the Keychain, never here). Deliberately outside resettableOptionKeys.
    static let benchmarkInstallationId = "benchmarkInstallationId"
    static let benchmarkKeyFingerprint = "benchmarkKeyFingerprint"

    // Image generation (text-to-image)
    static let imagenPrompt = "imagenPrompt"
    static let imagenAspect = "imagenAspect"
    static let imagenBaseSize = "imagenBaseSize"
    static let imagenSteps = "imagenSteps"
    static let imagenSeed = "imagenSeed"
    static let imagenFormat = "imagenFormat"
    static let imagenOffloadCPU = "imagenOffloadCPU"
    static let imagenGPU = "imagenGPU"
    static let imagenModel = "imagenModel"
    static let imagenCustomModel = "imagenCustomModel"
    static let imagenCustomVAE = "imagenCustomVAE"
    static let imagenCustomTextEncoder = "imagenCustomTextEncoder"
    static let imagenCustomIsDiffusion = "imagenCustomIsDiffusion"
    static let imagenCustomCfg = "imagenCustomCfg"
    static let imagenInitImage = "imagenInitImage"
    static let imagenStrength = "imagenStrength"
    /// Extra parallel generation instances (JSON: [ImageInstanceConfig]).
    static let imagenInstances = "imagenInstances"
    /// Delete generated output images (kestrel_*) when the app quits.
    static let imagenCleanupOnClose = "imagenCleanupOnClose"
    static let videoModel = "videoModel"
    static let videoFrames = "videoFrames"
    static let videoSteps = "videoSteps"
    static let videoRecipeVersion = "videoRecipeVersion"
    static let videoSize = "videoSize"
    static let videoGPU = "videoGPU"
    /// Seeded from the model's own default; without it Wan burns the image out.
    static let videoNegativePrompt = "videoNegativePrompt"
    /// Seeded once, so emptying the negative on purpose survives a relaunch.
    static let videoNegativeSeeded = "videoNegativeSeeded"
    /// Decode the frames in tiles (default on): fixed 3.4 GB instead of up to 16.
    static let videoVAETiling = "videoVAETiling"
    static let upscalerFlavor = "upscalerFlavor"
    static let imageStudioMode = "imageStudioMode"
    static let upscalerScale = "upscalerScale"
    static let upscalerCustomModel = "upscalerCustomModel"
    /// Show results as a grid instead of a list (queue feed / instances canvas).
    static let imagenQueueGrid = "imagenQueueGrid"
    static let imagenCanvasGrid = "imagenCanvasGrid"

    /// A stale "lang" value from pre-English-only builds lingers in upgraded
    /// defaults; Server.swift no longer reads it (English is hardcoded), so a
    /// stored "es" is ignored rather than honored.
    static func clearStaleLanguage() {
        UserDefaults.standard.removeObject(forKey: "lang")
    }

    /// Tunable option keys (engine / GPU / inference / chat). Resetting clears these
    /// so `@AppStorage` falls back to its declared defaults. The models folder, the
    /// selected model and onboarding state are deliberately NOT included, so a reset
    /// never hides or deletes downloaded models. Profiles and the Keychain API key
    /// live outside UserDefaults and are untouched.
    static let resettableOptionKeys = [
        serverBinary, port, engineControlTimeoutSeconds, ngl, ncmoe, ctx, contextAutomatic, threads, flashAttn, noMmap, jinja,
        vramReserve, gpuIndex, gpuList, whisperModel, speechInputMethod, whisperLoadPolicy,
        audioOperation, audioLanguage, audioTargetLanguage, audioExportFormat,
        audioFollowTranscript, audioTranscriptMode, audioExportTrack,
        audioGlossary, audioTranslationModel, audioVADMode,
        audioVADProfile, audioVADThreshold, audioVADMinSpeechMS,
        audioVADMinSilenceMS, audioVADMaxSpeechSeconds, audioVADSpeechPadMS,
        extraArgs, embeddings, agentToolsEnabled, toolsRuntime, jsSandboxEnabled,
        jsSandboxDefaultTimeoutMS, jsSandboxMaxTimeoutMS, jsSandboxMaxOutputCharacters,
        memoryToolsEnabled, memoryArchiveHookQueueLimit, memoryArchiveHookTimeout,
        toolsUnsupportedModels, mcpServers, uiMcpProxy,
        cacheTypeK, cacheTypeV, mlock, cacheRAM,
        parallelSlots, reasoningInline, specMTP, mtpDisabledModels, faAmd, prefetchExperts, ubatch,
        dynamicMoe, dynamicMoeSlots, dynamicMoePrefetch, dynamicMoePolicy, routerMode, routerModelsMax,
        persistCache, multiGPU, multiGPUCount, splitMode, splitGroupSize, mgpuEvents, mgpuPeer,
        forcePrivateBuffers, cacheReuse, cacheReuseWindowSize, apiKeyEnabled, localNetworkDiscovery,
        menuBarIcon, menuBarGPU, autoStart, updateAutoCheck, appAccent,
        chatTemp, chatMaxTokens, chatSystem, chatThinking, chatReasoningEffort,
        chatTopP, chatMinP, chatTopK,
        chatRepeatPenalty, chatRepeatLastN, chatSeed, chatStopSequences,
        chatDynatempRange, chatDynatempExponent, chatXTCProbability, chatXTCThreshold,
        chatTypicalP, chatPresencePenalty, chatFrequencyPenalty, chatDryMultiplier,
        chatDryBase, chatDryAllowedLength, chatDryPenaltyLastN, chatSamplers,
        chatBackendSampling, chatCustomJSON, chatAgenticMaxTurns,
        chatPasteLongTextLength, chatMaxImageMegapixels,
        chatPDFAsImages,
        chatAutoCompact, chatCompactionTrigger, chatCompactionKeepTailFraction,
        chatResponseMarginTokens, chatCompactionSummaryMaxTokens, chatCompactionSummarizeTemp,
        chatCompactionMinTailMessages, chatRecallMaxResults, chatRecallMaxCharacters,
        chatToolResultMaxTokens, chatToolResultMinTokens, chatShowSystemMessage, smoothTyping,
        imagenAspect, imagenBaseSize, imagenSteps, imagenFormat, imagenOffloadCPU, imagenGPU,
    ]

    /// Clears every tunable option so they revert to defaults, keeping models intact.
    static func resetOptionsToDefaults() {
        let defaults = UserDefaults.standard
        for key in resettableOptionKeys { defaults.removeObject(forKey: key) }
    }
}

/// Declared chat-setting defaults that more than one site must agree on.
/// The agentic turn budget's default 10 existed as three hand-copied
/// literals (reader, two @AppStorage bindings) plus two reset writers — one
/// divergence and the chat's exhaustion UX stops matching the stepper (W4-10).
enum ChatDefaults {
    static let agenticMaxTurns = 10
    /// Auto-compaction fires once this fraction of the live window is
    /// consumed (census W3-1).
    static let compactionTrigger = 0.7
    /// Fraction of the window auto-compaction leaves un-summarized
    /// (census W3-2; was the hardwired limit/4).
    static let compactionKeepTailFraction = 0.25
    /// Response-token headroom subtracted when clamping a turn to the
    /// window (census W3-3; was a 256 literal at three independent sites).
    static let responseMarginTokens = 256
    /// Summarize request budget (census W3-7): the compaction prompt
    /// reserves this many response tokens and the summarize call asks for
    /// the same — one setting keeps the two sides in lockstep.
    static let compactionSummaryMaxTokens = 512
    /// Sampling temperature of the compaction summarizer (census W3-8).
    static let compactionSummarizeTemp = 0.3
    /// Minimum un-summarized tail messages auto-compaction keeps (census
    /// W3-9; was the hardwired -4; the +2 already-compacted floor stays
    /// derived logic).
    static let compactionMinTailMessages = 4
    /// Cap on memory_recall results (census W3-10): the tool-contract
    /// default of 4 when the model passes no max_results stays a literal.
    static let recallMaxResults = 20
    /// Character cap on one memory_recall reply (census W3-12).
    static let recallMaxCharacters = 6_000
    /// Tool-result context caps (census W3-11): the static ceiling and the
    /// dynamic cap's floor.
    static let toolResultMaxTokens = 12_000
    static let toolResultMinTokens = 2_000
}

// MARK: - Logging

enum AppLog {
    private static let subsystem = "com.northlatchlabs.kestrel"
    static let server = Logger(subsystem: subsystem, category: "server")
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let chat = Logger(subsystem: subsystem, category: "chat")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}

/// App support directory for persistent state (logs, lockfiles, chats).
enum AppSupport {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kestrel")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Census W8 (T2-2 chunk B): every downstream persistence path
            // silently degraded when this bootstrap failed. The URL is still
            // returned (callers degrade exactly as before), but loudly now.
            AppLog.app.error("could not create the app support directory at \(dir.path): \(error.localizedDescription) — persistence paths degrade until it exists")
        }
        return dir
    }
}

/// Rotating plain-text log for the engine output, so crashes can be diagnosed
/// after the fact and exported from Settings.
/// Per-session log files kept under Application Support/logs, named with the start
/// timestamp (e.g. `server-2026-06-19_15-30-45.log`). Each server run writes its own
/// file, so a Mac crash leaves the session's log intact for later inspection. Files
/// older than `retentionDays` are pruned automatically so they don't pile up.
final class RotatingFileLog: @unchecked Sendable {
    private let dir: URL
    private let prefix: String
    private let maxBytes: UInt64
    private let retentionDays: Int
    private let queue = DispatchQueue(label: "kestrel.filelog")
    private var handle: FileHandle?
    private var currentURL: URL

    init(name: String, maxBytes: UInt64 = 10 * 1024 * 1024, retentionDays: Int = 3) {
        self.prefix = (name as NSString).deletingPathExtension   // "server.log" -> "server"
        self.maxBytes = maxBytes
        self.retentionDays = retentionDays
        self.dir = AppSupport.directory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.currentURL = dir.appendingPathComponent("\(prefix).log")   // until a session starts
        queue.async { [self] in cleanup() }   // prune stale logs at launch too
    }

    var fileURL: URL { queue.sync { currentURL } }
    var directory: URL { dir }

    /// Begins a new timestamped per-session file and prunes files past the retention
    /// window. Call once per server start so each run is isolated and crash-safe.
    func startSession() {
        queue.async { [self] in
            try? handle?.close(); handle = nil
            let stamp = Self.stampFormatter.string(from: Date())
            currentURL = dir.appendingPathComponent("\(prefix)-\(stamp).log")
            cleanup()
        }
    }

    func append(_ text: String) {
        queue.async { [self] in
            if handle == nil {
                if !FileManager.default.fileExists(atPath: currentURL.path) {
                    FileManager.default.createFile(atPath: currentURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: currentURL)
                _ = try? handle?.seekToEnd()
            }
            guard let handle else { return }
            try? handle.write(contentsOf: Data(text.utf8))
            // Flush to disk so a machine freeze / kernel panic (e.g. an AMD MoE GPU
            // deadlock) still leaves every line written so far — not just what the
            // OS happened to flush. A process crash was already safe; this covers
            // the harder case the logs exist for.
            try? handle.synchronize()
            if let size = try? handle.offset(), size > maxBytes {
                rotate()
            }
        }
    }

    /// Within a single session, cap growth: move the current file aside once and
    /// keep writing, so one runaway run can't fill the disk.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let prev = currentURL.deletingPathExtension().appendingPathExtension("prev.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: currentURL, to: prev)
    }

    /// Deletes session log files older than the retention window.
    private func cleanup() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files where f.lastPathComponent.hasPrefix(prefix) && f.pathExtension == "log" {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? fm.removeItem(at: f) }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Single accumulating benchmark history file (`benchmarks.txt`), pruned to the
/// last `retentionDays` of runs so it stays a useful, shareable record without
/// growing forever. Each run's header carries an ISO date used for pruning.
final class BenchmarkLog: @unchecked Sendable {
    let url: URL
    let directory: URL
    private let queue = DispatchQueue(label: "kestrel.benchlog")
    private let retentionDays: Int
    /// Last prune time (touched only on the log's serial queue): pruning on
    /// every append would rewrite the whole file per run; hourly is enough
    /// to keep a long session from accumulating multi-MB beyond the window.
    private var lastPrune = Date.distantPast
    static let runMarker = "=== Kestrel benchmark · "

    init(retentionDays: Int = 3) {
        self.retentionDays = retentionDays
        directory = AppSupport.directory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("benchmarks.txt")
        prune()
    }

    func append(_ text: String) {
        queue.async { [self] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(text.utf8))
            try? h.synchronize()   // survive a machine freeze mid-run
            try? h.close()
            if Date().timeIntervalSince(lastPrune) > 3600 {
                lastPrune = Date()
                prune()
            }
        }
    }

    /// Rewrite the file keeping only runs newer than the retention window, keyed
    /// off the ISO date in each run's header line.
    func prune() {
        queue.async { [self] in
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  content.contains(Self.runMarker) else { return }
            let iso = ISO8601DateFormatter()
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            var kept = ""
            for block in content.components(separatedBy: Self.runMarker).dropFirst() {
                guard let end = block.range(of: " ===") else { continue }
                let date = iso.date(from: String(block[block.startIndex..<end.lowerBound]))
                // Keep recent runs; keep unparseable ones to avoid losing data.
                if date == nil || date! >= cutoff { kept += Self.runMarker + block }
            }
            try? kept.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Shell-words argument parsing

enum ShellWords {
    /// Splits a command-line string honoring single/double quotes, so
    /// `--system "hello world"` becomes two arguments instead of three.
    static func split(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        var hasContent = false

        for ch in input {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasContent = true
            } else if ch == " " || ch == "\t" {
                if hasContent || !current.isEmpty {
                    result.append(current)
                    current = ""
                    hasContent = false
                }
            } else {
                current.append(ch)
            }
        }
        if hasContent || !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - Engine PID lockfile

/// Tracks the PIDs of the engines we spawned (one per running server), so a later
/// launch can reap orphans precisely (verifying each PID still points at one of our
/// binaries) instead of pattern-killing by path.
enum EngineLock {
    private static var url: URL { AppSupport.directory.appendingPathComponent("engine.pid") }

    /// Reap-state failures (PID-lockfile I/O, orphan sweep), oldest first,
    /// capped at 8: the census-era swallows silently disabled precise
    /// reaping and left port conflicts on relaunch (T2-2 chunk B). Rendered
    /// into the exported diagnostics report; empty means healthy.
    private static let reapFailures = OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let reapStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    nonisolated static func recordReapFailure(_ reason: String) {
        let entry = reapFailures.withLock { list -> String in
            let stamped = "\(reapStamp.string(from: Date())): \(reason)"
            list.append(stamped)
            if list.count > 8 { list.removeFirst(list.count - 8) }
            return stamped
        }
        AppLog.app.warning("engine reap: \(entry)")
    }

    /// Snapshot for the diagnostics report; ordering oldest to newest.
    nonisolated static func reapFailureReport() -> [String] {
        reapFailures.withLock { $0 }
    }

    private static func read() -> [Int32] {
        do {
            return try String(contentsOf: url, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        } catch let error as NSError
                  where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []   // absent lockfile: no engines recorded — benign
        } catch {
            // Census W8 (T2-2 chunk B): a failing PID-lockfile read silently
            // disabled precise reaping; surface it for the diagnostics report.
            recordReapFailure("pid lockfile unreadable (\(error.localizedDescription)); orphan reaping cannot see prior engines")
            return []
        }
    }

    /// How many engines this app currently owns. Injectable seam: launch-
    /// truth triage (ServerSettings.windowState) reads it to tell "no
    /// engine" from "engine without a published context", and checks
    /// override it instead of mutating the real PID lockfile.
    nonisolated(unsafe) static var liveCountForTriage: () -> Int = { read().count }

    private static func save(_ pids: [Int32]) {
        if pids.isEmpty {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                recordReapFailure("pid lockfile remove failed (\(error.localizedDescription)); a stale lockfile can misdirect reaping")
            }
        } else {
            do {
                try pids.map(String.init).joined(separator: "\n")
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                recordReapFailure("pid lockfile write failed (\(error.localizedDescription)); orphan reaping stays blind until a write succeeds")
            }
        }
    }

    static func add(pid: Int32) {
        var pids = read()
        if !pids.contains(pid) { pids.append(pid) }
        save(pids)
    }

    static func remove(pid: Int32) {
        save(read().filter { $0 != pid })
    }

    /// Kills any recorded PID still alive whose executable lives inside one of our app
    /// bundles, then clears the file. Returns whether at least one orphan was reaped.
    @discardableResult
    static func reapOrphans() -> Bool {
        var reaped = false
        for pid in read() {
            guard kill(pid, 0) == 0 else { continue }   // not running

            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(cString: buffer)

            // Only processes from a Kestrel bundle are ours to kill. Matched
            // on path components (exact "Kestrel.app" component), not a
            // substring: a foreign "MyKestrel.app" must never be a target.
            guard Self.isKestrelEnginePath(path) else { continue }

            AppLog.app.warning("Reaping orphaned engine pid \(pid) at \(path)")
            kill(pid, SIGTERM)
            usleep(500_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            reaped = true
        }
        save([])
        return reaped
    }

    /// True when `path` points inside a Kestrel.app bundle's Resources/bin —
    /// matched on path components with an exact "Kestrel.app" component, so a
    /// foreign "MyKestrel.app" on the same machine is never a kill target.
    static func isKestrelEnginePath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let appIndex = components.lastIndex(of: "Kestrel.app") else { return false }
        return components.count > appIndex + 3
            && components[appIndex + 1] == "Contents"
            && components[appIndex + 2] == "Resources"
            && components[appIndex + 3] == "bin"
    }

    /// Kills engines from one of our bundles that launchd has adopted: a router child whose
    /// parent engine died, or an engine whose app went away. A live engine always hangs off
    /// the app or off its router, so nothing running is touched.
    static func reapStrayEngines() {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return }
        for pid in pids.prefix(Int(n)) where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == 1 else { continue }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            guard Self.isKestrelEnginePath(path), path.hasSuffix("/llama-server") else { continue }
            AppLog.app.warning("Reaping stray engine pid \(pid) at \(path)")
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
    }
}

// MARK: - File hashing

enum FileHash {
    /// Streaming SHA-256 suitable for multi-gigabyte files. Any I/O failure
    /// (open, read, mid-stream) yields nil — never a digest of a truncated
    /// prefix — so integrity consumers (KES-09 update verification, download
    /// checksums, share artifacts) fail closed, and the failure is surfaced.
    static func sha256(of url: URL) -> String? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            AppLog.app.error("could not open \(url.lastPathComponent) for hashing: \(error.localizedDescription) — integrity verification fails closed")
            return nil
        }
        defer {
            // A failed close after a complete read cannot invalidate the
            // bytes already hashed; surface it without discarding the digest.
            do { try handle.close() } catch {
                AppLog.app.warning("could not close \(url.lastPathComponent) after hashing: \(error.localizedDescription)")
            }
        }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            // The pre-conversion swallow ended the loop on error and still
            // finalized: a well-formed digest of a file PREFIX — silently
            // wrong where it is not fail-closed by luck. Discard instead.
            AppLog.app.error("read failed partway through \(url.lastPathComponent): \(error.localizedDescription) — digest discarded; integrity verification fails closed")
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Keychain (provider credential storage)

enum Keychain {
    private static let service = "com.northlatchlabs.kestrel"

    /// In-process session cache. macOS evaluates an item's access-control list
    /// on every secret decryption, and this app is ad-hoc signed locally — each
    /// rebuild produces a new signing identity, so every uncached read of an
    /// item created by an older build raises the password dialog. Caching one
    /// successful read per launch turns "prompt on every navigation / every
    /// message" into "at most once per item per launch".
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func get(_ account: String) -> String? {
        if let cached = cache.withLock({ $0[account] }) { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)
        if let value {
            cache.withLock { $0[account] = value }
        }
        return value
    }

    /// Metadata-only existence probe: matching an item WITHOUT returning its
    /// secret never decrypts, so the ACL is never evaluated and this never
    /// raises the access dialog. Use this for the "does a key exist?" checks
    /// (settings UI, migration logic) — the value is read later, once, only
    /// when a request actually needs it.
    static func exists(_ account: String) -> Bool {
        if cache.withLock({ $0[account] }) != nil { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        // Cache only what the keychain actually accepted: get()/exists()
        // read the cache first, so caching a failed write would assert a
        // credential that is not stored (a caller-visible lie).
        cache.withLock { $0[account] = ok ? value : nil }
    }

    /// Stores private local material without iCloud sync or device migration.
    /// No access-control flags requiring biometrics or user presence are used,
    /// so background signing after explicit in-app consent stays prompt-free.
    @discardableResult
    static func setThisDeviceOnly(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        if ok {
            cache.withLock { $0[account] = value }
        }
        return ok
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        _ = cache.withLock { $0.removeValue(forKey: account) }
    }

    /// Returns the local engine's API key, generating one on first use.
    /// Stored in the local secret store (0600 file in a 0700 folder), NOT the
    /// Keychain: this key is generated by this app for this machine's own
    /// loopback engine, so OS-level credential protection would only add the
    /// access-dialog tax — and on ad-hoc local builds, that tax recurs on
    /// every rebuild. Legacy installs migrate their existing Keychain item on
    /// first use; if that one read is declined, a fresh key is generated and
    /// clients adopt it on the next server start.
    static func apiKey() -> String {
        if let existing = LocalSecretStore.value("engine-api-key") { return existing }
        if let legacy = get("api-key") {
            LocalSecretStore.store("engine-api-key", legacy)
            // Migration succeeded; retire the Keychain copy so no future
            // reader can trip an ACL prompt on it. Swallow failures.
            delete("api-key")
            return legacy
        }
        let fresh = (0..<32).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! }
        let key = String(fresh)
        LocalSecretStore.store("engine-api-key", key)
        return key
    }
}

// MARK: - Local secret store (machine-generated, machine-local secrets)

/// The one way secret-bearing files are written (engine key, provider route
/// keys, chat history): the destination must never
/// exist with permissions looser than 0600 at ANY instant — not at creation
/// (the open must carry the mode), and not on overwrite (a truncate-rewrite
/// of a legacy looser file is world-readable until a follow-up chmod, and
/// `.atomic` writes rename a default-mode temp into place first). Both hold
/// here because the content lands in a fresh 0600 temp file inside the same
/// directory, which then replaces the target in one rename(2) — the rename
/// keeps the temp's mode, so the final file is 0600 on every path, and a
/// crash mid-write can never leave a half-written secret behind.
enum OwnerOnlyFile {
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".owner-only-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else { return false }
        // rename(2) atomically replaces an existing target or moves over a
        // missing one; either way the inode (and its 0600 mode) is the temp's.
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            return false
        }
        return true
    }
}

/// File-backed storage for machine-local secrets — the local
/// engine's API key and the remote provider keys. Unlike the Keychain,
/// reading a 0600 file in a 0700 Application Support folder never involves an
/// ACL evaluation, so no access dialog can ever appear for it, and an ad-hoc
/// rebuild keeps access for free. Provider keys moved here from the Keychain
/// by deliberate decision: on ad-hoc builds the Keychain's per-signature ACL
/// raised the macOS password dialog after every rebuild, a cost that was
/// never requested. Legacy Keychain items migrate on first read and are then
/// deleted (see InferenceRoutes).
enum LocalSecretStore {
    /// In-process cache, same pattern as Keychain's: reads happen on hot paths
    /// (every chat send resolves the engine key via ServerSettings.activeAPIKey)
    /// and the file is only re-read after this process last saw it change —
    /// store() is the only writer, so the cache cannot go stale in-process.
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func url(_ name: String) -> URL {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory,
                                                       .userDomainMask, true).first
            ?? NSHomeDirectory() + "/Library/Application Support"
        return URL(fileURLWithPath: base + "/Kestrel/secrets/\(name)")
    }

    static func value(_ name: String) -> String? {
        if let cached = cache.withLock({ $0[name] }) { return cached }
        let path = url(name).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            var contents = try String(contentsOfFile: path, encoding: .utf8)
            while contents.hasSuffix("\n") { contents.removeLast() }
            let value = contents.isEmpty ? nil : contents
            if let value {
                cache.withLock { $0[name] = value }
            }
            return value
        } catch {
            // A present-but-unreadable secret must not read as "no key set":
            // that conflation surfaces as auth failures far from the cause.
            AppLog.app.error("secret \(name) exists but cannot be read: \(error.localizedDescription) — auth fails until the file is fixed or the secret re-entered")
            return nil
        }
    }

    /// Typed readability probe for launch-time surfacing: nil when the
    /// secret is absent or readable; an English reason when it exists but
    /// cannot be read. Engine launch logs the reason and carries on —
    /// surfacing never changes launch behavior.
    static func unreadableReason(_ name: String) -> String? {
        let path = url(name).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            _ = try String(contentsOfFile: path, encoding: .utf8)
            return nil
        } catch {
            // Foundation's English error strings carry typographic quotes;
            // the typed reason must stay ASCII (product doctrine), so the
            // embedded detail is normalized before it is surfaced.
            let detail = error.localizedDescription
                .replacingOccurrences(of: "\u{201C}", with: "\"")
                .replacingOccurrences(of: "\u{201D}", with: "\"")
                .replacingOccurrences(of: "\u{2019}", with: "'")
            let ascii = String(detail.unicodeScalars.filter { $0.isASCII })
            return "secret \(name) is present but unreadable: \(ascii); engine authentication will fail until the file is fixed or the secret is re-entered"
        }
    }

    @discardableResult
    static func store(_ name: String, _ value: String) -> Bool {
        let fileURL = url(name)
        let dirURL = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dirURL.path,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            AppLog.app.error("could not create the secrets directory at \(dirURL.path): \(error.localizedDescription) — the secret cannot be stored")
        }
        // Idempotent tighten on every write, not only at creation: a directory
        // that already existed (0755 from an older build or a restored backup)
        // must not keep the 0600-files-in-a-0700-folder invariant broken.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirURL.path)
        // OwnerOnlyFile: 0600 with no write-then-chmod window on ANY path —
        // fresh creation and legacy-loose overwrite alike (see its doc).
        let wrote = OwnerOnlyFile.write(Data(value.utf8), to: fileURL)
        if wrote {
            cache.withLock { $0[name] = value }
            return true
        }
        return false
    }

    static func delete(_ name: String) {
        let target = url(name)
        if FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                AppLog.app.error("could not delete secret \(name): \(error.localizedDescription) — the secret is left on disk after remove")
            }
        }
        _ = cache.withLock { $0.removeValue(forKey: name) }
    }
}

/// A notarized release has a stable Developer ID team. Local ad-hoc builds do
/// not, which is the only case where rebuilding can make Keychain ask whether
/// the changed app may reuse an existing benchmark identity.
enum AppCodeSignature {
    static let hasStableDeveloperIdentity: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return !team.isEmpty
    }()
}

/// A model whose tool call the engine refuses kills the turn with an HTTP 500, and it does it
/// on every tool, not only on one. Nothing in the template says which model gets it wrong, so
/// the failure itself is the signal: the model is remembered and stops receiving tools.
///
/// Mission C1 doctrine: the remaining trigger is a CUSTOM engine binary — one
/// that predates json_schema support or still synthesizes the buggy generic
/// grammar ("peg-native"). For the bundled engine (0.89.5) the 500 is
/// unreachable post-C1: the tool-turn envelope schema bound to every
/// tools-carrying request skips the generic tools branch that produces it,
/// and named template families use their own specialized handlers. The
/// blocklist therefore stays live for custom binaries only; existing entries
/// are kept (any model may run through a custom binary) and the unblock UI
/// remains the way out.
enum ToolSupport {
    static var currentModelIdentity: String? {
        if let alias = ServerSettings.activeRouterModel(), !alias.isEmpty { return alias }
        let path = UserDefaults.standard.string(forKey: SettingsKeys.modelPath) ?? ""
        return path.isEmpty ? nil : path
    }

    static func isBlocked(_ model: String?) -> Bool {
        guard let model, !model.isEmpty else { return false }
        return blockedModels.contains(model)
    }

    static var blockedModels: [String] {
        SettingsNumericCoercion.stringArray(SettingsKeys.toolsUnsupportedModels)
    }

    static func unblock(_ model: String) {
        var blocked = blockedModels
        blocked.removeAll { $0 == model }
        UserDefaults.standard.set(blocked, forKey: SettingsKeys.toolsUnsupportedModels)
    }

    static func block(_ model: String?) {
        guard let model, !model.isEmpty else { return }
        var blocked = blockedModels
        guard !blocked.contains(model) else { return }
        blocked.append(model)
        UserDefaults.standard.set(blocked, forKey: SettingsKeys.toolsUnsupportedModels)
    }

    /// Returns the tools-runtime problem as a bilingual pair (Spanish, then
    /// English) for `Localizer.t` when the configured backend cannot actually
    /// run on this machine. Empty configuration means "run tools right here"
    /// and is never a problem here.
    static func toolsRuntimeProblem(_ configuration: String) -> (es: String, en: String)? {
        let trimmed = configuration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scheme = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let binary: String
        switch scheme {
        case "docker", "podman":
            binary = scheme
        case "docker-container":
            binary = "docker"
        case "ssh":
            binary = "ssh"
        default:
            return (es: "Formato de aislamiento no reconocido: \(trimmed). Usa docker:imagen, podman:imagen, docker-container:id o ssh:destino.",
                    en: "Unrecognized isolation format: \(trimmed). Use docker:image, podman:image, docker-container:id, or ssh:target.")
        }
        guard ToolRuntimeLocator.locate(binary) == nil else { return nil }
        return (es: "El programa «\(binary)» no está instalado, así que el aislamiento \(scheme) no puede ejecutarse. Instálalo o borra el ajuste para ejecutar las herramientas aquí.",
                en: "The \(binary) program is not installed, so \(scheme) isolation cannot run. Install it or clear the setting to run tools right here.")
    }
}

/// Finds executables without spawning a login shell. PATH in a GUI app does
/// not include the shell's rc additions, so common install locations are
/// probed directly before falling back to `which`.
enum ToolRuntimeLocator {
    static func locate(_ name: String) -> String? {
        let extra = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin",
                     "/usr/bin", "/bin", "/usr/local/sbin"]
        for dir in extra where FileManager.default.isExecutableFile(atPath: dir + "/" + name) {
            return dir + "/" + name
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

extension String {
    /// Blank (whitespace/newline-only) strings collapse to nil — the same
    /// "unset" meaning as a missing optional.
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
