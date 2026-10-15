// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import Metal

extension Notification.Name {
    /// Posted when a fresh engine process has launched (KV slots are empty).
    static let engineDidStart = Notification.Name("kestrelEngineDidStart")
}

struct GPUDevice: Identifiable, Hashable {
    let index: Int
    let name: String
    let vramMB: Int
    var isExternal: Bool = false   // eGPU (MTLDeviceLocation.external)
    var isIntegrated: Bool = false // iGPU (MTLDevice.isLowPower); never auto-selected
    /// Metal peer group: 0 when the card has no Infinity Fabric link, shared with
    /// the other members when it has one.
    var peerGroupID: UInt64 = 0
    var peerCount: Int = 0
    /// Metal exposes bf16 only from the Metal 3 family up; older cards abort on a bf16 weight.
    var supportsBF16: Bool = true
    var id: Int { index }
    /// Rounded, since Metal reports a working set a little off the nominal size.
    var vramGB: Int { Int((Double(vramMB) / 1024).rounded()) }
}

enum DynamicMoeAutoRoute: Equatable {
    case cache
    case normalDense
    case normalFitsVRAM
    case normalInsufficientRAM
    case normalUnsupportedGPU
    case normalMissingModel
    case normalSplitOrRouter
    case normalMissingMetadata
    case normalInsufficientVRAM
    case normalNoCacheBenefit
    case normalOversizedHostBank
}

struct DynamicMoeModelInfo: Equatable {
    let layerCount: Int
    let expertCount: Int
    let activeExpertCount: Int
}

struct DynamicMoeSlotPlan: Equatable {
    let model: DynamicMoeModelInfo
    /// Smallest cache that can hold every expert selected by one decoded token.
    let minimumSlots: Int
    /// Largest valid K for this architecture, regardless of memory pressure.
    let maximumSlots: Int
    /// Largest K estimated to fit after fixed weights, runtime and transfer buffers.
    let recommendedMaximumSlots: Int
    let automaticSlots: Int
    let estimatedBytesPerSlot: UInt64
    let estimatedFixedVRAMBytes: UInt64

    func clamped(_ slots: Int) -> Int {
        min(max(slots, minimumSlots), maximumSlots)
    }

    func estimatedVRAMBytes(slots: Int) -> UInt64 {
        estimatedFixedVRAMBytes + UInt64(clamped(slots)) * estimatedBytesPerSlot
    }
}

struct ServerSettings {
    var serverBinary: String
    var modelPath: String
    var port: Int
    var ngl: Int
    var ncmoe: Int
    var ctx: Int
    var contextAutomatic: Bool = false
    var threads: Int
    var flashAttn: String      // auto | on | off
    var noMmap: Bool
    var jinja: Bool
    var vramReserveMB: Int
    var gpuIndex: Int          // -1 = system default
    /// Explicit set of physical GPUs to split across (2+ entries). Overrides
    /// `gpuIndex` and the all/N `multiGPU` split.
    var gpuList: [Int] = []
    var extraArgs: String
    /// Serve /v1/embeddings (--embeddings). llama-server restricts the process
    /// to embedding use, so it's meant for a dedicated embedding-model server.
    var embeddings: Bool = false
    var agentToolsEnabled: Bool = false
    var uiMcpProxy: Bool = false
    /// `--tools-runtime` target (`docker:image`, `podman:image`, `ssh:host`...). Empty
    /// runs the tools in the app's own environment, which is the engine default.
    var toolsRuntime: String = ""
    var cacheTypeK: String     // f16 | q8_0 | q5_x | q4_x | iq4_nl
    var cacheTypeV: String
    var mlock: Bool
    /// Host-RAM prompt cache cap in MiB (0 disables). The engine's own 8192 default
    /// grows with use and pushes a big model into swap, degrading speed per session.
    var cacheRAM: Int = 2048
    /// Emit reasoning inline in `content` (<think>…) instead of the separate
    /// `reasoning_content` field, for external clients that ignore the latter.
    var reasoningInline: Bool = false
    /// Server slots (0 = engine auto). With 1, requests queue instead of competing
    /// for the GPU, and a prefill aborted by a client timeout stays in the slot so
    /// the retry resumes where it left off.
    var parallelSlots: Int = 1
    var apiKeyEnabled: Bool = false
    /// Serve beyond loopback and advertise with Bonjour. Off by default: it opens
    /// the API to the whole local network, so it wants `apiKeyEnabled` alongside.
    var localNetworkDiscovery: Bool = false
    /// Legacy profile field kept for decoding older saved settings. MTP is now
    /// selected automatically from model capability and expert offload.
    var specMTP: Bool = false
    /// Route attention through the AMD Metal Flash-Attention kernel (KESTREL_FA_AMD).
    var faAmd: Bool = true
    /// MoE-offload prefill boost: overlap expert uploads with compute
    /// (GGML_SCHED_PREFETCH_EXPERTS) and keep CPU experts unpacked so their
    /// matmuls can offload (GGML_CPU_NO_REPACK).
    var prefetchExperts: Bool = true
    /// Prefill micro-batch (--ubatch-size); 0 leaves the engine's 512. Only worth
    /// raising with experts on CPU: each micro-batch pays one expert upload over
    /// the bus, so a long prompt pays it once per batch instead of once per token.
    /// Costs VRAM linearly (~0.5 GiB per 512 on a 35B), so it is not a default.
    var ubatch: Int = 0
    /// Experimental bounded-VRAM expert cache. Compiled into the bundled engine,
    /// but completely inert unless this persisted user choice is enabled.
    var dynamicMoe: Bool = false
    var dynamicMoeSlots: Int = 8
    var dynamicMoePrefetch: Int = 4
    var dynamicMoePolicy: String = "cache" // cache | auto
    /// Router mode (`--models-preset`): one process auto-loads/unloads whichever
    /// model a request's "model" field names, instead of the fixed `modelPath`.
    var routerMode: Bool = false
    /// Models the router keeps loaded at once (LRU); 1 is safest on a single GPU.
    var routerModelsMax: Int = 1
    /// Persist each conversation's KV cache to disk (`--slot-save-path`). Needs the
    /// AMD FA kernel: without it the V cache is transposed and save/restore copies
    /// it row-by-row, unusably slow.
    var persistCache: Bool = false
    /// EXPERIMENTAL: split one model across all detected GPUs. Unvalidated on
    /// AMD/Metal: cross-GPU copies take a different path than the staging the
    /// patch covers and could corrupt or hang.
    var multiGPU: Bool = false
    /// How many GPUs to split across when `multiGPU` is on. 0 = all detected.
    /// Fewer GPUs trade prompt speed for generation speed (less cross-card sync).
    var multiGPUCount: Int = 0
    /// How the split divides the model (`--split-mode`): `layer` gives each GPU
    /// whole layers, `tensor` splits every matmul so both work on the same token,
    /// which costs one allreduce per layer and only pays off on a big model.
    var splitMode: String = "layer"
    /// GPUs per tensor-parallel group when splitting by tensors. 0 or 1 means one
    /// group with every card, which is the plain tensor split. A smaller group
    /// splits tensors inside it and layers between groups, which keeps most of the
    /// prompt speed without paying the per-layer wait across every card.
    var splitGroupSize: Int = 0
    /// Hand off activations between GPUs with shared Metal events instead of
    /// draining both queues on every copy (KESTREL_MGPU_EVENTS). Inert on a layer
    /// split; on a tensor split it is most of the generation speed.
    var mgpuEvents: Bool = true
    /// When two split GPUs share a Metal peer group (Infinity Fabric Link, e.g. a
    /// W6800X/Vega II Duo), copy activations die-to-die instead of via host
    /// (KESTREL_MGPU_PEER). Worth 16% of the prefill, and only safe alongside mgpuEvents.
    var mgpuPeer: Bool = true
    /// Force VRAM-resident (private) Metal buffers. The backend forces shared ones
    /// for external GPUs, which streams weights over Thunderbolt every op; this
    /// covers the default-GPU case, where the app can't tell macOS picked an eGPU.
    var forcePrivateBuffers: Bool = false
    /// Reuse shifted KV chunks across mid-prompt divergences (agent edits, a
    /// stripped <think>). Fast but approximate, hence user-toggleable.
    var cacheReuse: Bool = true
    /// Load the multimodal projector (mmproj) for vision-capable models. Off skips it
    /// so a vision model runs text-only and frees the VRAM the image encoder would use.
    var loadVision: Bool = true
    /// Cap on the tokens one image may take. 0 keeps the model's own limit; lowering it
    /// shrinks the vision encoder's attention quadratically, which is what rescues a
    /// card that cannot allocate that buffer.
    var imageMaxTokens: Int = 0
    /// llama-bench workload sizes: prompt tokens (-p → ppN), generated tokens
    /// (-n → tgN) and context depth (-d, tokens already in the KV cache before
    /// measuring). Benchmark-only; llama-server ignores them.
    var benchPP: Int = 512
    var benchTG: Int = 128
    var benchDepth: Int = 0

    /// One model served across several GPUs, either by the all/N toggle or by an
    /// explicit selection of at least two cards.
    var isSplitting: Bool { multiGPU || gpuList.count >= 2 }
    /// Guards against a stale or hand-edited value: llama.cpp only takes these two,
    /// and a tensor split the model cannot take falls back instead of aborting.
    var effectiveSplitMode: String {
        (splitMode == "tensor" && tensorSplitLimit.map { splitDeviceCount <= $0 } != false) ? "tensor" : "layer"
    }

    /// The group size to pass, or nil when it would be a no-op or an invalid split.
    var effectiveSplitGroupSize: Int? {
        let n = splitDeviceCount
        guard splitGroupSize > 1, splitGroupSize < n, n % splitGroupSize == 0 else { return nil }
        return splitGroupSize
    }

    /// GPUs the split will span, matching how the launch environment picks them.
    var splitDeviceCount: Int {
        if gpuList.count >= 2 { return gpuList.count }
        guard multiGPU else { return 1 }
        let gpus = ServerController.availableGPUs()
        let discrete = gpus.filter { !$0.isIntegrated }.count
        let limit = discrete > 0 ? discrete : gpus.count
        return max(2, multiGPUCount > 0 ? min(multiGPUCount, limit) : limit)
    }

    /// Layer counts per GPU that even out the bytes rather than the layer count.
    /// `--n-cpu-moe` empties the experts of the first N layers, and llama.cpp still hands
    /// out layers by index, so without this the last GPUs take every expert and overflow.
    var layerBalancedTensorSplit: [Int]? {
        guard isSplitting, effectiveSplitMode == "layer", ncmoe > 0 else { return nil }
        let devices = splitDeviceCount
        guard devices >= 2 else { return nil }
        let flags = GGUFMetadataCache.tensorFlags(at: modelPath)
        let expert = Double(flags.expertBytesPerLayer)
        let other = Double(flags.otherBytesPerLayer)
        guard expert > 0, other > 0,
              let blocks = Self.ggufUInt32("block_count", at: modelPath).map(Int.init),
              blocks >= devices else { return nil }

        let weights = (0..<blocks).map { $0 < ncmoe ? other : other + expert }
        let target = weights.reduce(0, +) / Double(devices)
        var counts = [Int](repeating: 0, count: devices)
        var dev = 0
        var acc = 0.0
        for (il, w) in weights.enumerated() {
            // leave at least one layer for each device still waiting
            let mustAdvance = blocks - il == devices - dev
            if dev < devices - 1 && (mustAdvance || (acc + w/2 > target && counts[dev] > 0)) {
                dev += 1
                acc = 0
            }
            counts[dev] += 1
            acc += w
        }
        return counts.allSatisfy { $0 > 0 } ? counts : nil
    }

    /// GPUs this model's experts can be divided among, nil when nothing limits it.
    var tensorSplitLimit: Int? { Self.tensorSplitLimit(forModel: modelPath) }

    /// The user asked for a tensor split the model cannot take; the run uses layers.
    var tensorSplitDowngraded: Bool {
        splitMode == "tensor" && isSplitting && effectiveSplitMode == "layer"
    }

    var isMultimodal: Bool { Self.mmprojPath(forModel: modelPath) != nil }
    /// Vision actually loaded (projector available AND the eye is on); slot
    /// persistence gates on this, not on mere availability.
    var visionLoaded: Bool { loadVision && isMultimodal }

    /// `--no-mmap` and `--mlock` both write the engine's load mode and the last one wins, so
    /// passing the pair let mlock decide whether mmap stayed on. Nil keeps the engine default.
    static func loadMode(noMmap: Bool, mlock: Bool) -> String? {
        switch (noMmap, mlock) {
        case (true, true):   return "mlock"
        case (true, false):  return "none"
        case (false, true):  return "mmap+mlock"
        case (false, false): return nil
        }
    }

