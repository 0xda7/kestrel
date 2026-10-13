# Engines frontier — session 6 evidence (2026-10-13)

The four re-authored patches in this folder take the series STRICT-CLEAN (all
92, plain `git apply`) at `ed319febb` — five commits past the shipped pin
`cdc06426e`, through the graph-capture wall `84e76d8a2` (#29390). They live in
`git stash` ("engines-frontier-ed319febb re-authored patches") and here as
artifacts. The working tree and the local engine are RESTORED to the shipped
pin; main is untouched by this work.

## What was re-authored (and why each wall existed)

- `0002`: hunk 7's trailing context crossed 84e76d8a2's new `n_nodes == 0`
  early-return inside `ggml_metal_graph_compute`. The hunk interleaves
  CONTEXT lines (the function header) between insertion blocks — the splice
  must reproduce [insert 675 lines][header][hold_flush][has_error][n_nodes
  NEW][dispatch 53 lines] in the series' original order (hold_flush BEFORE
  has_error: every downstream patch 0060+ expects that order).
- `0039`: hunk 9's context contained `ctx->capture_compute,` — 84e76d8a2
  changed the argument to `ctx->capture_compute == 0`.
- `0063`: hunk 23 replaced `hold_flush` with the merge-graph conditional; a
  single blank line of context drift.
- `0085`: hunk with the `getenv`→`KESTREL_ENV` swap in the MoE dispatch, whose
  context crossed the (new) n_nodes block. Regenerated CLEANLY from the
  pristine original over a 1-80 baseline — an earlier regeneration built over
  a contaminated tree duplicated `ggml_metal_library_get_pipeline_bin_one_src1`
  (0073's function) and was discarded. LESSON: always regenerate from
  committed-baseline worktrees, never from drifted ones.
- `0090/0092/0097` needed NO re-authoring once the chain was clean.

## The bench verdict (why the pin did NOT move)

Spark-X2.5-1.7B-Q8_0, RX 5500M, `-ngl 99 -p 512 -n 128 -r 5`:

| tree | pp512 | tg128 |
|---|---:|---:|
| cdc06426e + original series (restored, this session) | — | **57.59 ± 0.78** |
| 84e76d8a2 + re-authored series | 798.56 ± 19.45 | **24.58 ± 7.61** |
| ed319febb + re-authored series | 991.25 ± 44.54 (r3) | **44.81 ± 2.77** |

Decode (tg) collapses while prefill (pp) largely survives, and the 84e7 point
is wildly unstable — the signature of per-token command-buffer/hold/flush
behavior, exactly the region 84e76d8a2 (#29390 graph capture) touches and our
0002/0063 re-splices reassemble. Gate FAILED → pin stays at cdc06426e.

## Next steps (session 7)

1. Isolate: at 84e76d8a2, bench with `KESTREL_MGPU_MERGE` semantics checked —
   first suspect is the 0063 hunk (held buffers vs. capture_compute changes)
   and 0002's reassembled preamble. A 5-minute A/B: revert 0063's hunk by hand
   in the worktree, rebuild llama-bench only, re-bench.
2. If a splice is at fault, re-splice that one hunk and re-run the gate.
3. If upstream #29390 is at fault (graph capture interacting with our
   multi-command-buffer decode), evaluate reverting #29390 in a new patch
   (0000-series style) or pinning past it once fixed upstream.
4. The frontier target beyond: `5a75f14c0` (FA per-dtype libraries) breaks
   patch 0001 — the kernels/ layout port proper (plan Group A keystone).
