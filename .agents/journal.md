
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

### AMENDMENT 1 (plan: remote-inference-providers)
- Step 2 delivered as design.md with one refinement: ChatInferenceRoute protocol replaced by enum InferenceDialect + Codable InferenceRoute + InferenceRoutes resolver. Reason: 3 known dialects, JSONEncoder→UserDefaults is the established persistence pattern (measuredBenchByModel), no dynamic registration anywhere. Step 4 request-boundary extraction unchanged; local byte-identity gate unchanged.
- Keychain account chosen: "remote-api-key" (single key per install, matching the single local-key model; per-route keys = amendment candidate).

## 2026-10-02 ~07:40–08:58 PT — Step 4 committed; step 5 live-fire GREEN (with two hard-won fixes)
- Step 4 (335d37b): request-boundary seam in ChatNative.swift (:40 activeStreamRemote, sendRoute, remote bypass of prepareSlot/engine /tools/X-Conversation-Id/resume, RouteWire.wire), RemoteProvidersSection UI, InferenceRoutes.swift, gate_local_byte_identity.sh PASSING.
- canSend defect (found live): Send required `server.state == .running`; with route configured + engine stopped, Return/Send silently swallowed. Fix: `remoteReady = InferenceRoutes.active()?.isConfigured == true` OR-ed into canSend (ChatNative.swift:3079). Proof: Send button gained AXPress only after text entered; AXPress delivered the message.
- serverAvailabilityBar .stopped branch: route configured → cloud.fill "Answering via the remote provider." (ES+EN); else legacy banner. Live AX evidence on both windows.
- **Keychain ACL hang (new failure mode, root-caused)**: rebuilt binary = new ad-hoc signature; keychain item from the previous binary makes `Keychain.get` (Support.swift:593, SecItemCopyMatching→SecKeychainItemCopyContent) block FOREVER on a SecurityAgent consent prompt that never renders (no on-screen window; securityd IPC hold). Symptom: assistant row spins, zero TCP sockets, zero app logs. Diagnosis: `sample <pid> 3` → 1565/1565 then 2361/2361 main-thread samples in Keychain.get. Trigger this time: RemoteProvidersSection.swift:53 calls Keychain.get synchronously in body when Inference pane opens.
- Recovery sequence (all captured): kill -9 SecurityAgent pid → read unblocked (sample count 0) → `security delete-generic-password -s com.northlatchlabs.kestrel -a remote-api-key` (attribute-only, no hang) → re-save key via app UI (paste into SecureField, Save key) → item cdat 20261002155239Z, NO SecurityAgent prompt → Test button → **"Connection OK (200)."** in AX tree.
- **LIVE-FIRE**: chat window, engine down (`pgrep llama-server` = NONE, `lsof :8080` = EMPTY), Send → assistant row 08:57 reply exactly **"GATEWAY LIVE."** with finished-stream actions (Copy/Regenerate/Show raw output). Banner "Answering via the remote provider." + toolbar "Server stopped" in same snapshot. Stream completed <12s.
- Doctrine: after EVERY rebuild+reinstall, keychain reads from the old item hang; re-save key from the new binary or delete+recreate. Diagnose any spinning task with zero sockets via `sample`.
