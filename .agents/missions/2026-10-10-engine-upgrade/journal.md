# Journal

- 2026-10-10 09:40 Step 0. Committed the completed tosh→kestrel rename (1dbd949, 51 files,
  tree clean afterwards). `~/toshllm-study` verified a pure clone at the 0.87.9 release commit
  (only untracked: STRUCTURAL_MAP.md, latch-demo.txt, .agents/) and moved to
  `~/.Trash/toshllm-study-20261010-095053`. Note: the 3 "tosh" grep hits left in Sources/ are
  the word "Hackintosh" — the rename is genuinely complete in code.
- 2026-10-10 09:55 Baseline on the 5500M (Spark-X2.5-1.7B-Q8_0, -ngl 99): pp512 1013.30 t/s,
  tg128 55.15 t/s, build 957538960 (b11141), Kestrel engine 0.88.0. Smoke (temp 0): "The
  capital of France is Paris." — coherent. Recorded in baseline-llama-bench.txt.
- 2026-10-10 10:05 Ran scripts/check-patch-series.sh aa94f20861 → 43/92 clean, 0 three-way,
  49 fail / 121 hunks (report: check-llama-vs-aa94f2.md). "What moved" shows structural
  collisions: 5a75f14c0 (FA per-dtype libraries), llama_batch_ext migration (#24669/#29601/#29385),
  upstream MoE-cache-over-multi-GPU (#30112) and GPU-side expert cache (#29887) overlapping
  kestrel-moe territory. A straight port is re-authoring, not repair → out of cycle scope.
- 2026-10-10 10:20 strict-apply-check.sh (first-failure, plain apply — the build's own bar)
  bisects the 408-commit window: fail at #102 (09-29), fail at #51-ish back to the pin+1.
  Frontier: **cdc06426e clean; 84e76d8a2 breaks 0002 in ggml-metal-context.m (its #29390
  graph-capture change)**. cdc06426e = sparse FA optimize (#29377), directly relevant to AMD
  prefill. Pin moved 9575389609 → cdc06426e (+31).
- 2026-10-10 10:35 whisper: v1.9.5 (d2a764c6) switched ggml-metal to the kernels/ layout —
  shared-metal/0001-* targets the monolithic ggml-metal.metal, so v1.9.3 stays until the
  shared backend is ported to kernels/ once (that port also collapses shared-metal into the
  llama series).
- 2026-10-10 10:45 sd.cpp: window 6dcb5bb..origin/master = 63 commits; ggml submodule gitlink
  leaves the current 4bf5f600 (old layout) after 30 commits; within those, sd-dry-run.sh
  (exact build sequence incl. the 4-expected-rejects assertion and both landing asserts)
  narrows to **241518b clean; e6281b6 (conditioning cache, #2034) breaks image/0049 in
  diffusion_engine.cpp**. Pin moved 6dcb5bb → 241518b (+7). Dry-run landed the full sequence
  including the reject-set assertion.
- 2026-10-10 10:55 Pins committed to scripts/build-engines.sh with frontier comments;
  patches/README.md gained the "Upstream frontier" section; CHANGELOG [Unreleased] gained the
  Changed entry. Engine rebuild started at the new pins (build-engines.log).
- 2026-10-10 11:05 Rebuild finished clean at the new pins (llama, whisper, sd; build log in
  this folder — the scripted reject-set and landing asserts all passed during it). 5500M bench
  at cdc06426e: pp512 1023.53 ± 0.36, tg128 55.86 ± 0.46 — +1.0%/+1.3% over baseline, no
  regression (newpin-llama-bench.txt). Smoke output byte-identical to baseline. Engines: done.
- 2026-10-10 11:20 Swift 6 wave. Package.swift 5.9 → 6.0 (Swift 6 language mode, macOS 14
  floor kept). First inventory: 206 error lines, then a clang-class IRGen crash
  ("SmallVector unable to grow, 2^32+1") that masked the tail. Fixed in order, each verified
  by rebuild: 7 View Equatable `==` → nonisolated (Equatable conformance crossing MainActor);
  every NSLock'd static cache → OSAllocatedUnfairLock (Support Keychain + LocalSecretStore,
  InferenceRoutes keyCache, ModelTraitsCache, GGUFMetadata triple→one CacheState, ModelName,
  Server cachedDefaultBinary/gpuCache) — two become nonisolated lets because their enum is
  MainActor-isolated; Stats MTLDevice list → @unchecked Sendable box (documented);
  FormattedTextCache → @unchecked Sendable (internals already locked); AppleSpeechDictation
  liveRequest keeps nonisolated(unsafe) with the safety argument written down (only the
  audio-tap thread touches append(), documented thread-safe). The pipe-pump local-var+NSLock
  patterns → locked state classes (PiDelegateService PumpState, LatchDelegateService
  PumpState, ChatNative latch streamedText → lock box — that one also fixes a genuinely
  unfenced cross-thread read the old comment admitted); URLSession disposition callback →
  semaphore + MainActor verdict so the non-Sendable completionHandler never crosses;
  MCP transport gains MCPResponse @unchecked Sendable so JSON payloads cross actor/task
  boundaries; SubtitleVideoExporter helpers de-asynced (sync calls don't send) with the
  format descriptions preloaded once; EngineChecker onFinish → @MainActor closure (implicitly
  Sendable); Server launch terminationHandler snapshots args before capture.
- 2026-10-10 12:05 remaining blocker is the IRGen crash, NOT code: bisect by stubbing every
  large SettingsTab body showed the crash vanish when bodies were stubbed and return when
  restored — but no single body is the trigger, and the crashing file moved (SettingsTab →
  DashboardTab → SettingsTab) as unrelated errors were fixed. Conclusion: cumulative
  module-level overflow in CLT Swift 6.3.3.1's debug IRGen under Swift 6 mode, not a code
  defect. The two big-builder splits (SettingsTab settingsForm into per-destination views,
  DashboardTab serverCard into picker+disclosure) are kept as real refactors. Gates moved to
  the toolchains that matter: release build (what make-app ships) and CI's Xcode 26 Swift.
- 2026-10-10 12:40 Resolution: with v6 mode the crash also hits release IRGen, so the mode
  is staged — targets build as Swift 5 + StrictConcurrency (upcoming feature) with the full
  v6 debt already paid; the flip to .v6 is two lines in Package.swift, documented there.
  Release build completes (303 s) and make-app assembles the app through the Swift stage.
  Local assembly then stops at "image-engine default.metallib is required": this machine has
  no Metal shader toolchain (xcrun metal fails under CLT-only; it ships with Xcode), which is
  the pre-existing reason dist/Kestrel.app was a dev-relic — full assembly belongs to CI's
  macos-26 runners. Engine binaries are correct with embedded Metal source (slower first
  model load only).
- 2026-10-10 12:45 Branch swift6-engine-upgrade pushed, PR #5 opened to let CI's Xcode 26
  toolchain arbitrate v6 mode. First CI round failed at startup — GitHub billing
  ("recent account payments have failed or your spending limit needs to be increased"),
  not code. With billing fixed the PR's Build job both arbitrates the crash and assembles
  the app.