    /// Directory where one server's per-conversation KV slot files live. Namespaced
    /// by port so independent servers don't overwrite each other's slot 0 / prefix
    /// files in a shared folder.
    static func slotCacheDir(port: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kestrel/slots/\(port)/\(slotKVSignature())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A slot only restores into an identical KV layout; separate folders per type
    /// turn a quant change into a cold prefill instead of a failed restore.
    private static func slotKVSignature() -> String {
        let d = UserDefaults.standard
        // a slot holding media only restores with a projector loaded, so vision state splits it too
        let vision = d.object(forKey: SettingsKeys.loadVision) as? Bool ?? true
        return "\(sanitizedKV(d.string(forKey: SettingsKeys.cacheTypeK), default: "f16"))"
             + "-\(sanitizedKV(d.string(forKey: SettingsKeys.cacheTypeV), default: "f16"))"
             + (vision ? "-v" : "")
    }

    /// Slot directory of the primary server (the one the native chat talks to).
    static var primarySlotCacheDir: URL { slotCacheDir(port: fromDefaults().port) }

    /// Drops a KV type left over from the retired turbo engine.
    static func sanitizedKV(_ value: String?, default def: String) -> String {
        guard let v = value, kvCacheTypes.contains(v) else { return def }
        return v
    }

    static let defaultFaAmd = true
    static let dynamicMoeTensorOverride = #"\.ffn_(up|down|gate|gate_up)_(ch|)exps=MTL0"#
    static let kvCacheTypes = ["f16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl", "turbo4", "turbo3"]

    /// Gemma attention takes flash-attention paths that fall through to the
    /// generic Metal kernel, which requires K and V to share a type — a mixed
    /// pair aborts the whole engine at load (GGML_ASSERT in ggml-metal-ops,
    /// observed twice 2026-10-14 with gemma-4-12b + q8_0/q4_0). The turbo vec
    /// kernels that tolerate mixed pairs never engage for gemma, so its K and
    /// V are equalized at launch on the smaller of the two types.
    static func kvTypesMustMatch(forModel path: String) -> Bool {
        path.lowercased().contains("gemma")
    }

    var usesTurboKV: Bool {
        cacheTypeK.hasPrefix("turbo") || cacheTypeV.hasPrefix("turbo")
    }

    var usesTurboValuesWithoutKeys: Bool {
        cacheTypeV.hasPrefix("turbo") && !cacheTypeK.hasPrefix("turbo")
    }

    var usesUnsupportedTurboQ4Mix: Bool {
        (cacheTypeK.hasPrefix("turbo") && cacheTypeV == "q4_0") ||
        (cacheTypeV.hasPrefix("turbo") && cacheTypeK == "q4_0")
    }

    /// The context window actually launched with. `contextAutomatic` used to
    /// be display-only — "Auto" aliased 16384 while the Dashboard claimed
    /// the app had chosen it. It now computes the largest window whose
    /// weights + KV cache still fit VRAM, with the same halving solver
    /// router mode uses, killing the context-spill class (a window that
    /// pushes KV out of VRAM and drops generation ~20×) at launch.
    var resolvedCtx: Int {
        guard contextAutomatic else { return ctx }
        // Scale by the pair the launch actually runs with (post-gemma
        // equalization), so the solver budgets the KV bytes that will really
        // be allocated — not one type's scale of them.
        let kv = effectiveCacheTypes
        return Self.routerCtx(forModel: modelPath, requested: ctx,
                              ncmoe: ncmoe,
                              kvScale: Self.kvScale(k: kv.k, v: kv.v),
                              reserveMB: vramReserveMB)
    }

    /// The K/V pair actually launched with. Gemma's attention hits the
    /// same-type-requiring generic Metal kernel (see kvTypesMustMatch), so
    /// a mixed pair is equalized on the smaller type at launch; this is
    /// that post-equalization pair. Benchmark records, labels and shares
    /// read it so they describe what ran, not what was merely configured
    /// (the configured pair stays in `cacheTypeK`/`cacheTypeV`).
    var effectiveCacheTypes: (k: String, v: String) {
        Self.effectiveCacheTypes(forModel: modelPath, k: cacheTypeK, v: cacheTypeV)
    }

    /// `effectiveCacheTypes` keyed by an explicit model path, so callers that
    /// serve many models at once (the router preset) equalize each section
    /// against its own model — the instance property keys on `modelPath`,
    /// which is empty in router mode and would never equalize anything.
    static func effectiveCacheTypes(forModel path: String, k: String, v: String) -> (k: String, v: String) {
        guard k != v, kvTypesMustMatch(forModel: path) else { return (k, v) }
        return Estimator.kvTypeScale(v) < Estimator.kvTypeScale(k) ? (v, v) : (k, k)
    }

    /// Average scale of a K/V pair. `ModelSpec.kvBytesPerToken` counts K and V
    /// bytes combined at f16, so a pair's true footprint scales by the mean of
    /// both types — the same formula Hardware.swift's estimator and the DFlash
    /// planner already use. Scaling by K alone mis-estimates every mixed pair
    /// (K=f16/V=q4 under-fits, K=q4/V=f16 over-fits and can spill).
    nonisolated static func kvScale(k: String, v: String) -> Double {
        (Estimator.kvTypeScale(k) + Estimator.kvTypeScale(v)) / 2
    }

    var arguments: [String] {
        if routerMode { return routerArguments }
        // Quantized KV requires FA, so it stays forced. Elsewhere the AMD kernel rides
        // on "auto": an explicit "1" would drop uncovered models to the CPU fallback.
        let faValue = kvNeedsFlashAttention ? "1" : (effectiveFaAmd ? "auto" : flashAttn)
        // Equalize K/V for models whose attention hits the same-type-requiring
        // generic Metal kernel (see kvTypesMustMatch); the smaller type keeps
        // VRAM at or below what the mixed pair already reserved.
        let effectiveKV = effectiveCacheTypes
        let effCacheTypeK = effectiveKV.k
        let effCacheTypeV = effectiveKV.v
        var args = [
            "-m", modelPath,
            "-ngl", String(ngl),
            "-c", String(resolvedCtx),
            "-t", String(threads),
            "-fa", faValue,
            "--host", localNetworkDiscovery ? "0.0.0.0" : "127.0.0.1",
            "--port", String(port),
        ]
        if !effectiveDynamicMoe && ncmoe > 0 { args += ["--n-cpu-moe", String(ncmoe)] }
        if let ub = effectiveUbatch { args += ["--ubatch-size", String(ub), "--batch-size", String(ub)] }
        let mode = effectiveDynamicMoe ? "mlock" : Self.loadMode(noMmap: noMmap, mlock: mlock)
        if let mode { args += ["--load-mode", mode] }
        if effectiveDynamicMoe {
            args += ["-ot", Self.dynamicMoeTensorOverride]
        }
        // A sibling projector lets the model read images, and needs --jinja.
        let mmproj = loadVision ? Self.mmprojPath(forModel: modelPath) : nil
        if let mmproj {
            args += ["--mmproj", mmproj]
            if Self.projectorNeedsCPU(mmproj) { args.append("--no-mmproj-offload") }
            if imageMaxTokens > 0 { args += ["--image-max-tokens", String(imageMaxTokens)] }
        }
        if jinja || mmproj != nil { args.append("--jinja") }
        if effCacheTypeK != "f16" { args += ["-ctk", effCacheTypeK] }
        if effCacheTypeV != "f16" { args += ["-ctv", effCacheTypeV] }
        // localhost-only endpoint; feeds the speculative-decoding readout in Diagnostics
        args.append("--metrics")
        args += ["--cache-ram", String(cacheRAM)]
        if cacheReuse && mmproj == nil {
            args += ["--cache-reuse", "256"]
        }
        if parallelSlots > 0 { args += ["--parallel", String(parallelSlots)] }
        // An explicit --parallel N splits the context pool across slots instead of
        // sharing it (only "auto" unifies), so ask for one pool ourselves: the chat
        // keeps its full window and API requests don't multiply KV memory.
        if parallelSlots > 1 { args.append("--kv-unified") }
        // Which devices to split across is decided by the env vars below.
        if isSplitting { args += ["--split-mode", effectiveSplitMode] }
        if let counts = layerBalancedTensorSplit {
            args += ["--tensor-split", counts.map(String.init).joined(separator: ",")]
        }
        // --embeddings dedicates the entire process to /v1/embeddings: chat
        // requests then fail with "context does not support logits
        // computation" (the 2026-10-14 all-night every-model-silent outage)
        // and the load-time warmup can abort the engine outright. It stays
        // available for a dedicated second RAG server — never on the primary
        // server the native chat talks to.
        if embeddings && port != Self.fromDefaults().port {
            args.append("--embeddings")
        }
        if agentToolsEnabled {
            if !args.contains("--jinja") { args.append("--jinja") }
            args += ["--tools", "all"]
            // The MCP proxy endpoint is REQUIRED for agent tools: without it
            // this engine build answers POST /tools with 404 "this feature is
            // disabled" (verified in the observed-in-use of 2026-10-01) — the tools
            // list, but calls fail. The flag is the engine's documented-risky
            // /cors-proxy relay, so it stays loopback-only unless the LAN
            // refusal above has been satisfied with an API key.
            if !toolsRuntime.isEmpty { args += ["--tools-runtime", toolsRuntime] }
        }
        if uiMcpProxy || agentToolsEnabled { args.append("--ui-mcp-proxy") }
        if persistCache && effectiveFaAmd {
            args += ["--slot-save-path", Self.slotCacheDir(port: port).path]
        }
        if reasoningInline { args += ["--reasoning-format", "none"] }
        if apiKeyEnabled {
            // KES-04: argv is world-readable via ps(1) for the server's whole
            // lifetime; this engine reads keys from a file just as well, and
            // the 0600 local secret store is where the key already lives.
            _ = Keychain.apiKey()  // materializes the file (legacy items migrate here)
            args += ["--api-key-file", LocalSecretStore.url("engine-api-key").path]
        }
        // A compatible downloaded DFlash draft takes precedence over embedded MTP.
        // Speculation decodes several tokens at once and the expert cache only has slots
        // for one token's experts, so the two cannot run together.
        if !effectiveDynamicMoe {
            if let selection = dflashSelection(modelPath: modelPath, ncmoe: ncmoe) {
                // Quantize the draft's KV cache: it doubles KV pressure at high ctx, and
                // q8_0 halves that footprint at no measurable quality cost for a draft.
                args += ["-md", selection.draft, "--spec-type", "draft-dflash",
                         "-ngld", String(selection.ngld),
                         "-ctkd", "q8_0", "-ctvd", "q8_0"]
            } else if Self.mtpEnabled(forModel: modelPath), let draft = Self.mtpDraftPath(forModel: modelPath) {
                args += ["-md", draft, "--spec-type", "draft-mtp"]
                args += Self.mtpDraftWidthArgs(forModel: modelPath, gpuArchitecture: selectedGPUArchitecture)
            } else if Self.mtpEnabled(forModel: modelPath), Self.modelHasMTP(at: modelPath) {
                args += ["--spec-type", "draft-mtp"]
                args += Self.mtpDraftWidthArgs(forModel: modelPath, gpuArchitecture: selectedGPUArchitecture)
            }
        }
        if let ui = Self.chatUIPath { args += ["--path", ui] }
        // Loopback-only bind unless the operator enabled LAN with a key: a
        // `--host` token from extraArgs would otherwise override the app's
        // own bind (later duplicates win) and bypass the start() refusal.
        args += Self.loopbackGuardedCLI(extraArgTokens.cli,
                                        lanAllowed: localNetworkDiscovery && apiKeyEnabled)
        return args
    }

    /// Router writes one entry per model with the same context, but a multi-head model
    /// caches several times more per token than a GQA one and can overflow VRAM on
    /// load, which hangs the driver. Shrink the context for the models that don't fit.
    nonisolated static func routerCtx(forModel path: String, requested: Int, ncmoe: Int,
                                      kvScale: Double, reserveMB: Int) -> Int {
        let kvPerToken = ModelSpec.kvBytesPerToken(atPath: path) * kvScale
        guard kvPerToken > 0, requested > 2048 else { return requested }
        let vramGB = Double(ServerController.availableGPUs().map(\.vramMB).max() ?? 0) / 1024
        guard vramGB > 0 else { return requested }
        let budget = vramGB - Double(reserveMB) / 1024
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
        let weightsGB = Double(size) / 1_073_741_824 * (ncmoe > 0 ? 0.45 : 1.0)
        let computeGB = 0.9
        var value = requested
        while value > 2048,
              weightsGB + computeGB + kvPerToken * Double(value) / 1_073_741_824 > budget {
            value /= 2
        }
        return value
    }

    /// Router-mode CLI args: no `-m`, the preset file lists every model. Per-model
    /// flags (mmproj, ncmoe, MTP...) live in that INI instead, see `routerPresetINI`.
    private var routerArguments: [String] {
        var args = [
            "--models-preset", Self.routerPresetPath(port: port).path,
            "--models-max", String(routerModelsMax),
            "--models-autoload",
            "--host", localNetworkDiscovery ? "0.0.0.0" : "127.0.0.1",
            "--port", String(port),
        ]
        args.append("--metrics")
        if agentToolsEnabled {
            args += ["--jinja", "--tools", "all"]
            // Same engine-404 guard as the main path above; the proxy flag is
            // what registers POST /tools, so it rides whenever tools do.
            if !toolsRuntime.isEmpty { args += ["--tools-runtime", toolsRuntime] }
        }
        if uiMcpProxy || agentToolsEnabled { args.append("--ui-mcp-proxy") }
        if apiKeyEnabled {
            // KES-04, router path: same file-backed key as the main launch path.
            _ = Keychain.apiKey()  // materializes the file (legacy items migrate here)
            args += ["--api-key-file", LocalSecretStore.url("engine-api-key").path]
        }
        if let ui = Self.chatUIPath { args += ["--path", ui] }
        // Loopback-only bind unless the operator enabled LAN with a key: a
        // `--host` token from extraArgs would otherwise override the app's
        // own bind (later duplicates win) and bypass the start() refusal.
        args += Self.loopbackGuardedCLI(extraArgTokens.cli,
                                        lanAllowed: localNetworkDiscovery && apiKeyEnabled)
        return args
    }

    /// Same folder `ModelStore` scans (`~/models` or the custom override),
    /// resolved independently since `ServerController` has no `ModelStore`.
    static var modelsDirectory: URL {
        let custom = UserDefaults.standard.string(forKey: SettingsKeys.modelsDir) ?? ""
        return custom.isEmpty ? ModelStore.defaultDirectory : URL(fileURLWithPath: custom, isDirectory: true)
    }

    static func routerPresetPath(port: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kestrel/router")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("preset-\(port).ini")
    }

    /// Stable, INI/URL-safe id derived from a model's filename: the router
    /// preset's section name and the value clients send as `"model"`.
    static func routerAlias(for modelPath: String) -> String {
        let base = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        var slug = String(base.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "model" : slug
    }

    /// Builds the router's `--models-preset` INI: one `[alias]` section per model,
    /// shared engine config plus per-path ncmoe/mmproj/MTP. `extraArgs` (free-form
    /// CLI tokens) isn't representable generically here, so it's skipped.
    func routerPresetINI(modelPaths: [String], ncmoeByPath: [String: Int]) -> String {
        // Same FA policy as `arguments`: force only for quantized KV.
        let faValue = kvNeedsFlashAttention ? "on" : (effectiveFaAmd ? "auto" : flashAttn)
        var seenAliases = Set<String>()
        var sections: [String] = []
        for path in modelPaths.sorted() {
            var alias = Self.routerAlias(for: path)
            if seenAliases.contains(alias) { alias += "-\(abs(path.hashValue) % 1000)" }
            seenAliases.insert(alias)

            // Same gemma equalization as `arguments` and `benchmarkArguments`,
            // applied per path: the router serves many models and only its
            // gemma sections hit the same-type-requiring generic Metal kernel.
            // A mixed pair written raw here aborts that model's child engine
            // at load — the same GGML_ASSERT the launch path equalizes away.
            let kv = Self.effectiveCacheTypes(forModel: path, k: cacheTypeK, v: cacheTypeV)
            let modelCtx = Self.routerCtx(forModel: path, requested: ctx, ncmoe: ncmoeByPath[path] ?? 0,
                                          kvScale: Self.kvScale(k: kv.k, v: kv.v),
                                          reserveMB: vramReserveMB)
            var lines = ["[\(alias)]", "model = \(path)", "n-gpu-layers = \(ngl)",
                         "ctx-size = \(modelCtx)", "threads = \(threads)", "flash-attn = \(faValue)"]
            if !effectiveDynamicMoe, let ncmoe = ncmoeByPath[path], ncmoe > 0 { lines.append("n-cpu-moe = \(ncmoe)") }
            if let mode = Self.loadMode(noMmap: noMmap, mlock: mlock) { lines.append("load-mode = \(mode)") }
            let mmproj = loadVision ? Self.mmprojPath(forModel: path) : nil
            if let mmproj {
                lines.append("mmproj = \(mmproj)")
                if Self.projectorNeedsCPU(mmproj) { lines.append("mmproj-offload = false") }
                if imageMaxTokens > 0 { lines.append("image-max-tokens = \(imageMaxTokens)") }
            }
            if jinja || mmproj != nil { lines.append("jinja = true") }
            if kv.k != "f16" { lines.append("cache-type-k = \(kv.k)") }
            if kv.v != "f16" { lines.append("cache-type-v = \(kv.v)") }
            lines.append("cache-ram = \(cacheRAM)")
            if cacheReuse && mmproj == nil { lines.append("cache-reuse = 256") }
            if parallelSlots > 0 { lines.append("parallel = \(parallelSlots)") }
            if parallelSlots > 1 { lines.append("kv-unified = true") }
            if isSplitting { lines.append("split-mode = \(effectiveSplitMode)") }
            if persistCache && effectiveFaAmd {
                // the engine rejects a slot path that isn't an existing directory
                let slotDir = Self.slotCacheDir(port: port).appendingPathComponent(alias)
                try? FileManager.default.createDirectory(at: slotDir, withIntermediateDirectories: true)
                lines.append("slot-save-path = \(slotDir.path)")
            }
            if reasoningInline { lines.append("reasoning-format = none") }
            if effectiveDynamicMoe {
                // see the speculation note in arguments(): it does not mix with the cache
            } else if let selection = dflashSelection(modelPath: path, ncmoe: ncmoeByPath[path] ?? 0) {
                lines.append("model-draft = \(selection.draft)")
                lines.append("spec-type = draft-dflash")
                lines.append("gpu-layers-draft = \(selection.ngld)")
                lines.append("cache-type-k-draft = q8_0")
                lines.append("cache-type-v-draft = q8_0")
            } else if Self.mtpEnabled(forModel: path), let draft = Self.mtpDraftPath(forModel: path) {
                lines.append("model-draft = \(draft)")
                lines.append("spec-type = draft-mtp")
                if let n = Self.mtpDraftWidth(forModel: path, gpuArchitecture: selectedGPUArchitecture) {
                    lines.append("spec-draft-n-max = \(n)")
                }
            } else if Self.mtpEnabled(forModel: path), Self.modelHasMTP(at: path) {
                lines.append("spec-type = draft-mtp")
                if let n = Self.mtpDraftWidth(forModel: path, gpuArchitecture: selectedGPUArchitecture) {
                    lines.append("spec-draft-n-max = \(n)")
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// KES-01/KES-06 loopback guard: the engine binds loopback unless the
    /// operator turned LAN on AND enabled the API key (start() refuses every
    /// other non-loopback bind). But user extraArgs ride AFTER the app's own
    /// `--host` token, and getopt lets the LAST duplicate flag win — a typed
    /// or imported `--host 0.0.0.0` would re-bind the engine to the LAN
    /// behind that refusal's back. Non-loopback `--host` tokens are therefore
    /// dropped from the extra-arg stream unless the LAN policy authorized
    /// them; loopback values always pass (no behavior change for them).
    /// Pure and static so the guard is unit-testable.
    nonisolated static func loopbackGuardedCLI(_ tokens: [String], lanAllowed: Bool) -> [String] {
        guard !lanAllowed else { return tokens }
        let loopback: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--host" {
                // Two-token form: a trailing flag with no value stays (there
                // is no bind to widen), a pair stays only when loopback.
                if i + 1 < tokens.count {
                    if loopback.contains(tokens[i + 1]) { out += [token, tokens[i + 1]] }
                    i += 2
                    continue
                }
                out.append(token)
                i += 1
                continue
            }
            if token.hasPrefix("--host=") {
                if loopback.contains(String(token.dropFirst("--host=".count))) { out.append(token) }
                i += 1
                continue
            }
            out.append(token)
            i += 1
        }
        return out
    }

    /// Splits the Extra arguments field: `KEY=VALUE` with an UPPERCASE name becomes an
    /// env var, everything else a CLI argument. The uppercase rule is what keeps
    /// lowercase flag values containing `=` (`--override-kv key=str:foo`) out of the env.
    var extraArgTokens: (env: [String: String], cli: [String]) {
        func isEnvName(_ s: Substring) -> Bool {
            guard let first = s.first, first == "_" || (first.isLetter && first.isUppercase) else { return false }
            return s.allSatisfy { $0 == "_" || $0.isNumber || ($0.isLetter && $0.isUppercase) }
        }
        var env: [String: String] = [:]
        var cli: [String] = []
        // The model's own arguments come last so they win over the shared field.
        let combined = extraArgs + " " + Self.extraArgs(forModel: modelPath)
        for tok in ShellWords.split(combined) {
            if let eq = tok.firstIndex(of: "="), eq != tok.startIndex, isEnvName(tok[..<eq]) {
                env[String(tok[..<eq])] = String(tok[tok.index(after: eq)...])
            } else {
                cli.append(tok)
            }
        }
        return (env, cli)
    }

    /// Arguments for `llama-bench`: separate from the server's because server-only
    /// flags are invalid here, but every option affecting speed must carry over.
    var benchmarkArguments: [String] {
        // Same load mode as the server, or the numbers are not the ones the app
        // delivers: with experts on the CPU, locking the model is worth most of
        // the prompt speed.
        var args = ["-m", modelPath, "-ngl", String(ngl), "-r", "2",
                    "-p", String(benchPPClamped), "-n", String(benchTGClamped)]
        let mode = effectiveDynamicMoe ? "mlock" : Self.loadMode(noMmap: noMmap, mlock: mlock)
        if let mode { args += ["--load-mode", mode] }
        if benchDepthClamped > 0 { args += ["-d", String(benchDepthClamped)] }
        if !effectiveDynamicMoe && ncmoe > 0 { args += ["-ncmoe", String(ncmoe)] }
        // Threads must be pinned to the app's setting or the benchmark measures
        // llama-bench's own default instead of the configuration we deliver.
        args += ["-t", String(threads)]
        if let ub = effectiveUbatch { args += ["-ub", String(ub), "-b", String(ub)] }
        if effectiveDynamicMoe { args += ["-ot", Self.dynamicMoeTensorOverride] }
        // Same gemma equalization as the server launch (effectiveCacheTypes):
        // llama-bench hits the same same-type-requiring kernel, so a mixed
        // pair would abort at load instead of measuring anything.
        let benchKV = effectiveCacheTypes
        if benchKV.k != "f16" { args += ["-ctk", benchKV.k] }
        if benchKV.v != "f16" { args += ["-ctv", benchKV.v] }
        if kvNeedsFlashAttention || flashAttn == "on" {
            args += ["-fa", "1"]
        } else if effectiveFaAmd {
            args += ["-fa", "auto"]
        }
        if isSplitting { args += ["--split-mode", effectiveSplitMode] }
        if let counts = layerBalancedTensorSplit {
            args += ["--tensor-split", counts.map(String.init).joined(separator: ",")]
        }
        return args
    }

    /// Workload sizes kept within what llama-bench accepts and a Mac can finish.
    var benchPPClamped: Int { min(max(benchPP, 16), 32768) }
    var benchTGClamped: Int { min(max(benchTG, 16), 8192) }
    var benchDepthClamped: Int { min(max(benchDepth, 0), 32768) }

    /// Human-readable name of the GPU a run actually used, for the benchmark
    /// record. Resolves the macOS-picked default to its real device name.
    var gpuLabel: String {
        let gpus = ServerController.availableGPUs()
        // Only the non-default mode is named, so old records stay comparable.
        let mode = effectiveSplitMode == "tensor" ? " · tensor" : ""
        if gpuList.count >= 2 { return "Split · \(gpuList.count) GPUs\(mode)" }
        if multiGPU {
            let discrete = gpus.filter { !$0.isIntegrated }.count
            let limit = discrete > 0 ? discrete : gpus.count
            let n = multiGPUCount > 0 ? min(multiGPUCount, limit) : limit
            return "Split · \(max(2, n)) GPUs\(mode)"
        }
        if gpuIndex >= 0 { return gpus.first { $0.index == gpuIndex }?.name ?? "GPU \(gpuIndex)" }
        return MTLCreateSystemDefaultDevice()?.name ?? "default"
    }

    /// Web chat UI bundled with the app (served via llama-server --path). The
    /// llama.cpp UI wins; the basic console stays as fallback.
    static var chatUIPath: String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        for name in ["web-ui", "test-ui"] {
            let dir = res.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: dir + "/index.html") { return dir }
        }
        return nil
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Finder-launched apps inherit a minimal PATH. Video input is decoded by
        // llama.cpp through ffmpeg/ffprobe, so expose their standard macOS locations.
        env["PATH"] = VideoRuntimeAvailability.augmentedPath(env["PATH"])
        // The engine logs this, so a log pasted from a bug report identifies the
        // app build even when the engine binary is older than the app.
        env["KESTREL_APP_VERSION"] = AppInfo.version
        env["GGML_METAL_VRAM_RESERVE_MB"] = String(vramReserveMB)
        // Physical GPU selection (consumed by the patched Metal backend, which maps
        // these to MTLCopyAllDevices() — the same order as the app's GPU picker).
        let gpus = ServerController.availableGPUs()
        if gpuList.count >= 2 {
            // Split across exactly these GPUs; slot i maps to the i-th listed index.
            env["GGML_METAL_DEVICE_LIST"] = gpuList.map(String.init).joined(separator: ",")
        } else if multiGPU {
            // Split across N GPUs. Fewer than all lets the user trade prompt speed
            // (more GPUs) for generation speed (fewer, less cross-card sync). 0 = all.
            // Integrated iGPUs don't count: the engine skips them when mapping slots.
            let discrete = gpus.filter { !$0.isIntegrated }.count
            let limit = discrete > 0 ? discrete : gpus.count
            let n = multiGPUCount > 0 ? min(multiGPUCount, limit) : limit
            env["GGML_METAL_DEVICES"] = String(max(2, n))
        } else if gpuIndex >= 0 {
            // Pin the engine to one physical GPU by index.
            env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex)
        }
        // The backend forces shared buffers for external GPUs, which streams weights
        // over Thunderbolt every op. Auto-override when a selected card is external;
        // the manual toggle covers the case where macOS picked the GPU.
        let splittingList = gpuList.count >= 2
        let selectedExternal = !multiGPU && !splittingList && gpuIndex >= 0
            && gpus.first { $0.index == gpuIndex }?.isExternal == true
        let anyExternalInSplit = (multiGPU && !splittingList && gpus.contains { $0.isExternal })
            || (splittingList && gpus.contains { gpuList.contains($0.index) && $0.isExternal })
        if forcePrivateBuffers || selectedExternal || anyExternalInSplit {
            env["GGML_METAL_SHARED_BUFFERS_DISABLE"] = "1"
        }
        if effectiveFaAmd { env["KESTREL_FA_AMD"] = "1" }
        // Only a tensor split reduces across cards, which is the copy the bridge speeds up.
        // A layer split has nothing for it to carry.
        if mgpuPeer && isSplitting && effectiveSplitMode == "tensor" { env["KESTREL_MGPU_PEER"] = "1" }
        if mgpuEvents && isSplitting { env["KESTREL_MGPU_EVENTS"] = "1" }
        // Groups only mean anything inside a tensor split, and only when they are
        // smaller than the split itself and divide it evenly.
        if effectiveSplitMode == "tensor", let g = effectiveSplitGroupSize {
            env["KESTREL_MGPU_TENSOR_GROUP"] = String(g)
        }
        // A DFlash draft runs its selector over the target's logits, so a head split by
        // vocabulary leaves no card holding a whole row and the engine aborts. Keep the head
        // on every card for that pairing; it costs its size per card and nothing otherwise.
        if isSplitting, effectiveSplitMode == "tensor", !effectiveDynamicMoe,
           dflashSelection(modelPath: modelPath, ncmoe: ncmoe) != nil {
            env["KESTREL_MIRROR_OUTPUT_HEAD"] = "1"
        }
        // Router mode has no single ncmoe (it's per-model, in the INI); the envs are
        // no-ops for dense models anyway.
        if effectiveDynamicMoe {
            env["KESTREL_MOE_MODE"] = "cache"
            if dynamicMoePolicy == "auto" { env["KESTREL_MOE_AUTO"] = "1" }
            env["KESTREL_MOE_SLOTS"] = String(effectiveDynamicMoeSlots)
            env["KESTREL_MOE_CPU_BANK"] = "1"
            env["GGML_SCHED_PREFETCH_EXPERTS"] = String(effectiveDynamicMoePrefetch)
            env["GGML_METAL_NCB"] = "8"
            if dynamicMoeExecutionRoute == .split {
                let profile = dynamicMoeOptimizationProfile
                env["KESTREL_MOE_SPLIT_BANK"] = "1"
                env["KESTREL_MOE_SLOTS"] = String(dynamicMoeSlotSplit.fixed)
                env["KESTREL_MOE_SPLIT_RING"] = String(dynamicMoeSlotSplit.ring)
                env["KESTREL_MOE_BOUNDED_STAGE"] = "1"
                env["KESTREL_MOE_BOUNDED_STAGE_FORCE"] = "1"
                env["KESTREL_MOE_DOUBLE_BUFFER"] = "1"
                if let mapPath = profile?.hotMapPath,
                   FileManager.default.fileExists(atPath: mapPath) {
                    env["KESTREL_MOE_HOT_MAP"] = mapPath
                    env["KESTREL_MOE_HOT_MAP_OUT"] = mapPath
                    if let experts = dynamicMoeModelInfo?.expertCount {
                        env["KESTREL_MOE_HOT_MAP_K"] = String(experts)
                    }
                }
            }
        } else if prefetchExperts && (ncmoe > 0 || routerMode) {
            // At/above the measured cliff the prefetch overlap collapses and stalls the
            // GPU, so stay below it. Router mode has no single ncmoe to compare.
            let cliff = Self.recalledPrefetchCliff(forModel: modelPath)
            if routerMode || cliff == nil || ncmoe < cliff! {
                env["GGML_SCHED_PREFETCH_EXPERTS"] = "1"
                env["GGML_CPU_NO_REPACK"] = "1"
            }
        }
        // KEY=VALUE tokens from Extra arguments become env vars (e.g. the GCN/Vega
        // wave64 safe-mode flag). Applied last so the user can override the above.
        for (k, v) in extraArgTokens.env { env[k] = v }
        // K is structural: a value larger than the GGUF's expert dimension makes
        // the backend skip cache creation. Keep the model-derived/clamped value even
        // when an old Extra arguments recipe still contains KESTREL_MOE_SLOTS.
        if effectiveDynamicMoe {
            env["KESTREL_MOE_SLOTS"] = String(dynamicMoeExecutionRoute == .split
                ? dynamicMoeSlotSplit.fixed : effectiveDynamicMoeSlots)
        }
        return env.compactMapValues { $0 }
    }

    /// Metal concurrency is stable and faster on Apple Silicon, but it corrupts
    /// output on discrete AMD GPUs (Intel Macs / Hackintosh), where it must stay off.
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }()



