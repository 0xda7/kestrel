# Laya × Kestrel — Architecture, Uses, Upgrade Roadmap (v0.89.11)

## The architecture (what shipped 0.89.11)

Kestrel is now a two-brain machine, which is exactly what System-1 decision
models are for:

- **Big model (Qwen etc.)** = the reasoner. Slow, articulate, expensive.
- **Laya** = the decision core. Non-autoregressive, ~33 ms per question,
  Apache-2.0, served by your own engine at `/v1/systemone` (port 8098).
- The chat agent now carries a built-in `laya_decide` tool: any document +
  any question set → typed decision card (choice with confidence bars,
  yes/no with probability, anchored score). No hardcoding: every question
  set is a JSON file in `…/Kestrel/laya-questions/` — add capability by
  adding files, not code. Nothing auto-starts; you press Start on the card.

## Today's click path

1. Kestrel → Servers → Laya Decisions → Start.
2. Chat with any big model. Attach or point at a document and say
   "run Laya triage on ~/papers/paper.txt". The agent calls laya_decide.

## The uses people demo (snake, crawling, research) — how they actually work

A decision model "plays snake" by being the policy in a loop: each tick,
the harness feeds the game state and Laya answers one typed question
("which direction?") in 33 ms. Same pattern for crawling: each page is
"state," Laya decides follow/skip/extract. That is the general pattern —
**Laya decides, a loop acts, a big model reads/summarizes when depth is
needed.** Kestrel now has the Laya half and the big-model half; the loops
(crawler, router) are the upgrades below.

## Unforeseen uses this architecture unlocks (each = one JSON set)

1. **Router:** "which model/provider should answer this?" → cheap, instant.
2. **Gate:** "is this question worth the big model, or answer directly?"
3. **Verifier:** classify the big model's draft (correct/hedged/off-topic).
4. **Triage at scale:** 1,000 documents → Laya picks the 20 worth reading.
5. **Support triage, CV screening, contract flagging, invoice routing.**
6. **Your own decision model:** Unsloth trains custom Laya/Jev sets →
   export GGUF → drop in ~/models → same card, same tool.

## Upgrade roadmap (priority order)

1. **Native Decisions tab** — file picker, set editor, decision cards with
   real bars, export CSV/JSON. (UI only; service layer already exists.)
2. **Laya-as-router** — incoming chat message → Laya picks local vs remote
   provider automatically. Biggest cost saver.
3. **Crawl loop** — fetch page → Laya follow/skip/extract → big model
   summarizes. "Research mode."
4. **Batch endpoint** — N documents × one set, one click, CSV out.
5. **Decision log** — every Laya call recorded (query, answer, confidence)
   for audit/quality tracking. Enterprise trail.
6. **Fine-tune pipeline doc** — your own decision sets via Unsloth → GGUF.
