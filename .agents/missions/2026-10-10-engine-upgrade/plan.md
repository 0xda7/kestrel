# Mission: engine upgrade + modernization (2026-10-10)

## Objective

Advance the vendored engine pins as far upstream as the patch series honestly allows,
document exactly where and why the frontier stops, and modernize the Swift app to Swift 6
strict concurrency — without shipping an unvalidated Metal backend.

## Success criteria

1. Every pin move is preceded by a strict dry-run (plain `git apply`, mirroring
   `build-engines.sh`) proving the full series lands on the new pin.
2. Rebuilt engines match or beat the pre-bump baseline on the 5500M
   (baseline: pp512 1013.30 t/s, tg128 55.15 t/s, Spark-X2.5-1.7B-Q8_0, build 957538960).
3. Generation smoke test stays coherent (temp 0, "The capital of France is" → " Paris.").
4. `make-app.sh` assembles and the CI build workflow is green.
5. Swift 6 language mode enabled; CI `swift test` green.

## Steps

- Step 0 housekeeping: commit the finished legacy→kestrel rename; remove the stale
  `~/kestrel-study` clone (v0.87.9, zero post-clone commits, moved to Trash).
- Step 1 engines: baseline bench → strict bisect of each upstream gap → pin moves →
  rebuild → 5500M validation → docs (patches/README frontier, CHANGELOG).
- Step 2 Swift 6: tools-version bump, strict concurrency waves (Task.detached,
  nonisolated(unsafe), DispatchQueue), gates.

## Bounds

- The 408-commit llama.cpp bump is out of scope this cycle: 49/92 patches fail at master
  with 121 rejected hunks and real semantic collisions (FA per-dtype libraries,
  llama_batch_ext, upstream MoE-cache-multigpu). Frontiers only; the port is a separate mission.
- No version bump, no release cut.
