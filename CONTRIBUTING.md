# Contributing to Kestrel

Thanks for your interest! Contributions are welcome under the project's
[GPL-3.0 license](LICENSE) — by submitting a pull request you agree that your
contribution is licensed under the same terms.

## Getting started

```bash
git clone https://github.com/0xda7/kestrel
cd kestrel
./scripts/build-engines.sh   # one-time: builds the patched llama.cpp engines
./make-app.sh                # builds and packages dist/Kestrel.app
open dist/Kestrel.app
swift test                   # unit tests (needs full Xcode, see below)
```

Requirements: macOS 14+, Xcode Command Line Tools, CMake. No Xcode project —
the app is plain Swift Package Manager (`swift build`). **Running the unit
tests (`swift test`) additionally requires a full Xcode install**, because
XCTest ships only with Xcode, never with Command Line Tools.

> **Note on tests:** installing Xcode is not enough if your active developer
> directory still points at the Command Line Tools — `swift test` then fails
> with `no such module 'XCTest'`. Switch once with
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, or scope
> it to a single command with
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
> Or just rely on CI, which runs the suite on every push and pull request.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/` | SwiftUI app (one file per concern: Server, Models, Chat, Benchmark…) |
| `Assets/` | App icon source, web chat UI, donation QR |
| `patches/` | AMD Metal patches applied on top of upstream llama.cpp |
| `scripts/` | Reproducible engine build + DMG packaging |
| `.github/workflows/` | CI: build on push, DMG release on tags |

## Guidelines

- **Target hardware is Intel Mac + AMD dGPU.** Test changes against a real
  Metal AMD setup when they touch the engine, server flags or memory logic.
- **English is the product language** (operator directive 2026-10-14):
  every user-facing string goes through `loc.t("es", "en")` and the English
  half is what ships — the Spanish halves remain in the call sites for
  bilingual engine diagnostics. Every new setting needs a tooltip
  (`.help` / `.infoTip`).
- **No new dependencies** without prior discussion — the app is intentionally
  dependency-free (SwiftPM with zero external packages).
- Keep the memory **estimator honest**: if you change `Estimator`, include the
  measurements that justify the new formula in the PR description.
- Engine changes go in `patches/` as diffs against the pinned llama.cpp commit
  (see `scripts/build-engines.sh`), never as vendored sources.

## Translations

English is the product language. The community overlay pipeline (JSON
per-language overlays, the auto-sync pre-commit hook and the translations CI)
was retired with the English-only directive — nothing in the shipped product
loads overlay files anymore. Call sites keep the `loc.t("es", "en")` shape so
a future picker can be wired back without touching every string; bring the
pipeline back from git history if that ever happens.

## Reporting issues

Include: macOS version, GPU model and VRAM, RAM, the model + quant you ran,
your Settings (a screenshot works), and the server log (Settings → Server log).
