## Patch series against llama.cpp `aa94f2086`

Pinned commit today: `9575389609d6f8437de0b205561a4824d217c409`.

| | Patch | Note |
|---|---|---|
| **FAILS** | `0001-metal-kernels.patch` | 1 hunk(s) rejected in mul_mm.metal  |
| **FAILS** | `0002-metal-backend-host.patch` | 7 hunk(s) rejected in CMakeLists.txt ggml-metal-context.m ggml-metal-device.h ggml-metal-device.m ggml-metal-impl.h ggml-metal-ops.cpp ggml-metal.cpp  |
| clean | `0003-moe-cache.patch` |  |
| **FAILS** | `0004-ggml-core.patch` | 13 hunk(s) rejected in CMakeLists.txt ggml-backend-impl.h ggml-backend-meta.cpp ggml-backend.cpp ggml-common.h ggml-cpu.c ggml-cpu.cpp ggml-quants.c ggml-quants.h ggml.c ggml.h ops.cpp ops.h  |
| **FAILS** | `0005-llama-core.patch` | 15 hunk(s) rejected in cohere2moe.cpp delta-net-base.cpp hy-v3.cpp llama-context.cpp llama-graph.cpp llama-graph.h llama-kv-cache.cpp llama-mmap.cpp llama-mmap.h llama-model-loader.cpp llama-model-loader.h llama-model.cpp qwen35.cpp qwen35moe.cpp step35.cpp  |
| **FAILS** | `0006-common-and-spec.patch` | 5 hunk(s) rejected in arg.cpp common.cpp common.h fit.cpp speculative.cpp  |
| **FAILS** | `0007-tools-and-build.patch` | 9 hunk(s) rejected in CMakeLists.txt build-info.cmake clip-model.h llama-bench.cpp server-chat.cpp test-backend-ops.cpp test-chat.cpp test-quantize-fns.cpp  |
| clean | `0008-metal-comm-allreduce-fail-loud.patch` |  |
| clean | `0009-metal-sync-flush-pending-waits.patch` |  |
| **FAILS** | `0010-pipeline-parallel-ignore-accel.patch` | 1 hunk(s) rejected in llama-context.cpp  |
| clean | `0011-mgpu-tensor-parallel-groups.patch` |  |
| **FAILS** | `0012-mgpu-group-events-and-pipeline.patch` | 1 hunk(s) rejected in llama-context.cpp  |
| clean | `0013-meta-direct-copies-and-read-batch.patch` |  |
| **FAILS** | `0014-tensor-split-per-group.patch` | 1 hunk(s) rejected in llama-model.h  |
| **FAILS** | `0015-pipeline-events-always.patch` | 1 hunk(s) rejected in llama-context.cpp  |
| clean | `0016-meta-gqa-attention-splits.patch` |  |
| clean | `0017-mgpu-parallel-subgraph-encode.patch` |  |
| **FAILS** | `0018-moe-cache-maps-thread-safe.patch` | 1 hunk(s) rejected in ggml-metal-ops.cpp  |
| **FAILS** | `0019-mgpu-fused-exchange-reduce.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| clean | `0020-moe-id-map-size.patch` |  |
| **FAILS** | `0021-moe-slot-stats.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| **FAILS** | `0022-moe-ring-bound-batch.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| clean | `0023-moe-compact-assemble.patch` |  |
| **FAILS** | `0024-moe-slot-stats-classify.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| clean | `0025-moe-skip-cache-when-slots-cover-experts.patch` |  |
| **FAILS** | `0026-metal-release-the-host-wrap.patch` | 1 hunk(s) rejected in ggml-metal-device.m  |
| **FAILS** | `0027-metal-fa-split-narrow-heads.patch` | 0 hunk(s) rejected in unknown |
| clean | `0028-metal-fa-split-depth-per-head.patch` |  |
| clean | `0029-metal-stage-large-uploads-through-the-ring.patch` |  |
| **FAILS** | `0030-metal-release-the-read-wrap.patch` | 1 hunk(s) rejected in ggml-metal-device.m  |
| clean | `0031-llms-log-the-tensor-group-layout.patch` |  |
| clean | `0032-metal-read-the-quant-arrays-a-word-at-a-time.patch` |  |
| **FAILS** | `0033-metal-a-separate-file-for-the-64-lane-kernels.patch` | 2 hunk(s) rejected in CMakeLists.txt ggml-metal-device.m  |
| clean | `0034-metal-keep-mxfp4-at-four-rows-per-simdgroup.patch` |  |
| clean | `0035-metal-let-the-expert-matvec-read-words-too.patch` |  |
| clean | `0036-metal-read-the-iq1-grid-entry-as-one-word.patch` |  |
| clean | `0037-metal-a-64-lane-matvec-for-every-quant-type.patch` |  |
| **FAILS** | `0038-metal-a-64-lane-gemm-of-its-own.patch` | 3 hunk(s) rejected in CMakeLists.txt ggml-metal-device.m ggml-metal-ops.cpp  |
| **FAILS** | `0039-metal-keep-the-measuring-switches.patch` | 2 hunk(s) rejected in ggml-metal-context.m ggml-metal-device.m  |
| clean | `0040-metal-a-64-lane-gemm-for-the-experts.patch` |  |
| **FAILS** | `0041-metal-64-lanes-for-the-expert-and-fused-matvec.patch` | 1 hunk(s) rejected in ggml-metal-ops.cpp  |
| **FAILS** | `0042-metal-a-64-lane-prefill-attention.patch` | 2 hunk(s) rejected in CMakeLists.txt ggml-metal-device.m  |
| clean | `0043-metal-a-tile-floor-for-each-quant.patch` |  |
| clean | `0044-metal-instrument-the-32-lane-matvec-for-a-lanes.patch` |  |
| clean | `0045-metal-a-64-lane-prefill-attention-for-the-asymm.patch` |  |
| clean | `0046-metal-a-tile-floor-per-quant-for-each-lane-widt.patch` |  |
| **FAILS** | `0047-port-adapt-the-series-to-upstream-465e49b9c.patch` | 5 hunk(s) rejected in ggml-metal-common.cpp ggml-metal-common.h ggml-metal-device.m llama-arch.cpp llama-bench.cpp  |
| **FAILS** | `0048-metal-sparse-attention-for-the-AMD-kernels.patch` | 0 hunk(s) rejected in unknown |
| clean | `0050-metal-ext-mv-wave64-tuning.patch` |  |
| clean | `0051-metal-ext-mv-wave64-single-pass.patch` |  |
| **FAILS** | `0054-metal-moe-off-active-stub.patch` | 1 hunk(s) rejected in ggml-metal-ops.cpp  |
| **FAILS** | `0055-metal-fa-dk384-640-guard.patch` | 1 hunk(s) rejected in ggml-metal-device.m  |
| **FAILS** | `0056-metal-aligned-mat-vec-reads-before-vega.patch` | 1 hunk(s) rejected in ggml-metal-device.h  |
| clean | `0057-llms-keep-the-output-head-on-every-card-for-dflash.patch` |  |
| **FAILS** | `0058-metal-a-64-lane-index-kernel-for-sparse-attention.patch` | 0 hunk(s) rejected in unknown |
| **FAILS** | `0059-metal-its-own-events-for-the-fused-exchange.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| **FAILS** | `0060-mgpu-collective-tracing.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| **FAILS** | `0061-metal-tp2-peer-direct-allreduce.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| **FAILS** | `0062-metal-tp2-peer-fused-reduce.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| **FAILS** | `0063-mgpu-merge-the-collective-into-the-next-subgraph.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| **FAILS** | `0064-mgpu-hold-the-collective-buffer-for-decode-batches.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| **FAILS** | `0065-mgpu-tp2-fused-boundary.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| clean | `0066-mgpu-tp2-wg32-sixteen-local-heads.patch` |  |
| clean | `0067-mgpu-tp2-wg32-measured-head-shapes.patch` |  |
| clean | `0068-mgpu-tp2-wg32-dk64-measured-head-shapes.patch` |  |
| **FAILS** | `0069-llms-qwen4exp-mtp-draft-head.patch` | 5 hunk(s) rejected in llama-arch.cpp llama-arch.h llama-model.h models.h qwen4exp.cpp  |
| **FAILS** | `0070-mgpu-dual-shape-graph-cache.patch` | 2 hunk(s) rejected in ggml-backend-meta.cpp ggml-backend.h  |
| **FAILS** | `0072-metal-zero-filled-collectives-and-one-shot-allreduce.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| **FAILS** | `0073-metal-f16-allreduce-transport.patch` | 1 hunk(s) rejected in ggml-metal-context.m  |
| clean | `0074-mgpu-tp4-topology-aware-allreduce.patch` |  |
| clean | `0075-metal-fa-prefill-falls-back-when-the-driver-refuses-the-kernel.patch` |  |
| clean | `0076-mgpu-subgraphs-survive-the-context-reset.patch` |  |
| **FAILS** | `0077-metal-kernels-compile-for-macos-12.patch` | 1 hunk(s) rejected in mul_mm.metal  |
| **FAILS** | `0078-metal-the-wide-q4k-q5k-tile-takes-the-scale-branch-per-wave.patch` | 1 hunk(s) rejected in mul_mm.metal  |
| **FAILS** | `0079-llms-prism-ternary-types-and-hadamard-runtime.patch` | 9 hunk(s) rejected in llama-context.cpp llama-graph.cpp llama-graph.h llama-model.cpp llama-model.h qwen35.cpp qwen35moe.cpp qwen3next.cpp test-backend-ops.cpp  |
| **FAILS** | `0080-metal-prism-ternary-kernels-and-fused-hadamard.patch` | 7 hunk(s) rejected in ggml-metal-common.cpp ggml-metal-device.h ggml-metal-device.m ggml-metal-impl.h ggml-metal-ops.cpp misc.metal mul_mm.metal  |
| **FAILS** | `0081-metal-the-expert-tile-skips-its-empty-column-half.patch` | 1 hunk(s) rejected in mul_mm.metal  |
| clean | `0082-metal-the-expert-tile-grid-keeps-an-odd-tile-count.patch` |  |
| **FAILS** | `0083-metal-q8_0-quads-load-as-two-halves.patch` | 1 hunk(s) rejected in dequantize.h  |
| clean | `0084-engine-a-state-save-reads-its-tensors-in-one-batch.patch` |  |
| **FAILS** | `0085-metal-the-encode-path-reads-each-environment-variable-once.patch` | 3 hunk(s) rejected in ggml-metal-context.m ggml-metal-device.m ggml-metal-ops.cpp  |
| clean | `0086-llms-the-two-expert-projections-load-as-one-matrix-on-64-lane-cards.patch` |  |
| clean | `0087-llms-the-moe-router-runs-as-one-kernel.patch` |  |
| clean | `0088-metal-a-q4_k-matvec-of-four-or-more-columns-takes-four-rows-on-64-lane-cards.patch` |  |
| clean | `0089-metal-iq4_xs-mat-vec-shares-each-block-across-columns.patch` |  |
| clean | `0090-metal-the-expert-grid-skips-slow-tile-counts-on-32-lanes.patch` |  |
| clean | `0091-metal-a-same-shape-copy-skips-its-index-divisions.patch` |  |
| **FAILS** | `0092-metal-a-few-columns-share-one-read-of-each-weight-block.patch` | 2 hunk(s) rejected in ggml-metal-device.h ggml-metal-ops.cpp  |
| clean | `0093-metal-the-attention-block-pre-pass-stays-inside-the-mask.patch` |  |
| clean | `0094-common-the-mtp-backoff-follows-the-last-dozen-drafts.patch` |  |
| **FAILS** | `0096-metal-64-lane-cards-read-two-columns-per-block-on-legacy-quants.patch` | 1 hunk(s) rejected in ggml-metal-device.h  |
| clean | `0097-metal-a-rescaled-expert-matmul-accumulates-in-float.patch` |  |

