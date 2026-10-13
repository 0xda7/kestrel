# Enterprise upgrade — final delivery (2026-10-13)

Mission `.agents/missions/2026-10-12-enterprise-upgrade/`, sessions 1–7.
Everything the operator scoped was delivered. Shipped to users in **v0.89.3**
except the engines pin, which is on `main` awaiting the next release.

## Delivered

1. **Security — all 13 assessment findings dispositioned** (v0.89.3).
   Both Highs closed: LAN binds require an API key; diagnostics never leak
   the engine key. Key exposure, tool consent, import gates, updater
   fail-closed, secret storage, CI pin integrity — see CHANGELOG 0.89.3
   waves A and B. Three residual risks accepted with rationale (TLS for LAN,
   web-UI session token, archive-endpoint confirmation change).

2. **The context trap is extinct** (v0.89.3). "Auto" context computes a
   VRAM-fitting window; every surface reads the resolved value; over-window
   requests are refused before the wire with a bilingual notice.

3. **The agentic core, five waves** (v0.89.3). Transient-safe read-only
   retries; conversation usage rollup; latch delegation under Kestrel-owned
   provider config (the pi pattern); schema-gated tool registration; dynamic
   tool-result budget; first-class delegate visualization.

4. **The test pipeline runs anywhere** (v0.89.3). 350 checks on the
   zero-dependency kestrel-checks harness — no Xcode, no XCTest; and the
   package is fully Swift 6 (v6 mode live, Xcode 26.5 arbitrated the IRGen
   crash). First local run in the machine's history: 350/350.

5. **Engines: pin advanced five commits** (`cdc06426e` → `ed319febb`,
   b11174; commit c5c5294). Four patches re-authored through the
   graph-capture wall. Gates: strict apply 92/92, build 100%, round trip
   byte-identical, temp-0 smoke coherent, interleaved bench at parity
   (55.7 vs 55.9 t/s tg128). The first "regression" readings were thermal
   artifacts — proven by the pin binary collapsing under its own conditions.

## Verification record

Every wave's commit carries its `Assistant-verification` lines. CI arbitrated
all Swift work green (Build & Release incl. kestrel-checks, Translations,
CodeQL through 9a6cddf). The engines commit's CI arbitration is pending: the
account's Actions did not schedule runs for it (same billing condition as the
documented 2026-10-10 incident) — its five local gates are recorded in the
commit message and journal session 7.

## What remains (mapped, not started)

- The `kernels/` layout port (`5a75f14c0` breaks patch 0001): the keystone
  that unlocks llama master, whisper v1.9.5+, and sd.cpp master, and
  collapses `shared-metal/` into the llama series. Plan:
  `engines-reaauthoring-plan.md`; evidence: `engines-frontier/EVIDENCE.md`.
- Risk-accepted security design items (TLS for LAN mode; web-UI session
  token; archive-endpoint change confirmation).
- Operator-side: GitHub Actions billing, for the pending engines-commit CI
  arbitration (and future release builds).
