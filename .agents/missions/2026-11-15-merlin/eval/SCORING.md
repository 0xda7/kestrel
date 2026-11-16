# MERLIN EVAL — Scoring Rubric & Baseline Protocol

**Mission:** 2026-11-15-merlin · **Suite:** `merlin-eval-v1` · Companion to `TASKS.md` / `tasks.json`

---

## 1. Grading model

Scoring is purely mechanical. There are exactly three levels:

| Level | Definition |
|---|---|
| **Assertion** | one predicate from the five kinds in `tasks.json` (`file_exists`, `file_contains`, `command_ok`, `json_field`, `grep_count`). Green or red, no partial credit. |
| **Task pass** | **all** assertions green **and** the run finished within `max_turns`. One red assertion = task failed. |
| **Axis gate** | **all** tasks on the axis pass. The gate is the metric; axis pass rate is informational. |

Two overriding rules:

1. **Immuable seeds.** The harness SHA-256-hashes every `immutable_seeds` file at workspace
   boot and re-verifies before scoring. Any drift (edited `check.py`, "recovered" `report.csv`)
   fails the task outright, regardless of assertion outcome.
2. **Completion contract.** The run must end via `task_done`. A budget-forced wrap-up is
   recorded but marks the task `budget_exhausted: true`. T14 additionally requires the stop to
   be voluntary — its `stop_authority_rule` makes budget-exhaustion a hard fail.

A task-level evaluator script must therefore compute, per task:
`pass: bool`, `budget_exhausted: bool`, `seed_drift: bool`, plus the counters in §3.

## 2. Per-assertion details

- `command_ok` runs from the workspace root via `/bin/sh -c`; timeout 10 s; a timeout or
  non-zero exit is a red assertion.
- `json_field` uses strict JSON parsing (no comments, no trailing commas), dot-path lookup
  (`items.0.cost` = first element), numeric equality with tolerance 1e-9, booleans/strings
  exact, and **no string↔number coercion** (`"23"` ≠ `23`).