    /// Default engine: the one bundled with the app. There is deliberately no
    /// fallback to a source checkout — if the bundle ships without an engine
    /// (a CI packaging failure, an engineless local build), start() reports the
    /// missing binary instead of silently launching whatever it finds elsewhere.
    static var defaultBinary: String {
        if let resolved = cachedDefaultBinary.withLock({ $0 }) { return resolved }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/llama-server").path
            ?? "Contents/Resources/bin/llama-server"
        cachedDefaultBinary.withLock { $0 = bundled }
        return bundled
    }

    private nonisolated static let cachedDefaultBinary = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The engine to launch. "bundled" resolves against the running bundle, so two
    /// installs sharing this defaults domain each use their own binary.
    static var engineKind: String {
        let d = UserDefaults.standard
        if let kind = d.string(forKey: SettingsKeys.engineKind) { return kind }
        // Migration: the kind used to be implied by a stored absolute path. A path
        // into any bundle (including the retired turbo engine) becomes "bundled".
        let legacy = d.string(forKey: SettingsKeys.serverBinary) ?? ""
        let kind = legacy.isEmpty || legacy.contains("/Contents/Resources/bin") ? "bundled" : "custom"
        d.set(kind, forKey: SettingsKeys.engineKind)
        if kind == "bundled" { d.removeObject(forKey: SettingsKeys.serverBinary) }
        return kind
    }

    /// Path of the engine to launch, resolved from the kind at read time.
    static func resolvedBinary() -> String {
        if engineKind == "custom" {
            let custom = UserDefaults.standard.string(forKey: SettingsKeys.serverBinary) ?? ""
            if !custom.isEmpty { return custom }
        }
        return defaultBinary
    }

