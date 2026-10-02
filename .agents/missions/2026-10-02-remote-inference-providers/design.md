# Design record: remote inference routes

Status: approved-by-plan (step 2 deliverable). This file is the contract steps 3–8 implement against.

## One refinement to the plan (AMENDMENT 1 to plan.md, journaled)

The plan promised a `ChatInferenceRoute` protocol. Implemented instead as an **enum dialect + Codable route struct + one resolver**. Reasons: exactly three dialects are known (local-llama, openai, anthropic), routes must persist through `JSONEncoder` → UserDefaults (the codebase's established pattern, cf. `measuredBenchByModel`), and no dynamic registration exists anywhere in the app. The request **boundary** extraction promised by step 4 is unchanged: the request build at `ChatNative.swift:881` moves behind the resolver; the local request body stays byte-identical (gate: captured diff).

## Data model (`Sources/Chat/InferenceRoutes.swift`)

```swift
enum InferenceDialect: String, Codable, CaseIterable { case localLlama, openAI, anthropic }

struct InferenceRoute: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String            // user-facing label
    var dialect: InferenceDialect
    var baseURL: String         // https:// enforced unless host is loopback
    var modelID: String         // user-entered; NEVER a code constant
    var maxTokensCap: Int?      // optional; nil = chat default
}

enum InferenceRoutes {
    static func load() -> [InferenceRoute]      // UserDefaults key "inferenceRoutes"
    static func save(_ routes: [InferenceRoute])
    static var activeID: String?                // UserDefaults "activeInferenceRoute"; nil = local engine
    static func active() -> InferenceRoute?
}
```

Key storage: `Keychain.set(key, account: "remote-api-key")` / `Keychain.get("remote-api-key")` — one key per install (matches the app's single-local-key model; per-route keys are an explicit non-goal this pass, recorded in plan Out-of-scope as an amendment candidate if the operator wants them).

## Request boundary (step 4)

`ChatNative.stream(into:...)` builds `body: [String: Any]` exactly as today, then:

```swift
let route = InferenceRoutes.active()   // nil ⇒ local engine, zero change
let wire = RouteWire.wire(body: body, route: route, port: port)
// wire.url, wire.headers, wire.body  → URLRequest as before
```

`RouteWire.wire` is the single transform point:

| dialect | url | headers | body transform |
|---|---|---|---|
| localLlama (route nil) | `http://127.0.0.1:{port}/v1/chat/completions` | Bearer local key | **none — passthrough** |
| openAI | `{base}/chat/completions` (base normalized: optional `/v1` appended if absent) | `Authorization: Bearer {remote key}` | strip llama-only fields (matrix below); force `model` = route.modelID; keep `stream_options.include_usage`; custom-JSON merge applied **after** strip |
| anthropic | `{base}/v1/messages` | `x-api-key`, `anthropic-version: 2023-06-01` | full remap (below) |

## Strip matrix — openAI dialect

Fields removed before send (llama-server extensions; strict endpoints 400):
`cache_prompt, id_slot, timings_per_token, return_progress, chat_template_kwargs, thinking_budget_tokens, reasoning_control, min_p, top_k, repeat_penalty, repeat_last_n, dynatemp_range, dynatemp_exponent, xtc_probability, xtc_threshold, typ_p, dry_multiplier, dry_base, dry_allowed_length, dry_penalty_last_n, backend_sampling, samplers`

Fields kept: `messages, stream, temperature, top_p, max_tokens, seed, presence_penalty, frequency_penalty, tools, tool_choice, model(forced)`.
Kept-with-note: `stream_options.include_usage` (valid OpenAI; stripped only if an endpoint rejects — operator custom-JSON can override anything).

## Anthropic remap

Request: `messages` (system extracted from leading system message → top-level `system`), `model` = route.modelID, `max_tokens` (**required** by Anthropic — default 4096 if chat left it unset), `temperature`, `stream: true`, `tools` → Anthropic tool schema only when non-empty (`name/description/input_schema`; `tool_choice: {type:"auto"}`). Sampling fields not in Anthropic's API are dropped.

Response SSE — translated to OpenAI-shaped `data:` JSON and fed to the **existing** `ChatStreamAccumulator` (zero accumulation logic duplicated):

| Anthropic event | synthesized OpenAI chunk |
|---|---|
| `message_start` (usage.input_tokens) | `{"choices":[{"delta":{}}],"usage":{"prompt_tokens":n}}` |
| `content_block_delta` `text_delta` | `{"choices":[{"delta":{"content": t}}]}` |
| `content_block_delta` `thinking_delta` | `{"choices":[{"delta":{"reasoning_content": t}}]}` |
| `message_delta` (stop_reason, output_tokens) | `{"choices":[{"delta":{},"finish_reason":map(stop_reason)}],"usage":{"completion_tokens":n}}` |
| `message_stop` | `[DONE]` |
| `error` | surfaced through `ChatStore.streamedError` path as `StreamError` |

stop_reason map: `end_turn/max_tokens→stop`, `tool_use→tool_calls`, else passthrough.

## Engine independence (directive compliance)

- route ≠ nil ⇒ no `prepareSlot`, no `X-Conversation-Id` slot semantics needed (harmless header, dropped), no engine `/tools` listing; tool availability = built-ins + JS sandbox + Latch + memory + MCP (all client-executed), filtered by `ToolSupport`.
- llama-server process state is irrelevant on remote routes: chat works while the local server is stopped (UI "server stopped" copy must not block remote send — verified in step 5 gate).
- Engine sources, launch args, and binaries: untouched (grep gate in step 9).

## Security gates

- Base URL must be `https://` unless host ∈ {127.0.0.1, localhost, ::1} — enforced in `RouteWire`, not just UI.
- Key reads go Keychain → header directly; never logged (`AppLog` grep gate), never persisted in UserDefaults.
- `X-Conversation-Id` header dropped on remote (internal KV-identity concept).

## Verification gates (recap from plan)

1. local body byte-diff: nil-route passthrough identical to pre-refactor build (fixture captured at debug flag).
2. openAI mock: streamed round-trip in real Chat UI (tokens, usage, stop).
3. anthropic mock: same via translated events.
4. tool loop: mock emits one `tool_calls` delta → client executes a built-in → reposts → final answer.
5. `swift build` green; grep: no new hardcoded model ids; no key in logs.
