# Kestrel upgrade — diagnosis report

Date: 2026-10-12 · Repo: `main` @ `bf5f1ae` (v0.89.2, tree clean) · Author: Xlaunch mission `2026-10-12-enterprise-upgrade`

Method: everything below was either reproduced on this machine this session (marked **[repro]**),
or is pinned to a file in this repository (marked with the path). No claim is inferred from the
mission brief alone.

## Verdict in one paragraph

Kestrel is not buggy because the code is careless — three repair waves (0.89.0–0.89.2) already
paid down the Swift 6 concurrency debt, killed the routing/attribution lies, and hardened the
sidecars. It stays error-prone for five structural reasons: **(1)** the machine that develops it
cannot run its own test suite, so every local change ships on `swift build` alone;
**(2)** the app still lets users (and sidecars) walk into configuration traps that fail slowly or
silently — the context-spill class; **(3)** provider configuration has historically had multiple
owners with silent fallbacks — mostly fixed, one instance left; **(4)** a 2026-10-10 security
assessment carries 2 High / 7 Medium / 4 Low findings that are open; **(5)** the engine patch
series is pinned behind upstream, so upstream fixes and model support arrive late. Detail and
evidence per item below, then the remediation plan.

## 1. The verification gap — this machine cannot test what it ships **[repro]**

- `swift build --disable-sandbox` → **Build complete! (22.56s)**, exit 0.
- `swift test --disable-sandbox` → **exit 1**, `no such module 'XCTest'` in
  `Tests/AudioVideoExportIntegrationTests.swift:5`.
- Cause: `xcode-select -p` = `/Library/Developer/CommandLineTools`; no `/Applications/Xcode.app`.
  CLT ships neither XCTest nor swift-testing (probed: a scratch package with `import Testing`
  fails identically — `/tmp/swtest`).
- `scripts/test.sh` handles this by pointing `DEVELOPER_DIR` at Xcode.app — and hard-fails here
  ("Xcode not found"). So the only machine-side gates that run are `swift build` and ad-hoc
  behavioral drivers (mission journals: "behavioral driver … 38/38").
- Consequence: the regression suites (`Tests/`, 4,631 LOC — Markdown, server selection, model
  detection, spec metrics, log presentation, …) execute **only in CI**. The 2026-10-10 journal
  records CI itself was down for a billing reason at a critical gate.
- Same root cause blocks local release assembly: no Metal toolchain under CLT, so
  `make-app.sh` cannot produce `default.metallib` locally (journal 2026-10-10 12:40) — the
  shipped `dist/Kestrel.app` can only be assembled by CI.

**Class:** correctness/infrastructure. **Severity: high** — this is why regressions of the
"fixed it locally, CI never saw the case" kind recur.

## 2. Configuration traps — the "models not working" class **[repro + documented]**

- Root cause chain documented in `docs/ENHANCEMENT-DUE-DILIGENCE.md` §1: 128k context on an
  8 GB GPU spills the KV cache out of VRAM → generation at **0.99 tok/s** (20× drop) → every
  sidecar turn burns its budget and dies with "exceeded its Ns budget". Measured on this
  machine (MacBookPro16,1, Radeon Pro 5500M 8 GB): 16k ctx + q8_0/f16 KV = **20.03 tok/s**.
- **Live this morning** (not history): `~/Library/Application Support/Kestrel/logs/
  server-2026-10-12_11-32-28.log` — `send_error: request (70871 tokens) exceeds the available
  context size (65536 tokens)`. A request path assembled a transcript bigger than the window
  and the engine refused it at send time.
- `contextAutomatic` exists in `ServerSettings` but is display-only — selecting "Auto" writes
  16384 (`docs/ENHANCEMENT-DUE-DILIGENCE.md` §1.4, roadmap item 4).

**Class:** correctness/UX. **Severity: high** — this is the dominant user-visible failure mode
(slow → timeout → "broken").

## 3. Config ownership and silent fallback — the "reports working but isn't" class

Three bugs of the same shape were fixed across 0.89.0–0.89.2 (each pinned in `CHANGELOG.md`):

1. pi ignored `--provider` and silently fell back to a dead OpenRouter default (401, empty
   bubble, exit 0) — fixed by the combined `--model provider/model` form.
