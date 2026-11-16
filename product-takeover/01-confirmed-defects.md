# 01 — Confirmed Defects (test box, 2026-11-15/16)

Environment: MacBook Pro 16" 2019 · i9-9980HK · Radeon Pro 5500M 4 GB (RDNA, wave32) ·
32 GB RAM · macOS 26.7.3. Install validated from the v0.90.0 release dmg.

| # | Severity | Defect | Evidence | Impact | Fix | Status |
|---|---|---|---|---|---|---|
| C1 | **P0** | v0.90.0 dmg is adhoc-signed; `spctl -a` rejects | `codesign -dv` → `Signature=adhoc`; `spctl: rejected`. README §Install claims Developer ID + notarized since 0.86.5 | Every browser-download user hits the Gatekeeper wall; kills trust and conversion at the front door | Restore Developer ID signing + notarization in release pipeline; add CI gate that verifies `spctl -a -vv` passes on the built dmg | open |
| C2 | **P0** | Release tag v0.90.0 ships bundle version 0.89.17 | `Info.plist CFBundleShortVersionString` = 0.89.17; server banner `Kestrel 0.89.17 (app 0.89.17)`; repo `VERSION` file = 0.89.17 at release commit | In-app updater can never offer the "new" release; users silently stay put; support confusion ("why is my kestrel not updating") | Bump VERSION as part of the release script (single source of truth, script-read, not hand-edited); add CI assertion tag == bundle version | **fix mechanism committed (`a28bda9`); re-cut release pending** |
| C3 | **P1** | Model catalog suggests models the bundled engine cannot load | `LFM3-1.7B-Q4_K_M.gguf` → `E llama_model_load: unknown model architecture: 'lfm3'`; 6 failed server restarts 02:39–02:45 as app/user retried | First-touch users see crash-loop; looks like a broken product on day one | Catalog must declare required engine capability per model; UI filters or warns before download; app stops auto-retrying a model that fails to parse | **fixed & committed (`79969da`): start refuses a (model, engine) pair that already failed architecture parse — engine switch/update auto-clears. Pre-download catalog filtering still open (arch unknown until GGUF is read)** |
| C4 | **P1** | Agent tool-call turn fails when grammar sampler init throws | task 4080: `E common_sampler_init: error initializing grammar sampler` → `Failed to initialize samplers: std::exception` (search-tool JSON schema grammar) | A whole turn errors out mid-conversation; user-visible failure in a headline feature (agent tools are experimental) | Catch sampler-init failure and fall back to unconstrained tool-call generation + retry; log the offending schema; add a regression test with the search-tool schema | **fixed & committed (`78db23a`): one retry without the grammar, 5 regression checks, 855/855 green** |
| C5 | **P2** | Generation speed on 5500M looked below class (~7.5–8.8 t/s tg, Qwen3-4B) | server logs 11-15/11-16 sessions; all earlier measurements contaminated by concurrent GPU work, hot thermals, and 3.3k-token context depth | **RESOLVED 2026-11-16 05:13, clean bench (app closed, GPU idle, 3 reps): pp512 = 325.5 ± 1.7 t/s, tg128 = 26.2 ± 0.2 t/s — card performs in class.** Live-chat gap vs tg128 is context depth + thermal, not a defect. New sub-finding: `llama-bench -fa 1` (forced standard FA) HANGS on this engine/card (17 min at 0% CPU); the default auto path (AMD kernel) works — report upstream | closed (watch: in-app deep-context tg as a UX expectation-setting item) |
| C6 | **P2** | Release title/version confusion ("0.90" read as "9.0") | Owner himself misread it | Signals versioning scheme communicates poorly | Consider calver-style or clearer scheme; changelog entry titles should carry the bundle version | open |

## Notes
- All other observed behavior healthy: hardware detection (correct GPU pick, RDNA wave32
  probe, AMD FA kernel on), prompt-cache reuse (LCP ~0.95, graphs reused 4034),
  server stable for hours, no crash reports.
- Contamination rule for benchmarks: never measure while a model is loaded in the app;
  kill all GPU consumers first.
