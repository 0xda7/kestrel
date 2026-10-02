# Kestrel Rebrand — Delivery Package

**Delivered:** 2026-10-01 · Commit `8e61ce7` · Baseline `28b653d` (rollback point) · Instrumentation `44165ca`
**Operator objective:** Reproductize ToshLLM as a new brand under Northlatch Labs licensing, with 100% removal of obsolete personal details and the original random name. Amended: full personal-identity purge including financial identity.

---

## 1. Outcome (business terms)

ToshLLM 0.87.9 is now **Kestrel 0.87.9**, a clean-room-rebrandable local-LLM product owned by **Northlatch Labs**:

| Dimension | Before | After |
|---|---|---|
| Product name | ToshLLM | **Kestrel** |
| Bundle ID / keychain | dev.engel.toshllm | **com.northlatchlabs.kestrel** |
| Repo slug | engeldlgado/toshllm | **northlatchlabs/kestrel** |
| Site refs | toshllm.com | **northlatchlabs.com/kestrel** |
| Contact | engeldlgado@gmail.com | **opensource@northlatchlabs.com** |
| Copyright | Engelbert Delgado | **Northlatch Labs** (file headers) |
| Donations | Binance Pay ID + personal USDT TRC-20 QR | **Single sponsor link** (GitHub Sponsors anchor) |

**Nothing functional changed.** Every behavioral surface the product spec guarantees survives:
`TOSH_*` environment and build defines (254 distinct tokens, set-diff vs baseline = 0), `tosh_*` C symbols, the `tosh-moe` engine module, legacy `toshllm_*` on-disk image compatibility, VERSION 0.87.9, and Package.swift dependencies (diff-empty vs baseline).

**Personal identity: zero.** Repo-wide sweep with the extended pattern (names, handles, both emails, wallet address `TFUG…JDUf`, ORCID, youpay.me) outside mission records: **0 lines**. Third-party credits (llama.cpp/ggml-org, iRon-Llama/Basten7, all contributors) fully preserved — README 17 credit lines, in-app docs 10.

## 2. Verification evidence (all captured in journal.md)

| Gate | Result |
|---|---|
| G2 `swiftc -parse`, all Swift | 198/198 files, 0 failures |
| G3 brand residuals | TRUE_RESIDUALS=0, BINARY_ART_MATCHES=0 (audit v4 content-verifies binaries; JFIF "Photoshop 3.0" marker is a false-positive class) |
| G4 personal sweep (extended) | 0 |
| G5 patch hunk integrity | 0 drift, rename-aware |
| G6 meta validity | .zenodo.json / CITATION.cff / build.yml all valid |
| Runtime build | **exit 0, 298.53s clean**, binary links as `Kestrel`, incremental 0.60s |
| Localization | 4 packs × 1859 keys, valid JSON, ImageGen key renamed with translated values |
| Donor purge | Binance/USDT absent from Sources, docs, scripts, assets; only historical CHANGELOG line remains |

## 3. Runbook (operator actions after pull)

**Code changes are complete and committed — the following require your machines/accounts and cannot be done from this repo:**