2. Deleting/re-creating a route orphaned the active-route selection; chat silently fell back to
   the local engine while Settings showed green — fixed by name re-binding + explicit warning.
3. The sidecar's `~/.pi/agent/models.json` was hand-authored outside the app with an embedded
   key; mismatch → empty reply, no diagnostic — fixed in 0.89.2: Kestrel generates the file from
   its own Settings on launch and every change.

**Remaining instance:** latch runs tool delegation under *its own* provider/model config, which
Kestrel neither routes nor constrains — currently disclosed in the tool description only
(`CHANGELOG.md` 0.89.0, "honest routing disclosure"). `~/kestrel-driver-r1` (stub-latch,
stub-pi) shows a driver harness exists for this path.

**Class:** correctness/trust. **Severity: medium** — the class is fixed at its third instance;
the fourth surface (latch) is disclosed but not owned.

## 4. Open security findings — assessment `docs/security-assessment-2026-10-10.md`

2 High · 7 Medium · 4 Low. Verified-against-source highlights:

- **KES-01 (High)** LAN mode: `--host 0.0.0.0` plaintext HTTP with optional API key
  (`Sources/Servers/Server.swift:329,434,382`) — any LAN host can use the engine, read/inject
  conversations, and reach the bundled web UI; refusal fires only when agent tools are also on
  (`Server.swift:1888`).
- **KES-03 (High)** "Export diagnostics" joins the full server argv including `--api-key` into
  a shareable file in ~/Downloads (`Sources/Servers/LogsTab.swift:466` bypasses the redactor at
  `Server.swift:1991`).
- **KES-02 (Med)** web UI URL carries no token; Bonjour TXT advertises `auth: none`
  (`Server.swift:1837,2479`).
- **KES-04 (Med)** API key and pi delegate prompts ride child-process argv — `ps`-visible.
- **KES-05 (Med)** "Always allow" on agent tools is permanent, global, and covers shell exec.
- Remaining findings (KES-06…13) not yet re-read this session; will be enumerated before the
  security wave executes.

**Class:** security. **Severity: high** (the two Highs ship in every release).

## 5. Structural debt — architecture and engines

- **One executable target**, 49,967 LOC across 16 module directories (`Sources/Chat` alone is
  12,824). No library boundaries → compile times and blast radius grow together; the two
  largest view builders were already split once (0.89.0).
- **Swift 6 language mode staged**: the codebase is clean under full v6 checking, but the
  toolchain (CLT 6.3.3.1 locally, Xcode 26 in CI run 38093069969) crashes in IRGen
  (`SmallVector 2^32+1`, module-cumulative). Two-line flip documented in `Package.swift`.
  External blocker — track, don't force.
- **Engine pins behind upstream** (`patches/README.md`, mission 2026-10-10): llama.cpp at
  `cdc06426e` (+31 from previous; frontier `84e76d8a2` breaks patch 0002), whisper at v1.9.3
  (v1.9.5 moved to kernels/ layout), sd.cpp at `241518b`. Reaching current upstream is
  re-authoring, not repair: 121 rejected hunks across 49 of 92 patches at `aa94f2086`.

**Class:** architectural. **Severity: medium** — cost is latency of upstream fixes, not
user-visible breakage today.

## 6. Agentic layer — present, not yet "exceptional at coding and delivery"

Exists today: per-step tool permissions (`ToolPermissionCard`), file read/edit/run tools,
sealed JavaScript sandbox (`JavaScriptSandboxService`, CSP `default-src 'none'`, unique origin —
assessment §Application), MCP client (`Sources/MCP`), agent continuation
(`AgentContinuation`), pi/latch sidecars with confined chat turns and JSONL traces, prompt
library with typed variables, skills discovery. Gaps an "enterprise agentic" bar would call out:
no retry policy on tool loops surfaced anywhere, no structured per-run usage rollup (roadmap 6),
tool-context budget is a fixed character cap (0.89.2 made it tunable but static), latch
delegation unconstrained (§3 above). Scope decision required before building (see plan).

## Remediation plan

Tracked in `.agents/missions/2026-10-12-enterprise-upgrade/plan.md`; working notes in that
folder's `journal.md`. Priority order (severity × evidence): security Highs → context-trap
extinction → verification gap (operator-gated: Xcode install vs suite migration) → agentic-core
wave (operator-gated scope) → engines (operator-gated effort).
