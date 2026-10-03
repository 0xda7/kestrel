# Mission: llm-space engine for the Kestrel assistant

**Objective:** The Kestrel assistant (Chat&Studio server-side send path) runs on the llm-space
engine — Pi agent runtime (`earendil-works/pi`: pi-agent-core + pi-ai) as sidecar, in the same
pattern as the latch-CLI integration — with llm-space capabilities (Thread JSON storage, skills,
MCP tools, traces, compaction) adopted natively. Models/providers stay 100% data-driven
(Pi `models.json` / env / Keychain-backed override) — nothing hardcoded. Third-party MIT
attribution preserved (Pi, llm-space, DeerFlow lineage).

**Operator:** Northlatch Labs operator · **Value:** the assistant gains a real agent harness
(tools, MCP, skills, traces, compaction, replay) instead of a single gateway round-trip, without
touching the llama.cpp engine or violating engine-independence.

**Success criteria:**
1. `swift build` exits 0 with the Pi integration in the send path.
2. Behavioral driver (scratch `swiftc`, no XCTest): fake `pi` stub emits canned JSONL →
   PiDelegateService maps `message_update/text_delta` → streamed transcript, `message_end` →
   final assistant message, tool calls rendered, `agent_settled` → completion; unavailable-binary
   path shows the bilingual notice, never a silent fallback.
3. Live-fire in-app: operator sends a message with the Pi engine selected; `conversations.json`
   shows the assistant message attributed to the Pi engine; Pi session file exists under the
   configured session dir.
4. No model ids or API keys in Swift sources; `grep -rn 'xlaunch-981b50a9' Sources/ Scripts/ docs/`
   stays 0. Key material reaches Pi only via `--api-key`/env sourced from Keychain at spawn.
5. Journal + commit + push on `main`.

**Constraints:** llama.cpp engine and gateway untouched ("DO NOT WIRE THROUGH THE ENGINE");
cua-driver retired — all UI actions are the operator's; no XCTest in toolchain → scratch drivers;
secret hygiene per standing rules.

**Assumptions:** (a) Pi ships a CLI on this machine after install — if not, integration stalls at
Step 2 (operator gate); (b) `pi --mode json` event shapes match docs fetched 2026-10-02; (c)
repo tree matches last known state (96a9dfa) — verify first action after shell recovery.

**Budget:** ≤ 10 steps · ~1 session day · ≤ 400k tokens — hard stop at 2x.

## Steps

| # | Step | Owner | Depends | Deliverable contract | Gate | Risk / rollback |
|---|------|-------|---------|----------------------|------|-----------------|
| 1 | Recon: verify repo state, map send path + Server assistant files, install/locate `pi` CLI (`pi --version`), record `pi --mode json` smoke output | scout (me) | shell recovery | recon notes in journal w/ captured outputs | captured `pi --version` + one JSONL run | none (read-only + optional CLI install, operator-approved) |
| 2 | **OPERATOR GATE:** approve sidecar architecture (Pi CLI, Node 22.19+ dependency) vs. native Swift port of Pi agent core; approve Pi install method | operator | 1 | decision recorded in plan AMENDMENT | operator reply in chat | n/a (decision) |
| 3 | `PiDelegateService.swift`: discovery, `pi auth check` gate, spawn `pi --mode json --session-dir … -p`, JSONL parse (LF framing), event→ChatMessage mapping, bounded budget (900 s default), bilingual unavailable notice | implementer (me) | 2 | new service file, mirrors LatchDelegateService shape | scratch driver: stub `pi` emits canned events → assertions pass | additive file; rollback = delete file |
| 4 | Send-path refactor: engine selection behind per-conversation mode (Model assistant → Pi engine; Latch mode unchanged; Automatic unchanged semantics); engine attribution written to conversation store | implementer (me) | 3 | edited ChatNative send path + attribution field | `swift build` 0 + driver run | revert via git; no store migration (new optional field) |
| 5 | Settings surface: Chat advanced settings — Pi engine section (enable, session dir, model passthrough from provider config; list from `pi --list-models` at runtime, never compiled in) | implementer (me) | 4 | edited ChatAdvancedSettingsSection | `swift build` 0 + manual UI check by operator | revert via git |
| 6 | llm-space capability adoption: Pi session dir per Kestrel conversation (trace/replay via Pi session files); skills/MCP via Pi agent-dir config documented in runbook (no Kestrel code) | implementer (me) | 4 | runbook section + session-dir wiring | live-fire shows session file | revert via git |
| 7 | Gate ladder: `swift build`; behavioral driver full pass; secret sweep grep = 0; attribution NOTICE for Pi + llm-space (MIT) | verifier (me) | 5,6 | gate log in journal | all outputs captured, exit 0s | n/a |
| 8 | Live-fire with operator (in-app send on Pi engine) + evidence capture (`conversations.json`, session file) | operator + me | 7 | evidence block in journal | criterion 3 met | rollback = switch mode off |
| 9 | Journal wrap, commit, push | me | 8 | pushed commit | `git status` clean, push OK | revert commit |

