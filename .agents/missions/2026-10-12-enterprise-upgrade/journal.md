# Journal

- 2026-10-12 (Xlaunch session) Orientation. Repo found at `/Users/admin/KimiK3_Nvidia/Kestrel-AIEngine`
  (canonical: only source copy; `~/kestrel-driver-r1` holds stub-latch/stub-pi driver harnesses,
  `~/Downloads/Kestrel-v0.88.0.dmg` is an old artifact). main @ bf5f1ae (0.89.2), tree clean,
  CI green (Build, CodeQL, Translations all success on the latest push), release v0.89.2 published.
- Diagnosis evidence gathered: `swift build` green (22.56s); `swift test` exits 1 (`no such module
  'XCTest'`) — CLT-only machine, no /Applications/Xcode.app; `import Testing` also unavailable
  (scratch probe /tmp/swtest); scripts/test.sh hard-fails by design; live engine log today shows
  `request (70871 tokens) exceeds the available context size (65536)`; security assessment
  2026-10-10 re-read through KES-05 (Highs: KES-01 LAN plaintext/no-key, KES-03 diagnostics
  argv leak); due-diligence context-spill measurements (0.99 vs 20.03 tok/s) confirmed as the
  documented root cause of the "models not working" reports.
- Step 0 complete: `UPGRADE_REPORT.md` written at repo root, plan.md + journal.md here.
- Step 1 complete. Operator chose maximum scope on all four questions: FULL security
  sweep (all 13 findings), agentic wave = BOTH (built-in loop + latch ownership), test pipeline =
  INSTALL XCODE (also unlocks local Metal/DMG assembly), engines = FULL re-authoring push.
  AMENDMENT 1: mission is explicitly multi-session; step budget raised to ≤ 40 steps by scope
  decision (still hard-stop at 2x). Xcode probe: no mas/xcodes installed; every install path
  needs Apple ID auth — surfaced to the operator as the one manual step; code waves proceed
  meanwhile (CI arbitrates tests).
- Step 2 (wave A) shipped as 115b38c, pushed to main: KES-01 (LAN requires key, any non-loopback
  bind), KES-03 (DiagnosticsExport reuses redactArguments; tests), KES-04 (engine key via
  --api-key-file, never argv), KES-02 (Bonjour never advertises auth:none), Settings copy
  honesty. swift build green. CI: Build & Release success; Translations FAILED (new strings not
  in template) → fixed by extract-strings.py + sync-translations.py; CodeQL in progress.
- Step 3 (wave B) implemented locally: KES-05 (session-scoped consent, shell excluded,
  legacy sweep + ToolConsentTests), KES-06 (SettingsArchive.processSpawningSummary +
  confirmationDialog + ImportSafetyTests), KES-07 (ChatStore.neutralizedWorkingDirectories),
  KES-08 (receiver token → LocalSecretStore with migration; settings field binds the store),
  KES-09 (updater fail-closed: checksum mandatory, codesign verify + team match, no quarantine
  strip), KES-10 (secrets/ dir 0700), KES-11 (build-engines.sh refuses env-overridden pins in
  CI), KES-11/13/14 (advisory-triage section in patches/README.md). KES-12 is a documented
  non-finding (CVE misattribution), no action.
- Remaining risk-accepted design items (recorded, not silently dropped): web-UI per-session token
  (engine-served UI cannot be tokenized client-side; key requirement covers the exposure);
  TLS for LAN mode (engine supports --ssl-key-file; design decision for a follow-up);
  endpoint-change confirmation for the memory-archive URL (local-write-only attack surface;
  posts are attributable). pi delegate prompts still ride argv (pi interface question; goes to
  the agentic wave).

