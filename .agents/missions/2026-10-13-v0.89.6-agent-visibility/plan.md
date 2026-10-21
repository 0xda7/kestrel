# Mission — v0.89.6: Agent visibility, usable agentic Pi, keychain-free providers

Repo: `~/KimiK3_Nvidia/Kestrel-AIEngine` (main branch after engine upgrade lands)
Date: 2026-10-13 · Executor: atomic agent · Supervisor gates: kestrel-checks green + live UI verification
**RESOURCE RULES: same operator cap — nice -j2 single builds, load checks, one line at a time.**

## Operator's named pains (his words, verbatim requirements)

1. "Latch Agent in Chat&Studio shows NOTHING in what it is doing — the
   workflows, the subagents."
2. "I never use the Pi agent, never got the chance to properly use the
   agentic pi with tools."
3. "The providers were super shit locked on my keychain."

## Fix 1 — Latch delegate LIVE console in the chat UI

The data already streams: `LatchDelegateService.runStreaming` pumps every
stdout chunk through `onOutput`. The UI just never shows it until the tool
finishes. Fix the experience:

- While `latch_delegate` runs, its tool card becomes a live console:
  streaming lines (auto-scrolling, monospaced), elapsed time, the budget
  countdown (timeout is known), and a working-directory line.
- Latch's own structured output (workflows, subagent activity markers)
  renders as indented sub-items when recognizable; raw lines stay raw.
- When the delegate finishes, the card collapses to the final report with
  a "show full transcript" expander. On timeout/abnormal exit, the partial
  transcript STAYS visible with the failure headline (never blank).
- Route: `execute(...)` currently forwards final result only; thread the
  existing `onOutput` snapshots into the tool-call presentation layer's
  live region (the streaming mechanism already exists for shell tool
  output — reuse it; do not invent a second path).

## Fix 2 — Agentic Pi, one click and visible

- Chat composer gains an "Agent (pi + tools)" toggle, visible per
  conversation: off by default (confinement rule unchanged), one click on.
- When on: the composer shows the working directory, the agent budget, and
  a plain-language line of what tool access means.
- Pi's tool activity (`toolcall_start` / `tool_execution_start` markers
  already parsed by PiDelegateService) must render in the reasoning panel
  live as named tool lines — verify end-to-end, fix if the stream is
  dropped anywhere between pump and panel.
- Settings burrow stays for binary path/model/timeout; the toggle is the
  front door.

## Fix 3 — Providers: keychain zero, forever

- Delete the dormant legacy Keychain item `remote-api-key` (operator
  approved this release; the delete never prompts).
- Grep-verify NO remaining read path touches Keychain for provider keys;
  add a check to LatchBridge/PiBridge suites pinning that provider keys
  come only from LocalSecretStore (a test-double Keychain that fails the
  suite if consulted).
- Settings → Providers: show each route's key storage ("local file" /
  "inherited — migrate now" with a one-click migrate that never prompts).
- After this, a fresh install + fresh routes must complete with ZERO
  system password dialogs — add that as a documented release-test step.

## Fix 4 — UI defect sweep for the release

- The three items above are the named ones. Supervisor collects the
  operator's additional UI bug list before dispatch; each gets the same
  treatment (fix + check where deterministic, verify in app otherwise).

## DoD

1. `swift run --disable-sandbox kestrel-checks` green (412 + new checks:
   delegate-stream wiring test with a scripted stub (the repo's
   kestrel-driver-r1 stubs fit this), pi-marker rendering path test,
   keychain-never-consulted test).
2. Live verification in the running app by the SUPERVISOR (not claimed by
   the agent): delegate console streams; pi toggle works; no password
   dialogs on fresh key save.
3. Journal; no commit until gated.

End with MISSION-STATUS: DONE or MISSION-STATUS: BLOCKED <reason>.
