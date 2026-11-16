# Merlin — the small-model agent kernel

Mission: 2026-11-15-merlin · Kernel: `Sources/Merlin` · CLI: `Sources/MerlinMain` ·
Eval: `Sources/MerlinEval` · App surface: `Sources/Chat/MerlinChatService.swift`

## What Merlin is

Merlin is the replacement agent runtime for Kestrel Engine, purpose-built for ≤9B local
models. The legacy chat agent loop it replaces was measured, not assumed: the slice-0
failure inventory (`.agents/missions/2026-11-15-merlin/DIAGNOSIS.md`) captured live
repros of GLM-4-9B falling out of the tool channel and hallucinating tool results, R1-8B
exhausting its token budget thinking without ever acting, and a turn machinery of
one-call-per-turn, per-call permission cards, and a 10-turn wall that made "never
completes anything" a designed outcome, not an accident.

The thesis is that the runtime supplies the cognition the model lacks. Small models fail
at agenting for structural reasons — context amnesia, format drift, lost-the-plot drift,
silent failure acceptance — and Merlin answers each with deterministic machinery: grammar
constraints so a malformed tool call is unemittable rather than repaired, an append-only
ledger so context stays flat across turns, post-condition checks and an adversarial
verifier so a wrong answer cannot pass quietly, and a stop authority so a looping model
wraps up instead of burning its budget. The model reasons; Merlin does everything else.

The kernel is nine systems (M0–M8, plan.md §3 condensed):

| # | System | Kills | Mechanism |
|---|--------|-------|-----------|
| M0 | Task Spine | "wait, what was I doing?" | goal + plan sketch + state digest re-injected every turn |
| M1 | Constrained Actor | malformed tool JSON | llama.cpp grammar (`tools[]` / `json_schema` envelope); malformed calls unemittable |
| M2 | Token-Efficient State | 4k–8k context melt | append-only ledger + workspace artifacts; model sees collapsed summaries |
| M3 | Structured Memory | forgotten facts | facts/decisions/blockers/artifacts entries; digest every turn |
| M4 | Guardian | silent wrong answers | deterministic post-conditions per tool result; failures become explicit retry instructions |
| M5 | Verifier | self-delusion | `task_done` claim checked mechanically, then adversarially by a second model call |
| M6 | Stop Authority | infinite loops | turn budget + progress detector (identical-result fingerprints) + completion contract |
| M7 | Retry Budgets | flaky tool I/O | per-tool-class backoff, transient-only; retries never burn turn budget |
| M8 | Model Profiles | one size fits none | per-family tool-call rung, think-token floor, template notes |

**Status: shipped behind a toggle, default Classic, eval gate pending.** The app
integration (slice 5) and the full kernel are in the tree; the eval suite's real gate —
14/14 tasks on at least two bench models with axis gates green (SCORING.md §5) — has not
run yet. The first smoke run proved the pipeline end-to-end but was stopped by a
llama-server wedge that hit both machinery modes equally (see "Known limitations" and
`results/smoke-spark17/NOTES.md`). The default stays Classic until that gate passes;
flipping it is an operator-approved moment (AMENDMENT 3).

---

## For operators

### How to use it

1. Open **Chat Settings → Agents** and set **Agent engine** to **Merlin** (default is
   Classic). The toggle persists under `chatAgentEngine`.
2. Type the task text into the composer (leave it unsent — Merlin takes the draft as the
   goal) and **right-click the chat surface → "Run as Merlin task"**. The menu item only
   appears when the engine is Merlin, the local engine is running with a model selected,
   and no run is in flight.
3. While it runs, the transcript shows a **progress fence**: one folding code block that
   accumulates one line per event — `turn N started`, `turn N · fs_read: …`,
   `turn N · blocker: …`. Progress is derived by polling the run's ledger file (the
   kernel has no streaming callback), so lines land within ~100 ms of each tool call.
