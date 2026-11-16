# SMOKE GATE NOTES — Spark-X2.5-1.7B (slice 4c-smoke) · 2026-11-15/16

**Verdict: ENVIRONMENT-LIMITED SMOKE — NOT a machinery verdict.**
The harness pipeline is proven end-to-end (T01 passed BOTH modes); every other cell was
stopped by a llama-server wedge that hit both machinery modes ~equally. The merlin-vs-
baseline delta on this run is 0% **because the environment failed both modes equally**,
not because the machinery has no effect. The real matrix (14×2 × 3 models) remains open
and belongs to the tuning/baseline phase per plan slice 4/6.

## What ran

- Reduced gate per lead directive: T01, T04, T07, T12, T13, T14 × {merlin, baseline},
  interleaved (merlin-first on odd-index tasks), run root
  `runs/20261115-224033/` (per-mode subtrees `merlin/`, `baseline/`).
- Server: bundled `vendor/llama.cpp/build-static/bin/llama-server`, model
  `/Users/admin/models/Spark-X2.5-1.7B-Q8_0.gguf`, `-ngl 0 -c 8192 -t 16`,
  port 8180, temp 0, `cache_prompt:false`, max_tokens 1024 (profile floor 512 + 512
  headroom), rung nativeTools (M8 profile `spark-x2.5`, MerlinProfileStore).
- Wall guard: 600 s per cell; per-request timeout 420 s inside the live actor.

## Per-cell outcomes (as they landed)

| cell | mode | outcome | turns | wall | harness_event |
|---|---|---|---|---|---|
| T01 | merlin | **PASS** | 3 | 88s | none |
| T01 | baseline | **PASS** | 3 | 65s | none |
| T04 | merlin | FAIL | 1 | 423s | **wedge** (420s request timeout → actor_failed) |
| T04 | baseline | FAIL | 7 | 834s | partial-wedge (slow completions; budget stop; 1st-turn 420s timeout) |
| T07 | merlin | FAIL | 1 | 421s | **wedge** |
| T07 | baseline | FAIL | 1 | 600s | **wedge** (budget stop at wall guard) |
| T12 | merlin | FAIL | 1 | 421s | **wedge** |
| T12 | baseline | FAIL | 1 | 601s | **wedge** |
| T13 | merlin | FAIL | 1 | 421s | **wedge** |
| T13 | baseline | FAIL | 1 | 601s | **wedge** |
| T14 | merlin | FAIL | 1 | 421s | **wedge** |
| T14 | baseline | FAIL | 1 | 601s | **wedge** |

Scorecards + delta: `out.txt` · full per-cell evidence incl. fail_reasons:
`report.json` (also `report-merlin.json`, `report-baseline.json` in the run root).
Wire-level evidence for earlier probes preserved in-transcript; per-task kernel ledgers
and wire trajectories under `runs/20261115-224033/{merlin,baseline}/<task>/`.
An earlier aborted run is preserved at `runs/20261115-220758-aborted-wirelog-in-workspace/`
(see "eval-validity catch" below).

## The wedge signature (evidence)

- **Accept-then-silence**: server accepts the HTTP request, launches the slot
  (`launch_slot_` in server-8180.log), produces ZERO tokens, and the request only ends
  when the client timeout or an external cancel kills it
  (`W srv stop: cancel task` lines; 6 cancel events on 8180, matching the 6 wedged
  merlin cells 1:1 — each wedge consumed the full 420 s window and the cell's wall
  clock is 421 s ±1 s, i.e. timeout-driven, not model-driven).
- **Hit both modes ~equally**: 5/6 merlin cells wedged; 5/6 baseline cells wedged
  (baseline cells show the same signature at the 600 s guard). T01 (both modes) ran
  BEFORE the wedge set in — wedge onset correlated with longer contexts/multi-turn
  traffic, not with machinery.
- **Not fixed by cache_prompt:false** (wedged both with cache on and off).
- **Not load**: box load average 3-6 on 16 cores; trivial completions returned in
  1.7-2.3 s between wedges; 6/6 consecutive rung-1 calls succeeded at ~6-8 s
  immediately after a restart with `-t 16` (thread starvation was the working theory;
  wedge returned anyway under sustained multi-turn load).
- **Prior incidents this session**: first server instance (port 8177, `-t 4`) wedged
  identically; second instance (8178, `-t 8`) wedged after ~30 min of matrix traffic;
  at ~12:55 an EXTERNAL event killed all llama-servers on the box (mine + other
  workers' soak pair, no crash line in any log) AND purged `/tmp` (first full matrix
  attempt's artifacts lost — partial cells T01-T03 merlin / T01-T04 baseline observed
  pre-wipe; merlin T01 ✔(3t) and T14 ✔(3t) probes captured in-transcript).

## Eval-validity catch (my own harness bug, fixed mid-smoke)

The first gate attempt put `wire-log.jsonl` INSIDE the task workspace; the T04 merlin
run `fs_list`ed the root and READ the log — a harness artifact visible to one mode
only breaks SCORING.md §7's identical-sandbox fairness rule. Fixed: wire logs moved to
`~/Library/Caches/merlin-eval-wirelogs/<task>-merlin.jsonl`. Aborted run preserved as
evidence.

## Design decisions documented in code (LiveDriver.swift header)

- machinery=merlin drives `MerlinKernel` directly (seed → kernel.run → ScoringEngine);
  the `EvalTurnDriver` seam serves only machinery=baseline (NaiveBaselineDriver +
  llama-server completion hook, lenient parse, ONE repair retry per SCORING.md §7
  rule 2). Scoring is machinery-blind (rule 3): identical ScoringEngine + seeds +
  assertions both modes.
- **Kernel transcript gap (REPORTED to lead, kernel-3's file — NOT patched)**:
  `MerlinKernel.run` never appends assistant/tool turns to the actor transcript, so
  the model never sees its own prior calls (live evidence: stock-actor T01 = 6/6
  identical fs_read, budget exhausted). Worked around harness-side via
  `LiveMerlinActor` (public Merlin API only): spine as system message, real
  assistant tool_calls turns, `role:"tool"` result turns from ledger deltas.
  Kernel-side fix recommended before slice 5.

## Re-run recommendation (tuning phase)

1. Run on a quiet box (no concurrent llama-servers — the wedge never appeared during
   single-tenant probes).
2. Investigate llama-server slot handling under multi-turn traffic (0.6.0-dev build
   11610; wedge = launched slot, zero tokens, indefinite hang) before burning matrix
   wall-clock.
3. Wall-guard policy per lead: one 420 s-timeout retry per cell, then
   `harness_event:wedge` and move on — codify in the harness (currently a wedge
   costs the full guard window per cell).
4. Consider parallel servers (one per worker slot) or `-t` sweep to find a stable
   config; `-t 16` + `cache_prompt:false` was stable for ~45 min, wedged after.
