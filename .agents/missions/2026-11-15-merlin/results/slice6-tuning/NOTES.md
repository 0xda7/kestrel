# SLICE 6 TUNING NOTES — evidence-driven hardening · 2026-11-15/16

Worker: tuning slice (all prior slices closed). Ports used: 8199 (Spark), 8201 (GLM), 8210 (wedge tests) — ALL servers killed, ports verified down at close.
Evidence persisted in `probes/` (the /tmp wipe precedent from the smoke gate made persistence mandatory).

## Item 1 — GLM rung-2 per-tool envelope grammar

**Finding (captured):** the shared-shape envelope (`name` enum-gated, `arguments` free object)
constrains call SHAPE only. A FORCEFUL instruction to emit `{"name":"fs_write","arguments":
{"report_file":"out/report.md"}}` produced EXACTLY that schema-sloppy envelope from GLM-4-9B
under the shared grammar (content: `{"name": "fs_write", "arguments": {"report_file": "out/report.md"}}`)
— kernel-2's soak deviation reproduced on demand. Under the identical forcing instruction with the
new per-tool grammar, GLM emitted `{"path": "out/report.md", "content": "Report generated successfully."}`
— the sloppy key was UNEMITTABLE. 8-cell matrix (3 shared-shape controls + 5 per-tool, tools
fs_write/fs_grep/todo_write/note_add/shell_run tempted): 8/8 envelope-parseable, argument keys
schema-valid, zero malformed (`glm-envelope-probe.log`).

**Change:** `MerlinModelProfile.EnvelopeMode` (.sharedShape | .perToolSchemas) — profile option;
glm-4 → .perToolSchemas (all other families keep sharedShape until their own rung-2 drift evidence
lands). `MerlinToolSchema.envelopeResponseFormat(mode:)` builds oneOf-of-{name:const, arguments:
<registry schema>} branches (C1 pattern, ChatToolsService.swift ToolTurnEnvelope — read, not
modified; branch schemas pulled LIVE from `MerlinToolRegistry.schema(for:)` so the grammar can
never drift from the executor). Wired into BOTH wire paths (LlamaServerActor + eval LiveMerlinActor)
and surfaced in report meta as `profile_envelope_mode`.

**Shipped-path verification:** T01 on GLM-4-9B through `merlin-eval --driver live --machinery
merlin` ran under `perToolSchemas` (report meta proves it); every emitted envelope call was
schema-valid. The run FAILED on a model-behavior axis, not a schema axis: GLM invented absolute
`/task-workspace/config/settings.json` paths (workspace-escape errors, then an honest task_done).
That is the harness's existing path-containment doing its job; recorded as a model note for the
baseline phase, NOT a slice-6 defect.

## Item 2 — Spark reasoning_content (eval-live's finding, re-probed)

**Finding (captured, Spark-X2.5-1.7B-Q8_0 on :8199):** `reasoning_content` IS emitted on
chat completions — 222 chars (probe 1/2) and 493 chars (probe 3, harder prompt) — and
`usage.completion_tokens` (89, 143) COUNTS those reasoning tokens: reasoning eats max_tokens.
ProfileStore's "No think budget." was wrong.

**Change:** spark-x2.5 `minCompletionTokens` 512 → 768 (`MerlinModelProfile.sparkReasoningFloor`),
templateNotes corrected with the measured evidence (the old note is quoted-and-retracted, and a
check pins that the retracted claim sentence is gone). Downstream budgets auto-follow (both call
sites derive floor+512): Spark eval completions now run at 1280 max_tokens — proven in run meta.

## Item 3 — Wedge hardening (codified policy)

**Change:** `WedgeHardening.runCell` — a cell whose failure is a request-timeout wedge (wall-guard
trip OR actor failure on a URLSession timeout) gets exactly ONE automatic retry on a FRESH server
instance (ServerSupervisor: LISTEN-only lsof → SIGTERM → relaunch bundled/vendor binary →
/health wait), then a second wedge scores permanently as `harness_event:wedge`. `--wedge-retry`
(default ON) / `--no-wedge-retry` / `--server-binary` / `--server-threads` (default 16). Every
wedge appends a one-line stamp (ISO8601, port, cell, event, detail) to `wedges.log` in the run
root; relaunch activity lands in `server-relaunch.log`. Wired into both machinery paths incl.
--interleave. Both branches proven functionally (see `probes/wedge-policy-proof.json`):
wedged→recovered (T01 PASS 3 turns on the fresh instance) and wedged→wedged (permanent
harness_event:wedge). **Bug found and fixed during the proof:** the first supervisor used
`lsof -ti tcp:P` which matches client sockets (the eval's own hung request) — fixed with
`-sTCP:LISTEN`, direct SIGTERM (no helper subprocess; pipe deadlock risk), and 5s-bounded lsof
reads (the wedge signature itself could otherwise stall the supervisor).

## Item 4 — Kernel progress seam (app-1's documented gap)

`MerlinKernel.Configuration.onEvent: (@Sendable (MerlinKernelEvent) -> Void)?` (nil default,
pre-slice-6 behavior preserved) + `MerlinKernelEvent`: turnStarted(turn), callExecuted(call,
summary), blocker(text), completed(MerlinOutcome). Fire-and-forget: synchronous inline
invocation at the natural ledger points, never awaited, non-throwing BY TYPE (an observer that
could stall the loop is not expressible), delivered exactly-once at every terminal outcome
(actor-failure, verified task_done, unchecked task_done, both budget exits). MerlinChatService
NOT touched (documented follow-up; the app may switch from 100ms ledger-polling later).

## Gates

- Whole package: `swift build --disable-sandbox` → **Build complete** (exit 0).
- Check binary (stderr → file): **Executed 838 checks, 0 failures**, exit 0 — twice (after check
  additions AND after the supervisor fix). Baseline was 830; +8 appended (4 MerlinChecks2 envelope,
  2 MerlinChecks2 spark-floor, 2 MerlinChecks kernel-seam). No new suite, no registry line.
- Live probes: all captured; servers KILLED (pids 5424/5428/7085/7238 + fake listener), ports
  8199/8201/8210 verified down via lsof AND refused health checks.

## Deviations

1. `Tests/MerlinChecks2.swift testProfileMatrixRungsMatchTheEvidence` (kernel-2's check): ONE
   assertion updated in place — Spark's floor pin moved from `defaultMinCompletionTokens` to
   `sparkReasoningFloor` (+ a >512 guard). The pin would otherwise contradict the corrected
   profile. Appended-only everywhere else.
2. Wedge-policy unit checks live OUTSIDE the check binary: `WedgeHardening`/`ServerSupervisor`
   are MerlinEval types, and MerlinEval is excluded from the KestrelCore target that the check
   binary @testable-imports (Package.swift is lead-owned; NOT my file). Verification is
   functional instead: the two full end-to-end wedge proofs above. The policy's TaskScore
   rebuild helper mirrors the existing `scoreAppending` (LiveDriver.swift) shape.
3. Item-1 probe tasks reuse kernel-2's "report_file" temptation wording; single-turn spine restates
   argument names, so the 8-cell matrix alone could NOT distinguish grammar strength (GLM
   self-normalizes under soft temptation) — the negative-control pair (forceful sloppy-key
   instruction under both grammars) is the decisive evidence and is what's quoted above.
4. GLM T01 under the new grammar fails on absolute-path inventions (workspace-escape errors) —
   model behavior, orthogonal to argument-schema validity; noted for the baseline phase.