4. When the run ends, an **outcome card** lands as its own message:
   `### Merlin run · completed | budgetExhausted | failed` plus `turns: N/M` and the
   run's summary (the completion claim, or the kernel's reason for stopping).
5. **Stop semantics, honest:** while a run is in flight the menu offers **"Stop Merlin
   task"**. Clicking it flips a cancellation gate; the kernel observes it at the **next
   turn boundary** and ends the run as failed with "cancelled by the operator". A
   mid-flight model completion or tool execution is **not** interrupted — the help text
   on the button says the same thing.

### What Merlin can do today

**Ten tools**, all resolved through the run's workspace sandbox: `fs_read`, `fs_write`,
`fs_list`, `fs_grep`, `shell_run` (cwd = workspace, fixed five-variable environment,
30 s wall clock, SIGTERM→SIGKILL ladder), `js_eval` (host-free JavaScriptCore context),
`todo_write`, `todo_read`, `note_add`, `task_done` (the explicit completion contract —
a run only ends as completed through it, citing its artifact paths).

**Workspace sandbox:** each run gets its own directory. In the app it lives under
`Application Support/Kestrel/MerlinWorkspaces/<uuid>/`; the CLI defaults to
`~/.kestrel/merlin/workspaces/<task-id>/`. A `.merlin-lock` marker pins each workspace to
one task id. Every path a tool touches is resolved and re-checked through
`MerlinWorkspace` — see the security section below for the exact guarantees.

**Per-model profiles** (M8): the kernel detects the model family from the GGUF filename
and picks the tool-call rung and completion budget from a measured matrix
(`MODEL-PROFILES-EVIDENCE.md`; live probes on the bundled llama-server, CPU, temp 0):

| Family | Rung (tool-call mode) | Think floor (`max_tokens`) | Notes |
|---|---|---|---|
| spark-x2.5 | 1 — native `tools[]` | 512 | byte-perfect on 1.7B and 4B; envelope also clean on 4B |
| lfm2.5 | 1 — native `tools[]` | 512 | engine flags the family grammar-sensitive — never the envelope; re-verify per release |
| deepseek-r1 | 1 — native `tools[]` + `reasoning_content` | **3000** | below floor + headroom the kernel refuses to run, loudly |
| qwen3.5 | 1 — native `tools[]` | 512 | dual-capable: envelope also clean |
| glm-4 | 2 — `json_schema` envelope | 512 | rung 1 fails and hallucinates results; kernel translates envelope content |
| unknown | 3 — rescue ladder | 512 | auto-promotes to rung 1 after 3 clean native parses; persisted to `~/.kestrel/merlin/profiles.json` |

Every completion runs with `max_tokens = floor + 512` headroom (M8 binding rule 3). A
configuration below that refuses at construction time instead of starving a thinking
model into inaction. Rungs flip only on captured evidence, never on a guess.

### Known limitations

- **`js_eval` has no preemption.** JavaScriptCore cannot interrupt a running script; a
  non-terminating script blocks the tool — and the run — indefinitely. The size cap
  (100 kB) bounds parse work, not runtime; the "watchdog" is observational only (it
  reports durations of completed evaluations).
- **Cancel lands at the turn boundary.** Nothing mid-flight is interrupted (see above).
- **llama-server wedge sensitivity.** The bundled server (0.6.0-dev build 11610)
  exhibited an accept-then-silence wedge under sustained multi-turn traffic during the
  smoke run: the slot launches, zero tokens are produced, and the request only ends on
  the client timeout. It hit Merlin machinery and the baseline equally (5/6 cells each),
  was not fixed by `cache_prompt:false`, and did not appear during single-tenant probes.
  Re-run the suite on a quiet box; investigate the server before burning matrix
  wall-clock (`results/smoke-spark17/NOTES.md`).
- **Envelope schema-sloppiness on GLM-4.** Rung-2 models sometimes emit argument keys
  that deviate from the schema; the journal's tuning note proposes per-tool-argument
  envelope branches (mission journal, slice-6 notes).
