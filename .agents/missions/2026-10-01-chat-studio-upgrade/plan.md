# Execution Plan — Chat & Studio Upgrade (llm-space unification)

Mission: `2026-10-01-chat-studio-upgrade` · Status: PROPOSED, awaiting operator gate
Date: 2026-10-01 · Owner: Claude (agent) under operator approval

## 1. Objective

Upgrade the **Chat & Studio** surface (the main chat window, `Sources/Chat/` + its
`ConversationListView` sidebar) with the five capabilities that make
[deer-flow/llm-space](https://github.com/deer-flow/llm-space) valuable to agent
builders — **Build / Trace / Debug-Replay / Evaluate / Manage** — implemented
natively in SwiftUI on Kestrel's existing architecture.

## 2. Non-negotiable constraints (from operator directives)

- **No engine changes.** Everything below is app-layer (SwiftUI + existing
  services). `llama-server`, its flags, and the engine binaries are untouched.
- **No hardcoded models.** All model-dependent behavior flows through existing
  settings/profile seams.
- **Enterprise architecture preserved.** Controllers stay `@MainActor
  ObservableObject`; persistence via the existing `ChatNative`/`ChatJSONL`
  schemas (extended additively, never breaking old archives).
- **License hygiene.** llm-space is MIT; we port **concepts only** — zero code
  copied (it is TypeScript/React; ours is Swift). Credit line "Thread-trace and
  replay UX inspired by deer-flow/llm-space (MIT)" goes in About/docs only.

## 3. Grounding (verified this session, file:line)

| llm-space capability | What Kestrel already has | Gap |
|---|---|---|
| Build (prompts, tools, model settings per thread) | `SystemPromptCard`, `ChatSettingsView`, MCP tools via `ChatToolsService` | No per-thread **versioned recipe**; no reusable prompt library |
| Trace (every model call + tool run, live) | Tool calls persisted in messages (`ChatJSONL.swift:90-95`), rendered by `ToolCallPresentation` | No structured **timeline inspector** with latency/payloads |
| Debug (replay + step through) | Branch tree already stored (parents/children in JSONL), `ForkConversationSheet` | No **step-through replay** UI over the existing tree |
| Evaluate (measure across runs) | Per-message tok/s + token counts (`ChatResponseMetrics`) | No per-thread rollups or **fork-vs-fork comparison** |
| Manage (threads as files) | JSONL archive + import/export (`ChatNative.swift:402,1952-1964`) | Single-file store; no per-thread file, tags, or workspace search |

## 4. Phased work breakdown

### Phase 0 — Complete wave-2 first (already approved, in flight)
- Benchmark button, measured-config pre-fill, CI release (`plan-wave2.md`).
- Owner: agent · Deliverable: released v0.88.0 with captured live-fire evidence.
- **Rationale:** wave-2 is fully scoped with verified seams; landing it first
  keeps one release train per program.
- Gate: `swift build` clean + live-fire log + CI green + DMG artifact.

### Phase 1 — Trace inspector (wave-3a)
- New `ChatTraceController` (`@MainActor ObservableObject`): derives a timeline
  from a conversation's persisted messages — model calls (prompt/eval tok/s from
  existing `timings`), tool runs (server, name, duration, args/result JSON).
- UI: right-hand inspector panel in the chat window (toolbar toggle), collapsible
  rows, click-to-highlight the transcript message.
- Owner: agent · Deliverable: `Sources/Chat/Trace/` (controller + 2 views).
- Gate: `swift build` clean; live-fire trace on operator's real model showing ≥1
  model call and ≥1 MCP tool run with real latencies.
- Risk: none to existing flows (read-only view). Rollback: remove files.
- Budget: ~4 h.

### Phase 2 — Replay / step-through (wave-3a, same release)
- Replay mode walks the existing branch tree (already in the archive): step
  forward/back through nodes, jump to any branch point, metrics per step.
- "Fork from here" reuses `ForkConversationSheet`.
- Gate: live-fire replay over a real branched conversation from the operator's
  own archive.
- Risk: read-only over the tree; fork path already shipped. Budget: ~4 h.

### Phase 3 — Evaluate rollups (wave-3b)
- Per-thread rollup header: avg tok/s, total tokens, tool success rate, duration.
- Compare mode: pick two branches/runs → side-by-side metrics.
- Gate: captured rollup output on the operator's machine.
- Risk: pure aggregation over persisted data. Budget: ~3 h.

### Phase 4 — Build: thread recipes + prompt library (wave-3b)
- Per-thread "recipe": pinned system prompt + tool allowlist + generation
  settings, versioned as additive JSONL header fields (old archives decode nil).
- Prompt library: reusable prompts stored beside threads; insert into any thread.
- Gate: recipe survives app restart and archive round-trip on real model.
- Risk: schema extension — mitigated by optional decode (`decodeIfPresent`
  semantics like `BenchResult.threads`). Budget: ~4 h.

### Phase 5 — Manage: threads-as-files (wave-3c)
- One JSONL file per thread under `~/Library/Application Support/Kestrel/Threads/`
  (same record schema as today); automatic one-time migration from
  `conversations.json` with the old file retained as backup; workspace search,
  tags, quick export/share.
- **Highest-risk phase (data migration)** — ships last, behind a migration that
  only runs once and keeps a rollback copy.
- Gate: migration dry-run on a copy of the operator's real archive; zero message
  loss verified by record-count diff.
- Budget: ~5 h.

## 5. Verification gates (all phases)

G0 `PATH="/tmp/swiftshim:$PATH" swift build` clean · G1 brand audit
(`audit-brand.sh`, TRUE_RESIDUALS=0) · G2 live-fire on the operator's real model
with captured output (exact args + model + observed behavior) · G3 release chain
(CHANGELOG section, tag, CI green, DMG) · No "working" claims without G2.

## 6. Budget

- Estimate: ~20 h agent wall-clock across 3 release waves (3a: Trace+Replay,
  3b: Evaluate+Recipes, 3c: Manage+migration) + 15% buffer → ~23 h.
- Hard stop at 2× overage per wave; mission-control review at 90%.
- Each wave ends in its own tagged release (no mega-release).

## 7. Operator decision gates

1. Approve program scope + wave order (this document).
2. Sequencing: wave-2 completion before Phase 1 (recommended) or interleaved.
3. Each wave's release = operator-approved tag (irreversible action).
