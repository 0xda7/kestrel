# Journal — engine-audit-legacy-rename (2026-10-05/06)

## Step 1 — Recon
- Pipeline: `scripts/build-engines.sh` resets `vendor/llama.cpp` to pin `957538960` and
  applies `patches/llama/*.patch` in name order; the vendor working tree is an artifact,
  the patch series is the source of truth. `patches/diag/` = manual diagnostics; `reference/`
  = archive (its README says so).
- Naming surface found (case-complete): lowercase `kestrel_*` C symbols + hyphenated
  `legacy-moe/` dir & `test-legacy-moe-cache` target in patches; uppercase `KESTREL_*` ONLY in
  Tests; Sources/scripts/CI already `KESTREL_*`.
- Trap found: `rg '\b[tT]osh'` is case-sensitive → matches `legacy`/`legacy`, never `uppercase legacy tokens`.
  All inventories were redone case-complete.

## Step 2 — Audits (3 read-only subagents)
- Swift sources: 16 modules mapped; top risks = self-update installs on missing checksum
  (Updates.swift:105-119), unverified model downloads when HF metadata absent
  (Models.swift:313-316), restart port-race + bare `kill(pid,0)` PID reuse
  (Server.swift:2243/1973/2239), API key on argv (Server.swift:381), stall watchdog stops
  wrong instance (ChatNative.swift:1947). All tests logic-only — safe, no GPU.
- Build/packaging: icon-1024.png is gitignored and `icon-gen.swift` is wired to nothing;
  `rebrand-webui.sh` icon/SW-revision branch therefore never runs in the pipeline; CI
  publishes ad-hoc-signed releases without failing; updater strips quarantine without
  signature continuity check; local make-app ships engine-less app on a warning.
- Patch series: 92 patches mapped into 8 areas; env knob inventory (~185 KESTREL_*);
  risk scan (seq_round static, host-wrap eviction vs in-flight reads, silent-numerics
  knobs). `reference/pending/0071` documents unapplied zero-alloc work.

## Steps 3-4 — Rename executed
- Repo: 44 files (40 patches + patches/README.md + 3 Tests files), 850 lines, pure
  one-for-one rename (lowercase, uppercase and title-case legacy tokens renamed one-for-one to kestrel), Macintosh excluded
  via lookbehind. Vendored tree: 205 files, `legacy-moe/`→`kestrel-moe/`,
  `test-legacy-moe-cache.cpp`→`test-kestrel-moe-cache.cpp`.
- Left as history per CHANGELOG.md:55 policy: CHANGELOG.md past releases,
  docs/ENHANCEMENT-DUE-DILIGENCE.md `dev.engel.kestrel` deleted-domain note, .agents/,
  reference/.

## Step 5 — Gates
- shared-hunks sha: captured before/after (tool hashes one patch's Metal hunks; not a
  cross-file equality check — lockstep preserved by identical transform on both series).
- check-patch-series vs pin: **92/92 apply cleanly, 0 fail**.
- `swift build`: **exit 0** (Build complete).
- `swift test`: **not runnable on this machine** — CLT lacks XCTest, no Xcode.app
  installed; `scripts/test.sh` documents the same requirement. CI runs it. Compensating
  static gate: every `KESTREL_*` key asserted in Tests is set in Sources (22 set /
  9 asserted; only opt-in gates KESTREL_AUDIO_VIDEO_FIXTURE, KESTREL_META_PROMPT_LIVE
  unset-by-design).
- Engine rebuild from renamed patches: `SKIP_WHISPER=1 SKIP_IMAGE=1 build-engines.sh`
  — running (llama only; whisper/image share identically-renamed shared-metal hunks).
  Pending: compile `test-kestrel-moe-cache` target.

## Step 6 — Latch solutions sweep (Pi agent / LLM Space)
- Latch Harness 3.14.3 (~/Desktop/latch): NOT PRESENT (zero hits, zero commits).
- Latch Orchestrator 1.0.2: NOT PRESENT.
- Installed Latch.app 3.14.3: NOT PRESENT.
- Kestrel v0.88.0: INTEGRATED — `Sources/Chat/PiDelegateService.swift` + send-path wiring,
  committed 2026-10-04 (`d3ba19e`), on main/pushed.
- northlatch-stack: pi agent profile INTEGRATED (agents/profiles/pi.json, verified
  2026-09-03 vs pi 0.84.4).
- Standalone LLM Space.app 4.19.1 + `/usr/local/bin/pi` exist as independent installs.
- => The Pi agent (LLM Space) integration lives in Kestrel (and northlatch-stack), NOT in
  the Latch harness/orchestrator solutions.

## Step 5, wave 2 — CORRECTION: underscore-embedded identifiers were missed
- Post-build `nm` of llama-server still showed 30 legacy symbols
  (`ggml_metal_kestrel_topk_moe_fusion`, `g_kestrel_prof`, `common_kestrel_version`…). Root cause:
  BOTH the inventory scans (`\b[tT]osh`) and the wave-1 rename (`(?<![A-Za-z0-9_])legacy`)
  required a word boundary BEFORE `legacy`, so every `xxx_kestrel_yyy` identifier survived
  scan *and* rename. The "tree clean" verification was false comfort from a blind pattern.
- Fix: second pass with `(?<![A-Za-z0-9])legacy` (underscore allowed before, alphanumerics
  still excluded so "Macintosh" and Kotlin `toShort()` stay untouched): 55 more files
  (patches + Tests + vendor/llama.cpp), whisper/SD `ggml-metal-device.m` trees synced too.
- Re-verified: 92/92 apply cleanly; 57 TUs recompiled; **nm of all five binaries:
  kestrel 505/505/505/503/60, legacy 0 everywhere.** `swift build` green. Lesson recorded:
  symbol-rename scans must be case-complete AND underscore-aware.

## Variance / notes
- Two Latch-sweep subagent attempts failed (concurrency limit, then quota); third succeeded.
- Mid-mission operator addition (Latch sweep) was planned as step 6, not silently expanded.
- Nothing installed to /Applications; running app untouched.
- `swift test` remains CI-only on this machine (CLT lacks XCTest, no Xcode.app —
  pre-existing; `scripts/test.sh` documents it). Static key cross-check passed instead.