- **Media tools are NOT included.** Video/audio/image generation tools are deferred to a
  dedicated phase after the core agent passes eval (AMENDMENT 1). The legacy media paths
  are documented in `DIAGNOSIS.md` and are out of the core gate.

---

## For developers

### Kernel map

| File (`Sources/Merlin/`) | System | One line |
|---|---|---|
| `MerlinKernel.swift` | loop + seams | The turn loop: spine prompt → actor batch (1–4 calls) → sequential execution (registry, guardian, ledger, budget check per call) → outcome; owns `MerlinActor`, `MerlinActorWithFeedback`, `MerlinTurnFeedback`, `MerlinOutcome`. |
| `LlamaServerActor.swift` | M1 | The model-facing actor: three-rung ladder against the bundled llama-server's OpenAI endpoint; keeps the transcript via turn feedback. |
| `TaskSpine.swift` | M0 | Pure prompt builder: goal + plan sketch + state digest + tool contract; no I/O. |
| `Ledger.swift` | M2 + M3 | Append-only JSONL ledger — the run's only ground truth; ≤200-char result collapse; digest is a pure function of entries. |
| `ToolRegistry.swift` | tool surface | Ten tools with schema + description + handler each; execution wrapped in M7 retry; fs tools refuse the ledger file directly. |
| `ToolSchema.swift` | M1 input | Wire payload catalog (`tools[]` array + `json_schema` envelope) compiled live from the registry, so advertised and executed surfaces cannot drift. |
| `MerlinGuardian.swift` | M4 | Deterministic post-conditions per tool class, re-derived from workspace and ledger; a rejection becomes an explicit retry instruction, not a run end. |
| `MerlinVerifier.swift` | M5 | Two-layer completion check: mechanical artifact verification always, plus an adversarial second model call. |
| `MerlinStopAuthority.swift` | M6 | Progress detector: fingerprints each executed call as a result signature; N identical signatures demand wrap-up. |
| `Retry.swift` | M7 | Classifies faults (transient vs model mistake), retries transient ones with backoff inside the tool turn. |
| `ProfileStore.swift` | M8 | Family matrix + GGUF-name detection + think-floor gate + unknown-family auto-promotion (`~/.kestrel/merlin/profiles.json`, best-effort persistence). |
| `Workspace.swift` | sandbox | Per-task sandbox: three path rejections, canonical root, `.merlin-lock`. |
| `MerlinShell.swift` | compute tools | `shell_run`: `/bin/sh -c`, workspace cwd, env allowlist, timeout ladder, pinned result contract. `MerlinJS`: host-free JavaScriptCore. |

App side: `Sources/Chat/MerlinChatService.swift` owns the whole app-facing surface
(toggle key, cancellable actor wrapper, runtime builder, run loop, transcript seams,
context-menu surface). `ChatNative.swift` is deliberately untouched. Eval side:
`Sources/MerlinEval/` — `main.swift` (CLI), `LiveDriver.swift` (live machinery, wall
guard, wire logging), `TaskSpec`/`Seed`/`Assertions`/`Scoring`/`Report` (mechanical
grading), `NaiveBaselineDriver` (SCORING §7 baseline).

### The actor seam

The kernel never talks to an LLM. It asks a `MerlinActor` for a batch:
`toolCalls(prompt:turn:) -> [MerlinToolCall]`, one to four calls per turn, one turn = one
model completion (AMENDMENT 2 — per-call round-trips to a CPU llama-server on a 9B model
cost 3–15 s; batching keeps wall-clock inside eval budgets).

`MerlinActorWithFeedback` adds `receive(feedback: MerlinTurnFeedback)`. The rationale is
measured, not aesthetic: in the eval-live probes the stock actor saw only its spine and a
bare "Begin turn N" cue, and re-issued the **identical failing call 6/6 turns** — the
model was blind to its own history. The kernel probes every actor with `as?` and hands
back each executed batch's outcomes (result text, error/guardian/verifier flags, stop
authority instructions) **before** the next `toolCalls` completion, so a transcript-
keeping actor can shape real assistant/tool wire turns. Plain `MerlinActor`
implementations keep working unchanged, with the spine digest as their only feedback.
The app's `MerlinCancellableActor` conforms (rather than wrapping opaquely) precisely so
the kernel's `as?` probe still hits through the wrapper.