    /// gpuList is persisted as a comma-separated string so @AppStorage can bind it.
    static func gpuList(fromCSV csv: String?) -> [Int] {
        (csv ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Reads persisted settings (same keys as the views' @AppStorage).
    static func fromDefaults() -> ServerSettings {
        let d = UserDefaults.standard
        func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) == nil ? def : d.integer(forKey: key) }
        func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) == nil ? def : d.bool(forKey: key) }
        return ServerSettings(
            serverBinary: resolvedBinary(),
            modelPath: d.string(forKey: SettingsKeys.modelPath) ?? "",
            port: int(SettingsKeys.port, 8080),
            ngl: int(SettingsKeys.ngl, 99),
            ncmoe: int(SettingsKeys.ncmoe, 0),
            ctx: int(SettingsKeys.ctx, 16384),
            contextAutomatic: bool(SettingsKeys.contextAutomatic, false),
            threads: int(SettingsKeys.threads, 6),
            flashAttn: d.string(forKey: SettingsKeys.flashAttn) ?? "auto",
            noMmap: bool(SettingsKeys.noMmap, true),
            jinja: bool(SettingsKeys.jinja, true),
            vramReserveMB: int(SettingsKeys.vramReserve, 1024),
            gpuIndex: int(SettingsKeys.gpuIndex, -1),
            gpuList: gpuList(fromCSV: d.string(forKey: SettingsKeys.gpuList)),
            extraArgs: d.string(forKey: SettingsKeys.extraArgs) ?? "",
            embeddings: bool(SettingsKeys.embeddings, false),
            agentToolsEnabled: bool(SettingsKeys.agentToolsEnabled, false),
            uiMcpProxy: bool(SettingsKeys.uiMcpProxy, false),
            toolsRuntime: (d.string(forKey: SettingsKeys.toolsRuntime) ?? "")
                .trimmingCharacters(in: .whitespaces),
            cacheTypeK: Self.sanitizedKV(d.string(forKey: SettingsKeys.cacheTypeK), default: "f16"),
            cacheTypeV: Self.sanitizedKV(d.string(forKey: SettingsKeys.cacheTypeV), default: "f16"),
            mlock: bool(SettingsKeys.mlock, false),
            cacheRAM: int(SettingsKeys.cacheRAM, 2048),
            reasoningInline: bool(SettingsKeys.reasoningInline, false),
            parallelSlots: int(SettingsKeys.parallelSlots, 1),
            apiKeyEnabled: bool(SettingsKeys.apiKeyEnabled, false),
            localNetworkDiscovery: bool(SettingsKeys.localNetworkDiscovery, false),
            specMTP: bool(SettingsKeys.specMTP, false),
            faAmd: bool(SettingsKeys.faAmd, defaultFaAmd),
            prefetchExperts: bool(SettingsKeys.prefetchExperts, true),
            ubatch: int(SettingsKeys.ubatch, 0),
            dynamicMoe: bool(SettingsKeys.dynamicMoe, false),
            dynamicMoeSlots: int(SettingsKeys.dynamicMoeSlots, 8),
            dynamicMoePrefetch: int(SettingsKeys.dynamicMoePrefetch, 4),
            dynamicMoePolicy: d.string(forKey: SettingsKeys.dynamicMoePolicy) ?? "cache",
            routerMode: bool(SettingsKeys.routerMode, false),
            routerModelsMax: int(SettingsKeys.routerModelsMax, 1),
            persistCache: bool(SettingsKeys.persistCache, false),
            multiGPU: bool(SettingsKeys.multiGPU, false),
            multiGPUCount: int(SettingsKeys.multiGPUCount, 0),
            splitMode: d.string(forKey: SettingsKeys.splitMode) ?? "layer",
            splitGroupSize: d.integer(forKey: SettingsKeys.splitGroupSize),
            mgpuEvents: bool(SettingsKeys.mgpuEvents, true),
            mgpuPeer: bool(SettingsKeys.mgpuPeer, true),
            forcePrivateBuffers: bool(SettingsKeys.forcePrivateBuffers, false),
            cacheReuse: bool(SettingsKeys.cacheReuse, true),
            loadVision: bool(SettingsKeys.loadVision, true),
            imageMaxTokens: int(SettingsKeys.imageMaxTokens, 0),
            benchPP: int(SettingsKeys.benchPP, 512),
            benchTG: int(SettingsKeys.benchTG, 128),
            benchDepth: int(SettingsKeys.benchDepth, 0))
    }

    /// True when the model's attention head dim exceeds 256 (Gemma 4's global layers
    /// use key_length 512).
    nonisolated static func modelHasBigHeadDim(at path: String) -> Bool {
        (GGUFMetadataCache.metadata(at: path)?.uint32(forSuffix: "attention.key_length") ?? 0) > 256
    }

    nonisolated static func modelSupportsTurboKV(at path: String) -> Bool {
        guard let metadata = GGUFMetadataCache.metadata(at: path) else { return false }
        let keyLength = metadata.uint32(forSuffix: "attention.key_length") ??
            metadata.uint32(forSuffix: "attention.key_length_mla") ?? {
            guard let embedding = metadata.uint32(forSuffix: "embedding_length"),
                  let heads = metadata.uint32(forSuffix: "attention.head_count"), heads > 0,
                  embedding % heads == 0 else { return nil }
            return embedding / heads
        }()
        let valueLength = metadata.uint32(forSuffix: "attention.value_length") ??
            metadata.uint32(forSuffix: "attention.value_length_mla") ?? keyLength

        guard let keyLength, let valueLength, keyLength > 0, valueLength > 0 else { return false }
        let sharedPadded = ((max(keyLength, valueLength) + 127) / 128) * 128
        return [128, 256, 384, 512, 640].contains(sharedPadded)
    }

    nonisolated static func modelUsesMLA(at path: String) -> Bool {
        guard let metadata = GGUFMetadataCache.metadata(at: path) else { return false }
        return metadata.uint32(forSuffix: "attention.key_length_mla") != nil ||
            metadata.uint32(forSuffix: "attention.value_length_mla") != nil
    }

    var kvNeedsFlashAttention: Bool {
        cacheTypeK != "f16" || cacheTypeV != "f16"
    }

    /// The user's AMD Flash-Attention choice. Quantized KV may still force
    /// normal Flash Attention when this is off.
    var effectiveFaAmd: Bool {
        faAmd
    }

    /// Router presets load models independently and cannot carry the per-tensor
    /// override required by this prototype, so keep the experiment fixed-model only.
    var dynamicMoeUIUnlocked: Bool { extraArgTokens.env["KESTREL_MOE_UI"] == "1" }
    var dynamicMoeGPU: GPUDevice? {
        let selected = ServerController.availableGPUs().filter { selectedGPUIndices.contains($0.index) }
        return selected.max { $0.vramMB < $1.vramMB }
    }
    var dynamicMoeOptimizationProfile: DynamicMoeOptimizationProfile? {
        DynamicMoeProfileStore.load(modelPath: modelPath, gpu: dynamicMoeGPU)
    }
    var dynamicMoeExecutionRoute: DynamicMoeExecutionRoute {
        if dynamicMoePolicy == "auto", let profile = dynamicMoeOptimizationProfile {
            return profile.route
        }
        guard let size = GGUFFile.totalSize(at: modelPath), let gpu = dynamicMoeGPU else {
            return .direct
        }
        return Self.dynamicMoeHostBankFitsDirectMetal(
            modelBytes: size, gpuVRAMMB: gpu.vramMB,
            physicalRAMBytes: ProcessInfo.processInfo.physicalMemory) ? .direct : .split
    }
    var dynamicMoeAutoRoute: DynamicMoeAutoRoute {
        guard !modelPath.isEmpty, let size = GGUFFile.totalSize(at: modelPath) else {
            return .normalMissingModel
        }
        let gpu = dynamicMoeGPU
        if dynamicMoeOptimizationProfile != nil, !isSplitting, !routerMode {
            return .cache
        }
        let base = Self.resolveDynamicMoeAuto(
            isMoE: Self.modelIsMoE(at: modelPath),
            modelBytes: size,
            gpuVRAMMB: gpu?.vramMB ?? 0,
            reserveMB: vramReserveMB,
            physicalRAMBytes: ProcessInfo.processInfo.physicalMemory,
            hasDiscreteGPU: gpu?.isIntegrated == false,
            splitOrRouter: isSplitting || routerMode)
        guard base == .cache else { return base }
        guard let info = dynamicMoeModelInfo else { return .normalMissingMetadata }
        guard info.activeExpertCount < info.expertCount else { return .normalNoCacheBenefit }
        guard dynamicMoeSlotPlan(prefetch: 4) != nil else { return .normalInsufficientVRAM }
        return .cache
    }
    /// MoE only: measured up to twice the prefill with experts on CPU (one expert
    /// upload per batch instead of per 512 tokens) and ~10% with the model whole on
    /// the card. A dense model measures slower with it, so it stays gated.
    /// Dynamic MoE gains the most: on a 35B A3B its prefill went 317 to 1088 t/s from
    /// 512 to 2048, against 455 to 862 for the same model on plain expert offload.
    var effectiveUbatch: Int? {
        guard ubatch > 0 else { return nil }
        guard routerMode || Self.modelIsMoE(at: modelPath) else { return nil }
        return ubatch
    }
    var effectiveDynamicMoe: Bool {
        guard dynamicMoe && dynamicMoeUIUnlocked,
              Self.modelIsMoE(at: modelPath), dynamicMoeModelInfo != nil else { return false }
        if dynamicMoePolicy == "auto" { return dynamicMoeAutoRoute == .cache }
        return !routerMode && !isSplitting
    }
    var effectiveDynamicMoeSlots: Int {
        if dynamicMoePolicy == "auto" {
            if let profile = dynamicMoeOptimizationProfile { return profile.slots }
            return dynamicMoeSlotPlan(prefetch: 4)?.automaticSlots ?? 0
        }
        if let info = dynamicMoeModelInfo {
            let minimum = min(max(info.activeExpertCount, 1), info.expertCount)
            return min(max(dynamicMoeSlots, minimum), info.expertCount)
        }
        return min(max(dynamicMoeSlots, 1), 256)
    }
    /// Splits the affordable slot budget between the permanently resident experts and the
    /// LRU ring. This is a trade, not a free win: measured on a 35B-A3B at the same VRAM,
    /// moving the budget into the ring is worth about +64% of generation and costs close to
    /// half the prefill, so it suits chat rather than long prompts. It flattens out once only
    /// the active experts stay fixed.
    var dynamicMoeSlotSplit: (fixed: Int, ring: Int) {
        let budget = effectiveDynamicMoeSlots
        guard let info = dynamicMoeModelInfo, budget > 0 else { return (budget, 0) }
        if let ring = dynamicMoeOptimizationProfile?.ringSlots {
            return (max(1, budget - ring), ring)
        }
        // The experts left out of the slots are wrapped as one host resource and read by the
        // fetch kernel, so they have to stay under what the card can keep resident: past it the
        // reservation is refused outright, and just below it generation collapses.
        var floor = 1
        if let size = GGUFFile.totalSize(at: modelPath), let gpu = dynamicMoeGPU {
            let mib = UInt64(1024 * 1024)
            let shared = min(size, UInt64(Double(UInt64(1024) * mib) * 1.3))
            let expertBytes = size > shared ? size - shared : 0
            let ceiling = UInt64(max(0, gpu.vramMB)) * mib * 3 / 4
            if expertBytes > ceiling {
                floor = Int((Double(info.expertCount) *
                    (1.0 - Double(ceiling)/Double(expertBytes))).rounded(.up))
            }
        }
        var fixed = min(max(max(info.activeExpertCount, floor), 1), budget)
        // A batch is served on the device only when its routing fits the ring; past it the whole
        // logical bank is reassembled layer by layer. The unit is ids, not experts, so a decode
        // step of a few tokens already needs several times the active count. Measured on a 35B
        // A3B: a ring of 8 dropped generation to 17.6 t/s against 49.7, at the same prefill.
        // The cold bank ceiling still wins, since `floor` is what makes the model start at all.
        let ringWanted = info.activeExpertCount * 8
        if budget - fixed < ringWanted {
            fixed = max(min(fixed, budget - ringWanted), max(floor, 1))
        }
        return (fixed, max(0, budget - fixed))
    }

    var effectiveDynamicMoePrefetch: Int {
        if dynamicMoePolicy == "auto", let profile = dynamicMoeOptimizationProfile {
            return profile.prefetch
        }
        return dynamicMoePolicy == "auto" ? 4 : min(max(dynamicMoePrefetch, 0), 16)
    }

    var dynamicMoeModelInfo: DynamicMoeModelInfo? {
        let layers = Int(Self.ggufUInt32("block_count", at: modelPath) ?? 0)
        let experts = Int(Self.ggufUInt32("expert_count", at: modelPath) ?? 0)
        let active = Int(Self.ggufUInt32("expert_used_count", at: modelPath) ?? 0)
        guard layers > 0, experts > 0, active > 0, active <= experts else { return nil }
        return DynamicMoeModelInfo(layerCount: layers, expertCount: experts,
                                   activeExpertCount: active)
    }

    func dynamicMoeSlotPlan(prefetch: Int? = nil) -> DynamicMoeSlotPlan? {
        guard let info = dynamicMoeModelInfo,
              let size = GGUFFile.totalSize(at: modelPath) else {
            return nil
        }
        let selected = ServerController.availableGPUs().filter { selectedGPUIndices.contains($0.index) }
        guard let gpu = selected.max(by: { $0.vramMB < $1.vramMB }), !gpu.isIntegrated else { return nil }
        return Self.resolveDynamicMoeSlots(
            modelBytes: size, model: info, gpuVRAMMB: gpu.vramMB,
            reserveMB: vramReserveMB, prefetch: prefetch ?? effectiveDynamicMoePrefetch,
            ubatch: effectiveUbatch ?? 512)
    }

    static func resolveDynamicMoeSlots(
        modelBytes: UInt64,
        model: DynamicMoeModelInfo,
        gpuVRAMMB: Int,
        reserveMB: Int,
        prefetch: Int,
        ubatch: Int = 512
    ) -> DynamicMoeSlotPlan? {
        guard modelBytes > 0, model.layerCount > 0, model.expertCount > 0,
              model.activeExpertCount > 0, model.activeExpertCount <= model.expertCount,
              gpuVRAMMB > reserveMB else { return nil }

        let mib = UInt64(1024 * 1024)
        let gib = UInt64(1024) * mib
        // The 1.3 GiB shared/non-MoE estimate is the same conservative split used by
        // Kestrel's ncmoe planner. The remainder is the quantized expert pool.
        let sharedBytes = min(modelBytes, UInt64(Double(gib) * 1.3))
        let expertBytes = modelBytes - sharedBytes
        guard expertBytes > 0 else { return nil }
        let bytesPerSlot = max(UInt64(1),
            UInt64(ceil(Double(expertBytes) / Double(model.expertCount))))

        // One full widest bank is staging; each prefetch slot can hold another. A
        // gate_up bank is approximately 2/3 of one layer's three expert matrices.
        let widestBankBytes = UInt64(ceil(
            Double(expertBytes) / Double(model.layerCount) * (2.0 / 3.0)))
        let transferBuffers = widestBankBytes * UInt64(max(0, min(prefetch, 16)) + 1)
        // A wider prefill micro-batch buys a lot of prompt speed but its compute buffers
        // come out of the same VRAM as the slots: measured about 640 MiB per extra 512
        // tokens on a 35B A3B.
        let extraUbatch = max(0, ubatch - 512)/512
        let runtimeBytes = UInt64(512) * mib + UInt64(extraUbatch) * UInt64(640) * mib
        let fixedBytes = sharedBytes + runtimeBytes + transferBuffers
        let availableBytes = UInt64(max(0, gpuVRAMMB - reserveMB)) * mib
        let budgetSlots = availableBytes > fixedBytes
            ? Int((availableBytes - fixedBytes) / bytesPerSlot) : 0
        let recommendedMaximum = min(model.expertCount, max(0, budgetSlots))
        guard recommendedMaximum >= model.activeExpertCount else { return nil }

        return DynamicMoeSlotPlan(
            model: model,
            minimumSlots: model.activeExpertCount,
            maximumSlots: model.expertCount,
            recommendedMaximumSlots: recommendedMaximum,
            automaticSlots: model.activeExpertCount,
            estimatedBytesPerSlot: bytesPerSlot,
            estimatedFixedVRAMBytes: fixedBytes)
    }

    static func resolveDynamicMoeAuto(
        isMoE: Bool,
        modelBytes: UInt64,
        gpuVRAMMB: Int,
        reserveMB: Int,
        physicalRAMBytes: UInt64,
        hasDiscreteGPU: Bool,
        splitOrRouter: Bool
    ) -> DynamicMoeAutoRoute {
        guard !splitOrRouter else { return .normalSplitOrRouter }
        guard isMoE else { return .normalDense }
        guard modelBytes > 0 else { return .normalMissingModel }
        guard hasDiscreteGPU, gpuVRAMMB > 0 else { return .normalUnsupportedGPU }

        // Besides the user's reserve, leave 512 MiB for compute/KV allocations. A GGUF
        // that fits below this line gains nothing from duplicating its expert bank in RAM.
        let mib = UInt64(1024 * 1024)
        let usableVRAM = UInt64(max(0, gpuVRAMMB - reserveMB - 512)) * mib
        guard modelBytes > usableVRAM else { return .normalFitsVRAM }

        // Dynamic MoE pins the quantized expert bank. Keep the model plus 25% and 4 GiB
        // for the OS/app/KV; if total RAM cannot provide that, normal ncmoe is safer.
        let ramHeadroom = max(modelBytes / 4, UInt64(4) * 1024 * 1024 * 1024)
        guard physicalRAMBytes >= modelBytes + ramHeadroom else { return .normalInsufficientRAM }
        return .cache
    }

    /// The current decode kernel directly binds the complete host expert pool to Metal. On a
    /// discrete GPU, measured banks larger than the device working set can stall the driver even
    /// when system RAM and swap are healthy. Auto stays on the validated side of that boundary;
    /// private Manual mode remains available for developing a bounded staging implementation.
    /// Direct mode wraps the whole expert bank as host memory, and Metal wires those pages, so
    /// what bounds it is system RAM rather than the card: the slots the graph reads are what
    /// lives in VRAM. Measured on a 32 GiB machine, a 9.6 GiB bank runs fine while 12.7 and
    /// 16.9 GiB starve the compositor, because wired pages cannot be evicted and swap is
    /// capped. A third of physical RAM is the line those three points draw.
    static func dynamicMoeHostBankFitsDirectMetal(modelBytes: UInt64, gpuVRAMMB: Int,
                                                  physicalRAMBytes: UInt64) -> Bool {
        guard modelBytes > 0, gpuVRAMMB > 0, physicalRAMBytes > 0 else { return false }
        let mib = UInt64(1024 * 1024)
        let sharedBytes = min(modelBytes, UInt64(Double(UInt64(1024) * mib) * 1.3))
        let estimatedExpertBytes = modelBytes - sharedBytes
        return estimatedExpertBytes <= physicalRAMBytes / 3
    }

    /// Resolves DFlash against the same physical GPU selection and memory reserve
    /// that will be passed to the engine. A nil plan means metadata or hardware is
    /// unavailable; a plan with nil layers means DFlash cannot fit safely.
    var selectedGPUIndices: Set<Int> {
        let gpus = ServerController.availableGPUs()
        if gpuList.count >= 2 { return Set(gpuList) }
        if multiGPU {
            let eligible = gpus.filter { !$0.isIntegrated }
            let pool = eligible.isEmpty ? gpus : eligible
            let count = multiGPUCount > 0 ? min(multiGPUCount, pool.count) : pool.count
            return Set(pool.prefix(count).map(\.index))
        }
        if gpuIndex >= 0 { return [gpuIndex] }
        if let gpu = gpus.filter({ !$0.isIntegrated }).max(by: { $0.vramMB < $1.vramMB })
            ?? gpus.max(by: { $0.vramMB < $1.vramMB }) {
            return [gpu.index]
        }
        return []
    }

    func dflashMemoryPlan(modelPath: String, draftPath: String, ncmoe: Int,
                          honorReserve: Bool = true) -> DflashMemoryPlan? {
        let gpus = ServerController.availableGPUs()
        let indices = selectedGPUIndices
        let selected = gpus.filter { indices.contains($0.index) }
        guard !selected.isEmpty else { return nil }

        guard let baseBytes = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size] as? NSNumber)?.doubleValue,
              let draftBytes = (try? FileManager.default.attributesOfItem(atPath: draftPath)[.size] as? NSNumber)?.doubleValue else {
            return nil
        }
        let baseLayers = Int(Self.ggufUInt32("block_count", at: modelPath) ?? 0)
        let repeatingDraftLayers = Int(Self.ggufUInt32("block_count", at: draftPath) ?? 0)
        guard baseLayers > 0, repeatingDraftLayers > 0 else { return nil }

        let headsKV = Double(Self.ggufUInt32("attention.head_count_kv", at: draftPath) ?? 0)
        let keyLength = Double(Self.ggufUInt32("attention.key_length", at: draftPath) ?? 0)
        let valueLength = Double(Self.ggufUInt32("attention.value_length", at: draftPath) ?? 0)
        guard headsKV > 0, keyLength > 0, valueLength > 0 else { return nil }
        // q8_0 stores 32 values plus a 16-bit scale in each 34-byte block.
        let q8BytesPerElement = 34.0 / 32.0
        let draftKVBytesPerToken = Double(repeatingDraftLayers) * headsKV
            * (keyLength + valueLength) * q8BytesPerElement
        let mainKVScale = (Estimator.kvTypeScale(cacheTypeK) + Estimator.kvTypeScale(cacheTypeV)) / 2
        let vramGB = Double(selected.reduce(0) { $0 + $1.vramMB }) / 1024
        let reserveGB = honorReserve ? Double(vramReserveMB * max(1, selected.count)) / 1024 : 0
        return DflashMemoryPlanner.plan(
            vramGB: vramGB, reserveGB: reserveGB,
            baseFileGB: baseBytes / 1_073_741_824, baseLayers: baseLayers, ncmoe: ncmoe,
            ctx: ctx, mainKVScale: mainKVScale,
            draftFileGB: draftBytes / 1_073_741_824, draftLayers: repeatingDraftLayers + 1,
            draftKVBytesPerToken: draftKVBytesPerToken)
    }

    private func dflashSelection(modelPath: String, ncmoe: Int) -> (draft: String, ngld: Int)? {
        guard let draft = Self.dflashDraftPath(forModel: modelPath) else { return nil }
        switch Self.dflashMode(forModel: modelPath) {
        case .off:
            return nil
        case .auto:
            guard DflashPolicy.autoEligible(isMoE: Self.modelIsMoE(at: modelPath), ncmoe: ncmoe),
                  let layers = dflashMemoryPlan(modelPath: modelPath, draftPath: draft,
                                                ncmoe: ncmoe)?.gpuLayers else { return nil }
            return (draft, layers)
        case .forced:
            let layers = dflashMemoryPlan(modelPath: modelPath, draftPath: draft,
                                          ncmoe: ncmoe, honorReserve: false)?.gpuLayers ?? 0
            return (draft, layers)
        }
    }

    var dflashPlanSummary: String {
        guard let draft = Self.dflashDraftPath(forModel: modelPath) else { return "not installed" }
        let mode = Self.dflashMode(forModel: modelPath)
        guard mode != .off else { return "off by user" }
        guard let plan = dflashMemoryPlan(modelPath: modelPath, draftPath: draft, ncmoe: ncmoe,
                                          honorReserve: mode == .auto) else {
            return "off (metadata or GPU capacity unavailable)"
        }
        let need = (plan.estimatedVRAMGB * 100).rounded() / 100
        let budget = (plan.budgetGB * 100).rounded() / 100
        guard let layers = plan.gpuLayers else {
            return "off by memory planner (need \(need) GiB, budget \(budget) GiB)"
        }
        return "\(mode.rawValue), ngld=\(layers) (estimated \(need) / \(budget) GiB budget)"
    }

    var benchmarkFlashAttentionRoute: String {
        if effectiveFaAmd { return "amd-gpu" }
        if flashAttn == "on" || kvNeedsFlashAttention { return "standard-cpu" }
        if flashAttn == "auto" { return "standard-auto" }
        return "off"
    }

    var benchmarkFlashAttentionLabel: String {
        switch benchmarkFlashAttentionRoute {
        case "amd-gpu": return "AMD Flash Attention (GPU)"
        case "standard-cpu": return "standard Flash Attention (CPU)"
        case "standard-auto": return "standard Flash Attention (auto)"
        default: return "off"
        }
    }

    /// Whether a GGUF ships the MTP (multi-token prediction) head. Quantizers often
    /// strip it but leave the key at 0, and the server aborts on the missing tensors,
    /// so trust the value and fall back to the tensor names.
    nonisolated static func modelHasMTP(at path: String) -> Bool {
        if let layers = ggufUInt32("nextn_predict_layers", at: path) {
            return layers >= 1
        }
        return GGUFMetadataCache.hasNextNTensor(at: path)
    }

    /// Strips what only names a build of the same model: quant, precision, shard and the
    /// markers that say "this file is the MTP head". What is left identifies the model.
    nonisolated static func mtpStem(_ fileName: String) -> String {
        var s = fileName.lowercased()
        if s.hasSuffix(".gguf") { s = String(s.dropLast(5)) }
        s = s.replacingOccurrences(of: ".mtp.", with: "-mtp-")
        if s.hasSuffix(".mtp") { s = String(s.dropLast(4)) + "-mtp" }

        var parts = s.split(separator: "-").map(String.init)
        let marker = { (t: String) -> Bool in
            if ["ud", "mtp", "nextn", "shared", "draft", "of", "f16", "f32", "bf16", "mxfp4",
                "xl", "xs", "s", "m", "l", "k"].contains(t) { return true }
            return t.range(of: #"^((i?q\d+(_[a-z0-9]+)*)|(\d{5}))$"#, options: .regularExpression) != nil
        }
        while let first = parts.first, marker(first) { parts.removeFirst() }
        while let last = parts.last, marker(last) { parts.removeLast() }
        return parts.joined(separator: "-")
    }

    /// A head must describe the same model, or the server aborts once it starts drafting.
    nonisolated static func mtpHeadMatches(head: String, model: String) -> Bool {
        // An unreadable header proves nothing: the name already tied the two files together,
        // so only a header that disagrees rejects the candidate.
        if let headArch = ggufString("general.architecture", at: head),
           let baseArch = ggufString("general.architecture", at: model),
           headArch != baseArch, headArch != baseArch + "_assistant" {
            return false
        }
        if let headEmbd = ggufUInt32("embedding_length", at: head),
           let baseEmbd = ggufUInt32("embedding_length", at: model), headEmbd != baseEmbd {
            return false
        }
        if let headVocab = ggufUInt32("vocab_size", at: head),
           let baseVocab = ggufUInt32("vocab_size", at: model), headVocab != baseVocab {
            return false
        }
        if let layers = ggufUInt32("nextn_predict_layers", at: head) {
            return layers >= 1
        }
        return true
    }

    /// Finds the MTP head of a model: beside it, or in the `MTP/` folder the upstream
    /// repackagers ship. Names vary (`mtp-<model>.gguf`, `<model>.mtp.gguf`, `<model>-MTP-Q8_0`),
    /// so the file name only proposes a candidate and the header decides.
    nonisolated static func mtpDraftPath(forModel modelPath: String) -> String? {
        guard !modelPath.isEmpty, !GGUFFile.isDraft(modelPath) else { return nil }
        let modelURL = URL(fileURLWithPath: modelPath)
        let dir = modelURL.deletingLastPathComponent()
        let modelStem = mtpStem(modelURL.lastPathComponent)

        let fm = FileManager.default
        var files: [URL] = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for sub in ["MTP", "mtp"] {
            let subDir = dir.appendingPathComponent(sub)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: subDir.path, isDirectory: &isDir), isDir.boolValue {
                files += (try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil)) ?? []
            }
        }

        let candidates = files.filter { file in
            guard file.pathExtension.lowercased() == "gguf", file.path != modelPath else { return false }
            let name = file.lastPathComponent.lowercased()
            let looksLikeHead = name.hasPrefix("mtp-") || name.contains(".mtp.")
                || name.contains("-mtp-") || name.hasSuffix("-mtp.gguf") || name.contains("nextn")
            guard looksLikeHead else { return false }
            let stem = mtpStem(file.lastPathComponent)
            guard stem == modelStem || modelStem.hasPrefix(stem) || stem.hasPrefix(modelStem) else { return false }
            return mtpHeadMatches(head: file.path, model: modelPath)
        }

        let exact = candidates.filter { mtpStem($0.lastPathComponent) == modelStem }
        let pool = exact.isEmpty ? candidates : exact
        guard pool.count <= 1 else {
            // several heads describe this model and nothing says which build to draft with:
            // picking one silently would ship a head the user did not choose
            AppLog.server.error("MTP: \(pool.count) heads match \(modelURL.lastPathComponent), none selected")
            return nil
        }
        return pool.first?.path
    }

    /// Draft width for this model on this card. Flash-Next verifies three tokens faster than
    /// four, so it keeps a width of its own. On AMD the verify pass grows faster than the
    /// accepted tokens past two drafts on 32-lane cards and past one on 64-lane cards; other
    /// GPUs keep the engine default. A user width in the extra arguments wins, because those
    /// are appended after these.
    nonisolated static func mtpDraftWidth(forModel path: String, gpuArchitecture: String?) -> Int? {
        if ggufString("general.architecture", at: path) == "qwen4exp" { return 2 }
        guard let arch = gpuArchitecture else { return nil }
        if arch == "GCN / Vega" { return 1 }
        if arch.hasPrefix("RDNA") { return 2 }
        return nil
    }

    nonisolated static func mtpDraftWidthArgs(forModel path: String, gpuArchitecture: String? = nil) -> [String] {
        mtpDraftWidth(forModel: path, gpuArchitecture: gpuArchitecture).map { ["--spec-draft-n-max", String($0)] } ?? []
    }

    /// Architecture shared by every card the server runs on, or nil when they differ.
    var selectedGPUArchitecture: String? {
        let indices = selectedGPUIndices
        let archs = Set(ServerController.availableGPUs().filter { indices.contains($0.index) }
            .map { GPUArchitectureClassifier.architecture(for: $0.name) ?? "" })
        guard archs.count == 1, let arch = archs.first, !arch.isEmpty else { return nil }
        return arch
    }

    nonisolated static func modelUsesMTP(at path: String) -> Bool {
        modelHasMTP(at: path) || mtpDraftPath(forModel: path) != nil
    }

    nonisolated static func mtpEnabled(forModel path: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: SettingsKeys.mtpDisabledModels) ?? []).contains(path)
    }

    nonisolated static func setMTPEnabled(_ enabled: Bool, forModel path: String) {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: SettingsKeys.mtpDisabledModels) ?? [])
        if enabled { disabled.remove(path) } else { disabled.insert(path) }
        UserDefaults.standard.set(Array(disabled), forKey: SettingsKeys.mtpDisabledModels)
    }

    /// True when the model's weights use a TurboQuant type (ggml_type 45/46). Read from
    /// the tensor types: these GGUFs carry no usable `general.file_type`. False on an
    /// unreadable header, so a model we can't parse is never blocked.
    nonisolated static func modelIsTurboQuantWeights(at path: String) -> Bool {
        GGUFMetadataCache.tensorFlags(at: path).hasTurboQuantTensor
    }

    /// First uint32 value for an exact GGUF metadata key or architecture suffix.
    nonisolated static func ggufUInt32(_ keySuffix: String, at path: String) -> UInt32? {
        GGUFMetadataCache.metadata(at: path)?.uint32(forSuffix: keySuffix)
    }

    /// String value for an exact GGUF metadata key.
    nonisolated static func ggufString(_ key: String, at path: String) -> String? {
        GGUFMetadataCache.metadata(at: path)?.string(for: key)
    }

    /// GPUs a tensor split can divide this model's experts among. Experts whose scales
    /// sit in their own tensor span two buffers, which the meta backend cannot divide.
    nonisolated static func tensorSplitLimit(forModel path: String) -> Int? {
        guard !path.isEmpty else { return nil }
        return GGUFMetadataCache.tensorFlags(at: path).hasExpertScaleTensor ? 1 : nil
    }

    /// True when the model is a Mixture-of-Experts (GGUF `<arch>.expert_count` > 0).
    /// Gates the `--n-cpu-moe` control, which a dense model ignores.
    nonisolated static func modelIsMoE(at path: String) -> Bool {
        GGUFMetadataCache.metadata(at: path)?.isMoE ?? false
    }

    /// Micro-batch sizes offered in the UI. 0 leaves the engine's own 512.
    nonisolated static let ubatchOptions = [0, 1024, 2048, 4096]

    nonisolated static func ubatchLabel(_ value: Int, loc: Localizer) -> String {
        value == 0 ? loc.t("512 (por defecto)", "512 (default)") : String(value)
    }

    /// Remembers the ncmoe the user settled on for a MoE model, so selecting
    /// that model again restores it instead of re-deriving the recommendation.
    nonisolated static func rememberNcmoe(_ value: Int, forModel path: String) {
        guard !path.isEmpty, modelIsMoE(at: path) else { return }
        var map = UserDefaults.standard.dictionary(forKey: SettingsKeys.ncmoeByModel) as? [String: Int] ?? [:]
        map[path] = value
        UserDefaults.standard.set(map, forKey: SettingsKeys.ncmoeByModel)
    }

    nonisolated static func recalledNcmoe(forModel path: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.ncmoeByModel) as? [String: Int])?[path]
    }

    /// One completed benchmark for a model: the configuration it ran with and the
    /// speed it delivered. Persisted as JSON in UserDefaults, keyed by model path.
    struct MeasuredBench: Codable {
        var ncmoe: Int
        var threads: Int
        var tg: Double
        var pp: Double
        var date: Date
    }

    /// Remembers a completed benchmark's measured-best configuration for a model
    /// so the next selection pre-fills it. Stores regardless of architecture: a
    /// dense model's measurement is equally real, it just has no ncmoe dimension.
    nonisolated static func rememberMeasuredBench(_ value: MeasuredBench, forModel path: String) {
        guard !path.isEmpty else { return }
        var map = Self.measuredBenchMap()
        map[path] = value
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: SettingsKeys.measuredBenchByModel)
        }
    }

    nonisolated static func recalledMeasuredBench(forModel path: String) -> MeasuredBench? {
        guard !path.isEmpty, let data = UserDefaults.standard.string(forKey: SettingsKeys.measuredBenchByModel)?.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([String: MeasuredBench].self, from: data))?[path]
    }

    nonisolated private static func measuredBenchMap() -> [String: MeasuredBench] {
        guard let data = UserDefaults.standard.string(forKey: SettingsKeys.measuredBenchByModel)?.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: MeasuredBench].self, from: data) else { return [:] }
        return map
    }

    /// Remembers the ncmoe at which the expert-prefetch overlap stalls the GPU; prefetch
    /// only runs below it. nil clears it, so a re-measuring sweep starts prefetch on.
    nonisolated static func rememberPrefetchCliff(_ value: Int?, forModel path: String) {
        guard !path.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: SettingsKeys.prefetchCliffByModel) as? [String: Int] ?? [:]
        if let value { map[path] = value } else { map.removeValue(forKey: path) }
        UserDefaults.standard.set(map, forKey: SettingsKeys.prefetchCliffByModel)
    }

    nonisolated static func recalledPrefetchCliff(forModel path: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.prefetchCliffByModel) as? [String: Int])?[path]
    }

    /// Finds the multimodal projector (mmproj) paired with a model, if any.
    private static func mmprojPairKey(_ model: String, _ projector: String) -> String {
        model + "\u{1}" + projector
    }

    /// Records that `projector` failed to load with `model` (e.g. an unknown CLIP
    /// projector type), so `mmprojPath` won't auto-attach it again. Persistent.
    nonisolated static func recordIncompatibleMmproj(model: String, projector: String) {
        var list = UserDefaults.standard.stringArray(forKey: SettingsKeys.incompatibleMmproj) ?? []
        let key = mmprojPairKey(model, projector)
        if !list.contains(key) {
            list.append(key)
            UserDefaults.standard.set(list, forKey: SettingsKeys.incompatibleMmproj)
        }
    }

    nonisolated static func isIncompatibleMmproj(model: String, projector: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: SettingsKeys.incompatibleMmproj) ?? [])
            .contains(mmprojPairKey(model, projector))
    }

    nonisolated static func extraArgs(forModel path: String) -> String {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.extraArgsByModel) as? [String: String])?[path] ?? ""
    }

    nonisolated static func setExtraArgs(_ args: String, forModel path: String) {
        var map = UserDefaults.standard.dictionary(forKey: SettingsKeys.extraArgsByModel) as? [String: String] ?? [:]
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map.removeValue(forKey: path) } else { map[path] = trimmed }
        UserDefaults.standard.set(map, forKey: SettingsKeys.extraArgsByModel)
    }

    nonisolated static func mmprojOverride(forModel path: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.mmprojOverride) as? [String: String])?[path]
    }

    nonisolated static func setMmprojOverride(_ projector: String?, forModel path: String) {
        var map = UserDefaults.standard.dictionary(forKey: SettingsKeys.mmprojOverride) as? [String: String] ?? [:]
        if let projector { map[path] = projector } else { map.removeValue(forKey: path) }
        UserDefaults.standard.set(map, forKey: SettingsKeys.mmprojOverride)
    }

    /// True only when both dims are readable and differ; unknown pairs pass.
    nonisolated static func mmprojIncompatible(model: String, projector: String) -> Bool {
        guard let embd = ggufUInt32("embedding_length", at: model),
              let proj = ggufUInt32("projection_dim", at: projector) else { return false }
        return proj != embd
    }

    /// Whether to offer the projector control for a model: it has a paired or
    /// pinned projector, an explicit choice (incl. off), or is a catalog vision model.
    nonisolated static func mightSupportVision(modelPath: String) -> Bool {
        if mmprojOverride(forModel: modelPath) != nil { return true }
        if mmprojPath(forModel: modelPath) != nil { return true }
        let name = URL(fileURLWithPath: modelPath).lastPathComponent
        return Catalog.models.contains { $0.fileName == name && $0.isVision }
    }

    /// The DFlash draft downloaded for a model, saved as `<model>.dflash.gguf`.
    nonisolated static func dflashDraftPath(forModel modelPath: String) -> String? {
        guard !modelPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: modelPath)
        let stem = url.deletingPathExtension().lastPathComponent
        let path = url.deletingLastPathComponent().appendingPathComponent("\(stem).dflash.gguf").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    nonisolated static func dflashMode(forModel modelPath: String) -> DflashMode {
        let defaults = UserDefaults.standard
        if let raw = (defaults.dictionary(forKey: SettingsKeys.dflashModes) as? [String: String])?[modelPath],
           let mode = DflashMode(rawValue: raw) {
            return mode
        }
        let disabled = defaults.stringArray(forKey: SettingsKeys.dflashDisabled) ?? []
        return disabled.contains(modelPath) ? .off : .auto
    }

    nonisolated static func setDflashMode(_ mode: DflashMode, forModel modelPath: String) {
        var modes = UserDefaults.standard.dictionary(forKey: SettingsKeys.dflashModes) as? [String: String] ?? [:]
        modes[modelPath] = mode.rawValue
        UserDefaults.standard.set(modes, forKey: SettingsKeys.dflashModes)
    }

    nonisolated static func dflashEnabled(forModel modelPath: String) -> Bool {
        dflashMode(forModel: modelPath) != .off
    }

    nonisolated static func setDflashEnabled(_ on: Bool, forModel modelPath: String) {
        setDflashMode(on ? .auto : .off, forModel: modelPath)
    }

    /// The active DFlash draft: present on disk and not switched off for this model.
    nonisolated static func activeDflashDraft(forModel modelPath: String) -> String? {
        guard dflashEnabled(forModel: modelPath) else { return nil }
        return dflashDraftPath(forModel: modelPath)
    }

    /// A bf16 projector aborts the engine on a card without the Metal 3 family: the loader
    /// puts the weight in device memory and the scheduler then refuses to run it there.
    /// Keeping the tower on the CPU costs image-encode time and keeps vision working.
    nonisolated static func projectorNeedsCPU(_ mmproj: String) -> Bool {
        guard GGUFMetadataCache.tensorFlags(at: mmproj).hasBF16Tensor else { return false }
        return ServerController.availableGPUs().contains { !$0.isIntegrated && !$0.supportsBF16 }
    }

    nonisolated static func mmprojPath(forModel modelPath: String) -> String? {
        guard !modelPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: modelPath)
        let name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().contains("mmproj") { return nil }  // the model itself is not a projector

        // A manual override wins: a path pins that projector, "" disables vision;
        // a stale path (file moved) falls through to auto-pairing.
        if let override = mmprojOverride(forModel: modelPath) {
            if override.isEmpty { return nil }
            if FileManager.default.fileExists(atPath: override) { return override }
        }

        let dir = url.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var projectors = files.filter {
            $0.pathExtension.lowercased() == "gguf" && $0.lastPathComponent.lowercased().contains("mmproj")
        }
        guard !projectors.isEmpty else { return nil }

        // Keep only projectors whose projection_dim matches the model's
        // embedding_length; unreadable ones are kept rather than punished.
        if let modelEmbd = ggufUInt32("embedding_length", at: modelPath) {
            let compatible = projectors.filter { p in
                guard let proj = ggufUInt32("projection_dim", at: p.path) else { return true }
                return proj == modelEmbd
            }
            if compatible.isEmpty { return nil }
            projectors = compatible
        }

        // Skip projectors recorded as incompatible with this model; a different
        // one for the same model still gets picked up.
        projectors = projectors.filter { !isIncompatibleMmproj(model: modelPath, projector: $0.path) }
        guard !projectors.isEmpty else { return nil }

        // Managed downloads use an exact model-specific stem: highest confidence,
        // so try it before the legacy names below.
        func core(_ s: String) -> String {
            String(s.lowercased().replacingOccurrences(of: "mmproj", with: "").filter { $0.isLetter || $0.isNumber })
        }
        let mn = core(name)
        guard !mn.isEmpty else { return nil }
        if let exact = projectors.first(where: {
            core($0.deletingPathExtension().lastPathComponent) == mn
        }) {
            return exact.path
        }

        // Legacy/manual names often omit the quant or model size. Fall back only
        // when the GGUF dimensions match and exactly one same-family projector
        // remains; ambiguity deliberately returns nil instead of guessing.
        guard let modelEmbd = ggufUInt32("embedding_length", at: modelPath) else { return nil }
        func family(_ value: String) -> String {
            ModelName(value).title.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        func sameFamily(_ lhs: String, _ rhs: String) -> Bool {
            guard lhs.count >= 5, rhs.count >= 5 else { return false }
            return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
        }
        let modelFamily = family(name)
        let matches = projectors.filter { projector in
            guard ggufUInt32("projection_dim", at: projector.path) == modelEmbd else { return false }
            return sameFamily(modelFamily, family(projector.lastPathComponent))
        }
        return matches.count == 1 ? matches[0].path : nil
    }

    /// The API key the chat must send, when protection is enabled in Settings.
    static func activeAPIKey() -> String? {
        UserDefaults.standard.bool(forKey: SettingsKeys.apiKeyEnabled) ? Keychain.apiKey() : nil
    }

    /// The model alias the native chat should send as `"model"`, or nil when
    /// the primary server isn't in router mode (single-model requests omit it).
    static func activeRouterModel() -> String? {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKeys.routerMode) else { return nil }
        let alias = d.string(forKey: SettingsKeys.chatSelectedModel) ?? ""
        if !alias.isEmpty { return alias }
        // Default to the first model when the chat hasn't picked one yet (its
        // picker's default-selection task lives in a lazily-built popover).
        return LocalModel.scan(in: modelsDirectory).first.map { routerAlias(for: $0.url.path) }
    }
}