**43 of 92 apply cleanly**, 0 need a three-way merge, 49 fail (121 hunks rejected).

### What moved underneath them

`ggml/src/ggml-metal/kernels/mul_mm.metal`:

- 2232bc8b5 metal : use bf16 math for mxfp4 mul-mat (#29770)

`app/CMakeLists.txt`:


`ggml/src/ggml-metal/ggml-metal-context.m`:

- 84e76d8a2 metal : fix graph capture and handle empty graphs (#29390)

`ggml/src/ggml-metal/ggml-metal-device.h`:

- a3a1c4747 metal : few-row MMA mat-mul (#29869)
- 926862e57 metal : add tensor API flash attention kernel for F16 KV (#29570)

`ggml/src/ggml-metal/ggml-metal-device.m`:

- 1f8fa5231 metal: add the 128/96 flash attention kernels, accept every compiled pair (#30209)
- a3a1c4747 metal : few-row MMA mat-mul (#29869)
- 889edf43d qwen4exp : halve the indexer score memory (#29825)
- 13b4d7135 metal : release temporary private transfer buffers (#29777)
- 4364bf723 metal: support left and circular padding in GGML_OP_PAD (#29561)
- e351231c4 metal: FWHT kernels for block widths above 512 (#29095)
- 5a75f14c0 metal : split fa kernels into per-dtype libraries (#29329)

`ggml/src/ggml-metal/ggml-metal-impl.h`:

- a3a1c4747 metal : few-row MMA mat-mul (#29869)
- 889edf43d qwen4exp : halve the indexer score memory (#29825)
- 926862e57 metal : add tensor API flash attention kernel for F16 KV (#29570)
- 18bbc46b4 metal: FWHT perf optimizations (#29602)
- 4364bf723 metal: support left and circular padding in GGML_OP_PAD (#29561)
- e351231c4 metal: FWHT kernels for block widths above 512 (#29095)

`ggml/src/ggml-metal/ggml-metal-ops.cpp`:

- 1f8fa5231 metal: add the 128/96 flash attention kernels, accept every compiled pair (#30209)
- 7e8324f5f metal : fix MUL_MAT+ADD fusion when the residual is itself a MUL_MAT (#30100)
- a043d38a6 metal : fix excess threadgroup memory in quantized flash attention (#29340)
- a3a1c4747 metal : few-row MMA mat-mul (#29869)
- 889edf43d qwen4exp : halve the indexer score memory (#29825)
- 926862e57 metal : add tensor API flash attention kernel for F16 KV (#29570)
- 4e2713c16 qwen4exp : optimize mask constructions (#29824)
- 4364bf723 metal: support left and circular padding in GGML_OP_PAD (#29561)
- e351231c4 metal: FWHT kernels for block widths above 512 (#29095)
- cdc06426e metal : optimize sparse FA + clean-up (#29377)

`ggml/src/ggml-metal/ggml-metal.cpp`:

- 631109b34 ggml : add `alloc_buffer_n` to buffer type interface (#23671)

`ggml/src/ggml-backend-impl.h`:

- 631109b34 ggml : add `alloc_buffer_n` to buffer type interface (#23671)

`ggml/src/ggml-backend-meta.cpp`:

- e60eff95f meta : handle host views (#30217)
- a46709b68 RPC: add `-sm tensor` (#26610)
- 631109b34 ggml : add `alloc_buffer_n` to buffer type interface (#23671)
- 5503b04b0 meta: clear inactive AllReduce shards with FILL, not SCALE (#29793)

`ggml/src/ggml-backend.cpp`:

- 6753a033f ggml: refactor selective expert copying to user code (#29943)
- 631109b34 ggml : add `alloc_buffer_n` to buffer type interface (#23671)
- 8019dc563 ggml : collect all input tensors into graph_inputs (#29634)

`ggml/src/ggml-common.h`:


`ggml/src/ggml-cpu/ggml-cpu.c`:

- 2bbca8f20 ggml-cpu: vectorize fp32 to fp16 conversion (#30157)
- a7b94df2c ggml-cpu: support BF16/FP16/FP32 K tails in tinyBLAS on x86 (#29806)
- 90c908d06 cpu: accept BF16 in src1 of mul_mat (#28937)
- 0c6a6a7ce Enables Windows ARM64 build with MSVC cl.exe (#28362)
- d834d44e6 ggml-cpu:  tiled mul_mat for k-quants (#27851)

`ggml/src/ggml-cpu/ggml-cpu.cpp`:

- 90c908d06 cpu: accept BF16 in src1 of mul_mat (#28937)

`ggml/src/ggml-quants.c`:

- 2923cf286 ggml-quants : avoid invalid rounding in qkx3 scale search (#29817)

`ggml/src/ggml-openvino/ggml-quants.h`:


`ggml/src/ggml.c`:

- 8ae386707 ggml: fix OOB write in ggml_acc with negative offset (#30135)
- 2149c00f4 ggml/gguf : fix integer overflow (#29384)
- b5cf8ce02 ggml : require input tensors to be GGML_OP_NONE (#29647)
- bced4595b sync : ggml (#29396)

`ggml/include/ggml.h`:


`ggml/src/ggml-cpu/ops.cpp`:

- 65840ed53 ggml: fix CLAMP on non-contiguous views (CPU, CUDA) (#29517)
- dd4c286f3 ggml-cpu : fix soft_max_back wrong output when dst aliases src1 (#27096)
- 2090f60f0 ggml : add BF16 unary, GLU, binary and scale ops (CPU, CUDA) (#29675)
- d3954b932 ggml : check row bounds in get_rows_back (#29575)
- 6f767fe96 ggml-cpu: enable tiled flash attention for non-vector-multiple head dims on x86 (#29423)

`ggml/src/ggml-cpu/ops.h`:


`common/parsers/cohere2moe.cpp`:

- 8b5436102 chat : refactor API (#30210)

`src/models/delta-net-base.cpp`:


`src/models/hy-v3.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- 448147d42 llama: share the nextn tensor flags between models (#30097)
- f0c41e016 models : consolidate nextn row cropping into shared helpers (#30017)

`src/llama-context.cpp`:

- a518119d3 llama: keep the backend sampling graph static across ubatches (#30223)
- c811cb8f0 llama: support MoE cache over multiple GPUs (#30112)
- d6cf9acb2 llama : add a GPU cache for MoE experts kept in host memory (#29887)
- 1a3011cc0 llama : re-reserve the sched when the nextn extraction flags change (#30020)
- 6753a033f ggml: refactor selective expert copying to user code (#29943)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)
- 99b95488c model: add support for clef decision model (text-only) (#29831)
- 4453b535f llama : preserve original batch order for speculative decoding layer inputs (#29019)
- 81ff93ea1 llama: properly handle KV on training (#28520)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)
- b5cf8ce02 ggml : require input tensors to be GGML_OP_NONE (#29647)
- ed7ac35e1 context : do not re-reserve the scheduler when toggling causal_attn (#28751)
- 4da633776 server : allow RANK pooling batch splitting for causal LLM rerankers (ie. Qwen3 and Qwen3-VL) (#28876)
- 08618ff8e llama : fix K/V and recurrent state cleanup after failed restores (#27530)
- e9f824d8c llama : add `llama_prec_policy` + model-driven W4A4 path (#24364)
- fc343a84b llama: add llama_batch_ext (#24669)

`src/llama-graph.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- 8e2d31e0e graph : reorder get_rows for embeddings (#30160)
- 6184e92c5 model : use exact GELU for ModernBERT encoders (#30108)
- a518119d3 llama: keep the backend sampling graph static across ubatches (#30223)
- c811cb8f0 llama: support MoE cache over multiple GPUs (#30112)
- 37ac63456 model : support classifier_activation for rerankers (#29692)
- d6cf9acb2 llama : add a GPU cache for MoE experts kept in host memory (#29887)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)
- 436f6f89e graph: gather the recurrent states once so the reserve covers every split (#29856)
- b56f34ab1 CUDA: Handle compute type for NVFP4 on cublass path (#29173)
- 81ff93ea1 llama: properly handle KV on training (#28520)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)
- 48de2a1bc model : support classifier_pooling for rerankers (#29627)
- 4da633776 server : allow RANK pooling batch splitting for causal LLM rerankers (ie. Qwen3 and Qwen3-VL) (#28876)
- e9f824d8c llama : add `llama_prec_policy` + model-driven W4A4 path (#24364)

`src/llama-graph.h`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- 6184e92c5 model : use exact GELU for ModernBERT encoders (#30108)
- d6cf9acb2 llama : add a GPU cache for MoE experts kept in host memory (#29887)
- f0c41e016 models : consolidate nextn row cropping into shared helpers (#30017)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)
- 436f6f89e graph: gather the recurrent states once so the reserve covers every split (#29856)
- e9f824d8c llama : add `llama_prec_policy` + model-driven W4A4 path (#24364)

`src/llama-kv-cache.cpp`:

- 210791069 kv-cache: fix restoring mismatched KV cache rotation by saving exact rotation metadata (#28498)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)
- 08618ff8e llama : fix K/V and recurrent state cleanup after failed restores (#27530)

`src/llama-mmap.cpp`:

- 32dd62ee6 llama-mmap : avoid a second full-size copy of each tensor with direct-io (#29749)
- 185103dcf llama: llama_prefetch_rows (#29599)

`src/llama-mmap.h`:

- 32dd62ee6 llama-mmap : avoid a second full-size copy of each tensor with direct-io (#29749)
- 185103dcf llama: llama_prefetch_rows (#29599)

`src/llama-model-loader.cpp`:

- 32dd62ee6 llama-mmap : avoid a second full-size copy of each tensor with direct-io (#29749)

`src/llama-model-loader.h`:


`src/llama-model.cpp`:

- 6184e92c5 model : use exact GELU for ModernBERT encoders (#30108)
- 37ac63456 model : support classifier_activation for rerankers (#29692)
- a657f7e98 model : add LiquidAI/d1-omni-600M decision model (#30114)
- 448147d42 llama: share the nextn tensor flags between models (#30097)
- 462524043 model : add K2 Horizon dense and MoVA support (#29535)
- 4fbc76dec model: support embeddinggemma2 (text+vision+audio) (#30054)
- 99b95488c model: add support for clef decision model (text-only) (#29831)
- 78e2964c2 llama: refer to segment documentation [no ci] (#29074)
- c061df198 Qwen4Exp: add MTP (#29761)
- 185103dcf llama: llama_prefetch_rows (#29599)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)
- 48de2a1bc model : support classifier_pooling for rerankers (#29627)
- e9f824d8c llama : add `llama_prec_policy` + model-driven W4A4 path (#24364)
- f805c57a2 llama : fix tensor split for fused qkv with uneven K/V head sizes (#29294)
- f830688e9 model : add Ling 3.0 VL support (#29151)

`src/models/qwen35.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- 448147d42 llama: share the nextn tensor flags between models (#30097)
- f0c41e016 models : consolidate nextn row cropping into shared helpers (#30017)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)
- a4cb4c61f llama, server: add /v1/systemone API (models: laya, julia-1, lev, openjev, kev) (#29818)

`src/models/qwen35moe.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- 448147d42 llama: share the nextn tensor flags between models (#30097)
- f0c41e016 models : consolidate nextn row cropping into shared helpers (#30017)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)

`src/models/step35.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- 448147d42 llama: share the nextn tensor flags between models (#30097)
- f0c41e016 models : consolidate nextn row cropping into shared helpers (#30017)

`common/arg.cpp`:

- aa94f2086 args: add LLAMA_ARG_SLOT_SAVE_PATH env for --slot-save-path (#30272)
- b42b7e6d3 server: use port 9931 by default (#30159)
- c811cb8f0 llama: support MoE cache over multiple GPUs (#30112)
- d6cf9acb2 llama : add a GPU cache for MoE experts kept in host memory (#29887)
- 4d60b4d08 common, server : report model input/output modalities in GET /models (#29987)
- 050439614 imatrix: calculate activation-based statistics for new format (GGUF) imatrices (#14891)
- 1fb7ef3e3 spec : add probabilistic sampling for simple draft and MTP (#27694)
- feb9a3d6d args: fix cli download mmproj arg  (#28977)
- 00af63567 common : use fs::path for config dir (#29649)
- 76a5bc86d common : use fs::path for cache dirs (#29595)
- a97cce86a common : avoid side effects around params parsing (#29537)

`common/common.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- baef3ed9a ui: Models Manager Follow-up Improvements (#30228)
- 033df86b6 server : preserve context checkpoints across slot save/restore (#26004)
- a657f7e98 model : add LiquidAI/d1-omni-600M decision model (#30114)
- 88dcc460d model : add LiquidAI/d1-3B decision model (#30110)
- d6cf9acb2 llama : add a GPU cache for MoE experts kept in host memory (#29887)
- da263e727 models: support pplx-decider (#30044)
- 4d60b4d08 common, server : report model input/output modalities in GET /models (#29987)
- a7fb71fab log, server: self contained colors, split child commands from logs in router mode (#29895)
- 050439614 imatrix: calculate activation-based statistics for new format (GGUF) imatrices (#14891)
- 6716df694 common : prepare load_from_models_dir() for path conversion (#29674)
- 1537a0a8b server : fix laya abort by limiting n_batch to n_ubatch (#29903)
- edd6e2bbd common : add common_is_tty() helper and fix deprecated warnings on Windows (#29860)
- 99b95488c model: add support for clef decision model (text-only) (#29831)
- 46ca246de model: support nimble decision model (#29844)
- a4cb4c61f llama, server: add /v1/systemone API (models: laya, julia-1, lev, openjev, kev) (#29818)
- 70849ee82 common : remove fs_open_ifstream() by using u8path() (#29841)
- f1cee9941 common,rpc : fix cache dir creation through symlinks on buggy libstdc++ (#29816)
- 60e9cf7a7 batch: migrate the rest of examples to llama_batch_ext (#29601)
- 00af63567 common : use fs::path for config dir (#29649)
- 31385c9ce common : add fs_write_atomic() (#29642)
- 76a5bc86d common : use fs::path for cache dirs (#29595)
- f1ea20621 batch: migrate speculative, mtmd and server to batch_ext (#29385)
- 6c7a87f7e common : fix HF cache paths on Windows (#29475)
- 4b1a27fa0 common,rpc : simplify fs_create_directory_with_parents() (#29432)
- 27b20ba8b common : extract shared unicode path/string helpers (#29415)
- fc343a84b llama: add llama_batch_ext (#24669)

`common/common.h`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- baef3ed9a ui: Models Manager Follow-up Improvements (#30228)
- b42b7e6d3 server: use port 9931 by default (#30159)
- c811cb8f0 llama: support MoE cache over multiple GPUs (#30112)
- 033df86b6 server : preserve context checkpoints across slot save/restore (#26004)
- a657f7e98 model : add LiquidAI/d1-omni-600M decision model (#30114)
- 88dcc460d model : add LiquidAI/d1-3B decision model (#30110)
- d6cf9acb2 llama : add a GPU cache for MoE experts kept in host memory (#29887)
- da263e727 models: support pplx-decider (#30044)
- 4d60b4d08 common, server : report model input/output modalities in GET /models (#29987)
- a7fb71fab log, server: self contained colors, split child commands from logs in router mode (#29895)
- 050439614 imatrix: calculate activation-based statistics for new format (GGUF) imatrices (#14891)
- 6716df694 common : prepare load_from_models_dir() for path conversion (#29674)
- edd6e2bbd common : add common_is_tty() helper and fix deprecated warnings on Windows (#29860)
- 99b95488c model: add support for clef decision model (text-only) (#29831)
- 1fb7ef3e3 spec : add probabilistic sampling for simple draft and MTP (#27694)
- 46ca246de model: support nimble decision model (#29844)
- a4cb4c61f llama, server: add /v1/systemone API (models: laya, julia-1, lev, openjev, kev) (#29818)
- 70849ee82 common : remove fs_open_ifstream() by using u8path() (#29841)
- f1cee9941 common,rpc : fix cache dir creation through symlinks on buggy libstdc++ (#29816)
- 60e9cf7a7 batch: migrate the rest of examples to llama_batch_ext (#29601)
- 00af63567 common : use fs::path for config dir (#29649)
- 31385c9ce common : add fs_write_atomic() (#29642)
- 76a5bc86d common : use fs::path for cache dirs (#29595)
- f1ea20621 batch: migrate speculative, mtmd and server to batch_ext (#29385)
- 6c7a87f7e common : fix HF cache paths on Windows (#29475)
- 136887b66 common : make string_split<T> throw on invalid values (#29518)
- 27b20ba8b common : extract shared unicode path/string helpers (#29415)
- fc343a84b llama: add llama_batch_ext (#24669)

`common/fit.cpp`:

- 2145525a4 Revert "Change max context length for auto-fitting with unified KV (#28849)" (#29437)

`common/speculative.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- d6cf9acb2 llama : add a GPU cache for MoE experts kept in host memory (#29887)
- 050439614 imatrix: calculate activation-based statistics for new format (GGUF) imatrices (#14891)
- 8330e9696 spec : fix n-gram drafts rejected at temp > 0 after truncation (#29924)
- 1fb7ef3e3 spec : add probabilistic sampling for simple draft and MTP (#27694)
- c061df198 Qwen4Exp: add MTP (#29761)
- 60e9cf7a7 batch: migrate the rest of examples to llama_batch_ext (#29601)
- f1ea20621 batch: migrate speculative, mtmd and server to batch_ext (#29385)
- 2b7058399 server,common : fix the GCC 12 stringop-overread false positive (again) (#29325)

`cmake/build-info.cmake`:


`tools/mtmd/clip-model.h`:

- a657f7e98 model : add LiquidAI/d1-omni-600M decision model (#30114)
- 552f18f91 mtmd: cap max_image to ubatch for non_causal models (#29773)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)

`tools/llama-bench/llama-bench.cpp`:

- f39148a95 llama-bench: respect -fitc if bigger than required benchmark size (#28331)
- 7dad6db85 llama-bench : fix verbosity filter to show GGML_LOG_ERROR (#28229)
- 60e9cf7a7 batch: migrate the rest of examples to llama_batch_ext (#29601)
- 187664b53 llama-bench : fix OOB access of hf_file (#29515)
- 965f89794 polished Readme and llama-bench (#28968)

`tools/server/server-chat.cpp`:


`tests/test-backend-ops.cpp`:

- 50e3e3e48 CUDA: Remove redundant CUDA copies after SSM_SCAN (#29807)
- d4d82d67f hexagon: fix IM2COL patch-embed DMA ring overflow (#30189)
- 71ad0590f CUDA: improve top-k algorithm selection (#28713)
- c35b66744 CUDA : looped PAD kernel for more than 65535 rows or slices (#30147)
- ff5888f99 vulkan : fix TOP_K for +inf/NaN inputs and k = 1 on negative values (#30107)
- dac308739 vulkan: extend sparse FA support to coopmat2 (#30003)
- 46baf1f1f sycl: FWHT optimizations (#29605)
- fda186661 CUDA: fix norm family kernels when ne[2]/ne[3] exceed grid dim limits (#28175)
- ff30363a0 sycl: fuse the delta-net alpha gate (add + unary + mul) (#29687)
- 42c787e8c cuda: update uncoalesced memory reads in pool2d (#29425)
- 988190680 metal : few-row MMA mat-mul for the remaining src0 types (#30065)
- 7e8324f5f metal : fix MUL_MAT+ADD fusion when the residual is itself a MUL_MAT (#30100)
- 5ad1c5da0 cuda : add BF16 support for XIELU (#29955)
- 65840ed53 ggml: fix CLAMP on non-contiguous views (CPU, CUDA) (#29517)
- a043d38a6 metal : fix excess threadgroup memory in quantized flash attention (#29340)
- b3daa077a vulkan: sparse flash attention for quantized K/V (#29639)
- 1b43d3116 cuda: tile the lightning indexer over keys and tokens for 4 heads (#29901)
- a3a1c4747 metal : few-row MMA mat-mul (#29869)
- a7b94df2c ggml-cpu: support BF16/FP16/FP32 K tails in tinyBLAS on x86 (#29806)
- 11fe02151 webgpu: add f16 support to fill/set_rows (#29897)
- a55e952b8 ci: fix flaky ADD_ADD f16 by using the fused ADD tolerance (#29904)
- 889edf43d qwen4exp : halve the indexer score memory (#29825)
- bed0a8566 CUDA: fuse shared experts into MMVQ (#29184)
- 134b2bb75 ggml-cuda : fix cpy transposed path corrupting non-contiguous dst (#27663)
- 926862e57 metal : add tensor API flash attention kernel for F16 KV (#29570)
- b93328954 sycl: large register file for D=512 FA vec kernels (#29062)
- f11d642a2 HIP: avoid treating CDNA as dgx spark for gqa_ratio 20 in fattn_mma dqk 576 (#29572)
- 2232bc8b5 metal : use bf16 math for mxfp4 mul-mat (#29770)
- 2090f60f0 ggml : add BF16 unary, GLU, binary and scale ops (CPU, CUDA) (#29675)
- 90c908d06 cpu: accept BF16 in src1 of mul_mat (#28937)
- 6f767fe96 ggml-cpu: enable tiled flash attention for non-vector-multiple head dims on x86 (#29423)
- 03a667aa3 vulkan: fuse qwen4exp's SCALE -> SIGMOID -> SCALE -> hc_post chain (#29520)
- 4364bf723 metal: support left and circular padding in GGML_OP_PAD (#29561)
- 526247161 vulkan: fix wrong results when a mul_mat reads a slice of a larger cache (#28956)
- 2b129ccfa hexagon: support for backend sampler (#29502)
- 95887577a cuda: support Nemotron 3 Puzzle state size 96 for ssm scan (#28717)
- 6f856c709 cuda: add F16 input to the FWHT (#29096)
- e351231c4 metal: FWHT kernels for block widths above 512 (#29095)
- e9f824d8c llama : add `llama_prec_policy` + model-driven W4A4 path (#24364)
- 8212c7802 test: flush status (#28352)
- 6b790a9c2 vulkan: handle misalignment in conv_2d and conv_3d (#29365)
- 53ed051ce cuda : add conv3d with implicit GEMM (#29137)

`tests/test-chat.cpp`:

- 8b5436102 chat : refactor API (#30210)
- bd4eeaa04 chat: fix jinja parser for TranslateGemma (#30096)
- 5de733437 chat : name tool and argument parser rules by index (#30088)
- 18b5f8b18 server : accumulate generated text and tokens as parse input (#29876)
- 462524043 model : add K2 Horizon dense and MoVA support (#29535)
- 9bf55f4a3 chat : honor json_schema in Ling 3.0 parser (#29813)
- b8f96c3e8 common : add LLM-jp-4.1 Harmony dialect handler (#29681)
- 139997d8e chat : fix Muse Glimmer ignoring response_format json_schema with --jinja (#29615)

`tests/test-quantize-fns.cpp`:

- 2923cf286 ggml-quants : avoid invalid rounding in qkx3 scale search (#29817)

`src/llama-model.h`:

- 448147d42 llama: share the nextn tensor flags between models (#30097)
- 462524043 model : add K2 Horizon dense and MoVA support (#29535)
- a4cb4c61f llama, server: add /v1/systemone API (models: laya, julia-1, lev, openjev, kev) (#29818)
- c061df198 Qwen4Exp: add MTP (#29761)
- 185103dcf llama: llama_prefetch_rows (#29599)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)
- e9f824d8c llama : add `llama_prec_policy` + model-driven W4A4 path (#24364)

`ggml/src/ggml-metal/ggml-metal-common.cpp`:

- 988190680 metal : few-row MMA mat-mul for the remaining src0 types (#30065)
- a3a1c4747 metal : few-row MMA mat-mul (#29869)
- e351231c4 metal: FWHT kernels for block widths above 512 (#29095)

`ggml/src/ggml-metal/ggml-metal-common.h`:

- a3a1c4747 metal : few-row MMA mat-mul (#29869)
- e351231c4 metal: FWHT kernels for block widths above 512 (#29095)

`src/llama-arch.cpp`:

- e60eff95f meta : handle host views (#30217)
- 37ac63456 model : support classifier_activation for rerankers (#29692)
- 462524043 model : add K2 Horizon dense and MoVA support (#29535)
- 4fbc76dec model: support embeddinggemma2 (text+vision+audio) (#30054)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)
- 99b95488c model: add support for clef decision model (text-only) (#29831)
- a4cb4c61f llama, server: add /v1/systemone API (models: laya, julia-1, lev, openjev, kev) (#29818)
- c061df198 Qwen4Exp: add MTP (#29761)
- 10f340d1a model : re-enable -sm tensor for qwen4exp (#28569)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)
- 48de2a1bc model : support classifier_pooling for rerankers (#29627)
- 85ca3b52c hrm : fix layer placement of `z_l_init` weight (#29512)
- e9f824d8c llama : add `llama_prec_policy` + model-driven W4A4 path (#24364)

`src/llama-arch.h`:

- 37ac63456 model : support classifier_activation for rerankers (#29692)
- 462524043 model : add K2 Horizon dense and MoVA support (#29535)
- 4fbc76dec model: support embeddinggemma2 (text+vision+audio) (#30054)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)
- 99b95488c model: add support for clef decision model (text-only) (#29831)
- a4cb4c61f llama, server: add /v1/systemone API (models: laya, julia-1, lev, openjev, kev) (#29818)
- c061df198 Qwen4Exp: add MTP (#29761)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)
- 48de2a1bc model : support classifier_pooling for rerankers (#29627)
- e9f824d8c llama : add `llama_prec_policy` + model-driven W4A4 path (#24364)

`src/models/models.h`:

- a657f7e98 model : add LiquidAI/d1-omni-600M decision model (#30114)
- b9acf138a feat: add GLM5Next MTP, optimize (#29928)
- 462524043 model : add K2 Horizon dense and MoVA support (#29535)
- 4fbc76dec model: support embeddinggemma2 (text+vision+audio) (#30054)
- 99b95488c model: add support for clef decision model (text-only) (#29831)
- a4cb4c61f llama, server: add /v1/systemone API (models: laya, julia-1, lev, openjev, kev) (#29818)
- c061df198 Qwen4Exp: add MTP (#29761)
- 66e0c17ee llama: fix qwen4exp (#29751)
- 649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)

`src/models/qwen4exp.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- 8e2d31e0e graph : reorder get_rows for embeddings (#30160)
- 448147d42 llama: share the nextn tensor flags between models (#30097)
- 310991409 llama: remove the gather path of the glm5-next sparse attention (#30042)
- f0c41e016 models : consolidate nextn row cropping into shared helpers (#30017)
- 43fe9c642 llama: fix k-pool scatter data race on shared sequences (#29994)
- c173a53bd llama : fix unexpected graph reallocation in the k-pool models (#29958)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)
- 889edf43d qwen4exp : halve the indexer score memory (#29825)
- 4e2713c16 qwen4exp : optimize mask constructions (#29824)
- 159c651f5 qwen4exp: fix tests (#29819)
- c061df198 Qwen4Exp: add MTP (#29761)
- 66e0c17ee llama: fix qwen4exp (#29751)
- 10f340d1a model : re-enable -sm tensor for qwen4exp (#28569)
- 185103dcf llama: llama_prefetch_rows (#29599)
- ed7ac35e1 context : do not re-reserve the scheduler when toggling causal_attn (#28751)

`ggml/include/ggml-backend.h`:

- 6753a033f ggml: refactor selective expert copying to user code (#29943)
- 631109b34 ggml : add `alloc_buffer_n` to buffer type interface (#23671)
- 78e2964c2 llama: refer to segment documentation [no ci] (#29074)

`src/models/qwen3next.cpp`:

- 781dbc5ac spec: properly handle mtmd input for mtp (#30257)
- 448147d42 llama: share the nextn tensor flags between models (#30097)
- f0c41e016 models : consolidate nextn row cropping into shared helpers (#30017)
- 0bb496dbd llama: support both embd + raw tokens in batch (#29622)

`ggml/src/ggml-metal/kernels/misc.metal`:

- 18bbc46b4 metal: FWHT perf optimizations (#29602)
- 4364bf723 metal: support left and circular padding in GGML_OP_PAD (#29561)
- e351231c4 metal: FWHT kernels for block widths above 512 (#29095)

`ggml/src/ggml-metal/kernels/dequantize.h`:

- 2232bc8b5 metal : use bf16 math for mxfp4 mul-mat (#29770)