### Running the kernel headless

```
merlin --task "<goal>" [--workspace dir] [--max-turns N]
```

Default workspace `~/.kestrel/merlin/workspaces/<task-id>/`, default budget 12 turns.
Note what this target is today: the **slice-1 plumbing runner**. It brings up the
sandbox, ledger, and spine, probes the tool registry with a real `fs_list`, and stops
cleanly — it does not construct the live model actor. The live-model path runs through
the eval target (below); wiring a live actor into the `merlin` CLI is open work.

### Running the eval harness

```
merlin-eval --tasks <tasks.json> --driver live --model-path <gguf> --port <n> \
            --machinery merlin|baseline [--task T01] ... [--interleave] [options]
```

- `--driver` — `scripted` (deterministic replay via `--script`), `naive-baseline`, or
  `live`.
- `--machinery` — `merlin` drives `MerlinKernel` + `LlamaServerActor` directly per task;
  `baseline` rides the `EvalTurnDriver` seam with the `NaiveBaselineDriver` completion
  hook (lenient parse, exactly one repair retry — SCORING.md §7 rule 2). Scoring is
  machinery-blind: the identical `ScoringEngine`, seeds, and assertions in both modes.
- `--temperature` (default 0), `--context-tokens` (default 8192),
  `--wall-guard-seconds` (default 600, min 30). A guard trip is recorded as
  `harness_timeout` — a documented harness event, not a model score.
- `--interleave` — run every selected task in both machinery modes, alternating which
  goes first per task (fairness rule 4).
- `--task` — repeatable id filter (default: all 14). `--runs-root` / `--report-out` /
  `--model` — run-tree root, report path, scorecard label.

The smoke used the **reduced gate**: tasks T01, T04, T07, T12, T13, T14 × both modes,
`--interleave`, Spark-X2.5-1.7B-Q8_0 on port 8180 (`-ngl 0 -c 8192 -t 16`, temp 0,
`cache_prompt:false`, max_tokens 1024 = profile floor 512 + headroom), 600 s wall guard.
Result: T01 passed in both modes (pipeline proven end-to-end); the other 10 cells were
stopped by the llama-server wedge. That run is **environment-limited evidence, not a
machinery verdict** — the delta table exists but means nothing yet.

**Wedge-retry policy** (documented in `results/smoke-spark17/NOTES.md`, codification
pending): one retry per cell after a wall-guard/timeout trip, then record the harness
event and move on — today a wedge costs the full guard window per cell. Also pending
from the same notes: the kernel transcript gap (the kernel never appends assistant/tool
turns to the actor transcript; the harness works around it with `LiveMerlinActor`)
should be fixed kernel-side before further integration.

### Suite governance

- The suite is **frozen at `merlin-eval-v1`** (14 tasks, 5 axes, machine-checkable only —
  five assertion kinds, no LLM judge). Any change to tasks, seeds, assertions, or budgets
  creates `merlin-eval-v2` and re-baselines everything. `tasks.json` is the machine
  twin and wins on divergence.
- **Machinery on/off protocol** (SCORING.md §7): the claim is the delta, not the absolute
  number. Baseline = same weights, same server, same system prompt, same 10-tool
  surface, same seeded workspaces, same `max_turns` — with M0–M8 off (free-form
  generation, lenient parse, full tool results echoed, no ledger/guardian/verifier/
  progress detection, hard budget cut). Fairness rules pin sampling, one parse-repair
  allowance, identical scoring, interleaved runs.
- **Anti-rationalization clause:** the baseline numbers ship in the report. A report
  containing only Merlin-mode numbers does not close slice 4's gate, no matter how good
  they look.
