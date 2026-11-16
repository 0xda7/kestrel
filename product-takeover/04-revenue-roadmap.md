# 04 — Revenue Roadmap (the plan)

Synthesis of the release-readiness audit (02) and product/market audit (03), plus the
confirmed-defect register (01). Strategy: **Strategy B (Base)** — dual-license + kernel IP —
executed with Strategy C (platform widening) kept as the 9-month pivot if licensing motion
fails. Success metric: first commercial revenue within 12 months, ≥$50k yr-1 run-rate.

---

## Phase 0 — Stop the bleeding (weeks 1–2) — *no revenue conversation can happen first*

| Order | Item | Source | Owner action |
|---|---|---|---|
| 0.1 | ~~Fix 2 High security findings~~ **VERIFIED ALREADY FIXED** — CHANGELOG 0.89.x "Security wave A" closed KES-01..04 (LAN bind requires API key; diagnostics redaction; --api-key-file; Bonjour auth). UPGRADE_REPORT §4 line refs were stale. | verified | none — documented |
| 0.2 | G1: single-source version truth — `AppInfo.version` reads bundle plist; release.sh asserts stamp | 02 G1 | **DONE — committed `a28bda9`**, 850 checks green. Release re-cut (bump VERSION → 0.90.1, tag) still pending owner's go |
| 0.3 | G2: signing hard-fail. CI tag builds **fail** when cert secrets absent; CI runs `spctl -a` on artifact; README states per-release signing truth | 02 G2 | needs Apple Developer account ($99/yr) + cert in GitHub secrets — **owner action required** |
| 0.4 | C3: catalog stops offering models the engine can't load (LFM3); no crash-loop retries | 01 C3 | **DONE — committed `79969da`**: failed (model, engine) pairs are remembered; start refuses up front with a bilingual message; engine switch/update clears the refusal. 855 checks green |
| 0.5 | C4: agent tool-call grammar failure falls back to unconstrained generation instead of erroring the turn | 01 C4 | **DONE — committed `78db23a`**, 855 checks green |
| 0.6 | G2 code half: CI tag builds fail hard when signing secrets absent; G4: make-app.sh fails hard on engine-less CI/release builds; README states real signing status | 02 G2/G4 | **DONE — committed `d3f6e59`**. Actual signing still requires owner's Apple Developer cert |
| 0.7 | C5 clean benchmark baseline (5500M 4 GB) | 01 C5 | **DONE — measured 2026-11-16, GPU idle:** Qwen3-4B Q4_K_M pp512 = 325.5 ± 1.7 t/s, tg128 = 26.2 ± 0.2 t/s → card is healthy; earlier low in-app numbers were contamination + context depth. Sub-finding: forced `-fa 1` hangs llama-bench (default auto path is fine) |

## Phase 1 — Trust & measurability (weeks 3–8)

| Order | Item | Why |
|---|---|---|
| 1.1 | Publish from a Northlatch org account; centralize repo slug; real landing page (docs, GPU matrix, pricing placeholder, enterprise contact) | unblocks every commercial conversation; kills R4 feed fragility |
| 1.2 | Signed auto-updater (Sparkle or hardened current path) + Stable vs Beta channels | the first Pro feature |
| 1.3 | Opt-in anonymous telemetry (installs, GPU model, DAU) | pricing/power/OEM pitch need numbers |
| 1.4 | Public product docs split from internal mission files; tested-GPU support matrix | cheapest sales asset |
| 1.5 | Pipeline quick wins: G4 engines-present hard fail, G5 CI version assertion, G6–G12 hygiene | prevents regressions of 0.2/0.3 |

## Phase 2 — Product quality (weeks 4–10)

| Order | Item | Why |
|---|---|---|
| 2.1 | First-run wizard: detect GPU → one-click known-good model → safe defaults | kills #1 "it's broken" support driver |
| 2.2 | Real automatic context sizing (`contextAutomatic` actually automatic) | kills the 0.99 t/s trap |
| 2.3 | Support channel: Discord + triage labels + paid-SLA tier design | paid tier prerequisite |
| 2.4 | Clean benchmark baseline per GPU class (this box: 5500M 4 GB; C5) | honest perf claims; support matrix data |

## Phase 3 — Revenue motions (weeks 6–12, overlapping)

| Order | Item | Target |
|---|---|---|
| 3.1 | "Kestrel Pro" page: $79/yr — auto-updater, stable channel, priority support, hardening | 1.5% of ~40k niche ≈ $25k/yr |
| 3.2 | Kernel-licensing outreach: AMD DevRel + 2 workstation OEMs, pitch = KestrelGEMM/attention benchmarks | 1 deal ≈ $20k–40k |
| 3.3 | Managed-deployment offering for Mac Pro fleets / studios | $20k+ per engagement |
| 3.4 | Upstream 2–3 most portable kernels to llama.cpp | credibility + moat defense + free distribution |
| 3.5 | GitHub Sponsors activation | $1k–8k |

## Decision gate (month 9)

- If Pro + licensing + deployments are tracking to ≥$50k yr-1 → stay course.
- Else → execute Strategy C pivot: widen platform beyond the dying niche and open metered
  private inference (the LM Studio/Ollama playbook). The niche app then becomes the
  showcase, not the product.

## What I need from the owner (cannot be self-served)

1. Apple Developer Program enrollment ($99/yr) → makes G2/0.3 real.
2. GitHub org (Northlatch-Labs exists) → transfer/redirect publishing.
3. Domain + one page host for the landing page.
4. Decision on Pro price point and whether telemetry opt-in is acceptable to ship.
5. Confirmation Northlatch holds copyright on all independently authored files
   (required for dual-licensing; contributor CLA/license-notice to prevent future leakage).
