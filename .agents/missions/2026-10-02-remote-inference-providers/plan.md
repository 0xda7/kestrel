# Mission: remote-inference-providers

**Objective:** Kestrel chat can run inference through a user-configured remote provider that speaks the OpenAI and/or Anthropic API dialects, with the local patched llama-server path untouched as the default.

**Operator:** Northlatch Labs owner · **Value:** model choice beyond what fits in 8 GB VRAM, without shipping a gateway process or touching the engine fork (binding directive: the engine stays Kestrel-local; nothing else runs through it).

**Success criteria:**
1. `swift build` green; local-engine chat regression clean (request body to `127.0.0.1` byte-identical when route = local).
2. Live-fire: one streamed chat round-trip against an OpenAI-dialect endpoint (mock first, real operator endpoint second) — tokens stream, usage meter fills, stop works.
3. Same against an Anthropic-dialect endpoint (`/v1/messages`, SSE event names differ).
4. No model IDs hardcoded anywhere in the inference path (grep-gated); presets carry endpoints only, model id is a user text field.
5. API key lives in Keychain (existing SecItem pattern in `Support.swift`), never interpolated into `AppLog`, TLS enforced for non-loopback base URLs.

**Constraints:** plain Swift/SwiftUI only; no new process dependencies (no LiteLLM/gateway sidecar — this app's identity is "native, zero runtime deps"); engine binaries untouched; no `dist/`-path assets.

**Assumptions:** (a) "the provider is OpenAI and Anthropic compatible" = one remote endpoint selectable per dialect — plan supports both; (b) scope is chat text (+ tool calls) only — audio/images/benchmarks stay engine-local this pass; (c) operator supplies a real endpoint + key for live-fire, or accepts mock-only verification plus operator-run live-fire.

**Budget:** ≤ 10 steps · ~2 working sessions · ≤ 400k tokens — hard stop at 2x.

## Steps

| # | Step | Owner | Depends on | Deliverable contract | Gate | Risk / rollback |
|---|------|-------|------------|----------------------|------|-----------------|
| 1 | Scout report (call-site inventory) | main agent | — | This plan + journal entry listing every inference call site | grep output captured in journal (done at plan time) | none (read-only) |
| 2 | Design record: `ChatInferenceRoute` protocol, route settings schema, dialect matrix | main agent | 1 | `design.md` in mission folder: protocol surface, which of the llama-only body fields get stripped per dialect | operator reads/approves before step 3 | none (doc) |
| 3 | Route settings: UI section + persistence | main agent | 2 | New `Sources/Chat/InferenceRoutes.swift` (+ Settings UI): base URL, dialect picker, model id field, key → Keychain; `@AppStorage`-compatible route list | `swift build` green; route round-trips through save/load | Settings bloat → feature-flagged section, rollback = remove file |
| 4 | Protocol extraction at the request boundary | main agent | 3 | `ChatNative.swift:881` request-build moves behind protocol; `LocalLlamaRoute` conformance reproduces current body **exactly** | compile + captured byte-diff of local request body vs pre-refactor (fixture test via print at debug flag) | tangling 2k-line file → extract minimal builder only; rollback = revert commit |
| 5 | OpenAI-dialect remote conformance | main agent | 4 | `RemoteOpenAIRoute`: strips `cache_prompt`, `timings_per_token`, `return_progress`, `chat_template_kwargs`, `thinking_budget_tokens`, `id_slot`, llama samplers (`min_p`, `top_k`, `dry_*`, `xtc_*`, `typ_p`, `dynatemp_*`, `samplers`, `backend_sampling`); Bearer auth; stream consumed by existing `ChatStreamAccumulator` (already parses `data:`/`choices[0].delta`/`usage`/`[DONE]`) | mock server round-trip streamed in the real Chat UI | unknown-field 400s on strict endpoints → strip-by-default allowlist, custom-JSON passthrough preserved for power users |
| 6 | Anthropic-dialect remote conformance | main agent | 5 | `RemoteAnthropicRoute`: `/v1/messages` body mapping, `x-api-key` + `anthropic-version` headers, SSE mapper `content_block_delta`/`message_delta`/`message_stop` → `ChatStreamEvent` (downstream UI code shared, not forked) | mock server round-trip streamed in the real Chat UI | dialect drift → mapper isolated in one file with the event table documented |
| 7 | Tool calls over remote (client-side loop) | main agent | 5 | Engine `/tools` listing skipped when route ≠ local; built-ins + MCP tools sent via existing `openAIDefinition`; `delta.tool_calls` already parsed by accumulator — wire the execute-and-repost loop | mock that emits a tool_call proves one full loop (request → call → result → final answer) | infinite loops → reuse existing iteration cap; rollback = disable tools on remote |
| 8 | Route plumbing for side-consumers | main agent | 4 | Compaction summarize (`ChatNative.swift:1749`) and AudioStudio caption (`AudioStudioController.swift:685`) route through the active route or fall back to local with a visible notice | compile; each fires once in a manual pass | scope creep → fallback-only is acceptable v1 |
| 9 | Verification gate ladder | main agent | 5–8 | Mock OpenAI + Anthropic servers (tiny local listeners, no deps) run end-to-end; `swift build` green; grep gates: no hardcoded model ids, no key interpolation in `AppLog` | all captured outputs appended to journal | mock drift from real API → operator live-fire is the final gate |
| 10 | Delivery package | main agent | 9 | `delivery/`: operator runbook (set up a route, switch chat to it, fall back), CHANGELOG entry, docs section in `Docs.swift` | operator accepts | — |

## Key scouting facts (evidence, captured this session)

- Main streaming path builds its request at `ChatNative.swift:881`; compaction summarize at `:1749`; audio caption at `AudioStudioController.swift:685` — all hardwired to `http://127.0.0.1:{port}/v1/chat/completions`.
- `ChatStreamAccumulator` (`ChatStreamProtocol.swift`) already consumes OpenAI-style SSE including `reasoning_content`, `usage`, `finish_reason`, `delta.tool_calls` — the OpenAI-dialect remote needs **no new parser**, only a different request builder + URL/headers.
- llama-server-only request fields that must not reach strict remote endpoints: `cache_prompt`, `id_slot`, `timings_per_token`, `return_progress`, `chat_template_kwargs`, `thinking_budget_tokens`, `reasoning_control`, `min_p`, `top_k`, `typ_p`, `dynatemp_*`, `xtc_*`, `dry_*`, `repeat_penalty/last_n`, `samplers`, `backend_sampling`, custom-JSON merge.
- Slot persistence (`prepareSlot`, `/slots/0`) and engine-side `/tools` are engine-local concerns — skipped entirely on remote routes.
- Keychain pattern already exists (`SecItem` in `Sources/App/Support.swift`); `ServerSettings.activeAPIKey()` is the local-server key, remote keys are separate items.
- The engine keeps zero involvement in remote routes — requests go browser-app → HTTPS provider directly. The local llama-server binary is neither started, consulted, nor modified.

## Out of scope
- Remote embeddings, TTS/STT, image/video generation, vision uploads.
- Benchmark/`/props`/`/metrics` over remote (they measure the local engine by definition).
- Multi-provider failover chains, cost dashboards, org-key management (future amendments).
- Any change to engine sources, build, or launch arguments.
