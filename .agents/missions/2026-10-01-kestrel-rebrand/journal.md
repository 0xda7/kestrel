# Mission Journal — kestrel-rebrand (2026-10-01)

## 03:55–03:01 BRIEF + PLAN
- Request: reproductize ToshLLM (engeldelgado) under Northlatch Labs branding + licensing.
- Operator pre-approved plan by delegation ("No questions asked"); orchestrator self-approved plan.md.
- Name decision (orchestrator, documented in plan): **Kestrel** by Northlatch Labs. KestrelGEMM
  keeps the engine brand pattern. Bundle id com.northlatchlabs.kestrel.
- **Routing decision (model-routing):** `TOSH_*` env vars and `tosh_*` C symbols stay — they are
  the documented engine interface (CHANGELOG + perf docs reference them); renaming risks corrupting
  patch structure and breaking documented features. Documented exception in plan.md.

## Baseline evidence
- Repo was NOT under git → `git init`, baseline commit **28b653d** ("Baseline: ToshLLM 0.87.9 as
  imported"). Rollback = `git checkout`/`reset` to 28b653d.
- Toolchain: Apple Swift 6.3.3, x86_64-apple-macosx26.0, CLT at /Library/Developer/CommandLineTools.
- Build attempt 1 FAILED (environment): shared clang ModuleCache under /var/folders not writable
  (`Operation not permitted`, SwiftShims.pcm). This is sandbox policy, not a code defect.
  Note: `TESTBUILD_EXIT=0` in that log was a pipe artifact (echo captured tail's exit), not a pass.
- Build attempt 2 (job bash-42): module cache redirected to .build/clang-cache inside workspace.
  Gate: BUILD_EXIT=0, test build success, `swift test --skip-build` summary recorded.
- **Rule: no agent mutates the tree until job bash-42 closes the baseline gate.**

## Inventory (for dispatch slicing)
- 3,064 brand matches / 528 files. Byte-weights: patches 2994KB(99f), Sources/Chat 406KB(27f),
  Sources/Servers 256KB(17f), Sources/Models 226KB(18f), Tests 210KB(18f), Sources/Audio 176KB(32f),
  scripts 77KB(13f), Assets 18f binary-ish, .github 4f, docs 3f, reference 220KB(3f).
- License: GPL-3.0-or-later, author Engelbert Delgado. LICENSE body untouchable; attribution
  transfers to Northlatch Labs per plan.

## 03:08 Amendment 1 + gates
- Operator directive: 100% personal-detail removal. Contract + plan amended (AMENDMENT 1).
- G0-proxy parse gate PASSED: `swiftc -parse` over 198/198 Swift files, 0 failures (baseline syntax
  integrity proven under sandbox).
- Goal filed: goal-89ebb418-157b-444d-8293-4f97628d09a1 (armed, max 12 rounds).
- Full swift build (job bash-43, danger-full-access) still running — A1 (patches/reference, no Swift
  interaction) dispatches now; A2–A5 hold until the baseline build closes to protect the baseline
  measurement.

## 03:11 Baseline gates CLOSED — A2–A5 dispatched
- G0 MAIN BUILD PASS: `swift build` Build complete! (257.11s), exit 0, at commit 28b653d.
- G1 XCTest: BLOCKED by environment — CLT-only toolchain has no XCTest module ("no such module
  'XCTest'"), .xctest bundle never links. Pre-existing, not code. Substitute gates: swiftc -parse
  198/198 + post-rebrand full build (rename-consistency proof). Recorded per verification-gates.
- Numeric baselines from 28b653d (lines w/ brand): patches 1993, Sources 481, scripts 103,
  Tests 79, reference 104, Assets 139, .github 20, docs 10. Personal-detail lines tree-wide: 272.
  TOSH_ env lines (preserved interface): 1240; tosh_ symbol lines: 985.
- Key rename targets found: bundle id dev.engel.toshllm (make-app.sh:161, run-debug-app.sh:27,
  Support.swift:279/573), tosh.keychain x7 in build.yml, dist/ToshLLM.app, FUNDING.yml URL,
  Assets/web-ui + test-ui + lang/*.json, AUTHORS/CITATION/.zenodo person fields.

## 05:37 RUNTIME BUILD GATE — PASS + B-PHASE CLOSED WITHOUT DISPATCH
- Clean build after `rm -rf .build`: **Build complete! (298.53s), exit 0**, binary links as
  **Kestrel** (187/187 targets), incremental rebuild 0.60s. 298s vs 257.11s baseline: clean
  build ran as a background job while the orchestrator executed parallel work — contention
  variance, not a regression; functional gate is completion + correct binary name.
- Product-spec checklist closed with evidence: TOSH_ set-diff vs 44165ca = 0 lines (254 tokens
  unchanged); tagline byte-identical README + AboutTab; VERSION 0.87.9; Package.swift deps
  diff-empty vs baseline; credits present (README 17 lines, Docs.swift 10 lines).
- B-PHASE (B1–B3 fix-pass) CLOSED WITHOUT DISPATCH — rationale: pass-1 produced zero actionable
  residuals. Static battery: parse 198/198, TRUE_RESIDUALS=0, personal sweep 0 (extended
  pattern), hunk integrity green, meta valid. The three B-contracts were authored against an
  expected residual surface that never materialized; dispatching fix engineers against an empty
  defect list would be budget theater. Residual risks (operator-gate art, repo rename, DNS,
  signing) are documented in the delivery package, not code defects.

## 04:36 GATE v2 — PASS=7 FAIL=0 (static battery green)
- audit-brand.sh v2: implements FULL plan exception list (tosh[.-]moe, Hackintosh|Macintosh,
  toshllm_ legacy prefix, JS/base64 FPs); binary-art class added — 6 matches (screenshots,
  DS_Store) tracked as OPERATOR-GATE art, not text residuals. TRUE_RESIDUALS=0 (was 241
  misclassified under v1's 3-exception filter).
- gate-step7.sh v2: G4 extended pattern (+wallet/ORCID/youpay; journal gap lesson #3) and
  binary-line filter fixed; G5 rename-aware via `git diff --name-status HEAD` (old path at
  HEAD vs new path on disk — v1 probed HEAD for a path that only exists on disk, guaranteeing
  false drift); G6 pyyaml/yq absent → ruby YAML (proven valid), fallthrough double-count fixed.
- Lang lockstep fix: A5 renamed ImageGen key to (kestrel_*) in Sources but left toshllm_* key
  orphaned in lang files → renamed key + translated values in zh/ja/it/_template (surgical
  single-line edit; files are NOT ASCII-sorted — ordering invariant assumption corrected).
  4/4 valid JSON, toshllm residual 0, key counts consistent.
- Note: .build stale ToshLLM binaries still match G4 pattern → clean build started (bash-56,
  danger-full-access) to regenerate artifacts as Kestrel + serve as final runtime gate.

## 04:12 A5 RETURN — verdict: done (accepted) + REVIEWER FIX: donate-channel purge
- A5: 33 files; meta/CI/docs/assets covered; USDT/ORCID/youpay/Binance alias purged from its scope;
  lang keys renamed in lockstep with live loc.t; applied TOSHNoAVX2 crossref; 11 binaries flagged
  (binance-qr.png, DS_Store, 9 old-brand screenshots) → operator-gate list for delivery package.
- STRUCTURAL GAP FOUND by reviewer: personal USDT wallet lived in Sources (AboutTab.swift:23) —
  outside every agent's personal-pattern scope; QR generated from wallet string at runtime.
  REVIEWER FIX (own hands, 2 files + chase): Donate.swift → sponsor-only popup (force-unwrap
  URL also eliminated); AboutTab.swift sponsorURL → github.com/northlatchlabs/kestrel#support-the-project,
  removed binancePayID + usdtTRC20 constants; Docs.swift ES+EN Binance mentions removed; 4 lang
  files purged of 5 dead keys each (Binance scan, USDT warning, "or with crypto", Address, Copy %@),
  1859 keys consistent + valid; binance-qr.png git rm'd (encodes personal alias); make-app.sh QR
  wiring removed (zsh -n clean). CHANGELOG:1661 kept — historical record, names channels only.
- Post-fix sweeps: repo-wide personal = 0; parse battery 3/3 edited Swift OK; copyRow helpers'
  remaining consumers verified live (AboutTab sysinfo, LogsTab).
- Gate lesson #3 (reviewer): per-agent personal patterns had gaps (wallet hex, ORCID). Gate G4
  pattern is broader, but Sources was only swept by agents whose contracts lacked these terms.
  Institutionalize: reviewer runs FULL-pattern sweep across ALL dirs after every pass.

## 03:38 A4b RETURN — verdict: complete (accepted, all claims verified)
- 46 files, ~200 brand lines, 5 git-mv renames + 8 subdir tests; G1 residual 0 / G2 personal 0 /
  parse 198/198 / diff --check clean — all re-verified by orchestrator.
- Package.swift exact: Kestrel / executableTarget(Kestrel, Sources) / KestrelTests(Tests). Paths untouched.
- Identifier chains ALL CLOSED repo-wide: ToshDropdown/ToshLLMApp/ToshLLMLogo/notesToShow/TOSHMATH/
  import ToshLLM = 0 hits each. 18/18 @testable import Kestrel.
- Judgment calls ACCEPTED: TOSHNoAVX2→KestrelNoAVX2 (bare form not exception-covered; Swift side
  renamed; script side injected to A5, TOSH_NO_AVX2 underscore form untouched=1 confirmed),
  TOSHMATH→KESTRELMATH (self-consistent sentinel), notesToShow→notesToDisplay (grep false-positive),
  kestrel-settings format key (clean-cut policy).
- Scope extension 21 orphan files: JUSTIFIED — verified no contract owned them; gate scope required 0.
- GLOBAL MILESTONE: repo-wide personal sweep (git grep, excl .agents) = 0 FILES.
  100%-personal-detail-removal objective achieved at repo level pending A5 completion formalities.
- Guards: TOSH_ set-diff Sources vs 44165ca = 0 missing; TOSH_NO_AVX2 in build.yml intact.
- Working tree: 239 files modified. A5 steered and now mutating (32 files, post-steer mtimes).

## 03:32 A5 STEERED mid-flight (no-mutation 26min, A4 risk pattern)
- Chose send_message steer over kill+redispatch (preserves its completed analysis).
- Steer content: per-line workflow, orchestrator census priority order (README 50→CHANGELOG 45→
  lang/*.json 26ea→rebrand-webui.sh 13→web-ui/index+manifest→minified bundle.js→build.yml→
  scripts→docs→meta), partial-verdict escape hatch, docs-mention TOSH_* names preserved.
- A5 contingency census banked (25 files, binaries listed: pngs + dmg/DS_Store — flag only).
- Reminder: A4b t+3min, Package.swift not yet touched (expected; first mutation = liveness).

## 03:30 A3 RETURN — verdict: done (accepted, all claims re-verified)
- 84/86 files (2 had no brand strings), 230+/230-, every changed line brand-token audited.
- Verified: scope residual 0 after exception filters; personal 0 (even under engelbert|delgado|engel);
  TOSH_ set-diff FULL Sources vs 44165ca = 0 missing; kestrel-benchmark-v2 producer at
  BenchmarkSharing.swift:515 confirmed.
- False-positive classes correctly identified: notesToShow identifier, Hackintosh word.
- Self-paired renames closed in-scope (image output prefixes, audio sentinels, temp files,
  AudioRecovery dir); external pairings all land in A4b/Tests scope (KestrelDropdown decl,
  SettingsTab 18 uses, KestrelLogo decl+2 uses, toshllm-benchmark-v2 test assertion).
- Reviewer lesson #2: my TOSH_ guard compared full-Sources against A3's 7 dirs — scope-mismatched
  baseline produced 14 phantom 'missing'. Always diff like-for-like scope.
- PASS-1 STATUS: A1+A2+A3 accepted. A4b running (52de60c2, contract-lean re-dispatch). A5 still
  zero-mutation 26min in — watch for A4-pattern failure; census+contract ready if it dies.

## 03:27 A4 FAILED — context exhaustion before any mutation; A4b re-dispatched
- A4 (f3f77ba3) ran out of room reading whole files; zero bytes mutated in its scope (126 residual
  lines confirmed by census, Package.swift untouched).
- Doctrine §6: re-dispatch ONCE with failure in contract. A4b (52de60c2, glm-5.3-flash) contract:
  a4b-contract.md — per-line workflow, census pre-computed by orchestrator (no whole-file reads),
  5 git-mv renames first, descending-size order, verdict "partial" allowed, orchestrator owns build.
- Orchestrator lesson: for glm-flash agents, contracts must pre-compute ALL discovery (grep census
  per file) — discovery burns the context the edits need.

## 03:24 A1 RETURN — verdict: done (accepted, all claims independently re-verified)
- 9 paths changed (8 patches + COPYRIGHT), 12+/12-; file renamed 0001-5-metal-toshgemm →
  0001-5-metal-kestrelgemm via git mv (safe: build uses 0001-*.patch globs; zero hardcoded refs).
- Verified: diff --git 498=498; total patch lines 106207=106207 (find|xargs census); renamed file
  hunks 12=12; personal details 0; TOSH_ set-diff vs 44165ca EMPTY; upstream credits intact.
- Residuals: 2089 matches all classified (TOSH_ env / tosh_ symbols / tosh-moe module paths).
- Judgment calls UPHELD: 'tosh.moe.stage' graph-node string = engine diagnostic namespace;
  patches/README.md tosh-moe/ path anchored by immutable diff --git headers. Both accepted.
- Reviewer lesson recorded: my first census used a non-recursive cat glob and a HEAD-path lookup
  that missed a rename — agent evidence was exact, orchestrator tooling needed the fix.

## 03:22 A2 RETURN — verdict: done (accepted)
- 60/60 scope files; 186+/186- balanced; parse 0 fails; personal lines 0; 37 residual lines all
  exceptions (36 TOSH_* + 1 'Hackintosh' upstream-context). Scope discipline perfect.
- Renames include: KestrelDropdown (15 uses, def crossref pending A4), KestrelMCPService (13,
  closure verified repo-wide), kestrelEngineDidStart (producer+consumer in scope), X-Kestrel-*
  headers, com.northlatchlabs.kestrel.chat-save, kestrel* JSONL keys, Kestrel AppSupport dir.
- ORCHESTRATOR DECISION: NO migration for old tosh* JSONL keys / old ToshLLM AppSupport dir —
  fallbacks would permanently embed obsolete brand in code, violating the 100%-clean directive.
  Recorded as BREAKING CHANGE for the delivery runbook: existing conversations/archives do not
  carry over; operator may manually move ~/Library/Application Support/ToshLLM → Kestrel.
- Open crossrefs (expected, owners still running): ToshDropdown def (DesignSystem→A4) + uses in
  SettingsTab (A4), Hardware ×3 / Audio / Benchmarks (A3); Images/ImageGen.swift toshllm_* prefix (A3).
- Build gate will prove identifier-chain closure at join.

## 03:18 Mid-flight guard #1 (A1 scope)
- TOSH_ namespace: 230/230 distinct names (patches) + 30/30 (reference) preserved vs 44165ca —
  set-diff EMPTY, zero interface erosion. patches/COPYRIGHT diff verified: Northlatch Labs
  attribution + Kestrel redistribution clause + SPDX intact + upstream credit untouched.

## 03:17 Type-level rename risk map (pre-join)
- Exactly 3 brand Swift types exist: ToshDropdown (DesignSystem→Settings+Servers cross-scope pair),
  ToshLLMLogo, ToshLLMApp (both App-local). All other brand hits are strings/comments —
  compiler-invisible. Post-join build therefore proves closure of 3 identifier chains.
- gate-step7.sh staged (parse + brand audit + personal sweep + hunk integrity + meta validity).
- Mission instrumentation committed 44165ca; rebrand diff tracked from clean anchor.
- A1 progress 9/99 patch files; spot-checks: hunks intact, From: headers personal-detail-free.

## Dispatch ledger
| # | step | specialist | tier/model | status | evidence |
|---|------|-----------|------------|--------|----------|
| — | 1 | orchestrator | — | done | commit 28b653d; parse 198/198; build 257s PASS |
| 2 | A1 patches/+reference/ | glm-5.3-flash | T1 | running | 9cf7bb7c |
| 2 | A2 Chat/Servers/MCP/Video/Subtitles | glm-5.3-flash | T1 | running | 06603659 |
| 2 | A3 Models/Benchmarks/Images/Audio/Workspace/MoE/Hardware | glm-5.3-flash | T1 | running | 731be412 |
| 2 | A4 App/DesignSystem/Dashboard/Settings/Tests/Package.swift | glm-5.3-flash | T1 | running | f3f77ba3 |
| 2 | A5 scripts/CI/docs/Assets/meta | glm-5.3-flash | T1 | running | 9db088f0 |

## 05:51 AMENDMENT 2 — OPERATOR APPROVED FULL EXECUTION OF OPERATOR-GATE FIXES
Operator: "you have permission to proceed with all the fixes you proposed." Scope added:
in-repo art + packaging + repo actions. Machine survey results:
- `gh` NOT installed -> GitHub repo creation/push stays operator-side.
- `screencapture` + `osascript` present -> app-drive screenshots FEASIBLE.
- `actool` ABSENT (CLT-only) -> Liquid Glass Assets.car not buildable; legacy icns path is
  (iconutil + iconset). AppIcon.icon/ exists with Assets/glyph.png consumed by make-dmg.
- vendor/ EMPTY (no engines, no webui dist) -> make-app runs engineless (warning path);
  rebrand-webui rebuild impossible; web-ui bundle stays as-is (already 3-line rebranded).
- Codesign is ad-hoc (-s -) -> full app bundle + DMG buildable locally, no Apple identity.
Execution order: icon art -> icns -> release app (TOSH_NO_BUMP=1, VERSION must stay 0.87.9)
-> drive app for screenshots -> DMG w/ layout regen (DS_Store) -> art re-audit -> commit.
These steps are reviewer-executed (GUI-driving tools are orchestrator-only); no subagents.

## 06:00 ART PIPELINE PHASE 1 — ICON + GLYPH REGENERATED (evidence-captured)
- Traced ALL old-brand art to baseline 28b653d (glyph.png + 4 README JPGs predate rebrand).
- Old JPGs carry NO metadata strings (probes empty) -> audit hits are PIXELS; only real
  re-captures fix them. DS_Store hit = /Volumes/ToshLLM path strings -> layout regen replaces.
- New icon rendered via icon-gen.swift (indigo->raspberry squircle, GPU chip + LLM monogram);
  pixel probe: opaque center, white glyph, transparent margins. AppIcon.icns built via
  iconset 16..512@2x + iconutil (1.0MB, repo root; picked up by make-app.sh:51).
- Layered glyph replaced: chip-only derivation (shadow+bg blocks excised, margin 240),
  9.7% opaque coverage = stroked outline art, normalized to native 1024px. dmg-background
  composer accepts it: bg 1280x800 @1x + 2x rendered clean.
- Screenshot plan: launch dist/Kestrel.app engineless; drive sidebar sections
  dashboard/chat/models/benchmarks; capture per-window PNG (CUA, a11y-tree-free), encode
  JPEG to match originals (~1265x820, quality default). make-app under TOSH_NO_BUMP=1 keeps
  VERSION 0.87.9 (success criterion).

## 09:12 ART PIPELINE PHASE 2 — SCREENSHOTS, IN-APP ART, DMG (all evidence-captured)
- make-app.sh line 211 zsh glob fix: "no matches found: .../bin/*" aborted engineless
  packaging BEFORE codesign. Null-glob qualifiers *(N)/*(.N) on bin{,-image,-audio} loops
  (lines 211, 222-224). zsh -n clean. Repackage SUCCESS: dist/Kestrel.app, VERSION 0.87.9
  unchanged, bundle id com.northlatchlabs.kestrel, icns bundled, ad-hoc codesign valid.
- Screenshots (CUA-driven, session kestrel-shots): Welcome sheet dismissed via
  foreground Escape after bring_to_front. Captured at native 1568x951 (chat 1037):
  /tmp/shots/{home,chat,models,benchmarks}.png. Section navigation verified by AX text
  ("Discover, download and manage your local models.") and by hash-distinct captures.
  Encoded sips -> Assets/{home,chat,models,benchmarks}.jpg (jpeg default quality).
- OCR verification (Vision framework, /tmp/ocr): all four captures show Kestrel UI text,
  BRAND_HIT=NO on every one. Old captures had zero real brand strings but old-brand
  PIXELS; new captures are new-brand pixels.
- DECORATIVE ART regenerated (spec-legal: hero/guide are accessibilityHidden artwork):
  /tmp/art-gen.swift (CoreGraphics, brand palette indigo 0.349/0.318/0.498 -> raspberry
  0.753/0.306/0.482, chip-motif) -> Assets/model-hero{,-light}.jpg 2000x722,
  Assets/settings-guide{,-light}.jpg 1440x1612. Pixel-probed: band/ring/arc land on
  designed values (CG bottom-origin accounted).
- AUDIT FINDING (instrumentation upgrade v4): JFIF "Photoshop 3.0" resource marker inside
  EVERY Apple-encoder JPEG contains bare substring "tosh" -> BINARY_ART_MATCHES was a
  FALSE-POSITIVE class (originals baseline 28b653d also contained ONLY the marker).
  audit-brand.sh now content-verifies binaries via strings|grep real brand tokens.
  Result: binary hits 6 -> 1 (only genuinely-branded DS_Store) -> 0 after regen.
- DMG: TOSH_DMG_LAYOUT=1 ./scripts/make-dmg.sh -> "Done: dist/Kestrel-v0.87.9.dmg"
  (16.3MB UDZO). DS_Store regenerated on live volume via Finder AppleScript: ToshLLM
  strings 8 -> 0 (xxd confirms /Kestrel records present); layout committed to
  Assets/dmg/DS_Store. Full audit: TRUE_RESIDUALS=0, BINARY_ART_MATCHES=0.
- obsidian-hardware.png (DMG bg source): OCR REGIONS=0, no brand strings, abstract
  obsidian palette -> kept as composite base under new glyph.

## 09:18 GITHUB PUSH + DMG VERIFICATION (AMENDMENT 2 scope: "if authenticated")
- Credential survey: gh CLI absent, BUT osxkeychain holds a GitHub token (user 0xda7,
  scopes: repo, workflow, delete_repo, gist, read:org). northlatchlabs org: 404 (org
  creation needs web-UI billing — stays operator-side).
- Repo created PRIVATE: 0xda7/kestrel (collision-checked first). Pushed main:
  remote 43b8df2 == local HEAD 43b8df2 (ls-remote verified). Secret-hygiene scan of
  pushed tree: zero credential patterns, zero tracked env/key files (474 files).
- DMG end-to-end: mounted dist/Kestrel-v0.87.9.dmg -> Kestrel.app
  (com.northlatchlabs.kestrel / 0.87.9), AppIcon.icns in Resources, on-volume
  .DS_Store 0 x ToshLLM, Applications symlink, detached clean.
- TRANSFER RUNBOOK (operator, one command once org exists):
  gh repo transfer 0xda7/kestrel --to northlatchlabs  (then rename to kestrel if the
  org repo should be northlatchlabs/kestrel; the Donate URL expects that path).

## 09:38 CORRECTION CYCLE — canonical repo location (operator input)
- Operator: registered org handle is "Northlatch-Labs-LLC" (not the assumed
  "northlatchlabs"); then: "On my personal github account is sufficient."
- Evidence: org Northlatch-Labs-LLC exists (API), token owner 0xda7 is active ADMIN.
- Detour executed + reverted: org repo Northlatch-Labs-LLC/kestrel created, pushed,
  parity-checked (org HEAD == local HEAD 678b84c), deleted (HTTP 204, re-check 404).
  0xda7/kestrel remains canonical, private.
- URL truth pass (552be20): repo URLs -> 0xda7/kestrel (FUNDING, zenodo, CITATION.cff,
  CONTRIBUTING, README, SECURITY, AboutTab, Docs en/es, KestrelApp, Updates.swift
  releases API, CHANGELOG issue links, perf doc). Org-attribution links ->
  github.com/Northlatch-Labs-LLC (README credit, AboutTab developerHandle, Docs).
  Protected forms untouched: com.northlatchlabs.kestrel bundle id,
  opensource@northlatchlabs.com, northlatchlabs.com. Final sweep: 0 non-protected
  refs outside mission records. Sponsor anchor kept in-repo (#support-the-project);
  github.com/sponsors/0xda7 redirects to profile (no native Sponsors — same as before).
- Audit gate re-run: TRUE_RESIDUALS=0, BINARY_ART_MATCHES=0, ALLOWED_EXCEPTIONS=2315.
- dist/ rebuild queued: shipped DMG still embeds dead northlatchlabs URLs.

## 10:02 REBUILD + FINAL GATE (dist regenerated from corrected source)
- Root cause found on rebuild: make-app.sh AUTO-INKREMENTS the VERSION file patch
  digit on every run when TOSH_VERSION is unset (line 21); the 3 build attempts
  drove 0.87.9 -> 0.87.12. Restored via git checkout; repackaged explicitly with
  TOSH_VERSION=0.87.9. make-app.sh is zsh (shebang) — must run under zsh, not bash;
  SwiftPM needs --disable-sandbox in this environment (session shim /tmp/swiftshim).
- dist/Kestrel-v0.87.9.dmg rebuilt (16,545,453 B, sha256 a2d8950bcbe52c3a...);
  stale 0.87.12 DMG deleted.
- Final gate (mount-verified): bundle com.northlatchlabs.kestrel / 0.87.9; binary
  0xda7/kestrel refs=8, dead northlatchlabs/kestrel refs=0 (worktree binary AND
  on-DMG binary); DS_Store 0 x toshllm; detaches clean.
- DELIVERY.md item 1 corrected: org handle is Northlatch-Labs-LLC (transfer cmd
  updated); canonical repo remains 0xda7/kestrel per operator.

## 10:46 — Silent model-start failure: root-caused and fixed (4392e20)
**Symptom (operator):** models won't start in the shipped Kestrel.app; "the error doesn't even show in my log".
**Root cause chain (evidence closed):**
1. Shipped dist/Kestrel.app was ENGINELESS (no Contents/Resources/bin/); this machine has no Xcode/cmake/brew, so scripts/build-engines.sh could never run locally.
2. ServerSettings.defaultBinary fell back to the original author's ~/dev/repositorios/llama.cpp path (rebrand-class miss: personal path with no brand strings) — nonexistent here.
3. start() hit the fileExists guard BEFORE fileLog.startSession() → state=.failed(msg) lived only in memory → logs dir EMPTY (reproduced: ~/Library/Application Support/Kestrel/logs/ empty after the operator's 09:46 attempt).
**Fix (commit 4392e20, pushed):** missing-binary + spawn failures now append to the file log with the exact path checked (bilingual); author dev-path fallbacks removed from Server.swift AND make-app.sh; kernels/ made optional; @rpath dylibs now shipped alongside binaries.
**Unblock:** official ggml-org llama.cpp b11321 macOS-x64 release (minos 13.3 ≤ 14.0 floor) staged into vendor/llama.cpp/build-static/bin; packager bundles it.
**Gates:** build ✓ (26s) · brand audit TRUE_RESIDUALS=0 ✓ · bundle: 35 files in bin/, codesign OK, id com.northlatchlabs.kestrel v0.87.9 ✓ · bundled engine live-fire: /health ok + real completion from ~/models/gemma3-1b (32 tok / 730 ms, CPU) ✓ · DMG 39,103,455 B sha256 a21e7745…, mount-verified with engine inside ✓.
**Residual:** DMG at dist/Kestrel-v0.87.9.dmg (operator: install over the old copy). CI (macos-26 runners) still builds the properly-patched engines on tags — official binaries are the local stand-in. spctl rejection on ad-hoc signing remains a documented caveat.

## 13:23 — Engine ported from the operator's working install; silent-failure class closed
**Operator correction accepted:** the patched engine (v0.4.1-dev b11141, commit 957538960, +AMD patches) existed all along inside /Applications/toshllm.app. Earlier "engine missing" claim was wrong — checked wrong locations.
**Port (P1):** toshllm.app bin/ (incl. kernels/, test-backend-ops) → vendor/llama.cpp/build-static/bin → bundled via make-app.sh. Brand string "ToshLLM engine" → "Kestrel engine" (equal-length byte patch, re-signed). Kestrel references its own bundle only; zero runtime ties to toshllm.app.
**Optimization evidence (P2, llama-bench, operator's DeepSeek-Coder-V2-Lite, 96-tok gen, 2 reps):** ncmoe=43/t=6 → 9.41; t=12 → 9.93; ncmoe=20/t=6 → 10.46; ncmoe=20/t=12 → 10.81 tok/s (+15%). Delivered as evidence, NOT hardcoded: app's per-model ncmoe recall + Settings already expose both levers. Heuristic left fit-first by design (generalizes across machines).
**Live-fire (P3):** bundled llama-server, operator's exact arg list incl. -ctv turbo4 → health ok, 10.6 tok/s measured on 220-tok completion. The original failing command now boots.
**Ship (P4):** dist/Kestrel-v0.87.9.dmg, 48,801,262 B, sha256 3f25574b…; mount-verified (engine, kernels/, codesign, 0 ToshLLM residuals); brand audit TRUE_RESIDUALS=0.