- 2026-10-12 21:30 SESSION BOUNDARY (Xlaunch session 1). CI arbitration complete:
  Build & Release SUCCESS on b126aa2 — `swift test` green in CI including the new
  SecretRedactionTests, ToolConsentTests, ImportSafetyTests (the first CI round caught one
  actor-isolation error in the KES-07 helper — fixed nonisolated, re-run green; the translation
  status-table gate caught two process misses — scripts/translation-status.py is the third
  script after extract-strings + sync-translations; auto-sync hook now enabled via
  git config core.hooksPath scripts/hooks). CodeQL in progress on the final commit (passed on
  the pre-session tree; these waves only narrow exposure).
  Commits this session: 115b38c (wave A), 6b33d9d (wave B), c9a94c3 + b126aa2 (gates).
- Step 5 investigation notes for the next session (context-trap extinction):
  * `contextAutomatic` confirmed display-only: stored at Server.swift:79, read only in
    fromDefaults (:805), never consulted by the launch path; Settings "Auto" writes 16384.
  * Reusable solver already exists: `ServerController.routerCtx(forModel:requested:ncmoe:
    kvScale:reserveMB:)` (Server.swift:409) halves the window until weights+compute+KV fit
    VRAM — generalize it to the single-model launch path and surface the chosen value in the
    startup banner + Dashboard.
  * Pre-send guard placement: ChatStore.send (ChatNative.swift:741) appends the user message
    then calls stream(into:) (:1047); pi/latch branch off inside stream, so the guard belongs
    after those branches on the engine/remote request assembly, estimator = chars/4 over
    system + wireContent, refuse with a bilingual notice when estimate + maxTokens + 256 >
    window (today's live failure: 70,871 tokens vs 65,536 in
    ~/Library/Application Support/Kestrel/logs/server-2026-10-12_11-32-28.log).
  * Auto-compact exists (compactIfNeeded :2212, fires >70% of ctx from engine-reported
    contextUsed) but only AFTER a completed exchange — a single huge paste still overflows;
    the pre-send guard covers exactly that hole.
- Step 4 (Xcode) still awaits the operator's Apple ID auth; no mas/xcodes on the machine.
  Steps 6 (agentic: loop upgrades + latch ownership) and 7 (engine series re-authoring)
  unstarted, per plan.

- 2026-10-12 22:10 SESSION BOUNDARY (Xlaunch session 2). Step 5 SHIPPED as f8a3e63, CI green
  (Build & Release incl. ContextTrapTests, Translations; CodeQL ran clean through the wave):
  ServerSettings.resolvedCtx (routerCtx solver generalized to the single-model launch), banner/
  Dashboard/estimate show the resolved window, picker keeps the configured ceiling, chat meter +
  compaction + slow-generation heuristics read the real window, pre-send over-window guard with
  bilingual notice in stream()'s engine branch (remote exempt). Routing note: solver reuse was T1
  with one T2 judgment (ceiling semantics); guard thresholds kept conservative (estimate +
  maxTokens + 256 > window).
- Step 6 slice 1 SHIPPED as 888b36c, CI green: transient-only tool retries (read-only tools,
  writesData-driven, 300ms/1.2s backoff, isTransient pure+tested) and the conversation usage
  rollup (roadmap 6: turns, generated sum, peak window) surfaced next to the context meter.
  Routing: retry-classification design was T2 (side-effect safety), implementation T1.
- Step 6 remaining scope, next session: (a) LATCH OWNERSHIP — latch's provider config lives at
  ~/.latch/v2/provider_config.json with credentials.json beside it; the pi pattern to copy is
  PiBridge.swift (generate from Settings → Providers on launch + every route change, import-once
  for hand-authored files, refuse-with-notice on missing pair). Read bot-config.v3.json for
  shape before writing the generator. (b) structured tool schemas, (c) dynamic tool-context
  budget, (d) tool-call visualization upgrades. Step 7 (engines re-authoring) unstarted; begin
  from patches/README.md's frontier notes + scripts/check-patch-series.sh.
- Xcode still absent locally (operator step); all verification remains CI-arbitrated.
