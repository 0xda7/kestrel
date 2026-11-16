# 03 — Product & Go-to-Market Audit (subagent, 2026-11-16)

## Core finding (brutal honesty clause)

The Intel-Mac + AMD-GPU niche is real but shrinking by design (Tahoe is the last x86 macOS;
no new Intel Macs ever). Honest ceiling for the niche alone: **$5k–60k/yr, decaying, ~3-year
window**. LM Studio and Ollama prove nobody pays for the desktop shell — they monetize via
cloud tokens and enterprise. **The business is not the app; the business is the AMD Metal
kernel IP plus a Pro/enterprise layer above the free GPL app.**

## Monetization ranking (GPL-3.0, copyright held by Northlatch → dual-licensing is legal)

1. **Kernel IP licensing** (KestrelGEMM, AMD attention, wave64, persistent staging) to
   AMD/OEMs/ROCm ecosystem — $25k–150k/deal. Patches against MIT llama.cpp should be
   donated upstream for goodwill; independently authored app/kernel files are the licensable asset.
2. **"Kestrel Pro" dual-license tier** ($79/yr: signed auto-updater, stable channel,
   priority support, security hardening) — $10k–60k/yr. Free GPL version stays complete.
3. **Managed local-AI deployments + SLAs** (Mac Pro farms, studios) — $20k–100k/yr.
4. Sponsorship ($1k–8k/yr) · 6. AMD DevRel grants/equipment · 7. Paid support.
   Forbidden: closing the app / paywalling binaries (fork risk, GPL irreversible).

## Top revenue-blocking gaps

1. Two **High security findings** in every release (plaintext LAN mode; API key leaked into
   diagnostics exports — UPGRADE_REPORT.md §4). Fix before any paid tier.
2. No real auto-updater (manual DMG re-download) — the first Pro feature.
3. **Zero telemetry** → no install base, no pricing power, no OEM pitch. Add opt-in counts.
4. Support = GitHub issues on exotic hardware; needs channel + tested-GPU support matrix.
5. Onboarding friction: multi-GB GGUF hunt; context-spill trap → "it's broken" (0.99 t/s).
   First-run wizard + real `contextAutomatic`.
6. Personal-account publishing; no product landing page → blocks every commercial conversation.
7. Beta label, no stable channel for paying customers.
8. Dev machine can't run its own test suite (single-machine verification gap).
9. Engine patch series 121 hunks behind upstream — port cadence needed; upstreaming = moat defense.
10. Docs are internal mission files, not product docs.

## Strategies (12-month)

- **A Conservative** (sponsorship only): $3k–8k/yr — a hobby with receipts.
- **B Base (recommended)**: Pro tier + 1 kernel/outreach motion + deployments:
  **$50k–90k yr-1**, ceiling ~$150k/yr while niche lives.
- **C Aggressive**: widen platform beyond dying niche + metered private inference
  (LM Studio/Ollama playbook): yr-1 $30k–120k, yr-2 $200k–500k possible; needs runway.

## 90-day sequence

Wk1–2 fix security Highs · Wk1–4 org account + landing page + public docs · Wk2–6 stable
channel + signed updater · Wk3–8 opt-in telemetry · Wk4–10 onboarding wizard ·
Wk6–12 dual-license outreach (AMD DevRel, workstation OEMs) · Ongoing: upstream kernels.

## Reconciliation note (empirical)

Market auditor asserted signing is fine since 0.86.5. Empirically false for v0.90.0
(adhoc, spctl-rejected on test box); release audit found the mechanism
(build.yml:131-135 silent no-op without cert secrets). Trust work must assume the
pipeline regresses silently — hence the hard-fail CI gate (G2).