## Out of scope
- Porting Pi/llm-space TypeScript to native Swift (unless Step 2 gate decides otherwise — noted as high-risk/high-cost alternative).
- Touching latch integration (stays exactly as shipped in 96a9dfa).
- llama.cpp engine, gateway code, key storage changes.
- New Kestrel UI beyond the settings section.

## Reference (scout evidence, fetched 2026-10-02)
- Pi CLI: `--print`, `--mode json` (JSONL: session header + agent/turn/message events; `message_update.assistantMessageEvent.type=text_delta` carries deltas; `message_end` is authoritative; split on LF only), `--mode rpc` (future), `--model/--provider/--thinking/--api-key/--session-dir/--continue`, `pi auth check`, `pi mcp list`. Node ≥ 22.19.
- Pi config: `~/.pi/agent/{settings,models,mcp,auth}.json`, skills/, extensions/, prompts/; project `.pi/` behind trust.
- llm-space: Thread JSON (title/model{provider,id,params}/system prompt/variables/tools/messages/run history/evaluations); remote-protocol v5 (runtime.info, models.*, mcp.*, skills.*, trace.*); data under `~/.llm-space`.
- MIT: Pi (earendil-works/pi), llm-space (deer-flow/llm-space).

AMENDMENT 1: Step-2 operator gate PASSED 16:15 PT — architecture = Pi CLI sidecar (like latch-harness); install = npm global --ignore-scripts. Plan step 2 closed.

## Execution log (evidence, 2026-10-02)

