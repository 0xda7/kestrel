# Mission — Remove Pi; Latch becomes the sole direct chat agent

Repo: `~/KimiK3_Nvidia/Kestrel-AIEngine` (main) · Date: 2026-10-14
Executor: atomic · Supervisor gates: kestrel-checks green, no dead references, live app verify
**RESOURCE RULES: 65% cap restored — nice -j2 single builds, load checks.**

## Operator decision (final)

"Only latch and his capabilities as the direct agent in my chat. I will
have only latch." Pi is REMOVED from the product.

## Remove (delete files + every reference)

- `Sources/Chat/PiBridge.swift`, `Sources/Chat/PiDelegateService.swift`,
  pi-specific UI (AgentContinuation*/agent-opt-in surfaces if pi-only),
  all Settings keys/UI: piBinaryPath, piPrimaryEnabled, piProvider,
  piModel, piThinkingLevel, piTimeout — sections in ChatSettingsView /
  ChatAdvancedSettingsSection / RemoteProvidersSection (keep LatchBridge
  sync), KestrelApp launch hook, Server.swift sync call.
- No generation of `~/.pi/agent/models.json` anywhere (app must not touch
  ~/.pi at all). LatchBridge ownership of ~/.latch/v2 stays untouched.
- Tests: remove PiBridgeTests file + its registry entry + any pi checks.

## Replace: latch as the DIRECT chat agent

- The chat's delegate turn (formerly pi) now runs through latch:
  `LatchDelegateService` gains a chat-turn mode — streaming stdout to the
  reasoning/live panel (same pump), final report = the assistant reply,
  budgets/abort reuse the existing latch machinery (60s floor, 900s cap,
  empty-output = surfaced failure, never blank).
- The conversation "agent" toggle = "Agent (latch + tools)", one click,
  working directory + budget shown — this folds the v0.89.6 pi-toggle item
  into latch.
- Chat settings: one agent section (latch binary path, timeout) — provider
  routing unchanged (LatchBridge already pins kestrel-local default).

## DoD

1. `grep -ri "piBridge\|PiDelegate\|piBinary\|piPrimary\|/\.pi/" Sources/`
   returns ZERO source references (changelog/docs mentions of history OK).
2. `swift run --disable-sandbox kestrel-checks` green (count = 412 minus
   removed pi checks, all remaining green; state the final count).
3. App builds; supervisor live-verifies: chat turn via latch streams and
   answers; agent toggle works.
4. Journal every removal decision; NO commit.

End with MISSION-STATUS: DONE or BLOCKED <reason>.
