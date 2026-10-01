# Mission: kestrel-rebrand

**Objective:** Reproductize ToshLLM 0.87.9 as **Kestrel** by Northlatch Labs — full brand
transfer (name, identity, licensing, URLs, authorship) with zero loss of product function.
**Operator:** engeldelgado → Northlatch Labs · **Value:** the product carries company brand and
license instead of a placeholder name and personal GitHub.
**Success criteria:**
1. `swift build` and `swift test` pass at least at baseline level (baseline build recorded first).
2. Zero user-facing "Tosh" brand strings remain outside the documented exceptions below.
3. `TOSH_*` env-var interface and `tosh_*` C symbol namespace unchanged (documented exceptions).
4. Licensing: GPL-3.0-or-later body untouched; copyright/attribution carries Northlatch Labs;
   original author credited.
5. Diff review confirms only brand-surface lines changed — no logic lines.

**Constraints:** No dependency changes. No version bump (stays 0.87.9). No C patch hunk
structure edits (+/-/@ lines only edited in their text content per rules). Irreversible actions
(publish, repo rename on GitHub) are operator gates — out of scope today.
**Assumptions:** Operator owns engeldlgado/toshllm and may rename the GitHub repo later (GitHub
redirects old links); new name "Kestrel" is operator-approved by delegation ("no questions asked").
**Budget:** ≤ 10 dispatches · ~90 min wall-clock · hard stop at 2x.

## Name mapping (canonical, deterministic)

| From | To | Notes |
|------|----|-------|
| `ToshLLM` | `Kestrel` | product, binary, module, UI |
| `toshllm` | `kestrel` | lowercase paths, filenames, URLs |
| `ToshGEMM` | `KestrelGEMM` | engine/kernel brand |
| `Tosh` (any other casing/compound) | case-consistent `Kestrel` | e.g. ToshDropdown → KestrelDropdown |
| `dev.engel.toshllm` | `com.northlatchlabs.kestrel` | bundle id |
| `github.com/engeldlgado/toshllm` | `github.com/northlatchlabs/kestrel` | |
| `toshllm.com` | `northlatchlabs.com/kestrel` | |
| `engeldlgado@gmail.com` | `opensource@northlatchlabs.com` | licence contact |
| `engeldlgado` (remaining) | `northlatchlabs` | |
| Tagline "run LLMs locally on Intel Macs with AMD GPUs" | unchanged | product spec |

## Documented exceptions (MUST NOT change)

- `TOSH_*` environment-variable names (in C code, Swift string literals, docs, scripts).
- `tosh_*` C identifiers/symbols inside patches and engine code.
- GPL-3.0 license text body (LICENSE file).
- Historical upstream project references (llama.cpp, stable-diffusion.cpp, whisper.cpp) and their
  authors' credits.
- Binary asset files: flag, don't edit.

## Attribution policy

Engelbert Delgado remains credited as original author everywhere authorship is asserted;
copyright holder becomes Northlatch Labs; contact becomes opensource@northlatchlabs.com.

## Steps

| # | Step | Owner (tier) | Depends | Deliverable contract | Gate | Risk / rollback |
|---|------|--------------|---------|----------------------|------|-----------------|
| 1 | Baseline git snapshot + baseline build/test record | orchestrator | — | commit 28b653d + build log | commit exists, log written | n/a (read-only) |
| 2 | Rebrand patches/ + reference/ (brand strings in comments/log text only) | A1 @ T1 | 1 | grep-residual report | no Tosh-brand outside exceptions; patch markers intact | `git checkout -- <files>` |
| 3 | Rebrand Sources/ Chat, Servers, MCP, Video, Subtitles | A2 @ T1 | 1 | same | same + symbols compile-checked at join | same |
| 4 | Rebrand Sources/ Models, Benchmarks, Images, Audio, Workspace, DynamicMoE, Hardware | A3 @ T1 | 1 | same | same | same |
| 5 | Rebrand Sources/ App, DesignSystem, Dashboard, Settings + Tests/ + Package.swift module rename | A4 @ T1 | 1 | same | same | same |
| 6 | Rebrand scripts/, .github/, docs/, Assets text, top-level meta (README, CHANGELOG, AUTHORS, CITATION.cff, .zenodo.json, SECURITY.md, CONTRIBUTING.md, make-app.sh, icon-gen.swift, Info.plist templates) | A5 @ T1 | 1 | same | same | same |
| 7 | Gate: `swift build` + `swift test`, residual grep audit, diff triage | orchestrator | 2–6 | gate log | G0/G1 green, G3 diff clean | rollback per-file |
| 8 | Fix pass: 3 engineers repair residuals/failures missed in pass 1 | B1–B3 @ T1 | 7 | zero residuals in scope | gate re-run green | same |
| 9 | Final review, spec-preservation checklist, commit history | orchestrator | 8 | review verdict + commits | all success criteria evidenced | revert commit |
| 10 | Delivery package + runbook | orchestrator | 9 | delivery/ doc | operator-readable | n/a |

## Out of scope
- GitHub repo rename, site DNS, code signing identities, icon artwork redesign beyond text,
  regenerating binary .icns if tooling fails, TOSH_* namespace migration.

AMENDMENT 1: Operator directive — 100% removal of personal details (Engelbert Delgado /
engeldelgado / engeldlgado / personal email / dev.engel) from all surfaces; authorship asserts
Northlatch Labs; third-party contributor credits preserved. Overrides the earlier keep-author rule.
