# SLICE 0 — LEGACY AGENT FAILURE INVENTORY (delivered 2026-11-15, worker 40e697f2)

Live repros: GLM-4-9B (port 8147) + R1-0528-Qwen3-8B (port 8148), bundled server b11610,
--jinja --tools all, CPU. Servers killed, ports verified clear. All file:line from current tree.

## P0 — run-killing
1. **GLM-class native tool channel broken; rescue can't parse the failure shape.** GLM emits
   `file_glob_search\n{"path":...}` ×4-7 → tool_calls:null, finish:length. Name sits OUTSIDE
   the braces; ToolCallRescue (ChatToolsService.swift:586-590, 623-663) requires name INSIDE →
   zero rescued calls → narration enters transcript. Envelope path WORKS for GLM (repro 1b
   byte-perfect) — but rung selection is a GGUF-metadata guess (EngineToolTemplate.swift:87-95):
   same family silently alternates working/dead rungs.
2. **Turn machinery = friction wall.** One call per turn (ChatNative.swift:1442-1474), per-call
   permission cards (ToolPermissionCard.swift:47-51), full regeneration per step, 10-turn budget
   (Support.swift:403) → continuation-click card (ChatNative.swift:1400-1414), budget resets to
   full on Continue (:1555). No progress/loop detection. "Never completes anything" is designed.
3. **Static budgets starve thinking models.** max_tokens=200 (clampedResponseTokens near full
   window, ChatNative.swift:912): R1 → finish:length, reasoning truncated, tool_calls:null,
   content:'' (repro 2c). At 2048 R1 works — but medium reasoning effort + 12k-char tool dumps
   (Support.swift:430) push the clamp into the starved regime every real turn.
4. **/tools 403s by default.** server.cpp:380-388 403s without --tools all; agentToolsEnabled
   defaults FALSE (ChatNative.swift:840, Server.swift:576-578) → agent discovers ZERO tools
   out of the box; ChatToolsService.list has no fallback (:154-163).
5. **Phantom tool get_datetime.** Parser carve-out (ChatToolsService.swift:354-358) + UI case
   (ToolCallPresentation.swift:82) exist; no executor anywhere → hallucinated capability,
   burned turn.

## P1 — degrading (8)
Envelope-miss → raw prose re-enters history, log-only (ChatNative:1294-1295); window clamp can
drop max_tokens below thinking need (no reasoning-floor, :901-913); queued message discards
pending tool calls (:1327-1329, 1494-1515); one 500 blocks tools model-wide persistently
(:1241-1242, Support.swift:1288-1310); shell bound to URLSession.shared 60s timeout
(ChatToolsService:236); result clamp by chars not tokens (:482-486); write-path no transient
retry (:199); rescue capped 3/turn (ToolCallRescue:566).
Wire find: assistant tool_calls message without following tool result → HTTP 400 hard-fail.

## P2 — unfinished capability
Video/image gen: requires Resources/bin-image/sd-cli which DOES NOT EXIST (ImageGen.swift:656-662)
→ UI "engine not installed". TTS: does not exist (0 grep hits). Media never wired as agent tools
(only attach-understanding paths, ChatNative:1879-1889). Memory tools app-local, non-portable
(ChatNative:2128). Slot restore errors swallowed (_ = try?, :1719-1723).

## Executive verdict — why ≤9B can't complete today
1. Tool-channel rung is a coin flip (broken native vs working envelope, GGUF-metadata heuristic,
   rescue can't parse dominant failure shape).
2. All cognition offloaded to the model while runtime adds friction (no spine/plan/verification;
   1 call/turn, per-call permissions, 10-turn wall + click).
3. Static token budgets vs dynamic thinking load + huge tool dumps → starvation exactly when
   working.

## MERLIN MAPPING (lead's merge note — how each P0 dies in the new architecture)
P0-1 → M8 ProfileStore: measured per-family rungs (GLM → envelope, verified), no metadata
guessing; envelope translation is the kernel's job. P0-2 → Merlin kernel: batched calls/turn,
sandboxed headless autonomy (no permission cards in eval/task mode), task_done completion
contract, turn budget with ledgered progress + planned M6 progress detector. P0-3 → M8
think-budget floors (R1 3000+512, loud refusal below floor). P0-4 → Merlin runs its own server
surface (--tools all) and owns the tool registry kernel-side; no /tools dependency. P0-5 →
ToolRegistry is the single source of truth; actors can only call registered tools.