/// Owns the running engine instances.
@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var servers: [ServerController]
    /// The instance the chat and benchmark act on.
    @Published var activeID: UUID

    /// Persisted added-server profiles. Also read by
    /// LayaDecideService.resolvedPort() from nonisolated code.
    nonisolated static let storeKey = "multiServerProfiles"
    private var pendingPersist: Task<Void, Never>?

    private init() {
        // Server 1 is the default: nil profile → driven by the global settings.
        let first = ServerController()
        var list = [first]
        // Recreate any extra servers the user added, each with its own config.
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let profiles = try? JSONDecoder().decode([Profile].self, from: data) {
            for var p in profiles {
                // Freeze the currently inherited model once, without changing the
                // model users were seeing before instance selection was restored.
                if let pins = p.pinned, !pins.contains(Profile.Pin.model) {
                    let current = ServerSettings.fromDefaults()
                    p.selectInstanceModel(path: current.modelPath,
                                          ncmoe: pins.contains(Profile.Pin.moe) ? p.ncmoe : current.ncmoe)
                }
                let c = ServerController()
                c.name = p.name
                c.profile = p
                list.append(c)
            }
        }
        // One-time seed of the "Laya Decisions" server card: the local
        // decision model as its own stoppable server on 8098, so Laya is
        // served from Kestrel — visible, user-started, user-stopped — never
        // a hidden background process. Skipped when the model file is
        // absent, the card already exists (by name or port), or the user
        // deleted it (remembered explicitly).
        let layaModel = NSHomeDirectory() + "/models/Laya-Q8_0.gguf"
        let layaDeletedKey = "layaDecisionsServerDeleted"
        if FileManager.default.fileExists(atPath: layaModel),
           !UserDefaults.standard.bool(forKey: layaDeletedKey),
           !list.contains(where: { $0.name == "Laya Decisions" || $0.profile?.port == 8098 }) {
            var p = ServerSettings.fromDefaults().makeProfile(name: "Laya Decisions")
            p.name = "Laya Decisions"
            p.port = 8098
            p.ctx = 2048
            p.pinned = [Profile.Pin.model, Profile.Pin.ctx]
            p.selectInstanceModel(path: layaModel, ncmoe: p.ncmoe)
            let c = ServerController()
            c.name = "Laya Decisions"
            c.profile = p
            list.append(c)
            UserDefaults.standard.set(false, forKey: layaDeletedKey)
        }
        servers = list
        activeID = first.id
        persist()
    }

    var active: ServerController { servers.first { $0.id == activeID } ?? servers[0] }

    func setActive(_ id: UUID) {
        if servers.contains(where: { $0.id == id }) { activeID = id }
    }

    /// Lowest port not already taken by a server, starting at the default.
    func freePort() -> Int {
        let used = Set(servers.map { $0.profile?.port ?? ServerSettings.fromDefaults().port })
        var p = 8080
        while used.contains(p) { p += 1 }
        return p
    }

    /// Adds a server from a base profile (or the current config), on a free port.
    @discardableResult
    func addServer(name: String, from base: Profile?) -> ServerController {
        var p = base ?? ServerSettings.fromDefaults().makeProfile(name: name)
        p.name = name
        p.port = freePort()
        // Each instance owns its model from creation. Other settings still inherit.
        if base == nil { p.pinned = [Profile.Pin.model] }
        p.selectInstanceModel(path: p.modelPath, ncmoe: p.ncmoe)
        let c = ServerController()
        c.name = name
        c.profile = p
        servers.append(c)
        activeID = c.id
        persist()
        return c
    }

    /// Removes an added server (never the default). Stops it first.
    func removeServer(_ id: UUID) {
        guard let i = servers.firstIndex(where: { $0.id == id }), i != 0 else { return }
        servers[i].stop()
        let wasActive = servers[i].id == activeID
        if servers[i].name == "Laya Decisions" {
            UserDefaults.standard.set(true, forKey: "layaDecisionsServerDeleted")
        }
        servers.remove(at: i)
        if wasActive { activeID = servers[0].id }
        persist()
    }

    func stopAll() { servers.forEach { $0.stop() } }

    func stopAllImmediately() { servers.forEach { $0.stopImmediately() } }

    /// Persists only the added servers (those with their own profile).
    func persist() {
        pendingPersist?.cancel()
        let profiles = servers.compactMap { $0.profile }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    func schedulePersist() {
        pendingPersist?.cancel()
        pendingPersist = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }
}

