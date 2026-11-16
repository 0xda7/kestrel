# MISSION MERLIN — a small-model agent kernel for Kestrel Engine

**Date:** 2026-11-15 · Operator: Northlatch Labs · Goal: the most professional, advanced agent
runtime purpose-built for ≤9B local models — headless kernel + Kestrel app integration,
sandboxed workspace, eval-benched. "Something the world has never seen."

## 1. BRIEF (outcome, in the operator's words)

A user picks **any ≤9B GGUF from their models folder, presses one button, and gets an agent
that actually completes multi-step tasks** — reads/writes files in its sandbox, runs code,
recovers from its own mistakes, and knows when to stop — at a quality bar today's agents only
reach with 70B+ frontier models. Done means: the eval suite (≥12 agentic tasks) is green on the
≤9B bench on disk, and the same kernel is one tap away inside the Kestrel app.

**Thesis (why the world hasn't seen this):** frontier agents inherit frontier-model cognition.
Small models fail at agenting for *structural* reasons — context amnesia, format drift,
lost-the-plot drift, silent failure acceptance — not just capability reasons. Merlin wins by
making the **runtime** supply the missing cognition: constrained decoding for format,
deterministic machinery for memory/state, adversarial verification for correctness. The model
reasons; Merlin *does everything else*.

## 2. ESTABLISHED GROUND TRUTH (scouted, evidence-cited)

| Fact | Evidence |
|---|---|
| Engine v0.89.17, Swift/SwiftUI on vendored llama.cpp, main c971109, clean-synced | git/gh api, 2026-11-15 |
| Grammar-constrained tool-call channel (Mission C1) exists: `response_format json_schema` envelope admitting exactly one tool-call JSON shape; malformed/fenced/tagged blobs are unemittable | ChatToolsService.swift:666-691 |
| `ToolCallRescue` ladder repairs malformed calls on non-constrained paths | ChatToolsService.swift:565-616 |
| Dynamic tool-result clamping exists (`dynamicToolResultCap`) | ChatToolsService.swift:493 |
| Permission store + always-allow + revocation exists | ChatToolsService.swift:109-152 |
| JS sandbox service exists (`JavaScriptSandboxService.toolName`) | ChatNative.swift:1592 |
| Memory service with dedicated tool names exists | ChatMemoryService.swift |
| Agent turn-budget/pending-continuation concept exists | AgentContinuation.swift, ChatNative.swift |
| ≤9B bench on disk: GLM-4-9B-Q4_K_M, Qwen3.5-9B-distilled, LFM2.5-8B-A1B, Spark-X2.5-4B, sakana-7b, DeepSeek-R1-8B, Forge-1-E2B, lfm2.5-2.6b | `ls ~/models` |
| Bundled llama-server buildable from `vendor/llama.cpp/` | vendor tree present |

## 3. ARCHITECTURE (what makes Merlin Merlin)

**Kernel** (`merlin` target, headless, scriptable, CI-able). Nine systems:

| # | System | The small-model failure it kills | Mechanism |
|---|--------|-------------------------------|-----------|
| M0 | **Task Spine** | "wait, what was I doing?" | Every turn injects: goal + short plan sketch + last result summary. No amnesia possible. |
| M1 | **Constrained Actor** | malformed tool JSON | llama.cpp grammar (`json_schema` per-tool schemas + envelope) — malformed calls *unemittable*, not repaired. |
| M2 | **Token-Efficient State** | 4k-8k context melts | Ledger + artifact files in workspace. Full results live on disk; model sees ≤N-line summaries. Context stays flat across turns. |
| M3 | **Structured Memory** | forgotten facts across turns | Deterministic key-value ledger (facts, decisions, blockers) + vector-lite recall via existing memory service. |
| M4 | **Guardian** | silent wrong answers | Post-condition checks per tool result (file exists? test green? JSON valid?); failures become explicit retry instructions. |
| M5 | **Verifier Persona** | self-delusion | Separate tiny verify call at milestones with adversarial prompt: "prove this is done, or name what's missing." Never trusts the worker's self-report. |
| M6 | **Stop Authority** | infinite loops | Turn budget + progress detector (identical-result repeats → force wrap-up), completion contract: final answer must cite artifacts. |
| M7 | **Retry Budgets** | flaky tool I/O | Per-tool-class retry w/ backoff, classified errors, never burns turn budget on retry. |
| M8 | **Model Profiles** | one size fits none | Per-model-family config: prompt style, tool-call mode (grammar/envelope/rescue), thinking-tag handling (R1 `<think>` already handled in engine), context budget, guard off-switches. |

**Tool surface** (all workspace-sandboxed): `fs_read`, `fs_write`, `fs_list`, `fs_grep`,
`shell_run` (cwd=workspace, no network env), `js_eval` (existing JSandbox), `todo_write`,
`todo_read`, `note_add`, `task_done` (explicit completion contract).
**Sandbox**: per-task workspace dir; allow-once permission prompts reuse the engine's existing
permission store; outside-workspace access requires prompt.

**App integration**: Merlin run = a chat mode in ChatNative that drives the kernel; run card
shows ledger, tool trace, verdict. Existing UI patterns (ChatToolViews) reused.

**Eval harness** (`merlin-eval` target): 12+ tasks across 5 axes (single-tool use, multi-step
file ops, code-fix loop, retrieval+synthesize, recovery-from-error), scored mechanically
(artifact assertions), pass gate per model, full report per run.

## 4. WORK SLICES

| # | Slice | Owner | Deliverable | Verification gate |
|---|-------|-------|-------------|-------------------|
| 1 | Kernel skeleton: Task Spine, ledger, workspace sandbox, tool registry | `kernel-1` | `merlin` target builds; unit checks in suite | build green; new checks pass |
| 2 | Constrained Actor (M1) + Model Profiles (M8) on bundled llama-server | `kernel-2` | grammar-driven tool calls end-to-end on 2 models | raw curl: 20/20 valid calls, 0 repairs needed |
| 3 | Guardian + Verifier + Stop Authority (M4-M6) | `kernel-3` | failure→retry→wrap-up machinery + tests | fault-injection tests pass; loop terminates ≤budget on 3 adversarial cases |
| 4 | Eval harness + 12 tasks, baselines on 3 models | `eval-1` | `merlin-eval` target + report | harness runs 3 models end-to-end; mechanical scores produced |
| 5 | App integration (chat mode + run card) | `app-1` | Merlin surface in Kestrel app | build green; manual smoke via app |
| 6 | Tuning pass against eval failures | lead | profiles/prompt fixes | eval deltas recorded; ≥1 weak model improves |
| 7 | Docs + CHANGELOG + close-out | lead | docs/merlin.md, CHANGELOG entry | docs build on real behavior, not claims |

Sequencing: 1→2→3 may partially overlap after skeleton lands; 4 needs 1-3; 5 needs 1; 6 after 4; 7 last.

## 5. RULES

- Doctrine: check, don't assert. Every gate closes on captured output.
- One writer per file: workers own their slice files; lead merges.
- Model runs are local only (bundled llama-server), no external API spend.
- Irreversible actions (commit/push/tag) = operator gates.
- Amendments append below, never silent drift.

## AMENDMENTS

AMENDMENT 1 (2026-11-15, operator + lead): **Scope redefined by operator.** The existing
product agent harness (chat agent loop, its tool execution paths, and the video/audio/media
tool surfaces) is confirmed broken/unfinished by the operator: "full of errors and never
completes anything." Lead's live probes corroborate: GLM-4-9B falls out of the tool channel
entirely and hallucinates tool results; R1-8B exhausts its budget thinking without acting;
tool results are invented rather than executed.

Consequences, binding for this mission:
1. Merlin is the **replacement** agent runtime for the product, not a parallel experiment.
   Slice 5 (app integration) retargets: the Merlin kernel becomes the engine's agent path;
   the legacy loop is retired behind a feature flag after Merlin passes its gates.
2. NEW Slice 0 (diagnosis): capture a failure inventory of the existing agent loop with live
   repro evidence (file:line + captured output), so "never completes anything" is a measured
   before-number, and Merlin's eval delta proves the fix.
3. Media tools (video/audio generation) join Merlin's tool surface in a dedicated phase AFTER
   the core agent passes eval (core first: fs/shell/js/memory/todo on ≤9B; then media as
   first-class Merlin tools). Unfinished legacy media paths are documented in the inventory
   and explicitly out of the core gate.
4. Operator note honored: small models + tools + agentic work is THE product requirement;
   every gate is judged on the ≤9B bench, never on a frontier model.

AMENDMENT 2 (2026-11-15, lead, design review of landed MerlinKernel.swift): **Actor seam
widened to batched calls.** The eval protocol (TASKS.md §2) defines a turn as ONE model
completion yielding up to 4 tool calls; the landed `MerlinActor.toolCall` returns exactly one.
Binding change before slice 2: `MerlinActor` produces `[MerlinToolCall]` (1...4) per turn —
the kernel executes them sequentially (guardian reviews each; ledger records each; turn budget
checked after each; `task_done` in a batch ends the run immediately, remaining calls dropped).
Rationale: per-call round-trips to a CPU llama-server on a 9B model cost 3–15s each; batching
keeps wall-clock inside eval budgets and matches the harness protocol the suite was validated
against. Slice 2's actor + eval harness are built against this shape.

AMENDMENT 3 (2026-11-15, lead, slice-5 integration design): **App integration ships behind a
toggle; legacy retirement is a separate operator gate.** (1) A chat-settings toggle
"Agent mode: Merlin | Classic" (default Classic until the eval suite gate passes; flipping the
default is an operator-approved moment). (2) Merlin mode routes sends through a new
MerlinChatService that drives MerlinKernel + LlamaServerActor against the app's ACTIVE
server/model selection (no second server spawn); the run renders in the existing transcript
using ChatToolViews patterns: per-call tool cards + a final run card (outcome, turns, ledger
digest, artifacts). (3) The legacy loop stays intact for rollback this release; removal is a
future mission after a release cycle on Merlin-default. (4) Media tools remain out of scope
for slice 5 per AMENDMENT 1 (post-core phase).

AMENDMENT 4 (2026-11-15, operator + lead): **Full-closure approval.** Operator approved all
pending decisions ("approval for all the requests"). Sequenced professionally:
1. Security fixes FIRST (SECURITY-REVIEW.md §3 minimal fix list): sandbox-confined shell with
   process-group kill + scratch HOME (fixes CRITICAL N1 durable half + HIGH N2), js_eval moved
   into a killable child process (new Sources/MerlinJSHelper target) with cancel-takeover
   (HIGH N3), schema honesty — the "network disabled" claims corrected to env-hygiene truth
   (ToolSchema/ToolRegistry/MerlinShell), ledger-forgery screens case-insensitive
   (ToolRegistry), injection defanging (outcome summary plain-text in MerlinChatService;
   verifier prompt data-framing in MerlinVerifier). Each with checks.
2. Commit waves: wave 1 = pre-mission slots patch (independent, already green, verified 703/0
   on 2026-11-13 and included in every suite run since); wave 2 = Merlin code + Package.swift
   + CHANGELOG + docs once hardening is green; wave 3 = mission evidence + eval results. Push
   after each wave's contents verified.
3. Eval gate: full 14×2 suite re-run on the FIXED, COMMITTED tree (wedge-retry machinery now
   in place; box currently quiet — load 1.92, zero servers); ≥2 bench models if it holds;
   gate = 14/14 merlin + axis gates per SCORING.md §5.
4. Merlin default flips to ON only if the gate passes (commit wave 4).
5. Media-tools phase: plan document staged; code only after the hardened core ships.

