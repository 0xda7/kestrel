# Kestrel Operator Manual — v0.89.12

Plain-English operating manual for the person who runs Kestrel daily.
Every "verified" claim below is backed by the check suite (426 checks,
0 failures, 2026-10-14) or by engine logs on this machine.

---

## 1. What Kestrel is

Kestrel runs language models locally on your Intel Mac with the AMD GPU.
It ships its own engine (llama.cpp fork), a chat app, and an agent tool
runtime: your model, running in the engine, calling tools — exec commands,
the JavaScript sandbox, MCP servers, and conversation memory. Nothing
leaves your machine unless you add a remote provider yourself.

## 2. Quick start

1. Open Kestrel (Applications → Kestrel).
2. Pick a model on the Home tab (your models live in `~/models`).
3. Press Start. The engine loads onto the AMD GPU (first load takes
   10–70 seconds depending on model size).
4. Go to Chat, type, send. Answers stream live.
5. To stop: press Stop on the Home tab. No background processes stay up.

## 3. What works — verified

| Capability | Status | Evidence |
|---|---|---|
| Local chat on text models (Qwen etc.) | Working | Engine log 2026-10-14 09:16: 12,614-token prompt, 1,042 tokens answered at 12 t/s |
| Agent Tools + JavaScript Sandbox | Working after 0.89.12 | The 2026-10-14 grammar failure on re-authored LFM2-family templates is fixed app-side; check pins the template bridge (`EngineToolTemplateTests`) |
| Gemma models (incl. vision) | Working after 0.89.10 | Two load-crashes 08:48/09:01 root-caused and guarded; regression check pins it |
| Conversation survives a failed turn | Working after 0.89.9/0.89.10 | The exact 400 "roles must alternate" from your logs is now merged away; check pins it |
| English-only interface | Working after 0.89.10 | Language picker removed; every label resolves to English; checks pin it |
| Providers you add yourself | Working | Settings → Providers; see §5 |

## 4. Known boundaries (honest list)

- **Embeddings (RAG indexing) is a separate server.** The toggle
  "Embeddings server" only applies to a *second* server card — it can
  never again ride the chat server (that was the all-night silence).
- **Gemma uses one memory type for K and V.** Mixed K/V is equalized
  automatically; other models keep your tuned settings.
- **The agent cannot ask you questions mid-task.** Give it complete
  instructions in one message (see §6).

## 5. Providers — you decide, nothing is built in

There is **no embedded login and no hidden route**. The local engine is
the default and everything else is yours to add:

1. Settings → Providers → add provider.
2. Name it (e.g. "z.ai"), paste the base URL (`https://…/v1`) and **your
   own API key**.
3. Your key is stored in the local secret store and sent only to that
   provider.
4. Remove it any time; the chat falls back to the local engine.

## 6. How to run a project with the agent

The assistant is your local model plus the engine's tool runtime:

1. Chat tab → Chat advanced settings → enable **Agent Tools** (and
   **JavaScript Sandbox** if you want code execution). The engine
   relaunches with `--jinja --tools all` and the tool surface appears
   in the chat's tools popover.
2. Talk to the model; it can read and edit files across a whole project
   with the exec tools (a working folder can be pinned per conversation
   with the folder chip), run JavaScript in the sandbox, call MCP
   servers you configure, and use conversation memory tools.
3. Every tool call asks permission the first time; you can allow it
   once, always, or always for one MCP server. Dangerous calls (shell)
   always ask.
4. Agent turns are bounded (Maximum agent turns, default 10); when the
   budget runs out a continuation card lets you keep going or stop.

## 7. The four 2026-10-14 incidents and their permanent guards

Each is pinned by a regression check that fails the build if it returns:

1. Embeddings mode on the chat server → now impossible on the primary
   server (`EnterpriseHardeningTests.testPrimaryServerNeverLaunches…`).
2. Gemma mixed-memory crash → equalized at launch
   (`…testGemmaEqualizesMixedKVTypes`).
3. Failed turn poisoning a conversation → turns merged (0.89.9 +
   compaction checks).
4. Agent Tools grammar failure on re-authored LFM2-family templates →
   the app now bridges the engine's format detection with a derived
   template file (`EngineToolTemplateTests`, five checks).

## 8. Troubleshooting — read the truth in the logs

Logs: `~/Library/Application Support/Kestrel/logs/server-*.log`
(newest last). Signatures and what they mean today:

- `does not support logits computation` → an embeddings-only server was
  asked to chat. Cannot happen on the chat server since 0.89.10; if you
  see it, it is a second server doing its intended job.
- `error parsing grammar: expecting newline or end` with Agent Tools on
  → fixed in 0.89.12 for re-authored LFM2-family templates. If it
  returns with a different model, the engine's generic tool-grammar
  fallback mis-derived that template's format — report the model.
- `Conversation roles must alternate` → impossible since 0.89.9.
- `GGML_ASSERT … ggml-metal-ops` → gemma is auto-protected since
  0.89.10; a *different* model name with this error means a new kernel
  gap — report it.
- Engine not listening → check the Home tab card; the log's `args:`
  line shows exactly what the engine was started with.

## 9. Where things live

| What | Where |
|---|---|
| App | `/Applications/Kestrel.app` |
| Source code | `~/KimiK3_Nvidia/Kestrel-AIEngine` (branch: surgical-mvp) |
| Models | `~/models` |
| Your chats | `~/Library/Application Support/Kestrel/conversations.json` |
| Engine logs | `~/Library/Application Support/Kestrel/logs/` |
| Derived tool templates | `~/Library/Application Support/Kestrel/tool-templates/` |
| Secrets | `~/Library/Application Support/Kestrel/secrets/` (0600) |

## 10. Release history (this machine)

- 0.89.12 (2026-10-14): Agent Tools grammar fix for re-authored
  LFM2-family templates; latch and Laya integrations removed end-to-end
  (the native assistant + engine tool runtime is the product).
- 0.89.10 (2026-10-14): all four incident fixes, English-only UI,
  hidden login removed. 413/413.
- 0.89.9: failed-turn merge fix (was committed but not installed —
  0.89.10 ships it).