- **Suite gate:** 14/14 tasks under Merlin machinery on at least two bench models, axis
  gates green. Runs are once per cell; only harness-crash reruns are allowed, marked
  `rerun: harness`.

### Where results live

- Mission folder: `.agents/missions/2026-11-15-merlin/` — `plan.md` (architecture +
  amendments), `DIAGNOSIS.md`, `MODEL-PROFILES-EVIDENCE.md`, `ACTOR-CONTRACT-PROBES.md`,
  `journal.md` (append-only evidence log).
- Suite spec: `eval/TASKS.md`, `eval/SCORING.md`, `eval/tasks.json`, `eval/scripts/`,
  `eval/fixtures/`.
- Smoke run: `results/smoke-spark17/` — `NOTES.md` (verdict + wedge evidence),
  `out.txt` (scorecards + delta), `report.json` (+ per-mode reports),
  `runs/20261115-224033/{merlin,baseline}/<task>/` (per-task kernel ledgers and wire
  trajectories); the aborted first attempt is preserved at
  `runs/20261115-220758-aborted-wirelog-in-workspace/`.
- Default CLI run tree: `~/.kestrel/merlin-eval/runs/<timestamp>/`.
- Eval wire logs: `~/Library/Caches/merlin-eval-wirelogs/<task>-<mode>.jsonl` — outside
  the task workspace on purpose (the first smoke attempt put them inside and the model
  read them; that broke SCORING §7's identical-sandbox rule and the run was aborted).
- Kernel workspaces: app — `Application Support/Kestrel/MerlinWorkspaces/<uuid>/`;
  CLI — `~/.kestrel/merlin/workspaces/<task-id>/`.

---

## Security posture

**Sandbox guarantees (as enforced, from `Workspace.swift` + `MerlinShell.swift`):**

1. **Three path rejections.** Relative paths containing a `..` segment are refused
   outright. Absolute paths are accepted only when they canonicalize inside the root.
   Every resolved path goes through `realpath(3)` — symlinked final components included
   — and is re-checked against the canonical root, so a symlink planted in the workspace
   cannot launder an outside target.
2. **Single resolution point.** Every filesystem tool resolves paths through
   `MerlinWorkspace` only; there is no raw-path tool handler. The ledger file is refused
   to fs tools directly — run memory is mutated only through the ledger-backed tools.
3. **One task per workspace.** The `.merlin-lock` marker makes adoption of a workspace
   owned by another task fail loudly instead of silently sharing state.
4. **Shell containment shape.** `shell_run` executes `/bin/sh -c` with cwd = workspace,
   a fixed five-variable environment (`PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_ALL` — no
   proxy variables, no credentials, nothing else from the parent process), a 30 s wall
   clock with a SIGTERM→SIGKILL ladder, and a 4000-character output cap. The result
   contract's first line (`exit <code>` / `timeout:`) is guardian-pinned; a result
   without it is treated as suspicious, not as evidence.
5. **Host-free JS.** `js_eval` runs in a fresh JavaScriptCore context per call that
   exports nothing — no `fetch`, no `require`, no `process`, no file bindings. Contexts
   are dropped after each evaluation.
6. **Loud refusals over silent starvation.** The M8 think-budget gate refuses to run
   below floor + headroom at construction time; profile persistence degrades to
   session-only memory rather than failing the kernel.

**Open items — see `SECURITY-REVIEW.md` in the mission folder.** The auditor's review of
this kernel is being written concurrently and is the authoritative list; the known items
that motivated it include the JSC no-preemption hole above, the fact that `shell_run`
inherits the operator's real `HOME`/`TMPDIR` values (by design — the child needs a home —
which means the shell sandbox is a cwd-and-environment boundary, not a seatbelt), the
envelope schema-sloppiness on rung-2 families, and the kernel transcript gap documented
in the smoke notes. Read that file before trusting the sandbox boundary for anything
adversarial; this section describes only what the code enforces today.