/// Engine output updates much faster than dashboard state. Keeping it in its own
/// observable prevents every log line from invalidating all server cards.
@MainActor
final class ServerLogBuffer: ObservableObject {
    private(set) var text = ""
    private var notificationPending = false

    func set(_ value: String) {
        text = value
        scheduleNotification()
    }

    func append(_ value: String, limit: Int = 120_000, retained: Int = 80_000) {
        text += value
        if text.count > limit { text = String(text.suffix(retained)) }
        scheduleNotification()
    }

    private func scheduleNotification() {
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self else { return }
            self.notificationPending = false
            self.objectWillChange.send()
        }
    }
}

@MainActor
final class ServerController: ObservableObject {
    let id = UUID()
    @Published var name: String = "Servidor 1"
    /// Per-server config. nil = the default server, which follows the global settings.
    @Published var profile: Profile?

    /// Config this server launches with: the global defaults plus its pinned
    /// fields. A nil pinned list is a pre-0.83 server: full snapshot, as before.
    func effectiveSettings() -> ServerSettings {
        guard let profile else { return .fromDefaults() }
        var s = ServerSettings.fromDefaults()
        if let pinned = profile.pinned {
            s.applyPinned(profile, Set(pinned))
        } else {
            s.apply(profile)
        }
        return s
    }

    enum State: Equatable { case stopped, starting, running, failed(String) }

    @Published var state: State = .stopped
    let logBuffer = ServerLogBuffer()
    var log: String {
        get { logBuffer.text }
        set { logBuffer.set(newValue) }
    }
    @Published var promptSpeed: Double?
    @Published var genSpeed: Double?
    @Published var genHistory: [Double] = []
    @Published var requestCount = 0
    @Published private(set) var startedAt: Date?
    @Published var dflashWarning: DflashRuntimeWarning?
    /// Model whose running engine actually has DFlash engaged, nil otherwise.
    @Published private(set) var activeDflashModelPath: String?
    @Published var dflashAcceptance: Double?

    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var dflashMemoryTask: Task<Void, Never>?
    private var launchedSettings: ServerSettings?
    private var lastStoppedPID: Int32?
    /// After a projector load failure, makes the next launch drop `--mmproj`
    /// (text-only). Reset on every fresh `start()`.
    private var retryWithoutMmproj = false
    private var currentPort = 8080
    private var discoveryService: NetService?
    private var discoveryEnabled = false
    private let fileLog = RotatingFileLog(name: "server.log")
    /// Pre-warm slot 0 across restarts for external clients (VS Code/Cline resend a
    /// fixed 15-19k-token prefix every request). Off for MTP models: the extra KV
    /// breaks slot restore.
    private var prewarmActive = false
    /// Single fixed file for the external-client prefix (not a conversation UUID,
    /// so the chat's orphan-prune leaves it alone).
    static func externalSlotFile(port: Int) -> URL {
        ServerSettings.slotCacheDir(port: port).appendingPathComponent("external.bin")
    }