- `grep_count` counts matching *lines* (grep -E semantics) and applies both bounds when given.
- `file_contains` with `values` + `in_order:true` requires every value present in the given
  first-occurrence order — this is how the suite enforces sorting (T11, T13) and supersession
  (T09's distractor date failing nothing, but order enforcing the final decision).
- Assertions are evaluated **after** the run ends, never mid-run; no assertion influences the
  agent's context.

## 3. Recorded metrics per task run

| Metric | Source |
|---|---|
| `turns_used` | model completions consumed (harness counter) |
| `turns_budget` | the task's `max_turns` |
| `wall_clock_s` | first completion start → `task_done` (or budget stop) |
| `tool_calls` | total executed tool calls |
| `tool_errors` | tool invocations that returned an error result (bad path, failed command, refused write) |
| `recovery_events` | a tool error followed, within 2 turns, by a *different* approach that does not repeat the identical failing call — counted mechanically from the tool trace |
| `repeat_failures` | identical failing tool call (same tool, same normalized args, same error class) issued ≥2 times — the loop signature |
| `repair_count` | re-emitted or repaired tool calls (only possible off the grammar path; on M1 paths this should be 0) |
| `voluntary_stop` | `task_done` before budget |

These feed the scorecard. `tool_errors` alone is not a fault signal — recovery tasks *should*
produce errors — which is why `recovery_events` and `repeat_failures` are tracked separately.

## 4. Per-model scorecard

One per (model × machinery-mode) run:

```
MODEL SCORECARD — <model-id> · suite merlin-eval-v1 · <date> · machinery: merlin|baseline
──────────────────────────────────────────────────────────────────────────────────────
pass_rate        : 11/14 (78.6%)          # passed tasks / 14
axis_gates       : A ✔  B ✔  C ✘  D ✔  E ✘ # per-axis all-tasks gates
median_turns     : 7.0   (of budget; per-task turns_used median over all 14 runs)
median_wallclock : 4m12s
tool_errors      : 23 total (T07:6, T13:9, …)
recovery_events  : 14   ·  repeat_failures: 3
repair_count     : 0                     # expected 0 on M1 grammar path
voluntary_stops  : 12/14
seed_drift       : none
per-task         : T01 ✔(2t) T02 ✔(3t) T03 ✔(11t) T04 ✘(16t,budget) … 
──────────────────────────────────────────────────────────────────────────────────────
verdict          : MERLIN GATE: <model-id> PASS/FAIL (suite gate = 14/14 tasks; axis
                   gates reported per axis; ≥1 failing axis = gate red)
```

Reporting is fixed-width text plus the same content as JSON (`report.json` per run) so the
numbers are diffable across models and across machinery on/off.

## 5. Overall mission report

```
MERLIN-EVAL REPORT — <date>
models: GLM-4-9B-Q4_K_M, Qwen3.5-9B-distilled, LFM2.5-8B-A1B  (plan §2 bench)

model                 machinery   pass_rate   axes          med_turns  med_time  recoveries  loops
GLM-4-9B-Q4_K_M       merlin      13/14 (93%) A✔B✔C✔D✔E✘   6.5        3m58s     15          0
GLM-4-9B-Q4_K_M       baseline    6/14  (43%) A✔B✘C✘D✘E✘   12.0       9m31s     4           5
Qwen3.5-9B-distilled  merlin      …
…

DELTA (merlin − baseline, per model): +50% pass rate, −5.5 median turns, −5 loops  ← the claim
known flaws: …
```

The report's headline is the **delta table**, not absolute scores (§7 explains why). Suite gate
for the mission: **14/14 tasks pass under Merlin machinery on at least two bench models**, with
axis gates green — matching plan.md §1's done-condition and slice 4's verification gate.

## 6. Retry policy for runs

Each (model, task) cell is run once. A harness-crash (not model fault: kernel panic, llama-server
die-off) may be re-run once and must be marked `rerun: harness`. Model-fault failures are never
re-run — a flaky-model re-run policy would inflate the scorecard and defeat the baseline
comparison. Record generation params (temperature, context budget) in `report.json` meta.

## 7. Baseline protocol (what makes the claim honest)

The mission claim is not "our model is good" — it is "**the runtime machinery** is what makes a
≤9B model agentic." That is only provable by running the identical suite twice per model, with
the machinery as the only variable.

**Baseline definition — `naive-loop`:** the same model weights, the same llama-server, the same
system prompt, the same 10-tool surface, the same seeded workspaces, the same max_turns — and
**none** of M0–M8:

| Off in baseline | Baseline behavior instead |
|---|---|
| M0 Task Spine | plain system prompt, no per-turn goal/plan/result re-injection |
| M1 Constrained Actor | free-form generation; tool calls parsed leniently (a `json.loads`-or-regex attempt, mirroring common naive loops); malformed calls become a generic parse-error message |
| M2 Token-Efficient State | full tool results echoed into context (no summaries, no ledger) |
| M3 Structured Memory | no ledger, no recall |
| M4 Guardian | tool results returned raw; no postcondition checks |
| M5 Verifier | none |
| M6 Stop Authority | hard turn-budget cut, no progress detector, no wrap-up phase |
| M7 Retry Budgets | no classified retries; errors surface once, verbatim |
| M8 Model Profiles | one stock prompt for all models (chat template + tools block only) |

Everything else — sandbox, seeds, assertion set, scoring — is byte-identical between the two
modes. The baseline runner is the same `merlin-eval` target with `machinery=baseline`; there is
no second code path to drift.

**Fairness rules:**
1. Same model file, same quantization, same llama-server build, same context window, same
   temperature/sampling in both modes.
2. Baseline gets the *same generous* parse repair opportunity a naive loop would have (one
   retry on unparseable output); it does not get Merlin's grammar, ledger, or guardian.
3. Both modes are scored by the identical assertion evaluator; nobody re-grades.
4. Runs interleaved (baseline/merlin alternating per task) so thermal/load drift hits both.

**Reading the delta:**
- Large merlin-vs-baseline gap on B/D/E axes, small on A → machinery pays off exactly where
  context/memory/recovery matter. Expected signature, and the honest one to publish.
- Small gap → the mission thesis is *not* supported by the suite; report that; do not tune the
  suite until the gap looks right. The suite is fixed before the first Merlin run and never
  edited in response to results.
- Baseline > 0 on tier-1 tasks is expected and fine — it bounds the claim: Merlin's job is the
  hard axes, not winning single reads.

**Anti-rationalization clause:** the baseline numbers ship in the report. A report containing
only Merlin-mode numbers does not close slice 4's gate, no matter how good they look.

## 8. Suite governance

- Frozen at `merlin-eval-v1`. Changes to tasks, seeds, assertions, or budgets create
  `merlin-eval-v2` and re-baseline everything; no in-place edits after first run.
- Every scored run writes `report.json` (tasks, assertions, metrics, seeds' hashes, model meta)
  into the mission folder — check, don't assert, applies to scores too.
