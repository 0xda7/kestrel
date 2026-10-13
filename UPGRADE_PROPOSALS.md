# Kestrel — future upgrade & optimization proposals

Companion to `UPGRADE_REPORT.md` (the 2026-10-12 diagnosis). Every item below
is grounded in evidence from the enterprise-upgrade mission's seven sessions;
effort is S/M/L (hours/days/weeks), and each names its verification gate.
Priorities: **[P1]** next release material · **[P2]** scheduled work ·
**[P3]** opportunistic.

## Engines (the mapped arc)

1. **[P1] The `kernels/` layout port** (L) — `5a75f14c0` (FA per-dtype
   libraries) breaks patch `0001`; porting the series to the split layout is
   the keystone that unlocks llama master, whisper ≥v1.9.5, sd.cpp master,
   and collapses `shared-metal/` into the llama series. Plan:
   `.agents/missions/2026-10-12-enterprise-upgrade/engines-reaauthoring-plan.md`.
   Gate: strict apply + build + round-trip + interleaved bench + smoke
   (the five-gate ladder the ed319febb landing used).
2. **[P2] The MoE-cache decision** (M) — Kestrel's expert cache (patches
   `0003/0023/0025`) vs upstream's own MoE-cache-over-multi-GPU (#30112,
   #29887): decide per mechanism with RDNA2 benchmarks; record which wins.
   Gate: spec-decode test + MoE bench rows, decision note in `patches/README.md`.
3. **[P2] A variance-aware bench harness** (S) — tonight proved benchmarks
   run right after builds are worthless on this machine (thermal). Add
   `scripts/bench.sh`: interleaved A/B against a saved reference binary,
   fixed cool-downs, ±band verdict. Gate: reproduces the ed319 parity result.

## Security (risk-accepted items, now schedulable)

4. **[P1] TLS for LAN mode** (M) — the bundled engine has `--ssl-key-file`;
   generate or import a cert, require HTTPS when non-loopback. Closes the
   cleartext-key exposure honestly. Gate: LAN serve + client over TLS + tests.
5. **[P2] Web-UI session token** (S) — embed a per-session token in the
   served UI URL as a second factor even on loopback (engine `--path` static
   UI can't inject it; proxy or query-param route needed — small design).
6. **[P2] Archive-endpoint change confirmation** (S) — confirm when the
   memory-archive URL changes host (local-write-only attack surface today).
7. **[P3] pi delegate prompts off argv** (M) — prompts ride argv
   (`ps`-visible); stdin or tempfile if pi's CLI allows.

## Code health & performance

8. **[P1] Split the monolith incrementally** (M, repeatable) — `KestrelCore`
   is one 50k-LOC module; `ChatNative.swift` alone is 5.8k lines mixing
   `ChatStore`, streaming, and views. Extract one seam at a time (ChatStore
   → its own file first; then `Sources/Chat` views). Gate per slice: build +
   kestrel-checks green, zero behavior change.
9. **[P2] Cache `resolvedCtx`** (S) — computing it stats the model file and
   scans GPUs; the chat meter reads it per render. Memoize on
   (modelPath, ctx, contextAutomatic, cacheTypeK, vramReserveMB). Gate:
   meter correctness test + a render-cost sanity check.
10. **[P2] Mixed-K/V KV sizing** (S) — `resolvedCtx` scales KV by
    `kvTypeScale(cacheTypeK)` only; q8_0-keys + f16-values (the recommended
    profile!) overestimates or underestimates. Use both types' scales.
    Gate: estimator unit test with mixed types vs `Estimator.estimate`.
11. **[P2] Token-estimate calibration** (S) — `estimatedTokens` is chars/4;
    sample real `contextUsed` per language and store a per-conversation
    calibration factor. Gate: guard fires within ±15% of engine counts.
12. **[P3] Parallelize kestrel-checks** (S) — suites run serially (~90 s);
    independent suites could run concurrently with per-check isolation kept.
    Gate: same 350 results, faster wall clock, watchdog still loud.
13. **[P3] `--filter` for kestrel-checks** (S) — the old `swift test --filter`
    ergonomics; register checks by name and accept a filter argument.
14. **[P3] KestrelTests.swift split** (S) — one 3.1k-line file holds ~30
    suites; one file per suite matches the rest of `Tests/`.

## Product / UX (from the due-diligence trail)

15. **[P2] Prompt Space wave 2** (M) — A/B variants shipped; add trace-list
    UI over `latestSessionTraces`.
16. **[P2] Stale-app guard** (S) — About shows build hash vs source-derived
    hash; Dashboard warns when dist predates the newest commit (the
    Amendment-4 lesson).
17. **[P3] Provider-side cancellation honesty** (S) — OpenAI/Anthropic
    dialects can't cancel server-side; show a "provider keeps generating"
    note on remote stops instead of silence.
18. **[P3] Router × contextAutomatic** (S) — router computes per-model ctx
    already; surface the resolved value per model in the Dashboard.

## Operational

19. **[P1] CI billing restoration** (operator) — the engines commit's CI
    arbitration is queued on the account's Actions minutes; confirm the
    checks when restored (local gates recorded in c5c5294's message).
20. **[P2] Release checklist entry for engines** (S) — pin bumps land with
    bench + triage notes; make `release.sh` remind when `VERSION` bumps with
    an unpinned engine delta.