    var logFileURL: URL { fileLog.fileURL }
    /// Folder with every per-session log file (kept ~3 days), for sharing past runs.
    var logsDirectory: URL { fileLog.directory }

    var serverURL: URL { URL(string: "http://127.0.0.1:\(currentPort)/")! }

    /// Web chat URL carrying the app's language and the real device names, so the
    /// bundled console reports what's in use instead of guessing. English is
    /// the product language (a stale stored "lang" is cleared at launch), so
    /// the console is always asked for English.
    var webChatURL: URL {
        var comps = URLComponents(string: "http://127.0.0.1:\(currentPort)/")!
        var items = [URLQueryItem(name: "lang", value: "en")]
        if let gpu = ServerController.availableGPUs().max(by: { $0.vramMB < $1.vramMB })?.name {
            items.append(URLQueryItem(name: "gpu", value: gpu))
        }
        // Real inference backend, read from the engine's startup log (a custom
        // external build may use Vulkan instead of the bundled Metal engine).
        let backend = log.range(of: "vulkan", options: .caseInsensitive) != nil ? "Vulkan" : "Metal"
        items.append(URLQueryItem(name: "backend", value: backend))
        comps.queryItems = items
        return comps.url!
    }

    /// Cached: the UI reads this from view bodies, and MTLCopyAllDevices() is far
    /// too expensive to run on every render.
    nonisolated static func availableGPUs(rescan: Bool = false) -> [GPUDevice] {
        if !rescan, let cached = gpuCache.withLock({ $0 }) { return cached }
        let devices = MTLCopyAllDevices().enumerated().map { i, dev in
            GPUDevice(index: i, name: dev.name,
                      vramMB: Int(dev.recommendedMaxWorkingSetSize / 1_048_576),
                      isExternal: dev.location == .external,
                      isIntegrated: dev.isLowPower,
                      peerGroupID: dev.peerGroupID,
                      peerCount: Int(dev.peerCount),
                      supportsBF16: dev.supportsFamily(.metal3))
        }
        gpuCache.withLock { $0 = devices }
        return devices
    }

    private nonisolated static let gpuCache = OSAllocatedUnfairLock<[GPUDevice]?>(initialState: nil)

    /// Whether any detected GPU is an external eGPU. Used to surface the
    /// VRAM-resident-weights option, which fixes eGPU slowness over Thunderbolt.
    nonisolated static func hasExternalGPU() -> Bool {
        availableGPUs().contains { $0.isExternal }
    }

