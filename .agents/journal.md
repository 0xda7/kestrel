
## 2026-10-01 ~20:45 PT — Dashboard upper GPU card: AMD Radeon now shown (operator report)
- Operator: "Can you make my AMD Radeon show in the upper Dashboard ..as rn i only see my defaukt 2 GB one".
- Root cause chain, each link closed on captured output:
  1. `DashboardMetricsView` used `vram.gpus.first` → always Intel UHD 630 (index 0). Fix `6125b15` (primaryGPU: busiest-else-largest).
  2. Live AX snapshot of pid 49761 still showed "GPU, 15%, Intel(R) UHD Graphics 630" — desktop compositing lit the iGPU, so "busiest" picked Intel. Fix `6ac3860` (residency >20% threshold — still Intel at 38% while idle, no model loaded).
  3. ioreg PerformanceStatistics capture: AMD driver exposes NO idle activity key + inUseVidMemoryBytes=0; Intel reports compositing activity. Any load-based rule is biased to the iGPU on this hardware. Fix `abd99cb`: residency-first (>256 MB used), else largest totalMB. No activity fallback.
- Deployed: TOSH_VERSION=0.88.0 TOSH_NO_BUMP=1 make-app.sh → distto /Applications, xattr -dr quarantine, relaunch (pid 50391).
- GATE CLOSED: cua-driver AX snapshot of Configuration window (id=control, window 1314): `AXStaticText = "GPU, 33%, AMD Radeon Pro 5500M"`. The 33% is max-across-GPUs (Intel compositing); the card NAME is the discrete GPU as requested.
- Note: fix is on main (abd99cb) but NOT in v0.88.0 release DMGs; next tag carries it.

## 2026-10-02 ~07:30 PT — Mission opened: remote-inference-providers
- Operator request: "most optimized method for integration of a Custom Provider for the Inference. The provider is OpenAI and Anthropic compatible."
- Scout (captured this session): inference call sites = ChatNative.swift:881 (main stream), :1749 (compaction summarize), AudioStudioController.swift:685 (caption), ChatStreamProtocol.swift:99/108 (UI stream readback — local-only concern), ChatToolsService.swift:105/117/140 (engine /tools). ChatStreamAccumulator already parses OpenAI SSE incl. delta.tool_calls/usage/[DONE] → OpenAI-dialect remote needs no new parser.
- Operator decisions: build now, endpoint supplied by operator (key to Keychain via Settings, never chat), OpenAI-compatible dialect first.
- Goal goal-7fcd52da-b3b2-4292-9c06-fcea446fb08f armed, 12 rounds.
- Directive reaffirmed: engine fork untouched; remote requests bypass llama-server entirely; no hardcoded model ids.