1. **GitHub**: ~~create `northlatchlabs/kestrel`, push `main`~~ **PUSHED** — canonical repo is `github.com/0xda7/kestrel` (**private**; operator confirmed personal account is the home). Registered org handle is `Northlatch-Labs-LLC` (token owner is org admin; a detour org-repo was created, parity-checked, and deleted — see journal 09:38). If the operator later wants it under the org: `gh repo transfer 0xda7/kestrel --to Northlatch-Labs-LLC` (all in-product URLs then follow via GitHub redirect), then set visibility Public and enable GitHub Sponsors. In-product URLs (552be20) already resolve today: releases API, issues, advisories, FUNDING, citation identifiers.
2. **DNS/web**: point `northlatchlabs.com/kestrel` (README/docs reference it).
3. **Code signing**: set the org's Team ID in release signing; bundle id changed, so generate a **new** Developer ID certificate provisioning for `com.northlatchlabs.kestrel`.
4. ~~App icon art~~ **DONE** (AMENDMENT 2): new Kestrel icon rendered via `icon-gen.swift` (indigo→raspberry squircle, GPU chip + LLM monogram), `AppIcon.icns` regenerated, layered glyph replaced (chip-only outline); DMG background composes the new glyph — verified in `dist/Kestrel-v0.87.9.dmg`.
5. ~~Replacement screenshots~~ **DONE** (AMENDMENT 2): `Assets/{home,chat,benchmarks,models}.jpg` re-captured from the running Kestrel app (1568×951/1037) and Vision-OCR-verified Kestrel-branded; `Assets/model-hero{,-light}.jpg` + `Assets/settings-guide{,-light}.jpg` regenerated as brand-styled CoreGraphics art (they are decorative `accessibilityHidden` artwork — no pixels of the old brand remain in `Assets/`).
6. ~~DMG assets~~ **DONE** (AMENDMENT 2): `Assets/dmg/DS_Store` regenerated on a live volume (ToshLLM strings 8 → 0, `/Kestrel` records confirmed); `TOSH_DMG_LAYOUT=1 ./scripts/make-dmg.sh` → `dist/Kestrel-v0.87.9.dmg`. `Assets/dmg/obsidian-hardware.png` OCR-scanned: zero text, zero brand strings — kept.
   - Audit instrumentation note: Apple JPEG encoders embed a JFIF "Photoshop 3.0" marker containing the bare substring "tosh"; `audit-brand.sh` v4 now content-verifies binary hits so this false-positive class (also present in the originals) no longer masks real residuals. Final: `TRUE_RESIDUALS=0`, `BINARY_ART_MATCHES=0`.
7. **Release**: run `.github/workflows/build.yml` (keychain steps already renamed to `kestrel.keychain`), then `scripts/release.sh`.

**User-facing BREAKING changes (no migration, by design):**
- App support dir moves `~/Library/Application Support/ToshLLM` → `…/Kestrel`. Users with models in the old dir must move it manually.
- Keychain entries under the old service are not read; re-authenticate providers once.
- Settings archives exported by old builds (`toshllm-settings` format key) are rejected by the new `kestrel-settings` reader.
- Old builds' `toshllm_*` generated-image files are still listed and deletable (compat kept); new files are written as `kestrel_*`.
- Donation channels are reduced to the sponsor link.

## 4. Rollback

```bash
git checkout 28b653d   # pristine ToshLLM 0.87.9, pre-rebrand
```
No data migrations were performed outside git; rollback is complete and lossless.

## 5. Metrics

