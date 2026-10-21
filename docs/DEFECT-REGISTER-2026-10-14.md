# Defect & Debt Register — rushed staging work, 2026-10-14 (0.89.9–0.89.12)

Everything the hurried delivery left behind. Severity-ordered. Status of
each at time of writing. This is the hunt list; nothing here is hidden.
(Statuses updated 2026-10-14 by the round-1 fix pass; "fixed" means the
source change landed this round — the check suite gate runs after it.)

## Critical (can break chat/agent again)

1. **Sandbox provider-config timing race.** FIXED (already self-healing
   before this pass): `LatchDelegateService.childEnvironment()` runs
   `LatchBridge.sync()` whenever the sidecar file is missing, so a fresh
   sandbox can never boot into the 0.89.6 failure shape. The rewritten
   allowlist `childEnvironment()` keeps that behavior, and
   `testChildEnvironmentMaterializesProviderConfigForFreshSandbox` now
   regression-guards it (removes the sidecar, calls childEnvironment(),
   asserts the file was materialized; machine state restored in defer).
2. **Laya tool port is hardcoded 8098.** FIXED:
   `LayaDecideService.resolvedPort()` reads the "Laya Decisions" card's
   persisted profile port at every `execute()` (health check and decide
   both use it), falling back to 8098 only when the card is absent.
3. **0.89.12 agent boot fix is not live-verified.** STILL OPEN: the key
   now passes, but no one has confirmed one agent turn end-to-end in the
   UI (chat → tool → reply, context bar populated). Requires hands on the
   installed app; not verifiable from a source-only pass.

## High (wrong behavior, not fatal)

4. **Translation pipeline still churns an English-only product.** FIXED:
   the overlay loader was dead at runtime (only 3 community languages
   remained, not 14), so the pipeline is retired — pre-commit hook,
   translations CI workflow, the four Python scripts and `Assets/lang/`
   are deleted, and make-app.sh no longer copies `lang/*.json` into the
   bundle (the web console fetch falls back to English).
5. **Dead localization code.** FIXED: `discoverLanguages()`,
   `displayName`, `loadOverlay`/`overlay`/`langDirectory` and
   `availableLanguages` are deleted; `SettingsKeys.language` is gone and
   a stale stored "lang" is cleared at launch; Server.swift's six
   language reads are pinned to English; the Spanish Docs array and
   `donateNoteES` are stripped along with the parity test.
6. **KV badge inconsistency.** FIXED in the surviving form: no view
   consumed `usesTurboKV` (the original "UI badges" claim was not
   reproducible), so the fix landed where the mislabel lived —
   `ServerSettings.effectiveCacheTypes` now exposes the post-equalization
   pair and benchmark records, run headers, share payloads and the
   Benchmarks tab chips read it; llama-bench arguments equalize the same
   way the server launch does.

## Medium (debt, cleanliness)

7. `LayaDecideService.execute` force-unwraps. FIXED: the question
   dictionary is bound once as a non-optional local (iterating the
   dictionary directly), and `nilIfBlank` moved to a shared String
   extension in Support.swift.
8. Test `testLatchChildEnvironmentIsIsolated…` was machine-dependent.
   FIXED: the test seeds `latch-api-key` with a sentinel (restoring the
   prior value in a defer) and asserts the allowlist directly — no
   machine-local branch left.
9. Empty App Support leftovers. RECLASSIFIED: `slots/` is NOT an orphan —
   it is the live engine slot cache (persisted KV, ~18 MB) created and
   read by live code; `benchmarks.txt` does not grow unbounded (it is
   pruned to the last 3 days of runs at init and now periodically on
   append as well). The genuinely empty dirs (`dynamic-moe/`, `router/`,
   `memory-archive-hook/`) are created eagerly by live code — harmless,
   left as is.
10. `sandboxHome` copies `~/.zcode/cli/config.json` once and never
    refreshes. FIXED by removal: the sandbox is no longer seeded from the
    operator's real ZCode config at all (it carried the outer product's
    plugin/skill state into the embedded agent's HOME). A fresh sandbox
    gets a minimal `{}` boot config; providers and the gateway key reach
    the harness only via LatchBridge's `provider_config.json` and
    `LATCH_API_KEY`, so there is nothing left to go stale.

## Left to do (the real product work)

- **Capability audit**: every screen/feature inventoried, marked
  working/broken/dead with evidence; kill list for bloat; suite rebuilt
  around capabilities. (The mission for the next session.)
- **Native Decisions tab** (service layer shipped; UI pending).
- **Laya-as-router**, crawl loop, batch decisions, decision audit log
  (see LAYA-ARCHITECTURE.md roadmap).
- Live verification pass: one real turn of chat, agent, tools, Laya,
  context bar — on the installed 0.89.12.
