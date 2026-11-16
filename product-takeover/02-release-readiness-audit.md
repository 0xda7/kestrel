# 02 — Release-Readiness & Release-Pipeline Audit (subagent, 2026-11-16)

Full findings verified with file:line references. Nothing modified.

## Root causes confirmed

- **R1 (P0) — Version truth lives in 3 places.** Release commit `d6bb1e2` hand-edited
  `Sources/App/AboutTab.swift:10` to "0.90.0" but never touched the `VERSION` file
  (0.89.17 at the tag; `git show d6bb1e2:VERSION` → 0.89.17). `scripts/release.sh` was
  bypassed — the exact failure mode its own comment (release.sh:23-25) guards against.
  CI's `make-app.sh` (CI=true path, :24-26) reads VERSION verbatim → bundle plist 0.89.17
  while the About page says 0.90.0. `release.sh` now *refuses to run* (tag v0.89.17 exists).
- **R2 (P0) — Signing silently no-ops.** `build.yml:131-135` keeps an ad-hoc signature and
  exits 0 when `MACOS_CERT_P12` is absent. v0.90.0 shipped an *unsigned DMG* containing an
  ad-hoc app (empirically verified on the test box: `codesign -dv` → adhoc; `spctl` rejects).
  README:140-142's "signed and notarized since 0.86.5" is currently false.
- **R3 (P1) — No Sparkle.** Hand-rolled `UpdateChecker` (Sources/Models/Updates.swift)
  polls GitHub API and compares against the hand-edited `AppInfo.version` constant, not the
  bundle plist. Builds claiming 0.90.0 will never be offered 0.90.x fixes. Good mitigations
  exist (fail-closed checksum KES-09, team-ID check :330-337, never-leave-no-app swap).
- **R4 (P1) — Feed pinned to personal account** (`0xda7/kestrel`, Updates.swift:35/423,
  AboutTab.swift:15) while branding is northlatchlabs; update failures only log
  (Updates.swift:490-499).

## Clean-room breakers / hygiene

- make-app.sh:56-58 falls back to `$HOME/.kestrel-engines` — release can ship with
  no engines (warning only, :82).
- Hardcoded `/Applications/Xcode.app` DEVELOPER_DIR (make-app.sh:188-190; build-engines.sh:54-55).
- make-dmg.sh:60-63 detaches any volume named "Kestrel" on the build machine.
- Engine cache key (build.yml:95) misses upstream pins; keychain password literal `ci` (:137-142).
- No `.gitignore` entry for `*.dmg`/`checksums.txt` (release artifacts risk being committed).
- CITATION.cff frozen at 0.83.21/2026-08-12; SECURITY.md claims Dependabot, none configured.

## Gap register & fix order

G1 (P0, S): single-source version truth — `AppInfo.version` reads `Bundle.main`
CFBundleShortVersionString; release.sh asserts VERSION == tag; re-cut 0.90.1.
G2 (P0, S+cert): make missing signing secrets a hard tag-build failure; verify `spctl -a`
on the artifact in CI; correct README per-release.
G5/G4 (P1, S): CI asserts VERSION == tag == plist before publishing; make-app.sh fails hard
when bundled engines absent on release path.
G3 (P1, S): centralize repo slug; surface update-check failure in UI.
Quick wins (XS): G6 CITATION stamping, G7 dependabot.yml, G11 .gitignore, G12 test.sh
warning when engines missing, G8 detach by device id, G9/G10 cache/keychain hygiene.

Note: `scripts/test.sh` = `swift run --disable-sandbox kestrel-checks` — a zero-dependency
harness (Tests/Checks, Package.swift:30); no Xcode GUI needed, but engine-pinned checks
require `scripts/build-engines.sh` first on a fresh clone.
