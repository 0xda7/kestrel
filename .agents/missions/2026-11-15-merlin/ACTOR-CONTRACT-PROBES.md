# MERLIN Actor-Contract Probes — verbatim evidence (2026-11-15)

Slice 2's soak gate replays these against the bundled server per family.
Server: `vendor/llama.cpp/build-static/bin/llama-server` 0.6.0-dev build 11610.
All probes CPU-only (`-ngl 0`), temp 0, `/v1/chat/completions`.

## Native-tools body (rung 1 probe — "body-glm.json")

```json
{"messages":[{"role":"system","content":"You are a file assistant."},{"role":"user","content":"List the files in the docs folder."}],
 "tools":[{"type":"function","function":{"name":"fs_read","description":"Read a text file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
          {"type":"function","function":{"name":"fs_list","description":"List files in a directory","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
          {"type":"function","function":{"name":"fs_write","description":"Write a text file","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}],
 "tool_choice":"required","max_tokens":200,"temperature":0}
```

Observed: Spark-X2.5-1.7B ✅ (calc test), LFM2.5-2.6B ✅, Qwen3.5-9B ✅, Spark-4B ✅,
R1-8B ✅ (with max_tokens 3000 + reasoning_content), GLM-4-9B ❌ (inline syntax + hallucinated results).

## json_schema envelope body (rung 2 probe — "body-glm-schema.json")

```json
{"messages":[{"role":"system","content":"You are a file assistant. You must call tools using the JSON format."},
{"role":"user","content":"Call fs_list on the docs folder."}],
 "response_format":{"type":"json_schema","json_schema":{"strict":true,"name":"tool_envelope","schema":{"type":"object","properties":{"name":{"type":"string","enum":["fs_read","fs_list","fs_write"]},"arguments":{"type":"object"}},"required":["name","arguments"],"additionalProperties":false}}},
 "max_tokens":200,"temperature":0}
```

Observed: GLM-4-9B ✅ content `{"name": "fs_list", "arguments": {"path": "docs"}}` (grammar-locked).
Also clean on Qwen3.5-9B and Spark-4B.

## Soak protocol (slice 2 gate)

- Families: Spark-X2.5-1.7B (rung 1, fast load) + GLM-4-9B (rung 2) — both rungs soaked.
- 20/20 valid structured calls per model across 10 varied tool-surface requests
  (read/list/grep/write/completion-contract), zero malformed, zero hallucinated results.
- R1-8B additional check: completion with `max_tokens = floor + 512` acts (issues a call),
  completion below floor is REFUSED by the kernel config check (loud error, not silence).
