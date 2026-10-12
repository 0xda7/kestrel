# Mission: 2026-10-12-enterprise-upgrade

**Objective:** Diagnose and extinguish the recurring failure classes in Kestrel (v0.89.2), then raise it to enterprise grade across security, engine configuration honesty, verification, and the agentic core.
**Operator:** Kestrel maintainer (0xda7/kestrel) · **Value:** users stop hitting silent/slow failures; the maintainer can test locally before push; the shipped app stops carrying High security findings.
**Success criteria:**
1. `swift test` (or its migrated equivalent) runs to green **on this machine**, not only in CI.
2. Both High security findings (KES-01, KES-03) are fixed with regression tests proving the fix.
3. A request larger than the context window can no longer reach the engine unanswered-by-design (today's 70,871 > 65,536 error class), and `contextAutomatic` computes a VRAM-fitting window instead of aliasing 16384.
4. Every wave lands with `swift build` green and its named gate passed; CHANGELOG and journal record it.
**Constraints:** GPL-3.0 repo conventions (CHANGELOG per wave, mission journal); no behavior change outside a wave's stated intent; v6 language-mode flip stays blocked on the documented toolchain bug; `dist/` assembly stays CI-owned unless Xcode is installed.
**Assumptions:** CI (GitHub Actions) remains available; the operator's Keychain/local secret store layout from 0.89.2 is the baseline; engine rebuilds need the patched-tree build scripts (hours, not minutes).
**Budget:** ≤ 24 steps · multi-session · hard stop at 2x overage → replan.

## Steps

| # | Step | Owner | Depends on | Deliverable contract | Gate | Risk / rollback |
|---|------|-------|------------|----------------------|------|-----------------|
| 0 | Diagnosis report | xlaunch | — | `UPGRADE_REPORT.md` at repo root, evidence-pinned | Operator accepts diagnosis | — |
| 1 | Scope decisions | operator | 0 | Answers to the 4 scope questions recorded in journal | Questions answered | — |
| 2 | Security wave A: the two Highs | xlaunch | 1 | KES-03 redactor reuse in LogsTab + test asserting key absent from diagnostics; KES-01 key required when LAN is on, refusal test | `swift build` green + new tests + code review of diff | Pure code, revert per commit |
| 3 | Security wave B: mediums/lows | xlaunch | 2 | Enumerated KES-06…13 triage; fixes or explicit risk-acceptances per finding | Same gate per finding | Same |
| 4 | Local test pipeline | xlaunch | 1 | Per operator choice: Xcode installed, or suite migrated to swift-testing package dep, or CI-only documented | Chosen pipeline runs green locally on a real test | Package manifest churn — revertable; Xcode install is operator-irreversible-ish |
| 5 | Context-trap extinction | xlaunch | 1 | `contextAutomatic` computes from KV math at launch (Dashboard readout); pre-send guard blocks/trims over-window transcripts with a bilingual notice | Unit tests on the KV math + over-window fixture; live engine check | Feature-flagged, defaults preserved |
| 6 | Agentic core wave | xlaunch | 1 | Per operator scope (built-in loop upgrades, sidecar ownership, or both) + tests | Scope-defined gate | Per design |
| 7 | Engines wave (optional) | xlaunch | 1 | Patch-series re-authoring toward upstream frontier per operator effort call | `scripts/check-patch-series.sh` + rebuild + bench no-regression | Pin revert |
| 8 | Docs & delivery | xlaunch | 2–7 | CHANGELOG entries per wave; README/docs updates; `delivery/` summary | Operator review | — |

## Out of scope

- The v6 language-mode flip (toolchain bug, externally blocked — tracked, not forced).
- Whisper/sd.cpp `kernels/` layout port beyond what the engines wave explicitly scopes.
- Any new product surface (video, image gen) beyond reliability fixes.
- Server TLS termination (assessment recommends design work; separate mission if wanted).
