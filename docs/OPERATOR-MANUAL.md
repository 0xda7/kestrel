# Kestrel Operator Manual — v0.89.10

Plain-English operating manual for the person who runs Kestrel daily.
Every "verified" claim below is backed by the check suite (413 checks,
0 failures, 2026-10-14) or by engine logs on this machine.

---

## 1. What Kestrel is

Kestrel runs language models locally on your Intel Mac with the AMD GPU.
It ships its own engine (llama.cpp fork), a chat app, and an agent
("latch") that can do multi-step work on your files. Nothing leaves your
machine unless you add a remote provider yourself.

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
| Gemma models (incl. vision) | Working after 0.89.10 | Two load-crashes 08:48/09:01 root-caused and guarded; regression check pins it |
| Conversation survives a failed turn | Working after 0.89.9/0.89.10 | The exact 400 "roles must alternate" from your logs is now merged away; check pins it |
| Laya Decisions server card | Loads; decisions only | It is a typed decision model, not a chat model — the server card on port 8098 is for decision calls |
| English-only interface | Working after 0.89.10 | Language picker removed; every label resolves to English; checks pin it |
| Agent isolated from your other apps | Working after 0.89.10 | Agent home = `…/Kestrel/latch-home`; its history can no longer appear inside ZCode; check pins it |
| Providers you add yourself | Working | Settings → Providers; see §5 |

## 4. Known boundaries (honest list)

- **Embeddings (RAG indexing) is a separate server.** The toggle
  "Embeddings server" only applies to a *second* server card — it can
  never again ride the chat server (that was the all-night silence).
- **Gemma uses one memory type for K and V.** Mixed K/V is equalized
  automatically; other models keep your tuned settings.
- **The agent cannot ask you questions mid-task.** Give it complete
  instructions in one message (see §6).
- **Laya is for decisions, not conversation** — that is its design.

## 5. Providers — you decide, nothing is built in

There is **no embedded login and no hidden route**. The local engine is
the default and everything else is yours to add:

1. Settings → Providers → add provider.
2. Name it (e.g. "z.ai"), paste the base URL (`https://…/v1`) and **your
   own API key**.
3. Your key is stored in the local secret store and written only to the
   agent's private config file (`…/Kestrel/latch-home/.latch/v2/`).
4. Remove it any time; the agent falls back to the local engine.

## 6. How to run a project with the agent

The agent ("latch") can read and edit files across a whole project:

1. Chat tab → enable the agent mode (Chat advanced settings → Latch).
2. Two ways to work:
   - **Direct chat:** talk to the agent; it streams its work live. Attach
     folders/files with the attach button so it can read your project.
   - **Delegate a task:** ask for a self-contained job ("audit
     ~/code/myapp for X, write the report to Y"). Give absolute paths,
     constraints, and the expected output — it runs minutes and returns
     a finished report; it cannot ask questions mid-run.
3. Timeout guidance: 120 s or more for real work (floor 60, cap 900).
4. Everything the agent writes (history, sessions) lives only in
   `~/Library/Application Support/Kestrel/latch-home/` — separate from
   every other app you own.

## 7. The four 2026-10-14 incidents and their permanent guards

Each is pinned by a regression check that fails the build if it returns:

1. Embeddings mode on the chat server → now impossible on the primary
   server (`EnterpriseHardeningTests.testPrimaryServerNeverLaunches…`).
2. Gemma mixed-memory crash → equalized at launch
   (`…testGemmaEqualizesMixedKVTypes`).
3. Failed turn poisoning a conversation → turns merged (0.89.9 +
   compaction checks).
4. Agent history leaking into ZCode / hidden login → isolated home +
   scrubbed environment (`…testLatchChildEnvironmentIsIsolated…`).

## 8. Laya — the decision engine (what it is, how to use it)

Laya is **not a chat model**. It is a typed-decision engine: you give it a
document plus a question set, it returns structured decisions with
confidence — built for triage, not conversation. Chatting with it gives
you nothing by design.

**What you can do with it (all via `~/bin/laya` in Terminal):**

1. `laya ~/papers/paper.txt` — instant triage of any document with the
   built-in medical set: study type (trial / cohort / case report /
   review / other, each with a confidence bar), complications YES/NO with
   probability, clinical-relevance score.
2. `laya anyfile.txt -q my-questions.json` — your own decision workflow,
   any domain. Three question types:
   - `choice` — picks one label; define each bucket's criteria.
   - `noul` — yes/no with probability.
   - `score` — anchored rating (define low/middle/high anchors).
3. It reads the first 12,000 characters, cleans code blocks, retries on
   rejects. Output is a printed decision card per question.

**How to run it (no code, no builds):**

1. The "Laya Decisions" card re-appears on the Servers tab (the
   deleted-flag setting was reset to false on 2026-10-14; it seeds on
   app launch).
2. Servers tab → **Laya Decisions** → press **Start** (port 8098 — it
   never auto-starts; you decide when models run).
3. Terminal: `~/bin/laya ~/papers/paper.txt`
4. Press **Stop** on the card when done to free VRAM.

If the CLI says "Laya engine is not running," that is its designed
behavior: it never spawns processes — start the card in the app.

## 9. Troubleshooting — read the truth in the logs

Logs: `~/Library/Application Support/Kestrel/logs/server-*.log`
(newest last). Signatures and what they mean today:

- `does not support logits computation` → an embeddings-only server was
  asked to chat. Cannot happen on the chat server since 0.89.10; if you
  see it, it is a second server doing its intended job.
- `Conversation roles must alternate` → impossible since 0.89.9.
- `GGML_ASSERT … ggml-metal-ops` → gemma is auto-protected since
  0.89.10; a *different* model name with this error means a new kernel
  gap — report it.
- Engine not listening → check the Home tab card; the log's `args:`
  line shows exactly what the engine was started with.

## 10. Where things live

| What | Where |
|---|---|
| App | `/Applications/Kestrel.app` (0.89.10) |
| Source code | `~/KimiK3_Nvidia/Kestrel-AIEngine` (branch: surgical-mvp) |
| Models | `~/models` |
| Your chats | `~/Library/Application Support/Kestrel/conversations.json` |
| Engine logs | `~/Library/Application Support/Kestrel/logs/` |
| Agent private home | `~/Library/Application Support/Kestrel/latch-home/` |
| Secrets | `~/Library/Application Support/Kestrel/secrets/` (0600) |

## 11. Release history (this machine)

- 0.89.10 (2026-10-14): all four incident fixes, English-only UI,
  agent isolation, hidden login removed, 4 regression guards. 413/413.
- 0.89.9: failed-turn merge fix (was committed but not installed —
  0.89.10 ships it).
