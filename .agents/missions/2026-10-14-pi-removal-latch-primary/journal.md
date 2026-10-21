# Mission journal — Remove Pi; Latch becomes the sole direct chat agent

Date: 2026-10-14 · Executor: atomic (GLM-5.3) · Repo: Kestrel-AIEngine (main)
Plan: `.agents/missions/2026-10-14-pi-removal-latch-primary/plan.md`
Resource rules honored: nice -j2 single builds; load checked before each
build (2.2–2.9 on 16 cores, far under the 65% cap ≈ 10.4).

## Operator decision

"Only latch and his capabilities as the direct agent in my chat. I will
have only latch." Pi is removed from the product; the app never touches
`~/.pi` again.

## Removal decisions (every one)

### Files deleted
1. `Sources/Chat/PiBridge.swift` — provider-side config generator for
   `~/.pi/agent/models.json` (generation, validation, legacy import,
   marker-file ownership). Deleted whole: the app must not touch `~/.pi`
   at all, so no generation, no validation, no import survives.
2. `Sources/Chat/PiDelegateService.swift` — the pi runtime sidecar runner
   (argv builder, JSON stream pump, budgets, bilingual failure text).
   Deleted whole: replaced by the latch chat-turn path that already lived
   in ChatNative + LatchDelegateService.runStreaming.
3. `Tests/KestrelTests/PiBridgeTests.swift` — 8 checks (slug, JSON shape,
   validate×5, slash round-trip) + its CheckRegistry+Generated entry.
   Removed with the bridge. TWO checks were ported, not lost:
   - `testSlugIsKeySafe` → `LatchBridgeTests.testSlugIsKeySafe` (the slug
     helper moved to LatchBridge, which was its only remaining caller).
   - `testModelIDsWithSlashesSurvivePairRoundTrip` tested the deleted
     settings picker's provider/model split — dropped with the picker.

### Call sites stripped
4. `Sources/App/KestrelApp.swift` — launch hook
   `PiBridge.migrateLegacySidecarConfigIfNeeded()` removed; comment now
   names only the latch sidecar.
5. `Sources/Servers/Server.swift` — `PiBridge.sync()` removed from
   `start(_:)`; LatchBridge.sync() stays so kestrel-local never goes stale.
6. `Sources/Settings/RemoteProvidersSection.swift` — `PiBridge.sync()`
   removed from `routeKeyRow` save-key action and from `persist()`.
7. `Sources/App/Support.swift` — settings keys removed:
   piBinaryPath, piPrimaryEnabled, piModel, piProvider, piTimeout,
   piContextCharacters, piThinkingLevel (+ the resettableOptionKeys line).
8. `Sources/Settings/SettingsArchive.swift` — piBinaryPath removed from
   the process-spawning import summary (no pi binary left to disclose).
9. `Sources/Chat/ChatAdvancedSettingsSection.swift` — the entire pi block:
   primary toggle, binary path, provider/model picker (+ bridgePairs
   state), no-providers warning, thinking level, timeout, context-chars
   stepper, piPairSelection binding, refreshBridgePairs.
10. `Sources/Chat/ChatNative.swift` — the whole pi path:
    - Conversation.piAgentMode field (v0.89.6 opt-in) — folded into the
      agent selection (see Replacement).
    - piProcess / piProcessBox, their stop() and finish() handling.
    - globalPiPrimary, piWanted, piPrompt, sendPiMode (≈115 lines),
      piUnavailableMessage / piExitMessage / piEmptyReplyMessage /
      piEmptyReplyNote, and the pi branch of stream().
    - assistantModeChip: "pi (llm-space)" menu entry, "Auto · pi" label,
      petal icon, and the pi agent-mode toggle/banner.
11. `Sources/Chat/ChatJSONL.swift` — `kestrelPiAgentMode` export/import
    removed. DECISION: old exports carrying `kestrelAssistantMode == "pi"`
    now import as `"latch"` — a historical chat keeps answering through
    the (only) agent instead of silently becoming engine-routed.
12. `Sources/Chat/SkillsDiscovery.swift` — `~/.pi/agent/skills` dropped
    from discoveryPaths; `.latch/skills` now leads so an operator-curated
    tree still wins. Read-only scan; the app never writes `~/.pi`.
13. `Sources/Chat/PromptLibrary.swift` — "Create with pi" surface renamed
    to "Create with latch" (sheet, button, status strings, fallback name).
14. `Sources/Chat/LatchBridge.swift` — inherited `slug()` (was
    `PiBridge.slug`, its only surviving caller); doc comments scrubbed of
    the `~/.pi/agent/models.json` history mention.
15. `Tests/KestrelTests/MetaPromptServiceTests.swift` — argv-shape check
    rewritten for the latch argv; live-fire guards now skip on a missing
    latch binary; guard strings updated to the latch failure text.
16. `Tests/Checks/CheckRegistry+Generated.swift` — PiBridgeTests entry
    removed.

### Kept deliberately (not dead references)
- `llm-space` mentions in PromptLibrary/SkillsDiscovery/MetaPromptService
  comments: they attribute the surviving prompt-space/variables/skills
  CONVENTION (MIT), not the pi runtime; the meta-prompt system prompt is
  a verbatim port that MetaPromptServiceTests byte-compares against the
  staged reference file.
