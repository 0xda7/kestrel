# Wave-2 Plan — Development Propositions Delivered End to End

Mission: turn the three confirmed propositions into shipped, working product.

## Objective (operator's words honored)
"Development proposition confirmed, deliver end to end" — no demos, no slices: each
proposition lands as working product behind the app's own architecture.

## Scope
1. **In-app per-model speed benchmark** — a Benchmark button in the model UI runs
   llama-bench (ships in bundle) on the selected model, stores results per model
   (UserDefaults, keyed by model path + config), shows tok/s. No hardcoded models/paths.
2. **Measured-config pre-fill** — when the user picks a model, if a benchmark exists for
   it on this machine, prefill ncmoe/threads from the best *measured* config; otherwise
   fall back to the existing fit heuristic. New Settings keys; recall pattern mirrors
   existing `recalledNcmoe`.
3. **CI tag-release** — extend `.github/workflows/build.yml` with a `tag` trigger: on
   `v*` tag, build fresh engines from `LLAMA_COMMIT` + patches, byte-patch
   `ToshLLM engine`→`Kestrel engine`, build app+DMG, attach to GitHub Release.
   Operator owns repo secrets/visibility; workflow is committed code.

## Out of scope (stated, not drifted)
- Apple notarization (needs operator Apple Developer account).
- Heuristic rewrite for other machines' hardware (data doesn't exist yet).

## Steps, owners, gates
| # | Step | Owner | Deliverable | Gate | Risk/rollback |
|---|------|-------|-------------|------|---------------|
| 1 | Scout: CI workflow, build-engines.sh, UI seams (Components.swift 85, Hardware.swift 246), where model list lives | scout | seam map w/ line numbers | file:line evidence | none (read-only) |
| 2 | Implement benchmark engine-call + storage + UI button | implementer | Swift code | swift build clean | revert commit |
| 3 | Implement measured pre-fill (recall + precedence + Settings keys) | implementer | Swift code | swift build clean | revert commit |
| 4 | CI `tag` trigger job: engines→patch→app→DMG→release artifact | implementer | workflow yaml | actionlint/yamllint or parsed by gh | revert commit |
| 5 | Local rebuild v0.88.0 + live-fire (bundled server, user model, exact args) | implementer | dist/Kestrel-v0.88.0.dmg | health ok + tok/s captured + audit TRUE_RESIDUALS=0 | keep v0.87.9 DMG |
| 6 | Commit, push, tag v0.88.0, monitor CI | implementer | tag pushed, CI run logged | green run or documented blocker | tag delete + retag |
| 7 | Journal + delivery package | lead | journal entry, runbook | evidence links | none |

## Budget
Steps 7, wall-clock ≤ 3 h, CI wait ≤ 40 min. 2x overage → stop and report.

## Acceptance (done means)
- Benchmark button works on operator's machine against their model with captured output.
- Pre-fill changes only when measurement exists; heuristic untouched otherwise.
- CI workflow parses and is committed; first real green run logged (or blocker named).
- New DMG installs; brand audit 0 residuals; tree clean; pushed.
