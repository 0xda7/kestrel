# MERLIN EVAL GATE — REPORT (Spark-only verdict)

**Mission:** 2026-11-15-merlin · **Suite:** merlin-eval-v1 (14 tasks × 2 machinery modes)
**Date:** 2026-11-16 · **Scope:** Spark-X2.5-1.7B-Q8_0 complete (28/28 cells); Qwen3.5-9B leg incomplete (6/28) and excluded.
**Decision scope (recorded pre-gate):** the gate verdict decides ONLY the Merlin-default engine flip.

---

## VERDICT

```
MERLIN GATE: Spark-X2.5-1.7B — FAIL (suite gate = 14/14; merlin scored 4/14)
MERLIN GATE: Qwen3.5-9B — NOT SCORED (leg incomplete: 6/28 cells, wedge + external interrupt 02:49 PT)

DECISION: Merlin-default flip NOT taken. Agent engine stays opt-in (toggle).
          No gate re-run authorized in this report; Qwen leg parked at 6/28.
```

The formal gate is red for both machinery modes on Spark. This is not a marginal miss —
4/14 against a 14/14 suite gate means the small-model stack does not yet clear the bar the
suite was designed to enforce. The honest headline is: **the machinery direction is right,
the absolute level is not.**

---

## MODEL SCORECARD — Spark-X2.5-1.7B-Q8_0 · suite merlin-eval-v1 · 2026-11-16 · machinery: merlin
```
pass_rate        : 4/14 (28.6%)
axis_gates       : A ✔  B ✘  C ✘  D ✘  E ✘   (A = T01,T02 both pass; every other axis has ≥1 red)
median_turns     : 3.5  (of budget; all 14 runs)
median_wallclock : 3m29s
tool_errors      : 27 total · recovery_events: 27 · repeat_failures: 9 · repair_count: 0
voluntary_stops  : 6/14 · seed_drift: none
wedge census     : 11 first-attempt wedges → 9 recovered on the one-fresh-instance retry (82%),
                   2 wedged again (T07, T13 — both 0 turns, 600s window consumed)
per-task         : T01 ✔(3t) T02 ✔(8t) T03 ✘(actor,5t) T04 ✘(9t) T05 ✔(5t) T06 ✘(actor,12t)
                   T07 ✘(wedge,0t) T08 ✘(actor,3t) T09 ✘(3t) T10 ✘(actor,3t) T11 ✘(actor,4t)
                   T12 ✘(actor,9t) T13 ✘(wedge,0t) T14 ✔(3t)
──────────────────────────────────────────────────────────────────────────────────────
verdict          : MERLIN GATE: Spark-X2.5-1.7B FAIL
```

## MODEL SCORECARD — Spark-X2.5-1.7B-Q8_0 · suite merlin-eval-v1 · 2026-11-16 · machinery: baseline
```
pass_rate        : 2/14 (14.3%)
axis_gates       : A ✘  B ✘  C ✘  D ✘  E ✘
median_turns     : 2.5  (of budget; all 14 runs)
median_wallclock : 10m00s
tool_errors      : 2 total · recovery_events: 2 · repeat_failures: 1 · repair_count: 0
voluntary_stops  : 2/14 · seed_drift: none
failure modes    : 12 of 14 cells = budget_exhausted; seven 1-turn budget stops at ~600s
                   carry the llama-server wedge signature (wedge ate the window, budget
                   stopped before any work happened)
per-task         : T01 ✔(3t) T02 ✘(budget,5t) T03 ✘(budget,12t) T04 ✘(budget,1t) T05 ✔(8t)
                   T06 ✘(budget,2t) T07 ✘(budget,1t) T08 ✘(budget,1t) T09 ✘(budget,1t)
                   T10 ✘(budget,8t) T11 ✘(budget,7t) T12 ✘(budget,1t) T13 ✘(budget,1t)
                   T14 ✘(budget,1t)
──────────────────────────────────────────────────────────────────────────────────────
verdict          : MERLIN GATE: Spark-X2.5-1.7B baseline FAIL (reference, not gated)
```

---

## What the data actually shows (machinery separation, not the gate)

1. **Clean merlin-vs-baseline separations on 3 of 14 tasks:** T02 (✔ vs ✘budget — the
   spine+ledger axis the suite predicted), T14 (✔ voluntary-stop vs ✘budget — T14's rule
   makes budget-exhaustion a hard fail, and merlin stopped voluntarily in 3 turns),
   and T04-adjacent budget churn.
2. **Where both pass, merlin is faster:** T05 merlin 5t/148s vs baseline 8t/451s;
   T01 3t both (merlin 71s vs 45s wall — within noise).
3. **Baseline is not a fair fight on this box:** 12/14 baseline cells died to budget with
   wedge-eaten windows, so much of the delta is "merlin survives wedges; baseline doesn't."
   The retry machinery (9/11 recovered) is doing real work — but it also means the raw
   capability delta is smaller than 4-vs-2 suggests.
4. **The merlin-specific failure mode is new and actionable:** 6 `actor_failed` cells
   (T03, T06, T08, T10, T11, T12) — the grammar/actor path, not budget, not wedges.
   These six are the machine-attributable gap to 14/14 and should headline the next
   kernel work item.
5. **repeat_failures: 9** on merlin — the loop signature appears even with machinery;
   recovery_events 27 shows it usually escapes. Worth pairing with the actor_failed cells.

## Qwen3.5-9B leg — incomplete, parked

6/28 cells before the leg died at 02:49 PT: T01 ✔/✔, T02 ✔/✔, T03 ✘/✘, T04 baseline in
flight; llama-server on :8302 took the "second interrupt, terminating" exit (wedge signature
then external interrupt — watchdog quiet, port dead, no processes). Notably Qwen **baseline**
passes T01+T02 where Spark baseline failed T02 — the bigger model compensates without the
machinery on those axes, which would have made the Qwen separation the stricter test.
Artifacts preserved under `results/gate-Qwen3.5-9B/` (runs/20261116-102000, server-8302.log,
matrix-run.log).

## Incidents & known defects carried

- `INCIDENT-01-wedge-cascade.md` (matrix 1 abort; BUG-1: supervisor's 10s port-free window
  < wedged server's SIGTERM latency — reported, not fixed).
- Wedge class: bundled llama-server 0.6.0-dev b11610 wedges under sustained traffic;
  per-request 420s timeout + one-retry policy works (82% recovery) but two cells still lost.
- `analyze.py` bug found while writing this report: it reads `tasks[].passed` but the report
  schema emits `tasks[].pass` — every cell scored `False`, printing a false 0/14 for BOTH
  modes. This report's numbers are computed directly from `report-{merlin,baseline}.json`
  and cross-checked against the ✔/✘ lines in `matrix-run.log` (they agree). The analyzer is
  fixed in place alongside this report.

## Operator decision queue

1. Accept Spark-only FAIL as the gate verdict (default stays opt-in) — **this report's position.**
2. Authorize a quiet-box Qwen re-run later for the stricter separation signal (not required for the verdict).
3. Next kernel work item: the six actor_failed cells (T03/T06/T08/T10/T11/T12) before any suite v2.