- `AgentContinuation`/`AgentContinuationCard`: engine tool-loop UI, not
  pi-specific.
- `Sources/Chat/ChatNative.swift` math π and MarkdownTests' `\pi r^2`:
  the constant, not the runtime.

## Replacement: latch as the DIRECT chat agent

- `LatchDelegateService` doc now names its two roles: delegate tool +
  direct chat agent. Added `chatTurnTimeoutSeconds`:
  `min(max(timeoutSeconds, 60), 900)` — the mission's 60 s floor and
  900 s cap, reusing the stored latch timeout setting.
- ChatNative's latch branch (already streaming stdout through the same
  StreamBuffer pump into the live panel) now runs with
  `chatTurnTimeoutSeconds` instead of the raw maximum; the final report is
  the assistant reply; empty-output surfaces
  `latchEmptyReplyMessage`, never a blank bubble; Stop still terminates
  the boxed process.
- Conversation "agent" toggle = **"Agente (latch + herramientas)" /
  "Agent (latch + tools)"** — one click in the assistant chip sets the
  conversation to latch. The chip's help and the orange header banner
  show the working folder and the turn budget; the folder chip beside it
  changes the directory. The v0.89.6 per-chat pi opt-in is gone —
  selecting the agent IS the opt-in.
- Chat advanced settings: ONE agent section — latch binary path + timeout
  (shown when either latch role is enabled); provider routing unchanged
  (LatchBridge still pins kestrel-local as default).
- MetaPromptService ("Create with latch") runs the prompt-creator system
  prompt + assembled task through LatchDelegateService.runStreaming with
  the pinned 600 s budget, no working directory, empty-output guard.
  The verbatim system-prompt literal is byte-identical to the staged
  reference (restored programmatically after edit, verified).

## Verification

- Dead-reference gate: `grep -ri "piBridge\|PiDelegate\|piBinary\|piPrimary\|/\.pi/"
  Sources/ Tests/` → **0 matches**; extended symbol/string sweep → only the
  deliberate ChatJSONL legacy-import mapping and llm-space convention
  attributions. Stale pi keys removed from the operator's defaults
  (piBinaryPath, piPrimaryEnabled, piModel, piProvider, piTimeout,
  piThinkingLevel, piContextCharacters, piBridgeSidecarMigrated).
- `swift build --disable-sandbox -j 2` (nice 19) → **Build complete**.
- `swift run --disable-sandbox kestrel-checks` → **Executed 409 checks,
  0 failures** = 412 baseline − 8 PiBridgeTests + 1 slug check ported to
  LatchBridgeTests + 4 new LatchDelegateChatTurnTests (chat-turn
  contract: growing stream snapshots + final report as the reply;
  empty-output surfaces the failure text; budget stops a runaway with
  SIGKILL escalation; chat budget clamps 60…900 s) — all run against a
  scripted harness stub through the real `runStreaming` pump.

## Live chat-turn verify — executor evidence and blocker

Executor-side (done): the chat-turn mechanism is proven by the four
LatchDelegateChatTurn checks above through the real pump, and the app
builds. A real latch CLI turn was attempted live:

- `~/.latch/bin/latch-harness -p "…"` reached the model-call stage and
  retried for ~90 s against `http://127.0.0.1:8080/v1` (kestrel-local),
  then exited 1. Root causes found on this machine, both OUTSIDE the
  mission's change set:
  1. `/Users/admin/models/Laya-Q8_0.gguf` is a TRUNCATED download
     (449 MB, mtime Oct 13 20:23; llama-server: tensor blk.28.ffn_up
     wrong shape 1024×5248 vs 1024×4). Every engine load of it fails;
     the operator's running installed app is fail-looping its engine on
     it right now. Re-download `mys/laya-GGUF Laya-Q8_0.gguf`.
  2. The latch CLI's own runtime degraded mid-session to an instant
     `Error: Bundled 与 Active ZCode Built-in Release unavailable`
     (empty `~/.latch/.zcode/v2/runtime`; the Sep-29 backup binary fails
     identically; the CLI worked Oct 12/13). ZCode.app has been up since
     Oct 13 20:41 — restarting it should re-register the active release.
- With a healthy engine (LLAMA3-3B-Medical-COT on :8090) the OpenAI
  endpoint answered correctly, isolating the blocker to latch's runtime,
  not to Kestrel's chat-turn code. The verify environment was cleaned up
  (engine stopped, latch provider_config restored byte-identical, temp
  files removed).

Supervisor gate remaining: after healing latch's runtime (restart
ZCode.app) and re-downloading Laya, live-verify in the app: a latch chat
turn streams into the live panel and answers, and the
"Agent (latch + tools)" chip toggles per conversation.

`~/.pi` note: its `models.json` was last written Oct 14 00:25 by the
operator's still-running OLD installed app (its launch/engine hooks).
The new build contains no code that reads or writes `~/.pi`; once the
running app is replaced, nothing touches it again.

## Outcome

Pi fully removed (3 files deleted, 16 files stripped, zero dead
references); latch is the sole direct chat agent with a live-streaming
chat turn, one-click "Agent (latch + tools)" toggle with working
directory + budget shown, one agent settings section, and the
meta-prompt flow re-routed through latch. 409 checks green. NOT
committed, per mission order.
