# Mission: Kestrel Agent Harness Hardening ("baby Cordis" in-app)

Date: 2026-10-01 · Operator directive: "just the harness capabilities built better in the
current Agentic capabilities of the current app" — no separate product, no engine wiring
through a different runtime; strengthen the agent loop that already ships in Chat & Studio.

## Verified baseline (captured this session)
- Engine-served builtin tools (`GET/POST /tools`, `x-tool-cwd`): read_file, edit_file,
  write_file, get_datetime, file_glob_search, grep_search, exec_shell_command, run_javascript
  — `Sources/Chat/ChatToolsService.swift:85`.
- Multi-turn loop exists: `AgentRunContext` + `remainingTurns` + permission gating +
  always-allow + queued-message interruption (ChatNative.swift:330, 1120–1200).
  Turn limit: `chatAgenticMaxTurns`, default 10 (ChatNative.swift:354).
- Isolation: `--tools-runtime` docker:/podman:/ssh: (Server.swift:94) — docker binary NOT
  installed on this machine (`which docker` exit 1), so container isolation is currently
  unavailable; documented, not silently assumed.
- latch: `~/.latch/bin/latch-harness` v1.0.0-alpha.1, embedded node v24.14.0, `doctor` healthy,
  headless `--prompt`/`--attach` + stdio app-server. `~/.local/bin/latch` shim is broken
  (`exec: node: not found`) — bridge calls the binary directly, never the shim.

## Phases (each closed on `swift build` +, where behavior, live-fire on operator's model)
- H1 Tool-call robustness for small models: tolerant `parseArguments` (BOM, markdown fences,
  trailing commas via string-aware scan; empty → {}), and a text-side rescue that converts a
  `<tool_call>{…}</tool_call>` or fenced {"name","arguments"} block into a real tool call when
  the engine emitted none. Tool-result clamp with [truncated] marker before it enters context.
- H2 Latch delegation tool: app-side `latch_delegate` tool (Process → latch-harness --prompt,
  --attach), settings-driven binary path + timeout (SettingsKeys, no hardcoded models),
  permission-gated like every write tool, streamed result into the existing tool-call card.
- H3 Harness discipline: harness system-prompt section (one tool at a time, verify before
  final answer, stop when done) appended only when tools are active; turn/tool counter in the
  agent summary.
- H4 Runtime-status honesty: chat advanced settings show whether the configured
  --tools-runtime backend (docker/podman/ssh) binary actually exists on this machine.

## Out of scope
- No code copied from deer-flow/llm-space or any external harness; concepts only.
- No model names hardcoded anywhere; latch runs its own account/config.
- Engine (llama.cpp fork) untouched.

## AMENDMENT 1 (2026-10-01 16:2x PT)
H1–H4 all implemented and compiled (gates: `Build complete!` at 40.55s / 43.77s /
19.53s incl. discipline prompt, runtime-honesty check, overview benchmark button).
Commits f826a27 + d23d13a (release: 0.88.0), pushed; tag v0.88.0 pushed → CI run
36940659745 building branded engines + DMGs. G2 live-fire on the operator's real
model pending while CI runs. Wave-2 chunk 3 (Measure speed on server overview)
landed in the same commit stream.

## AMENDMENT 2 (2026-10-01 16:34 PT) — LIVE-FIRE DEFECT FOUND AND FIXED
Live-fire on the operator's real model (Qwen3.5-9B-distilled-IQ4_NL) against the bundled
patched engine exposed a ship-blocker the compile gates could never see: with the app's
exact agent-tools arg set (--jinja --tools all), GET /tools lists the builtins but
POST /tools answers 404 {"error":{"message":"this feature is disabled"}} — in-app tool
execution would have failed on every call. Adding --webui-mcp-proxy flips POST /tools on
(read_file VERSION → "0.88.0", exec_shell_command date → exit 0, grep_search → matches).
Fix commit 36f991e (both arg sites in Server.swift), gate `Build complete! (8.80s)`, pushed.
Evidence file: /tmp/g2_note.md (captured curl outputs). Engine half of G2 CLOSED; app-GUI
half (SwiftUI loop end-to-end) still needs the operator's run of the 0.88.0 build.
