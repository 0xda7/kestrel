# Engines re-authoring plan — the full push (step 7)

Companion to `.agents/missions/2026-10-10-engine-upgrade/` (which found the frontier);
this is the executable map for the push the operator scoped on 2026-10-12.
Frontier refreshed against upstream master `cbe28bb3c` (2026-10-12, this session):
**40 of 92 patches apply cleanly, 52 fail, 124 hunks rejected** (report:
`frontier-cbe28bb3c.md`). Two days earlier at `aa94f2086` it was 43/49/121 —
the series is drifting backwards ~3 patches/day while unpinned.

## The structural fact that orders everything

Upstream's Metal backend now lives in the split layout (`ggml/src/ggml-metal/
{context,device,ops,common}` + `kernels/*.metal` + per-dtype FA libraries).
Kestrel's series still targets the monolithic `ggml-metal.metal` shape for its
kernel additions. Every Metal patch therefore fails for the SAME root cause
(file layout), and whisper.cpp v1.9.5 + sd.cpp master crossed the same split —
one port of the shared backend fixes three engines and collapses
`shared-metal/` into the llama series (already noted in
`scripts/build-engines.sh:15-16`).

**Order of work is therefore: Group A first; most of B becomes mechanical
after it.** Chasing hunks against the old layout is re-authoring twice.

## Groups (execute in order; each is one or more sessions with its own gate)

### Group A — the layout port (the keystone)
Re-author the base + file-creating patches against the split tree:
`0001` (kernels), `0002` (backend host), `0033`, `0038`, `0042` (new kernel
files + CMake), plus `0047` (the previous port-adapt patch, which becomes the
template for this one). Upstream changes to absorb: graph-capture rework
(`84e76d8a2`), FA per-dtype libraries (`5a75f14c0`), few-row MMA (`a3a1c4747`),
128/96 FA kernels (`1f8fa5231`).
**Gate:** `check-patch-series.sh` shows Group-A patches clean at the new pin;
`build-engines.sh` builds; `llama-bench` pp512/tg128 within ±2% of the
cdc06426e baseline on the 5500M (method: `.agents/missions/2026-10-10-engine-upgrade/baseline-llama-bench.txt`).
**Effort:** the largest single group; budget a full session.

### Group B — the one-hunk Metal family (mechanical after A)
`0018 0019 0021 0022 0024 0026 0030 0039 0041 0048 0054 0055 0056 0058…`
(one rejected hunk each in `ggml-metal-device.m` / `-context.m` / `-ops.cpp`).
After Group A these are relocations to the new files, not rewrites.
**Gate:** series check + build + bench per landing.

### Group C — llama-side refactors
`0005` (15 hunks: batch_ext migration across context/graph/model-loader),
`0010 0012 0014 0015` (context/model one-hunkers riding the same refactor).
Absorb: `llama_batch_ext` migration, graph-capture, `llama-graph` splits.
**Gate:** build + `swift test` (server/model tests) + smoke chat.

### Group D — the semantic decision: Kestrel MoE cache vs upstream's
`0003 0023 0025` (Kestrel's expert cache) vs upstream's own
MoE-cache-over-multi-GPU (#30112) and GPU-side expert cache (#29887).
This is not hunk repair: decide per mechanism whether upstream's version now
covers Kestrel's (drop the patch) or Kestrel's hot-map/ring still wins on
RDNA2 (keep, re-author against the new structures). Record the decision and
its benchmark basis in the CHANGELOG entry that lands it.
**Gate:** `scripts/test-spec-decode.sh` + MoE bench rows (README table)
no-regression; decision note in `patches/README.md`.

### Group E — whisper + sd.cpp collapse
After Group A: port `shared-metal/` into the llama series once; bump whisper
to ≥v1.9.5 and sd.cpp toward master (frontier notes in
`.agents/missions/2026-10-10-engine-upgrade/journal.md` 2026-10-10 10:35/10:45).
**Gate:** engine rebuild clean + transcription/image smoke + advisory-triage
note per `patches/README.md` § Advisory triage.

## Working rules (from the 2026-10-10 mission, still binding)

- `git apply` plain is the build's own bar; three-way is for judging only.
- Never regenerate the series with `git diff` defaults of ±3; match the
  existing convention (see `patches/README.md`).
- One patch per change, numbered in apply order; verify the round trip
  (worktree at pin → apply all → diff against live tree) before moving a pin.
- Each pin bump lands with its bench comparison and advisory triage note.
- CI (`bump-engines.yml`) smoke-tests real inference before any PR merges.

## Where to start (session 5)

Group A, patch `0047`-style: create the new port-adapt patch against
`cbe28bb3c`'s split tree; `0001`+`0002` re-authored on top of it. The 2026-10-10
mission's strict-apply-check bisect harness (`strict-apply-check.sh`) is the
tool for finding the exact landing points.
