# INCIDENT 01 — wedge cascade + relaunch-window bug (aborted matrix 1)

**Run tree preserved:** `runs-ABORTED-01-wedge-cascade/` (log: `matrix-run-ABORTED-01.log`)
**Started:** 2026-11-16T03:39:06Z · **Aborted:** 2026-11-16T04:29Z
**Matrix intended:** 14 tasks × 2 machinery, interleaved, Spark-X2.5-1.7B-Q8_0, port 8301, -t 8.

## Timeline (all times UTC, from server-8301.log + supervisor relaunch log)

- 03:39:06 matrix 1 starts; T01 merlin/baseline PASS cleanly (cells in tree).
- 03:46:2x T03 merlin request accepted by server (task 3758, slot launched) — ZERO
  tokens produced; the smoke's accept-then-silence wedge signature.
- 03:52:50 420 s request timeout fires → T03 merlin scores `actor_failed` (wedge class).
  Wedge policy engages: SIGTERM to listener pid 12405 → **server did not die within
  `waitForPortFree(timeout: 10)` (LiveDriver.swift:1097)** →
  `relaunch_failed: port 8301 still occupied after kill` → T03 permanently
  `harness_event:wedge`, retry denied.
- 03:53–04:08 the ORIGINAL wedged server keeps serving: T03 baseline consumed its
  600 s wall guard against it (unstamped — see BUG-2), T04 merlin ditto.
- 04:07:5x external SIGTERM (operator-side probe of the bug) kills pid 12405 in <12 s,
  proving SIGTERM *does* work on the wedged server — just slower than the supervisor's
  10 s port-free window.
- 04:18:12 T05 merlin wedges the same way (task 3761 cancel); policy retries;
  port now free (server already dead) → fresh instance launches ready (pid 12930).
- 04:18–04:29 T05 baseline + onward would run against the fresh instance, but cells
  T03b/T04m/T04b already burned unstamped against the wedged instance →
  matrix 1 ABORTED and preserved as evidence; matrix 2 restarted clean.

## Bugs surfaced (reported, not fixed — tree is the artifact under judgment)

### BUG-1: supervisor kill window too short for a wedged server (retry denial)
`ServerSupervisor.restart()` (Sources/MerlinEval/LiveDriver.swift ~line 1093-1097):
`killPortListener()` sends SIGTERM, then `waitForPortFree(timeout: 10)` polls lsof for
**10 s**. A wedged llama-server (0 CPU, hung slot) takes ~10-15 s to die from SIGTERM
(external evidence 04:07-04:18: TERM at 04:07:5x + still-listening at 04:18:12 window;
server gone by 04:18:13). Result: the codified one-fresh-instance retry is denied
(`relaunch_failed: port still occupied`) on the very cells that need it most —
wedges cluster, so the first wedge poisons subsequent cells through the same stuck
instance. **Repro:** wedge a request (or `kill -STOP <server-pid>` mid-request),
trigger `--wedge-retry`, observe `relaunch_failed: port N still occupied after kill`
~10 s after the SIGTERM line in the relaunch log; then watch SIGTERM complete at
+10-15 s. **Fix direction (not applied):** SIGKILL fallback after the TERM, or extend
the port-free window to ≥30 s.

### BUG-2: wall-guard wedges on the baseline path never reach the wedge policy
T03 baseline burned its full 600 s wall guard against the wedged server and scored
plain `budget_exhausted` with **no wedge stamp** (wedges.log has T03 merlin only).
`WedgeHardening.isRequestTimeoutWedge` catches `harness_timeout` and
`actor_failed`(timeout-text) (LiveDriver.swift ~930-939); a baseline budget-exhaust
whose final turn was a 420 s client timeout is classified as a model failure instead
of the harness event it was. Census implication: without the server log, wall-guard
baseline cells during a wedge would be silently counted against the model. (In the
clean matrices this should not recur; the census below still cross-checks
server-cancel events per cell.)

## Why abort (not patch-and-continue)

SCORING.md §6: llama-server die-off is a harness fault; model-fault failures are never
re-run, but harness-faulted cells may be re-run once marked `rerun: harness`. Matrix 1
mixed real model outcomes (T01/T02 cells) with poisoned cells (T03 retry-denied; T04
both modes against a dead-stuck server, unstamped). A matrix resumed in place could
not be labeled honestly per cell. Full restart preserves the fresh-instance fairness
rule; matrix 1 is kept as bug evidence only, NEVER scored.
