# MERLIN M8 — Model Profile Matrix (evidence: live probes 2026-11-15)

All rows measured by the lead against `vendor/llama.cpp/build-static/bin/llama-server`
(0.6.0-dev build 11610, 091b6a7fc), CPU-only (`-ngl 0`), `/v1/chat/completions`, temp 0.
Raw evidence: mission journal §"M1 actor contract evidence" + §"M8 profile matrix evidence".

## The matrix

| Family (test model) | Params | Native `tools[]` (rung 1) | `tool_choice:"required"` | `--jinja` | `json_schema` envelope (rung 2) | Profile verdict |
|---|---|---|---|---|---|---|
| Spark-X2.5 (Spark-X2.5-1.7B-Q8_0) | 1.7B | ✅ byte-perfect `{"a":2,"b":2,"op":"+"}` | n/t | n/t | n/t | **rung 1**, no think budget |
| LFM2.5 (lfm2.5-2.6b-fable5) | 2.6B | ✅ correct tool choice among 2, exact args | n/t | n/t | n/t | **rung 1** (engine flags family grammar-sensitive — verify per release) |
| DeepSeek-R1-Qwen3 (R1-0528-Qwen3-8B) | 8B | ✅ with `reasoning_content:true` — **requires `max_tokens ≥ ~3000`**; at 200 tokens thinking eats budget, no action | required works | n/t | n/t | **rung 1 + think_budget floor 3000** (separate reasoning budget from action budget) |
| Qwen3.5 (Qwen3.5-9B-distilled-IQ4_NL) | 9B | ✅ byte-perfect | n/t | n/t | ✅ also clean | **rung 1**, dual-capable fallback |
| Spark-X2.5-4B (Spark-X2.5-4B-Q4_K_M) | 4B | ✅ byte-perfect | n/t | n/t | ✅ also clean | **rung 1**, dual-capable fallback |
| GLM-4 (GLM-4-9B-0414) | 9B | ❌ `tool_calls:null`, raw call syntax inline in content, **hallucinated fake tool results** | ❌ same failure | ❌ same failure | ✅ **byte-perfect** `{"name":"fs_list","arguments":{"path":"docs"}}`, grammar-locked | **rung 2 (envelope)**; kernel must translate envelope content → tool execution |

n/t = not tested (unnecessary once a rung passed; matrix fills in per-family during slice 4 baselines).

## Binding rules for ProfileStore.swift (slice 2)

1. **Default rung is 1 (native tools).** A family moves to rung 2 only on captured evidence of
   rung-1 failure (GLM-4 today). Rung 3 (rescue ladder) exists for unprofiled models.
2. **Envelope translation (rung 2):** the kernel parses `content` as the envelope JSON
   (grammar makes it parseable), converts to internal ToolCall, executes, and feeds the result
   back as a user-role tool-result message. Reuse the C1 translation approach
   (ChatToolsService.swift:666+).
3. **Think-budget floor:** profiles carry `min_completion_tokens`. The kernel refuses to run a
   completion if `max_tokens < profile.floor + action_headroom` (default headroom 512) — a
   starved R1 silently doing nothing is worse than a loud config error.
4. **Hallucination guard (M4 tie-in):** GLM's inline "results" happen when narration replaces
   execution. Kernel rule: any assistant content that *looks like* a tool call on a rung-2
   family is parsed as an envelope candidate; if it fails envelope parse AND names a known
   tool, Guardian flags `suspected_result_hallucination` and the turn is re-asked with the
   spine reminder "results come only from tools."
5. **Unknown families** (user loads an unprofiled GGUF): start rung 3 (rescue ladder, the
   engine's existing ToolCallRescue), then auto-upgrade: if the first 3 native calls parse
   clean, promote to rung 1 for the session; persist the promotion per family hash in
   `~/.kestrel/merlin/profiles.json`.

## Re-verification protocol (per engine release)

Rerun the two probe bodies (journal has them verbatim) per profiled family at each bundled
engine bump; a rung flip updates profiles.json + CHANGELOG. The 20/20 slice-2 gate uses
Spark-X2.5-1.7B (fast load, rung 1) + GLM-4-9B (rung 2) so both rungs get the 20-call soak.