- **245 files changed** across 1 atomic commit; 1634 insertions, 1108 deletions.
- **Pass 1:** 5 agents (A1 core sources, A2 build/config, A3 UI/localization, A4b lean re-dispatch of A4's meta scope, A5 meta/CI/docs/assets) — all returns evidence-checked and accepted.
- **Fix pass (B1–B3): closed without dispatch** — pass 1 + reviewer surgery left zero actionable residuals (rationale journaled 05:37).
- **Reviewer surgery:** 1 structural identity leak (USDT wallet + QR) found outside all agent pattern scopes; fixed end-to-end (Sources, docs ES/EN, 4 lang packs, build script, asset deleted).
- **Gate tooling hardened:** audit exception list corrected (241 → 0 true residuals), rename-aware hunk gate, extended personal pattern, validator fallback. G4 gap lesson institutionalized: reviewer runs full-pattern sweeps across all dirs after every pass.
- **Budget:** within plan; 1 re-dispatch (A4→A4b, context-death cause), 1 mid-flight steer (A5), 0 budget-stop events.

## 6. Known limitations

- 6 binary-art old-brand matches remain until operator supplies replacement art (§3.5–3.6).
- `vendor/` engine sources and upstream patches intentionally keep `tosh`-prefixed C symbols — renaming them would break the patch series against upstream llama.cpp.
- Web-ui bundle (`Assets/web-ui/…/bundle.js`) renamed at the 3 branded physical lines only; a rebuild from the webui source with `scripts/rebrand-webui.sh` is advised before public release.

## AMENDMENT 3 (2026-10-01) — wave-2 release
- v0.88.0 tagged and pushed; CI run 36940659745 builds both variants + DMGs from the tag.
- Live-fire on the operator's real model found and fixed a POST /tools ship-blocker
  (36f991e: --webui-mcp-proxy now passed with agent tools). That fix landed on main AFTER
  the v0.88.0 tag was cut — the tag's CI artifacts do NOT contain it.
- Operator decision needed: (a) keep v0.88.0 as the exercise run and cut v0.88.1 from
  current main for the installable DMG, or (b) delete + retag v0.88.0 at 36f991e
  (`git tag -d v0.88.0 && git push origin :refs/tags/v0.88.0` then re-tag) so the release
  carries the fix. Recommended: (b) — nothing has been consumed from the release yet.

## WAVE-2 DELIVERY (2026-10-01 17:08 PT) — v0.88.0 released and verified

**Outcome.** Kestrel 0.88.0 is published at github.com/0xda7/kestrel/releases/tag/v0.88.0:
a freshly CI-compiled, Kestrel-branded app for both x86_64 variants (AVX2 + noavx2 DMGs,
70.5/69.7 MB) carrying the hardened agent harness — tolerant tool-call parsing, text-side
tool-call rescue, latch delegation, discipline prompt, per-model speed benchmark button,
and measured-first ncmoe/threads pre-fill. The engine is untouched; nothing is wired
through it; no models are hardcoded.

**What changed** (commits f826a27 → cb649ed):
- Agent harness H1–H4 in Chat (f826a27): rescue of text-form tool calls (max 3/turn, visible
  text only, never on cancel/error), 12k-char result clamp, latch_delegate tool
  (settings-driven path/timeout), 5-rule discipline prompt, continuation card now shows
  turns used + tools executed.
- Live-fire fixes found only by running the operator's real 9B model: POST /tools was
  404-disabled without --webui-mcp-proxy (36f991e); CI packaging failed because
  .gitignore's `dist/` rule silently swallowed vendored mermaid/katex bundles (5202d7e).
- Release chain: CHANGELOG [0.88.0] section → release.sh → tag v0.88.0 → CI green
  (run 36942558831) → release published with checksums.

**How to use it.** Download `Kestrel-v0.88.0.dmg` from the release page (noavx2 variant
only for pre-2013 Macs), drag to Applications, launch. Verify the checksum first:
`shasum -a 256 Kestrel-v0.88.0.dmg` must print `9b515b72…175579f`. For the agent stack:
enable tools in Chat settings, then ask the model something requiring a tool — the call now
survives text-form output and the continuation card reports turns/tools used.

**Runbook.** Health: app Logs tab shows engine args (look for `--jinja --tools all
--webui-mcp-proxy` when agent tools are on). Failure 1 — tool call "does nothing": check
the log for `--webui-mcp-proxy`; if absent you are on ≤0.87.x, upgrade. Failure 2 — CI
red on a future tag: read the make-app.sh step first; every cp source must be git-tracked
(audit loop is in the wave-2 journal). Failure 3 — latch_delegate errors: verify the
binary path in Chat advanced settings (`~/.latch/bin/latch-harness`) is executable.
Escalation: mission journal + harness plan amendments 1–4 hold the full evidence chain.

**Rollback.** `git tag -d v0.88.0 && git push origin :refs/tags/v0.88.0 && git push origin :refs/tags/v0.88.0` (tested pattern — executed once today at 16:46 PT) then delete the release
in the UI; the previous installable is v0.87.9 in dist/. The app itself rolls back by
deleting Kestrel.app and reinstalling the older DMG. Local `~/Library/Application
Support/Kestrel` is unaffected by downgrades.

**Impact & measurement.** Baseline: tool calls silently lost on reasoning models (~356
thinking tokens per trivial prompt observed); POST /tools broken in shipped builds; no
per-model speed feedback. Target: calls execute every turn, POST /tools 200, speed
measured per model. Actual (captured): native tool_calls round-trip ✓, POST /tools
read_file/exec/grep ✓ after fix, DMG checksum-verified ✓. Watch live: repo Actions tab;
in-app Benchmarks tab.

**Limitations & follow-ups.** The app-GUI half of the agent loop (SwiftUI end-to-end with
the model in the window) remains operator-run — every API/engine-level link is verified
here, the last inch is yours. Notarization secrets, repo visibility, DNS, and Sponsors
stay operator-side as listed above. Next highest-value move: your GUI run of 0.88.0 on
the 9B model, then Chat & Studio llm-space phases 1–5.
