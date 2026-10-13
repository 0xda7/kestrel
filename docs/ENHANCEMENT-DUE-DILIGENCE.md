# Enhancement due diligence — stability & optimization

Companion to the 2026-10-03 repair wave (see `CHANGELOG.md` Unreleased and `.agents/journal.md`).
Everything below is either measured on this machine or pinned to code with `file:line` style
references. Items marked **[opinion]** are correcting advice the operator owns; items marked
**[shipped]** are already in the tree and verified; **[roadmap]** items need operator scope
approval before implementation.

## 1. Engine configuration — the root cause of "models not working" [opinion]

The failing-model reports in `conversations.json` all trace to one number: generation ran at
**0.99 tokens/second** (engine log task 280), so every sidecar turn — pi, latch, tool
delegation — burned its whole budget and died with "exceeded its Ns budget".

Measured on this machine (MacBookPro16,1, i9-9980HK, Radeon Pro 5500M 8 GB, engine build
b11141, model `Qwen3.5-9B-distilled-IQ4_NL.gguf`, `-ngl 99`):

| Config | Context | KV (K/V) | Generation |
|---|---|---|---|
| running instance (2026-10-02) | 131,072 | q8_0 / turbo4 | **0.99 tok/s** |
| candidate | 16,384 | q8_0 / turbo4 | 2.35 tok/s |
| candidate | 16,384 | q8_0 / q8_0 | 19.83 tok/s |
| candidate | 16,384 | q8_0 / f16 | **20.03 tok/s** |

Reading:

1. **Context spill is the dominant killer.** 128k context on an 8 GB card pushes the KV cache
   out of VRAM; generation drops ~20×. The Settings UI already labels ≥128k "very large (for
   testing)" — the running config used it for daily chat.
2. **turbo4 V-cache costs ~8× even fully on-GPU** at 16k (2.35 vs 20.03). This matches the
   app's own warning that quantized V without the AMD Flash-Attention kernel drops ~3×+.
   The turbo KV program remains operator-owned per directive; this table is the A/B record
   behind the recommendation.
3. **Recommendation:** daily chat at 16k with q8_0 keys + f16 values; keep 128k only for the
   long-context tests it was designed for. One command reproduces the fast profile once the
   operator's testing window closes:
   `defaults write com.northlatchlabs.kestrel ctx -int 16384`
   (`cacheTypeK q8_0` + `cacheTypeV f16` if the turbo verdict allows it), then restart the
   engine from the Dashboard.
4. `contextAutomatic` exists in `ServerSettings` but is display-only — selecting "Auto" in the
   UI writes 16384 into `ctx`. Either document that or make the launch path compute it
   (roadmap item 4).

## 2. Shipped in this wave [shipped]

- Sidecar hardening: race-free bounded stream accumulation, live reasoning UI, stderr
  diagnostics on abnormal exit, SIGKILL escalation that cannot delay the timeout verdict,
  latch empty-success guard (details in CHANGELOG).
- Truthful attribution: remote replies record the route's model id; per-route Keychain
  credentials with legacy migration.
- Security: conversations/projects.json written 0600; no force-unwraps on the request path;
  secrets sweep of Sources/scripts/Assets clean.
- Verification: `swift build --disable-sandbox` exit 0; behavioral driver over the shipped
  sources 38/38; live-fire `pi` → running engine streamed `LIVE-FIRE-OK`; local API-key auth
  re-verified (401/200/401/401) on a test port.

## 3. Security follow-ups [opinion, operator-gated]

1. **Enable the engine API key** (`SettingsKeys.apiKeyEnabled`, Keychain-backed, already
   wired into the chat client and log-masked). llama-server warns "no API key and CORS allows
   all origins" — any local process (or a webpage via localhost) can use the model and read
   prompts today. Deliberately NOT flipped in this wave because the pi provider entry
   (`~/.pi/agent/models.json`, key `kestrel-local-dummy`) and any latch provider config would
   401 until updated. Steps when ready: flip the toggle in Server settings, then replace the
   dummy key in `~/.pi/agent/models.json` with the Keychain item
   (`security find-generic-password -s com.northlatchlabs.kestrel -a api-key -w`).
2. **Ad-hoc signing, no hardened runtime.** The dist app is ad-hoc signed without
   entitlements. Fine for a local dev build; a notarized release path already exists in CI.
3. **Legacy defaults domain** (the pre-rename app's personal domain) — done 2026-10-03: the inert domain was
   exported and deleted; the drift risk is gone.

## 4. Roadmap (ranked, awaiting scope approval) [roadmap]

1. **Stale-app guard.** The running dist binary predates its sources after every repair wave
   (this bit the Amendment 4 rollout). Cheap fix: About tab shows the build hash vs the
   source-derived one; Dashboard warns when dist is older than the newest source commit.
2. **Prompt Space wave 2.** PromptLibrary (shipped wave 1) gains llm-space-style typed
   variables (date/cwd/skills-list) and A/B variants; trace-list UI uses the already-shipped
   `latestSessionTraces`.
3. **Skills discovery.** LLM Space reads Claude-format SKILL.md from multiple discovery
   paths; Kestrel can surface `~/.pi/agent/skills` (+ `~/.claude/skills`) in the Prompt Space
   sheet read-only before considering authoring.
4. **Make contextAutomatic real.** Compute a VRAM-fitting context from the model's KV math at
   launch time instead of aliasing 16384, with a Dashboard readout of the chosen value.
5. **Provider-side cancellation honesty.** OpenAI/Anthropic dialects expose no cancel API, so
   stop() on a remote route can only end the local drain (the provider keeps generating).
   Options: display a "provider keeps running" note on remote stops, or prefer providers that
   support cancel (none of the two dialects do today — factual, not fixable client-side).
6. **Run-usage tracking per message.** LLM Space stores per-run usage; Kestrel already
   persists `timings` + `genSpeed` per message — exposing a per-conversation usage rollup is
   mostly a UI task.
