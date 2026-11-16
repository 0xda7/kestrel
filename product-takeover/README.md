# Kestrel Product Takeover — Working Documents

Owner: Northlatch Labs. Prepared 2026-11-16 from hands-on validation on the test box
(MacBook Pro 16" 2019, i9-9980HK, Radeon Pro 5500M 4 GB, macOS 26.7.3) plus repository
audit. Status columns updated as items are fixed.

---

## Document index

| File | Purpose |
|---|---|
| `01-confirmed-defects.md` | Defects confirmed empirically on the test box (this takeover's evidence base) |
| `02-release-readiness-audit.md` | Release pipeline / updater / signing audit (subagent) |
| `03-product-market-audit.md` | Product, monetization, and go-to-market audit (subagent) |
| `04-revenue-roadmap.md` | The plan: prioritized execution to revenue |

---

## Ground rules established for this takeover

1. **GPL-3.0 stays.** Code is published, free, and stays free. Revenue comes from around
   the code: dual-licensing (Northlatch owns copyright, so this is available), support,
   signed/notarized distribution, and partnerships.
2. **Trust before revenue.** Nothing sells until installation is Gatekeeper-clean,
   auto-update works, and releases are reproducible. That is P0.
3. **One source of truth for version.** The VERSION file, git tags, bundle version, and
   update feed must never disagree again (this release: tag v0.90.0, bundle 0.89.17).
4. **Every claim in docs must be honored by the pipeline** (e.g. "signed and notarized
   since 0.86.5" — v0.90.0 ships adhoc-signed; either fix the pipeline or fix the claim).
5. **The niche is honest but small.** Strategy must be validated against market reality
   before committing effort; see `03-product-market-audit.md`.