    func start(_ settings: ServerSettings) {
        guard state == .stopped || isFailed else { return }
        // The sidecar's kestrel-local entry names the model that is about
        // to load; refresh it so latch never sees a stale model id.
        LatchBridge.sync()
        guard FileManager.default.fileExists(atPath: settings.serverBinary) else {
            let msg = "The llama-server engine was not found at:\n\(settings.serverBinary)\nReinstall Kestrel (it must include Resources/bin/llama-server) or choose another engine in Settings."
            fileLog.append("[start] \(msg.replacingOccurrences(of: "\n", with: " "))")
            state = .failed(msg)
            return
        }
        if settings.localNetworkDiscovery && !settings.apiKeyEnabled {
            // Refusal, not a warning (KES-01): a LAN bind serves the engine —
            // and with agent tools on, exec/write tools — to every host that
            // can reach this Mac, over plaintext HTTP where the key is the
            // only gate. Agent tools previously triggered this refusal; the
            // key is now required for ANY non-loopback bind, tools or not.
            state = .failed(Self.lanWithoutKeyRefusalMessage())
            return
        }
        if settings.routerMode {
            let models = LocalModel.scan(in: ServerSettings.modelsDirectory)
            guard !models.isEmpty else {
                state = .failed("No models downloaded in the models folder")
                return
            }
            if settings.usesTurboKV,
               let incompatible = models.first(where: { !ServerSettings.modelSupportsTurboKV(at: $0.url.path) }) {
                failTurboKV(model: incompatible.url.lastPathComponent)
                return
            }
            if settings.usesTurboValuesWithoutKeys,
               let mla = models.first(where: { ServerSettings.modelUsesMLA(at: $0.url.path) }) {
                failTurboKV(model: mla.url.lastPathComponent)
                return
            }
            if settings.usesUnsupportedTurboQ4Mix {
                failTurboKV(model: "router")
                return
            }
        } else {
            guard FileManager.default.fileExists(atPath: settings.modelPath) else {
                state = .failed("Select a model in the Models tab")
                return
            }
            // TurboQuant weight quants (tq3_1s/tq4_1s) decode to garbage, so refuse
            // rather than serve it.
            if ServerSettings.modelIsTurboQuantWeights(at: settings.modelPath) {
                state = .failed("TurboQuant model not supported: TurboQuant weight quantization (tq3_1s/tq4_1s) produces incorrect output on this engine, for both dense and MoE models. Use a standard-quant model (Q4_K, Q5_K, Q6_K, Q8_0…).")
                return
            }
            if settings.usesTurboKV &&
               (ServerSettings.isAppleSilicon || !ServerSettings.modelSupportsTurboKV(at: settings.modelPath)) {
                failTurboKV(model: URL(fileURLWithPath: settings.modelPath).lastPathComponent)
                return
            }
            if settings.usesTurboValuesWithoutKeys && ServerSettings.modelUsesMLA(at: settings.modelPath) {
                failTurboKV(model: URL(fileURLWithPath: settings.modelPath).lastPathComponent)
                return
            }
            if settings.usesUnsupportedTurboQ4Mix {
                failTurboKV(model: URL(fileURLWithPath: settings.modelPath).lastPathComponent)
                return
            }
        }

        log = ""
        retryWithoutMmproj = false
        promptSpeed = nil
        genSpeed = nil
        genHistory = []
        requestCount = 0
        currentPort = settings.port
        discoveryEnabled = settings.localNetworkDiscovery
        stopDiscovery()
        state = .starting
        startedAt = nil

        // A stopped engine can take seconds to die (SIGTERM mid-generation) and still
        // holds the port meanwhile, so wait for the previous PID before binding.
        let previousPID = lastStoppedPID
        lastStoppedPID = nil
        Task { [weak self] in
            if let pid = previousPID {
                for _ in 0..<24 where kill(pid, 0) == 0 {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            self?.launch(settings)
        }
    }

    private func failTurboKV(model: String) {
        state = .failed("TurboQuant KV is not compatible with \(model) or the selected combination: it requires AMD Metal and heads padded to 128, 256, 384, 512 or 640; on MLA, Turbo values also require Turbo keys; q4_0 cannot be mixed with Turbo.")
    }

    /// KES-01: any non-loopback bind without an API key is refused — LAN
    /// mode is plaintext HTTP, so the key is the only gate between the LAN
    /// and this machine's engine (and its agent tools). Pure and static so
    /// the refusal contract is unit-testable. English only: the product
    /// language is English and the retired language picker's stored "es" is
    /// cleared at launch.
    nonisolated static func lanWithoutKeyRefusalMessage() -> String {
        "Cannot start on the local network: the plaintext HTTP server requires \"Protect the API with a key\". Enable the key in Settings or turn local discovery off."
    }

    /// Header at the top of the server log: version, engine, model, GPUs and the
    /// resolved settings, so a pasted log is debuggable without round-trips.
    nonisolated static func startupBanner(settings: ServerSettings) -> String {
        let engine: String
        engine = settings.serverBinary == ServerSettings.defaultBinary ? "bundled (official)" : "external"
        // Device order changes between boots, so an index alone does not identify a
        // card in a pasted log; the peer group does identify who it is linked to.
        let gpus = availableGPUs().map {
            let peer = $0.peerGroupID == 0
                ? " · no peer group"
                : " · peer group \($0.peerGroupID) (\($0.peerCount) GPUs)"
            return "    [\($0.index)] \($0.name) · \($0.vramGB) GB\(peer)\($0.isExternal ? " · EXTERNAL/eGPU" : "")\($0.isIntegrated ? " · iGPU (not auto-selected)" : "")"
        }.joined(separator: "\n")
        let envKeys = ["GGML_METAL_VRAM_RESERVE_MB",
                       "GGML_METAL_DEVICE_INDEX", "GGML_METAL_DEVICES", "GGML_METAL_DEVICE_LIST",
                       "GGML_METAL_SHARED_BUFFERS_DISABLE", "KESTREL_FA_AMD",
                       "GGML_SCHED_PREFETCH_EXPERTS", "GGML_CPU_NO_REPACK",
                       "KESTREL_MOE_UI", "KESTREL_MOE_MODE", "KESTREL_MOE_SLOTS", "KESTREL_MOE_CPU_BANK",
                       "KESTREL_MOE_SPLIT_BANK", "KESTREL_MOE_SPLIT_RING", "KESTREL_MOE_BOUNDED_STAGE",
                       "KESTREL_MOE_BOUNDED_STAGE_FORCE", "KESTREL_MOE_DOUBLE_BUFFER", "KESTREL_MOE_HOT_MAP",
                       "KESTREL_MOE_HOT_MAP_OUT", "KESTREL_MOE_HOT_MAP_K",
                       "GGML_METAL_NCB",
                       "KESTREL_MGPU_PEER", "KESTREL_MGPU_PEER_DISABLE", "KESTREL_MGPU_EVENTS"]
        let env = settings.environment
        // KES-03: env tokens typed into the free-form Extra arguments field
        // ("OPENAI_API_KEY=sk-…") are credentials. Show their NAMES only —
        // the banner flows into the in-app log and from there into the
        // shareable diagnostics export. argv and env masking both come from
        // the ONE redaction implementation (SecretRedactor); no parallel
        // copies, so a rule improved here improves every surface at once.
        let userKeys = settings.extraArgTokens.env.keys.filter { !envKeys.contains($0) }
        let envLine = SecretRedactor.environmentLine(environment: env, appSetKeys: envKeys,
                                                     userKeys: Array(userKeys))
        let moeLine = settings.effectiveDynamicMoe
            ? "ncmoe=0 dynamic-moe=K\(settings.effectiveDynamicMoeSlots)"
            : "ncmoe=\(settings.ncmoe)"
        var gpuSel = settings.multiGPU ? "split-all" : (settings.gpuIndex >= 0 ? "index \(settings.gpuIndex)" : "default (macOS picks)")
        if settings.isSplitting { gpuSel += " · split-mode \(settings.effectiveSplitMode)" }
        if settings.tensorSplitDowngraded {
            gpuSel += " (tensor needs \(settings.splitDeviceCount) way split of experts this model only divides \(settings.tensorSplitLimit ?? 1) ways)"
        }
        return """
        ========================================================
         Kestrel \(AppInfo.version) — server start (\(ServerSettings.isAppleSilicon ? "arm64" : "x86_64")\(AppInfo.isNoAVX2 ? " · no-AVX2 build" : ""))
         engine : \(engine)
         model  : \(settings.routerMode ? "router (autoload, max \(settings.routerModelsMax) loaded)" : (settings.modelPath as NSString).lastPathComponent)
         GPUs detected:
        \(gpus.isEmpty ? "    (none)" : gpus)
         GPU select: \(gpuSel) | force-VRAM-buffers: \(env["GGML_METAL_SHARED_BUFFERS_DISABLE"] == "1" ? "yes" : "no")
         settings: ngl=\(settings.ngl) \(moeLine) ctx=\(settings.resolvedCtx)\(settings.contextAutomatic ? " (auto)" : "") fa=\(settings.flashAttn) ctk=\(settings.effectiveCacheTypes.k) ctv=\(settings.effectiveCacheTypes.v) cacheRAM=\(settings.cacheRAM)
         dflash : \(settings.routerMode ? "per-model router plan" : settings.dflashPlanSummary)
         env: \(envLine)
         args: \(SecretRedactor.arguments(settings.arguments).joined(separator: " "))
        ========================================================

        """
    }

    private func launch(_ settings: ServerSettings) {
        guard state == .starting else { return }   // user hit Stop meanwhile

        if settings.routerMode {
            let models = LocalModel.scan(in: ServerSettings.modelsDirectory)
            let paths = models.map(\.url.path)
            let ncmoeByPath = Dictionary(uniqueKeysWithValues: paths.map {
                ($0, Estimator.ncmoeForSelection(path: $0, models: models))
            })
            let ini = settings.routerPresetINI(modelPaths: paths, ncmoeByPath: ncmoeByPath)
            let presetURL = ServerSettings.routerPresetPath(port: settings.port)
            do {
                try ini.write(to: presetURL, atomically: true, encoding: .utf8)
            } catch {
                // A failed write would launch against the STALE preset file —
                // the engine would come up serving the wrong models, silently.
                // Fail the launch with the exact cause instead.
                let msg = "No se pudo escribir el preset del router (\(presetURL.lastPathComponent)): \(error.localizedDescription) / could not write the router preset: the engine is not started against a stale model list"
                fileLog.append("[start] \(msg)")
                state = .failed(msg)
                return
            }
        }

        prewarmActive = !settings.routerMode && settings.persistCache && settings.effectiveFaAmd
            && !settings.visionLoaded && !ServerSettings.modelUsesMTP(at: settings.modelPath)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.serverBinary)
        var args = settings.arguments
        if retryWithoutMmproj, let i = args.firstIndex(of: "--mmproj") {
            args.removeSubrange(i ..< min(i + 2, args.count))   // drop "--mmproj <path>"
        }
        p.arguments = args
        p.environment = settings.environment
        launchedSettings = settings
        activeDflashModelPath = args.contains("draft-dflash") ? settings.modelPath : nil
        dflashAcceptance = nil

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        // Snapshot after launch finished mutating args: the Sendable
        // termination handler may not capture the mutable local itself.
        let argsAtLaunch = args
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                // A process we already replaced (stop → start) must not touch
                // the new engine's state, health watch or PID lockfile.
                guard self.process === proc else { return }
                self.healthTask?.cancel()
                self.stopDiscovery()
                EngineLock.remove(pid: proc.processIdentifier)
                // a router that died leaves its model children behind, holding their weights
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    EngineLock.reapStrayEngines()
                }
                if case .failed = self.state { return }
                if proc.terminationStatus == 0 || proc.terminationStatus == 15 {
                    self.state = .stopped
                } else {
                    // A projector that won't load fails the whole launch; retry
                    // once without it so the model still runs text-only.
                    let tail = self.log.suffix(6000).lowercased()
                    let clipFailed = tail.contains("failed to load clip")
                        || tail.contains("unknown projector type")
                        || tail.contains("failed to load multimodal model")
                    if clipFailed && !self.retryWithoutMmproj && argsAtLaunch.contains("--mmproj") {
                        // Don't auto-attach this projector again for this model.
                        if let i = argsAtLaunch.firstIndex(of: "--mmproj"), i + 1 < argsAtLaunch.count {
                            ServerSettings.recordIncompatibleMmproj(model: settings.modelPath, projector: argsAtLaunch[i + 1])
                        }
                        self.retryWithoutMmproj = true
                        EngineLock.remove(pid: proc.processIdentifier)
                        self.consume("\n[Kestrel] el proyector (mmproj) no se pudo cargar — reintentando solo-texto (visión desactivada) / projector failed to load — retrying text-only (vision disabled)\n")
                        self.state = .starting
                        self.launch(settings)
                        return
                    }
                    AppLog.server.error("engine exited with status \(proc.terminationStatus)")
                    self.state = .failed(Self.diagnose(self.log, exitCode: proc.terminationStatus))
                }
            }
        }

        fileLog.startSession()   // new timestamped per-session file, prunes old ones
        consume(Self.startupBanner(settings: settings))
        do {
            try p.run()
            process = p
            EngineLock.add(pid: p.processIdentifier)
            // A fresh engine starts with empty KV slots; tell the chat so it
            // re-restores the active conversation's persisted cache on next turn.
            NotificationCenter.default.post(name: .engineDidStart, object: nil)
            watchHealth(port: settings.port)
        } catch {
            fileLog.append("[start] launch failed: \(error.localizedDescription)")
            state = .failed("No se pudo lanzar: \(error.localizedDescription)")
        }
    }

    /// Maps known engine failure patterns to actionable, bilingual messages.
    static func diagnose(_ log: String, exitCode: Int32) -> String {
        let tail = log.suffix(6000).lowercased()
        if tail.contains("unknown model architecture") || tail.contains("unknown architecture") {
            return "Arquitectura no soportada por este motor / model architecture not supported by this engine"
        }
        if tail.contains("split_mode_tensor not implemented for architecture") {
            return "Esta arquitectura no admite el reparto por tensores: cámbialo a por capas en Ajustes / this architecture has no tensor split: switch to by layers in Settings"
        }
        if tail.contains("address already in use") || tail.contains("couldn't bind") {
            return "Puerto ocupado: cambia el puerto en Ajustes / port busy: change it in Settings"
        }
        // A refused block does not necessarily mean total memory is exhausted.
        if tail.contains("failed to allocate buffer, size =") {
            // Graph tensors cannot be split by the weight-buffer cap.
            if tail.contains("ggml_gallocr_reserve") {
                return "La tarjeta rechazó un bloque de memoria del grafo: reduce el contexto, y si el modelo tiene visión baja el tope de tokens por imagen / the card refused a graph memory block: reduce context, and lower the image token cap if the model has vision"
            }
            return "La tarjeta rechazó un bloque de memoria demasiado grande: reduce el contexto, o arranca con KESTREL_METAL_MAX_BUFFER_MB=1024 para repartirlo / the card refused a single oversized memory block: reduce context, or start with KESTREL_METAL_MAX_BUFFER_MB=1024 to split it"
        }
        if tail.contains("out of memory") || tail.contains("failed to allocate")
            || tail.contains("insufficient memory") || tail.contains("kiogpucommandbuffercallbackerroroutofmemory") {
            return "Memoria insuficiente: sube 'Expertos MoE en CPU' o reduce el contexto / out of memory: raise 'MoE experts on CPU' or reduce context"
        }
        if tail.contains("quantized v cache") {
            return "El KV cuantizado requiere Flash Attention: activa el kernel AMD o usa FA estándar / quantized KV requires Flash Attention: enable the AMD kernel or use standard FA"
        }
        // The tensor named in the abort says whether it is the projector or the model itself.
        if tail.contains("pre-allocated tensor") && tail.contains("cannot run the operation") {
            return tail.contains("pre-allocated tensor (v.")
                ? "El proyector de visión usa un formato que esta tarjeta no ejecuta (normalmente BF16): descarga el mmproj en F16 / the vision projector uses a format this card cannot run (usually BF16): download the F16 mmproj"
                : "Un tensor del modelo usa un formato que esta tarjeta no ejecuta (normalmente BF16): usa un GGUF en F16 o cuantizado / a model tensor uses a format this card cannot run (usually BF16): use an F16 or quantized GGUF"
        }
        // The engine's own wording. Matching a bare "mtp" also matched every file named -MTP-.
        if tail.contains("doesn't contain mtp layers") || tail.contains("failed to create mtp context") {
            return "Este modelo no trae cabezal MTP: descarga la variante -MTP- / model has no MTP head: download the -MTP- variant"
        }
        if tail.contains("invalid ggml type") || tail.contains("should be in [0,") {
            return "Cuantización no soportada por el motor (formato de un fork): usa un GGUF con quant estándar (Q4_K_M, Q8_0, Q2_0_g64…) / quantization not supported by the engine (a fork's format): use a GGUF with a standard quant (Q4_K_M, Q8_0, Q2_0_g64…)"
        }
        // Prism ML models store rotated weights; a transform this engine does not know would
        // load and answer with garbage, so the engine refuses it instead
        if tail.contains("prism.hadamard") || tail.contains("Hadamard") {
            return "El modelo pide una rotación de Hadamard que este motor no admite: usa otra versión del GGUF / the model asks for a Hadamard rotation this engine does not support: use another build of the GGUF"
        }
        if tail.contains("invalid magic") || tail.contains("failed to load model")
            || tail.contains("error loading model") {
            return "Modelo dañado o incompleto: vuelve a descargarlo / model file damaged or incomplete: re-download it"
        }
        if exitCode == SIGILL {
            return AppInfo.isNoAVX2
                ? "Instrucción ilegal (SIGILL): este CPU no soporta el motor — reporta tu modelo de CPU en GitHub / illegal instruction (SIGILL): this CPU can't run the engine — report your CPU model on GitHub"
                : "Instrucción ilegal (SIGILL): este CPU no soporta AVX2 — instala la versión no-AVX2 del release / illegal instruction (SIGILL): this CPU lacks AVX2 — install the no-AVX2 build from the release"
        }
        return "El motor terminó con código \(exitCode) — revisa el registro en Ajustes / engine exited with code \(exitCode) — see the log in Settings"
    }

    /// Router mode spawns one child engine per loaded model. They hold the weights
    /// (mlock'd), so a survivor keeps the RAM until it is killed by hand.
    nonisolated static func reapChildren(of parent: pid_t) {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(parent)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let kids = String(decoding: out, as: UTF8.self)
            .split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        guard !kids.isEmpty else { return }
        for kid in kids { kill(kid, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            for kid in kids where kill(kid, 0) == 0 { kill(kid, SIGKILL) }
        }
    }

    /// SIGKILL escalation shared by the engine-kill paths: `terminate()` was
    /// already sent; if the child ignores it past the grace period, take the
    /// process down and sweep the router's orphaned model children. Detached
    /// with a structured sleep (the same shape as the latch budget's
    /// escalation) so the caller's own verdict never waits on the grace
    /// period.
    nonisolated static func escalateKill(pid: pid_t, after grace: TimeInterval) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(grace))
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            EngineLock.reapStrayEngines()
        }
    }

    func stop() {
        AudioStudioController.shared.shutdown()
        SpeechDictationController.shared.shutdown()
        AppleSpeechDictationController.shared.shutdown()
        healthTask?.cancel()
        dflashMemoryTask?.cancel()
        activeDflashModelPath = nil
        dflashAcceptance = nil
        stopDiscovery()
        if let p = process {
            Self.reapChildren(of: p.processIdentifier)
            let pid = p.processIdentifier
            lastStoppedPID = pid
            // Drop this engine's PID now: once process is niled below, the termination
            // handler's guard skips its own removal.
            EngineLock.remove(pid: pid)
            let prewarm = prewarmActive
            let port = currentPort
            // SIGKILL fallback in case the deferred terminate stalls: the engine's
            // working set has to be freed.
            Self.escalateKill(pid: pid, after: 6)
            if prewarm {
                // Snapshot slot 0 to disk before killing the engine, so the next
                // launch can restore the fixed external-client prefix. Best-effort,
                // bounded; terminate runs even if the save fails or times out.
                Task.detached {
                    await ServerController.slotAction("save", port: port,
                                                      file: ServerController.externalSlotFile(port: port).lastPathComponent)
                    p.terminate()
                }
            } else {
                p.terminate()
            }
        } else if let pid = lastStoppedPID {
            EngineLock.remove(pid: pid)
        }
        process = nil
        state = .stopped
        startedAt = nil
    }

    /// Quitting: the engine must be signalled inline, since a detached task does
    /// not outlive the process.
    func stopImmediately() {
        AudioStudioController.shared.shutdown()
        SpeechDictationController.shared.shutdown()
        AppleSpeechDictationController.shared.shutdown()
        healthTask?.cancel()
        dflashMemoryTask?.cancel()
        activeDflashModelPath = nil
        dflashAcceptance = nil
        stopDiscovery()
        defer { process = nil; state = .stopped }
        guard let p = process else {
            if let pid = lastStoppedPID { EngineLock.remove(pid: pid) }
            return
        }
        let pid = p.processIdentifier
        lastStoppedPID = pid
        Self.reapChildren(of: pid)
        EngineLock.remove(pid: pid)
        if prewarmActive {
            Self.slotSaveBlocking(port: currentPort,
                                  file: Self.externalSlotFile(port: currentPort).lastPathComponent,
                                  timeout: 10)
        }
        p.terminate()
        var waited = 0
        while p.isRunning && waited < 20 {
            usleep(100_000)
            waited += 1
        }
        if p.isRunning { kill(pid, SIGKILL) }
    }

    /// Restart with new settings, if currently up. Waits (bounded) for the old
    /// engine to exit so the relaunch doesn't race it for the port.
    func restart(_ settings: ServerSettings) {
        guard state == .running || state == .starting else { return }
        stop()
        Task { @MainActor in
            for _ in 0..<40 {
                guard let pid = lastStoppedPID, kill(pid, 0) == 0 else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            start(settings)
        }
    }

    /// POST /slots/0?action=save|restore (best-effort, short timeout). Used to
    /// pre-warm the external-client prefix across engine restarts.
    nonisolated static func slotAction(_ action: String, port: Int, file: String) async {
        // 30 s: a save flushes the whole slot KV through loopback to disk.
        guard let req = EngineHTTP.slotRequest(port: port, action: action,
                                               filename: file, timeout: 30) else { return }
        _ = try? await EngineHTTP.session.data(for: req)
    }

    /// Same request on the way out, where an await would never resume. Bounded so
    /// a busy engine cannot hold the quit open.
    nonisolated static func slotSaveBlocking(port: Int, file: String, timeout: TimeInterval) {
        guard let req = EngineHTTP.slotRequest(port: port, action: "save",
                                               filename: file, timeout: timeout) else { return }
        let done = DispatchSemaphore(value: 0)
        let task = EngineHTTP.session.dataTask(with: req) { _, _, _ in done.signal() }
        task.resume()
        if done.wait(timeout: .now() + timeout) == .timedOut { task.cancel() }
    }

    /// Restore the saved external-client prefix into slot 0 (only if a file exists).
    private func restoreExternalSlot(port: Int) async {
        guard prewarmActive,
              FileManager.default.fileExists(atPath: Self.externalSlotFile(port: port).path) else { return }
        await Self.slotAction("restore", port: port, file: Self.externalSlotFile(port: port).lastPathComponent)
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    private func watchHealth(port: Int) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            var urlComponents = URLComponents()
            urlComponents.scheme = "http"
            urlComponents.host = "127.0.0.1"
            urlComponents.port = port
            urlComponents.path = "/health"
            guard let url = urlComponents.url else { return }
            for _ in 0..<150 {   // up to ~5 min for large models
                if Task.isCancelled { return }
                // The engine answers {"status":"ok"} — parse it exactly. A
                // substring check flipped a port collision with any foreign
                // service whose body happened to contain "ok" into "running".
                // Control session: a wedged engine fails this probe in 10 s
                // instead of stalling the 2 s poll loop for a minute.
                if let (data, response) = try? await EngineHTTP.session.data(from: url),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let body = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   body["status"] == "ok" {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.state = .running
                        self?.startedAt = Date()
                        self?.startDiscoveryIfNeeded(port: port)
                        self?.startDflashMemoryCheck()
                    }
                    // Pre-warm slot 0 with the last session's prefix so an external
                    // client's first request skips the multi-minute cold prefill.
                    await self?.restoreExternalSlot(port: port)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            await MainActor.run {
                self?.state = .failed("El servidor no respondió al health check / the server did not answer the health check — see the log in Settings")
                self?.stopDiscovery()
                if let p = self?.process {
                    let pid = p.processIdentifier
                    // Record the PID like stop() does: a restart must wait for
                    // this engine to release the port instead of racing it.
                    self?.lastStoppedPID = pid
                    Self.reapChildren(of: pid)
                    p.terminate()
                    Self.escalateKill(pid: pid, after: 6)
                }
            }
        }
    }

    private func startDflashMemoryCheck() {
        dflashMemoryTask?.cancel()
        guard let settings = launchedSettings,
              settings.arguments.contains("draft-dflash") else { return }
        let monitoredGPUIndices = settings.selectedGPUIndices
        dflashMemoryTask = Task { [weak self] in
            var peak: GPUStat?
            var fractions: [Double] = []
            for _ in 0..<8 {
                if Task.isCancelled { return }
                let allStats = await Task.detached(priority: .utility) { VRAMMonitor.snapshot() }.value
                let selectedStats = allStats.filter { monitoredGPUIndices.contains($0.id) }
                let stats = selectedStats.isEmpty ? allStats : selectedStats
                if let sample = stats.max(by: { $0.fraction < $1.fraction }) {
                    fractions.append(sample.fraction)
                    if let current = peak {
                        if sample.fraction > current.fraction { peak = sample }
                    } else {
                        peak = sample
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, let peak else { return }
            if peak.fraction >= 0.90 {
                consume("\n[Kestrel] DFlash runtime VRAM peak: \(Int(peak.fraction * 100))% (\(Int(peak.usedMB)) / \(Int(peak.totalMB)) MiB)\n")
            }
            guard DflashPolicy.shouldWarn(fractions: fractions) else { return }
            let signature = dflashWarningSignature(settings: settings)
            let acknowledged = UserDefaults.standard.stringArray(
                forKey: SettingsKeys.dflashWarningAcknowledged) ?? []
            guard !acknowledged.contains(signature) else { return }
            dflashWarning = DflashRuntimeWarning(
                modelPath: settings.modelPath,
                usedGB: peak.usedMB / 1024,
                totalGB: peak.totalMB / 1024,
                fraction: peak.fraction)
        }
    }

    private func dflashWarningSignature(settings: ServerSettings) -> String {
        let ngld = settings.arguments.firstIndex(of: "-ngld").flatMap {
            settings.arguments.indices.contains($0 + 1) ? settings.arguments[$0 + 1] : nil
        } ?? "none"
        let gpus = settings.selectedGPUIndices.sorted().map(String.init).joined(separator: ",")
        return "\(settings.modelPath)|\(settings.ctx)|\(settings.ncmoe)|\(settings.cacheTypeK)|\(settings.cacheTypeV)|\(ngld)|gpus=\(gpus)"
    }

    func acknowledgeDflashWarning() {
        guard let settings = launchedSettings else { dflashWarning = nil; return }
        let signature = dflashWarningSignature(settings: settings)
        var acknowledged = UserDefaults.standard.stringArray(
            forKey: SettingsKeys.dflashWarningAcknowledged) ?? []
        if !acknowledged.contains(signature) { acknowledged.append(signature) }
        UserDefaults.standard.set(acknowledged, forKey: SettingsKeys.dflashWarningAcknowledged)
        dflashWarning = nil
    }

    func useAutomaticDflashAndRestart() {
        guard let settings = launchedSettings else { dflashWarning = nil; return }
        ServerSettings.setDflashMode(.auto, forModel: settings.modelPath)
        dflashWarning = nil
        restart(effectiveSettings())
    }

    func disableDflashAndRestart() {
        guard let settings = launchedSettings else { dflashWarning = nil; return }
        ServerSettings.setDflashMode(.off, forModel: settings.modelPath)
        dflashWarning = nil
        restart(effectiveSettings())
    }

    private func startDiscoveryIfNeeded(port: Int) {
        guard discoveryEnabled else { return }
        stopDiscovery()
        let service = NetService(domain: "local.", type: "_http._tcp.", name: "Kestrel API", port: Int32(port))
        var txt: [String: Data] = [
            "path": Data("/v1".utf8),
            "protocol": Data("openai-compatible".utf8),
        ]
        // Advertise protection only when it exists; never broadcast
        // "auth: none" to the LAN (KES-02).
        if UserDefaults.standard.bool(forKey: SettingsKeys.apiKeyEnabled) {
            txt["auth"] = Data("bearer".utf8)
        }
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        discoveryService = service
    }

    private func stopDiscovery() {
        discoveryService?.stop()
        discoveryService = nil
    }

    private func consume(_ text: String) {
        logBuffer.append(text)
        fileLog.append(text)

        for line in text.split(separator: "\n") {
            if line.contains("draft acceptance ="),
               let m = line.range(of: #"draft acceptance = ([0-9]+\.[0-9]+)"#, options: .regularExpression) {
                dflashAcceptance = Double(line[m].split(separator: "=")[1].trimmingCharacters(in: .whitespaces))
            }
            guard line.contains("tokens per second"), line.contains("eval time") else { continue }
            guard let match = line.range(of: #"([0-9]+\.[0-9]+) tokens per second"#, options: .regularExpression) else { continue }
            let value = Double(line[match].split(separator: " ")[0]) ?? 0
            if line.contains("prompt eval") {
                promptSpeed = value
            } else {
                genSpeed = value
                genHistory.append(value)
                if genHistory.count > 60 { genHistory.removeFirst() }
                requestCount += 1
            }
        }
    }
}
