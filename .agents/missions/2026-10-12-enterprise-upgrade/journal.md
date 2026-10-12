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
