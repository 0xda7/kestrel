# Kestrel Agent Harness — Product Specification

Kestrel is a local-first autonomous coding agent harness with its own
served inference. A goal goes in; verified work comes out. The models run
on Kestrel's own engine cards; the agent loop lives in the app; nothing
depends on a cloud or an external harness binary.

## 1. Architecture

- **AgentOrchestrator (app-side Swift).** The autonomous loop:
  plan → act → observe → verify → report, with bounded iterations.
  One orchestrator, N sessions. UI: a mission view showing every step,
  every diff, every command, live — plus a hard stop button.
- **Models are swappable data (the ruling).** Any tool-calling model on
  any running server card drives the loop; a second card can host a
  decision model for 33 ms gating between steps. Multi-server is the
  foundation: reasoner, decision gate, and draft model may be three
  different cards.
- **Tools (app-mediated, jailed):** read, write, edit (exact-match
  replace), glob, grep, shell — all scoped to the mission's working
  directory. File ops cannot escape the jail; shell runs with an
  explicit allow-list; no network egress by default. These reuse the
  existing chat tool dispatch and the engine's exec path — one tool
  implementation, not a second one (deep-clean enforces this).
- **Verification gates (the anti-bullshit core).** A mission declares its
  gate: a command (test suite, build, script) and its success condition.
  The agent may not report success until the gate passes — the same
  standard applied to this product's own development. Gate output is
  stored with the mission as the receipt.
- **Sessions:** persistent, resumable transcripts with every file diff;
  cancel and resume mid-mission; costs (tokens, wall time) per step.

## 2. Autonomy levels (per mission, operator-set)

- **L0 Supervised:** every tool call awaits approval.
- **L1 Guarded (default):** reads run free; writes/shell need approval
  unless allow-listed.
- **L2 Autonomous:** the loop runs to the gate; only gate failures and
  escalations pause it.
- **L3 Fleet:** multiple missions in parallel, each in its own working
  copy (git worktree isolation), with a shared model pool across cards.

## 3. Build phases

- **Phase A — Loop core:** orchestrator, mission view, file+shell tools,
  transcript+diffs, stop/resume, L0–L1. Gate: a real mission that edits
  code and passes its declared test command.
- **Phase B — Trust:** L2 autonomy, gate enforcement with receipts,
  budgets (steps/time/tokens), escalation questions surfaced in-app.
- **Phase C — Routing:** decision-model gating between steps (route/
  verify/continue) per the model-agnostic ruling; model fallback chains
  across cards.
- **Phase D — Fleet:** parallel worktree missions, queue, shared pool.

## 4. Non-negotiables

1. Nothing embedded or hardcoded; models, ports, gates, and tools
   configuration are operator data.
2. Multi-server composition in every feature.
3. No external harness binary; the loop is Kestrel's own code.
4. English only. No dead code (deep-clean baseline maintained).
5. Every capability: UI-reachable, documented in the operator manual,
   pinned by a check that fails without it.
