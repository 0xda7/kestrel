# Defect & Debt Register — rushed staging work, 2026-10-14 (0.89.9–0.89.12)

Everything the hurried delivery left behind. Severity-ordered. Status of
each at time of writing. This is the hunt list; nothing here is hidden.

## Critical (can break chat/agent again)

1. **Sandbox provider-config timing race.** The agent's sandbox home gets
   `provider_config.json` only when `LatchBridge.sync()` runs (server
   start / route change). If the sandbox is fresh and no server event has
   fired, the harness can boot without its "Active" config → the 0.89.6
   failure shape returns. Fix: `childEnvironment()` must ensure
   `LatchBridge.sync()` ran (or the file exists) before spawning.
2. **Laya tool port is hardcoded 8098.** If the "Laya Decisions" card's
   port is edited in the UI, `laya_decide` still calls 8098 → engine-down
   error while the card is green. Fix: read the card's actual port.
3. **0.89.12 agent boot fix is not live-verified.** The key now passes,
   but no one has confirmed one agent turn end-to-end in the UI.

## High (wrong behavior, not fatal)

4. **Translation pipeline still churns an English-only product.** The
   pre-commit hook regenerates 14 language files × 1,934 keys on every
   commit; `lang/*.json` still ship in Resources. Dead weight + repo churn.
5. **Dead localization code**: `discoverLanguages()`, `displayName`,
   overlay loader, `SettingsKeys.language` — all unreachable after
   English-only. Docs tab may still carry Spanish doc pages (Docs.swift
   has separate ES/EN sections) — verify and strip.
6. **KV badge inconsistency**: UI badges (`usesTurboKV` etc.) read the raw
   settings while gemma launches with the equalized pair — badge can
   claim a mix the launch doesn't use.

## Medium (debt, cleanliness)

7. `LayaDecideService.execute` uses force-unwraps (`questions!`) and a
   `nilIfBlank` string extension tacked at file bottom — works, but
   should be structured optionals.
8. Test `testLatchChildEnvironmentIsIsolated…` behaves differently
   depending on whether a `latch-api-key` secret exists on the machine.
9. Empty App Support leftovers: `dynamic-moe/`, `router/`,
   `memory-archive-hook/`, `slots/` dirs; `benchmarks.txt` (4.6 MB) grows
   unbounded in logs.
10. `sandboxHome` copies `~/.zcode/cli/config.json` once and never
    refreshes — if harness boot config changes, sandbox stays stale.

## Left to do (the real product work)

- **Capability audit**: every screen/feature inventoried, marked
  working/broken/dead with evidence; kill list for bloat; suite rebuilt
  around capabilities. (The mission for the next session.)
- **Native Decisions tab** (service layer shipped; UI pending).
- **Laya-as-router**, crawl loop, batch decisions, decision audit log
  (see LAYA-ARCHITECTURE.md roadmap).
- Live verification pass: one real turn of chat, agent, tools, Laya,
  context bar — on the installed 0.89.12.