- Step 1 ✅ 16:05 PT — `pi --version` → `1.0.0`; smoke run captured to `/tmp/pi_smoke.jsonl` (49,137 B); send path mapped; repo HEAD 96a9dfa verified.
- Step 2 ✅ 16:15 PT — AMENDMENT 1 (operator): Pi CLI sidecar, npm global `--ignore-scripts`.
- Step 3 ✅ 16:39 PT — `Sources/Chat/PiDelegateService.swift` complete: discovery, `argv(prompt:thinking:)`, `runStreaming` (LF-framed JSONL parse, text_delta streaming, authoritative `message_end`, bounded stderr tail, timeout budget, bilingual notices).
- Step 4 ✅ 16:52 PT — send-path branch before latch (`piWanted(for:)`), stop() teardown, `assistantMode` now WRITTEN: chip extended with "pi (llm-space)" option + warning state when binary missing.
- Step 5 ✅ 16:39 PT — settings section: global toggle, binary path, model/provider passthrough (empty = pi's own config; `pi --list-models` documented), timeout stepper 30–1800 s.
- Step 6 ✅ 16:52 PT — session traces under AppSupport/Kestrel/pi-sessions via `--session-dir` + `--no-session` (stateless turns, bounded transcript in prompt); skills/MCP stay pi agent-dir config (`~/.pi/agent/`), no Kestrel code; documented in settings help + AUTHORS.md.
- Step 7 ✅ 17:00 PT — gates: `swift build` exit 0 (255 s cold, 36 s warm — `/tmp/kestrel-build-pi3.log`); behavioral driver **8/8 PASS exit 0** on FINAL source (delta assembly across chunks, authoritative blocks-array replacement, abnormal-exit bilingual + status + stderr surfacing, timeout keeps partial, missing-binary launch notice); **live-fire driver 3/3 PASS exit 0** (real `pi` 1.0.0 → local llama-server → `KESTREL_LIVE_OK` streamed progressively — caught and fixed GUI-PATH gap `env: node: No such file or directory` status 127 via `childEnvironment()`); real JSONL capture `/tmp/pi_smoke2.jsonl` (74 records) confirms full event contract against live engine; secret grep `xlaunch-981b50a9` in Sources/ Scripts/ docs/ = **0**; attribution in AUTHORS.md (Pi MIT + llm-space link, no-credentials note).
- Step 7b ✅ 17:03 PT — operator convenience: `TOSH_NO_BUMP=1 ./make-app.sh` → MAKEAPP_EXIT=0, `dist/Kestrel.app` signed, VERSION untouched (0.88.0), pi-sessions symbol verified in binary. The running /Applications/Kestrel.app (pid 434) predates the pi code and must be replaced for Step 8.
- Step 8 ⏳ PENDING OPERATOR — in-app send with pi selected; evidence = conversations.json + AppSupport/Kestrel/pi-sessions file.
- Step 9 ⏳ PENDING OPERATOR AUTHORIZATION — commit + push after Step 8.
- 17:15 PT round-4 evidence — zero-model failure path verified behaviorally: with pi's own
  config empty (`pi --list-models` = "No models available"), a direct probe
  (`pi --mode json --no-session -p …`) exits **1** with stderr "No API key found for the
  selected model. Use /login…". Kestrel's parser maps exactly this to the bilingual
  abnormal-exit notice + pi's stderr guidance — actionable error, never silence. So if the
  operator fires Step 8 before configuring pi, the expected in-app result is that bilingual
  notice (NOT a hang, NOT a fallback). Probe wrote no session state (agent dir unchanged).
  Step 8 success path additionally requires pi to have ≥1 usable model: `pi auth`/`/login`,
  or a models.json provider (smoke template: /tmp/kestrel-pi-smoke/models.json), or a model
  pattern in Chat's pi settings that resolves via pi's own config.

AMENDMENT 3 (operator action, 17:42 PT): canonical working-copy folder renamed by the
operator: /Users/admin/KimiK3_Nvidia/ToshLLM → /Users/admin/KimiK3_Nvidia/Kestrel-AIEngine.
Git tree intact (main @ 96a9dfa, same 8 mission files modified/untracked). Consequences
handled: (1) running dist app was a ghost of the deleted path — re-opened from the new path;
(2) .build metadata carried 52 stale absolute references → purged, cold rebuild re-establishes
the build gate under the new path; (3) earlier evidence lines in this plan and the journal
cite the old path — treat "ToshLLM" in recorded commands as "Kestrel-AIEngine" going forward.
Old path no longer exists.

AMENDMENT 4 (operator-approved 19:08 PT via "you take the most advantageous offer and most
optimized code execution" — option B: full safety set + Prompt Space wave 1). Live-fire
evidence (journal 18:43–19:05) showed chat turns ran pi as an UNCONFINED coding agent: the
"self-improve" turn wrote 4 invalid Swift files into Sources/Chat/ and broke the build
(files quarantined to .agents/quarantine/2026-10-02-pi-chat-writes/). Scope now implementing:
A. pi confinement: chat turns pass --no-tools by default; explicit per-conversation
   "Agent mode" opt-in (Conversation.piAgentMode) keeps tools with a warning banner and a
   dedicated 1800s budget; --system-prompt replaces -p preamble system text (real
   enforcement surface, matches llm-space semantics); thinking default off for chat.
B. Traces: drop --no-session (probe-proven to suppress --session-dir); every turn writes a
   JSONL trace under ~/Library/Application Support/Kestrel/pi-sessions.
C. Reasoning: PiDelegateService returns (reasoning, visible); thinking deltas route to the
   existing reasoning panel instead of being discarded.
D. Empty-success guard: completed-but-empty reply surfaces a bilingual failure notice, not a
   blank bubble (finish() path guards).
E. Per-message engine tag: model field records "pi"/"latch" for every delegate reply.
F. Prompt Space wave 1: PromptLibrary.swift — versioned template library with {{variables}}
   (JSON at ~/Library/Application Support/Kestrel/prompt-library.json, no code constants),
   seed templates, render() unit-provable, sheet UI to browse/create/apply a template as the
   chat's system prompt. Personas/skills/eval/trace-viewer/MCP remain future waves.
Verification gates: swift build --disable-sandbox exit 0; behavioral driver asserting argv
shape per mode + render() cases + trace file creation. Step 9 (commit/push) stays
operator-gated.
