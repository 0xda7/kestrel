# MISSION MERLIN — journal (append-only)

## 2026-11-15 — mission opened

- Operator brief: engineer the most professional/advanced agent for ≤9B local models on Kestrel Engine. Not Surgical.
- Scope locked via operator answers: headless kernel + app integration; sandboxed workspace; name **Merlin**; success bar = eval-benched (12+ tasks, mechanical assertions).
- Plan authored: .agents/missions/2026-11-15-merlin/plan.md (9 systems M0–M8, 7 slices).
- Ground truth scouted: C1 grammar-constrained tool channel exists (ChatToolsService.swift:666+); ToolCallRescue ladder; permission store; JS sandbox; memory service; PendingAgentContinuation turn budgets. ≤9B bench on disk: GLM-4-9B, Qwen3.5-9B-distilled, LFM2.5-8B-A1B, Spark-X2.5-4B/1.7B, sakana-7b, R1-8B, Forge-1-E2B.
- Goal registered: goal-53267c33-67ec-4abb-9b73-3ae51bb8832f (12 rounds max).
- Lead edit: Package.swift — `merlin` executable target added (path Sources/MerlinMain, dep KestrelCore). Build pending kernel-1's files.
- Dispatched: eval-1 (39688a42) → eval suite design (TASKS.md, tasks.json, SCORING.md). kernel-1 (986edc0b) → kernel skeleton (Workspace, Ledger, TaskSpine, ToolRegistry, Retry, MerlinKernel, CLI, checks).
- Lead side-task: probe bundled llama-server grammar mode for the M1 contract (evidence below when done).

## 2026-11-15 — M1 actor contract evidence (lead, live probes)

Server: vendor/llama.cpp/build-static/bin/llama-server, version 0.6.0-dev build 11610 (091b6a7fc). Model: Spark-X2.5-1.7B-Q8_0, port 8123, -ngl 0, c 4096, ready after 4s.

- PROBE native tools (`tools` + `tool_choice:"auto"`): **PERFECT tool call from a 1.7B model** — `{"name":"calc","arguments":"{\"a\":2,\"b\":2,\"op\":\"+\"}"}`, empty content, standard OpenAI tool_calls shape. The server grammar-constrains tool schemas natively. → M1 primary path: native tools API.
- PROBE json_schema response_format envelope: empty content on this model — envelope path NOT assumed; must be verified per-model-family before use (matches engine caution at Support.swift:1273 re buggy generic grammars on some families).
- M1 ladder design consequence: 1) native tools (grammar, structured) → 2) json_schema envelope (per-family profile flag) → 3) ToolCallRescue (non-constrained, last resort). M8 model profiles pick the rung per family.
- Second probe, LFM2.5-2.6b-fable5 (the family engine flags grammar-sensitive, ChatToolsService.swift:678): **PERFECT native call** — picked fs_read over fs_write, argument `{"path":"notes.txt"}` exact. Native-tools rung verified on 2/2 families (Spark-X2.5, LFM2.5). Slice-2 contract is grounded: M8 profiles can default native-tools ON for these families, envelope rung per-family opt-in pending more probes (GLM/Qwen/R1 when slice 2 starts).

## 2026-11-15 — M8 profile matrix evidence (lead, live probes round 2-4)

- **GLM-4-9B**: native tools FAILS — `tool_calls:null`, raw call syntax inline in content, AND hallucinated a fake directory listing (invented 5 .md files). tool_choice:"required" and --jinja do NOT fix it. **json_schema envelope: PERFECT** — `{"name":"fs_list","arguments":{"path":"docs"}}`, grammar-locked, no drift possible. → GLM profile: rung 2 (envelope).
- **R1-0528-Qwen3-8B**: native tools PERFECT with reasoning (`reasoning_content:true` + correct `fs_list{"path":"docs"}` call) — but needs max_tokens ≥3000; at 200 tokens the thinking eats the budget and no action happens. → R1 profile: rung 1 + think_budget ~3000 floor.
- Profile matrix so far: Spark-X2.5→rung1; LFM2.5→rung1; R1-Qwen3→rung1+think_budget; GLM-4→rung2. M8 is now evidence-designed, not speculative.
- Note: engine's existing chat path must translate envelope-content → tool_calls for rung-2 families (C1 already does exactly this — reuse).

## 2026-11-15 — AMENDMENT 1: Merlin is the replacement, not an add-on (operator + lead)

- OPERATOR: existing product agent harness is broken — "full of errors and never completes anything; video, audio, and all the agent tools not working; unfinished capabilities." Merlin retargeted as THE agent runtime; legacy loop retired behind a flag after Merlin passes gates.
- Dispatched diagnosis worker (slice 0, 40e697f2): failure inventory of the legacy agent path (static file:line findings + ≥2 live repros mirroring ChatNative's request shapes + media-tools wiring table). This produces the measured "before" number Merlin's eval delta will be judged against.
- New phase order: 0 diagnosis → 1-3 kernel (fs/shell/js/todo tools; core loop) → 4 eval gate (≤9B bench, machinery ON vs OFF) → 5 app integration (Merlin becomes the engine's agent path) → media tools phase (video/audio as Merlin tools, AFTER core gate) → docs/close.
- Lead probe evidence feeding this: GLM-4-9B tool_calls:null + hallucinated listing (no execution feedback loop); R1-8B starved at 200 max_tokens, perfect at 3000; envelope rung rescues GLM byte-perfectly.
- eval-1 progress: TASKS.md (891 lines, 14 tasks/5 axes, mechanical gates) + tasks.json (valid, 8 keys incl. immutable_seeds_rule + completion_contract) delivered; SCORING.md pending.
- kernel-1 progress: Sources/Merlin/Workspace.swift + Sources/MerlinMain/main.swift on disk; ledger/registry/kernel/checks pending.

## 2026-11-15 — round 2-3: eval suite closed, seam amendment, integration fixes

- eval-1 (39688a42) CLOSED with validation evidence: 14/14 tasks pass vs reference solutions; 5 adversarial traps fail on intended assertions; checkers executed in temp sandboxes (T06/T07/T08 exit-1→0 chains proven; T13 127→missing-input→BUILD OK chain reproduced). Suite gate = 14/14 + axis gates + mandatory machinery-OFF baseline (anti-rationalization clause).
- Lead: MODEL-PROFILES-EVIDENCE.md written (rung matrix from live probes; think-budget floors; hallucination guard; unknown-family auto-promotion protocol). Binding input for slice 2.
- Lead integration fix: Package.swift — KestrelCore now excludes ["Main", "MerlinMain"] (overlap error: 'target merlin has overlapping sources'). My bug, fixed on my file.
- Lead design review of landed MerlinKernel.swift: approved seams (MerlinActor/Guardian/TaskDoneSignal/error-as-state). ONE binding change via AMENDMENT 2: actor returns [MerlinToolCall] (1...4) per turn (batched) — matches TASKS.md §2 turn definition; wall-clock rationale (3-15s per CPU inference round-trip on 9B).
- kernel-1 (986edc0b): 7/8 files landed; mid-iteration Sendable fixes observed; steered twice (errno Int32/Int, Amendment 2 batch seam). Awaiting their gate: build green + MerlinChecks green.
- Sequencing note: kernel-2 (actor+profiles, new files only) dispatches immediately after kernel-1's gate; kernel-3 (guardian + shell/js) follows — it edits ToolRegistry.swift (kernel-1's file), so it must not overlap kernel-1.

## 2026-11-15 — round 4: matrix complete, eval target live, harness dispatched

- M8 matrix extended to 6 families with live probes: Qwen3.5-9B-distilled → rung 1 (native byte-perfect; envelope also clean); Spark-X2.5-4B → rung 1 (dual-capable). Matrix in MODEL-PROFILES-EVIDENCE.md now covers Spark-1.7B/4B, LFM2.5-2.6B, R1-8B, Qwen3.5-9B, GLM-4-9B — the full headline bench.
- Lead: `merlin-eval` executable target created (Sources/MerlinEval, Package.swift lead-owned edit) — stub builds and runs: "Build of product 'merlin-eval' complete".
- Dispatched eval-harness (2fbac216, slice 4b): task loader, seeder + immutable-seed hashing, 5-kind assertion engine (exact TASKS.md §3 semantics), turn-driver seam (scripted + naive-baseline drivers), harness-side tool executor, SCORING.md §1-§3 metrics, scorecard/report generators, CLI, self-test proof incl. intentional-fail cases (T14 thrash variant, seed-drift tamper).
- kernel-1: converging (early builds show Sendable capture fixes in progress; main.swift wiring MerlinKernel). Diagnosis worker running live repro on port 8147 (its own server, hands off).

## 2026-11-15 — round 5: probe contracts persisted, scoring protocol ratified

- Lead: ACTOR-CONTRACT-PROBES.md written — verbatim native-tools + json_schema envelope bodies preserved (was /tmp-only) + the slice-2 soak protocol (20/20 valid calls on Spark-1.7B rung-1 + GLM-9B rung-2; R1 think-budget refusal check).
- SCORING.md full review complete: baseline protocol ratified by lead — naive-loop definition per-system (M0-M8 off table), fairness rules (same weights/server/sampling, interleaved runs, one parse-retry allowance), suite gate = 14/14 on ≥2 bench models + axis gates, anti-rationalization clause, suite frozen as merlin-eval-v1 (v2 + re-baseline for any change).
- Bench for slice 4c confirmed: GLM-4-9B, Qwen3.5-9B-distilled, LFM2.5-8B-A1B (SCORING.md §5) + Spark-X2.5-1.7B as the fast smoke model.
- kernel-1: 9 strict-concurrency errors remaining (converging); eval-harness scaffold in progress; diag repros still running.

## 2026-11-15 — round 6: slice 2 dispatched early, batch seam verified

- Lead review: Amendment-2 batch seam FULLY landed in MerlinKernel.swift (protocol `toolCalls -> [MerlinToolCall]`, batch clamped to maxCallsPerTurn, ordered execution, mid-batch task_done honored, out-of-contract batches ledgered not trusted). Actor protocol now stable → slice 2 dispatch unblocked early.
- Dispatched kernel-2 (4ef53deb): ProfileStore (family detection, rung matrix, auto-promotion), LlamaServerActor (M1 ladder: native/envelope/rescue + hallucination flag + think-budget refusal), ToolSchema catalog (10 tools), MerlinChecks2, live soak 20/20 on Spark-1.7B + GLM-9B. Files: ProfileStore/LlamaServerActor/ToolSchema/MerlinChecks2 only — no overlap with kernel-1 (which still owns Kernel/ToolRegistry/Retry/Workspace/Ledger/TaskSpine + MerlinChecks).
- merlin target reached 0 build errors mid-round; CLI smoke test green (spine renders goal/blockers/artifacts/tool contract; workspace + ledger created). kernel-1's remaining gate: its own MerlinChecks.swift + suite green.

## 2026-11-15 — round 7: SLICE 0 CLOSED — the before-picture is now measured

- Diagnosis worker (40e697f2) DELIVERED and closed early per lead steer: 4 live repros (GLM-9B, R1-8B), 5 P0 / 8 P1 / 5 P2 findings with file:line, media-tools table (video broken: sd-cli binary absent; TTS nonexistent; media never wired as agent tools). Persisted to DIAGNOSIS.md with lead's Merlin-mapping merge note (each P0 → the Merlin system that kills it).
- Headline: legacy loop's "never completes anything" is architectural (rung coin-flip + friction wall + static budgets) — validating AMENDMENT 1's replacement decision with evidence.
- Cross-worker coordination handled: kernel-1 flagged eval-harness's JSONValue.swift breaking the whole-package build (4 lines: missing try ×3, nonexistent hexDigitValue); lead steered eval-harness with the exact fixes.
- kernel-1 status: its products build green (kestrel-checks + merlin products); MerlinChecks.swift landed; check binary run in progress → final report next.
- Workers active: kernel-1 (closing), kernel-2 (actor+profiles, in flight), eval-harness (harness core + the 4-line fix).

## 2026-11-15 — round 8-9: SLICE 1 CLOSED, SLICE 4b CLOSED, suite green, next wave dispatched

- kernel-1 CLOSED: 2,157 lines (Workspace/Ledger/TaskSpine/Retry/ToolRegistry/MerlinKernel + CLI + 30 checks). Two crash-class bugs found by its own checks: realpath(&buf) heap corruption (segfaulted shared binary) and resolvingSymlinksInPath missing symlinked-leaf escapes — both fixed. kernel-2 lldb later attributed the residual SIGSEGV to the RUNNER's stderr write in the boxed session (redirect to file = clean), not the check. Deviations accepted: Merlin-prefixed types (flat-module collisions), public API (cross-module need).
- kernel-2 gates 1+2 GREEN: whole package builds; **776 checks, 0 failures — lead independently reproduced**. R1 think-budget probe: 200-token completion REFUSED with loud ProfileError (floor 3512); floor+512 accepted. 20/20 soak on Spark-1.7B :8151 + GLM-9B :8152 in progress.
- eval-harness (4b) CLOSED: 12 files, 2,730 lines. Self-test 8/8: T01/T04/T06/T07/T12/T14-compliant pass; T14-thrashing correctly FAILS (budget_exhausted + stop_authority_rule); T06 seed-drift tamper caught via SHA-256 (auto-fail even with green tampered checker). Two harness bugs found+fixed (NSLock re-entrancy, run-dir collision). Suite location correction noted: eval/ lives in the mission folder.
- Lead: whole-package gate independently verified — "Executed 776 checks, 0 failures", exit 0.
- Dispatched kernel-3 (3162e2bc, slice 3): MerlinGuardian (M4), MerlinVerifier (M5, adversarial completion check w/ mechanical artifact gate + scripted-client model call), MerlinStopAuthority (M6 progress detector), MerlinShell (kernel-side shell/js_eval wiring), MerlinChecks3. Surgical-edit rights on MerlinKernel/ToolRegistry now that kernel-1 closed.
- Dispatched eval-live (2c6e6319, slice 4c-smoke): LiveDriver + baseline completion hook + first live numbers — full 14×2 matrix on Spark-1.7B (fast bench), interleaved per fairness rule, results to results/smoke-spark17/. Kernel edits by kernel-3 may interleave; contract includes build-retry protocol.

## 2026-11-15 — rounds 10-11: trust layer files landed, live driver converging, cross-slice routing

- kernel-3: all 4 source files landed (MerlinGuardian/MerlinVerifier/MerlinStopAuthority/MerlinShell); MerlinChecks3.swift on disk; suite re-run mid-convergence: 776/0 still. Whole-package errors peaked at 21 (their in-flight churn) → 0, then eval-live's LiveDriver introduced 5 new ones; kernel-3 flagged with exact lines (good citizenship).
- Lead routing decisions: (1) MerlinOutcome public convenience init hosted in kernel-3's MerlinVerifier.swift (KestrelCore-side; cross-module extensions can't assign struct stored props) + a pinning check; (2) eval-live fixes its own NSLock-from-async violations via sync withLock helper or actor; (3) no cross-file patching — last-lander retries whole package.
- eval-live: LiveDriver.swift landed and converging; smoke results pending (14×2 matrix on Spark-1.7B, ~30-90 min wall-clock).
- kernel-2 soak still live (GLM-9B CPU calls are 1-2 min each; 20-call drive + R1 refusal evidence already captured).

## 2026-11-15 — round 13 (budget extended to 20 by operator "continue"): slice 3 verified, slice 5 dispatched

- Lead independent verification: whole package "Build complete", check binary "Executed 816 checks, 0 failures", exit 0. 13 Merlin files + 13 MerlinEval files on disk.
- kernel-3 CLOSED (delivered): MerlinGuardian 222 (deterministic post-conditions + hallucination-vocabulary screen), MerlinVerifier 349 (artifact contract + scripted/injected LlamaVerifierClient + unchanged-ledger skip rule), MerlinStopAuthority 193 (signature streaks N=3 + wrapUpAdvisory in spine), MerlinShell 274 (env allowlist, SIGTERM→SIGKILL, JSContext with honest no-preemption doc), MerlinChecks3 899/40 checks. Surgical hunks documented on MerlinKernel (verifier/stop hooks, MerlinOutcome public init) and ToolRegistry (shell/js wired, task_done artifacts contract, timeout arg). Flagged deviation accepted: one stale stub test in MerlinChecks minimally rewritten.
- Goal: operator extended budget 12→20 via direct "continue" (goal re-armed, rev 4).
- AMENDMENT 3 authored: app integration behind toggle (default classic until eval gate passes; legacy retirement = separate operator gate after a release cycle).
- Dispatched app-1 (b006d320, slice 5): MerlinChatService (drives kernel against the app's ACTIVE server, cancellation at turn boundary, workspace under app store dir), settings toggle, minimal composer surface ("Run as Merlin task"), MerlinChecks4. ChatNative/ToolsService untouched.
- kernel-2 soak: still mid-drive (~25s/turn CPU); round-1 evidence banked (10/10 per model, 0 malformed, 0 hallucinated); close-with-deviation fallback agreed if not done in ~20 min.
- eval-live smoke: still running (results pending).

## 2026-11-15 — round 13 cont: SLICE 2 CLOSED — all kernel systems landed

- kernel-2 CLOSED: ProfileStore 294 (renamed MerlinProfileStore — collision with Sources/Servers/Profiles.swift:81 ProfileStore), LlamaServerActor 546 (M1 ladder + loud think-budget refusal + hallucination flag), ToolSchema 99 (live-registry-pinned catalog), MerlinChecks2 652/43 checks. Gates: merlin product green; 776/0; LIVE SOAK Spark-1.7B rung-1 10/10 + GLM-9B rung-2 10/10, zero malformed/hallucinated; R1 200-token loud refusal captured; servers killed, ports verified down.
- Deviations accepted: 10/10-per-rung instead of 20/20 (models emit 1 call/turn; 20-turn re-drive stalled on a HUNG server slot amid foreign traffic on the shared box; driver archived /tmp/merlin-soak/ for a quiet-box re-run). Slice-6 note: GLM rung-2 argument keys sometimes schema-sloppy → consider per-tool-argument envelope branches. Env note: check binary needs stderr→file in boxed sessions (runner's own stderr write raises ObjC exception).
- Mission count: 6 slices closed (0,1,2,4a,4b,3). Active: eval-live smoke, app-1 (slice 5). Queued: slice 6 tuning (after smoke), slice 7 docs.
- All nine Merlin systems (M0-M8) now exist in code, checked and green.

## 2026-11-15 — round 13 cont: SLICE 2 closed; live-found kernel bug re-dispatched to kernel-3

- kernel-2 CLOSED (see prior entry). Mission count: 6 slices closed.
- eval-live mid-run report routed THREE findings:
  1. KERNEL BUG (P0, live-proven): kernel never appends assistant/tool turns to the actor transcript — model blind to its own prior calls (T01 probe: 6/6 identical fs_read, budget death). eval-live worked around harness-side (LiveMerlinActor implements the declared transcript shape via public API). RE-DISPATCHED kernel-3 (their files): feedback seam in MerlinKernel (+actor if needed), stop-authority + guardian rejections folded into conversation, backward compat, new checks. URGENT: app-1 drives the kernel directly and inherits the bug otherwise.
  2. Server stability: llama-server wedges after slot-release/LRU-reuse with cache_prompt:true — workaround cache_prompt:false + 420s timeouts. Also: all box llama-servers killed simultaneously ~12:55 by external cause (memory-pressure/fleet cleanup) — if any worker reports connection-lost mid-run, that's why.
  3. Profile note: Spark-X2.5-1.7B emits reasoning_content (eats budget); ProfileStore templateNotes say "no think budget" — re-probe queued for slice 6 tuning.
- Smoke matrix running: 14×2 interleaved, wall guard 600s/task, port 8178, ~60-90 min.

## 2026-11-15 — round 13 cont: transcript feedback seam FIXED (re-dispatch closed)

- kernel-3 re-dispatch DELIVERED: MerlinActorWithFeedback protocol + MerlinTurnFeedback payload; kernel probes actor with as?, calls receive() once per batch; LlamaServerActor conforms (assistant tool_calls turn + role:"tool" turns + RUNTIME instruction turns — guardian/verifier/stop-authority reach the model as conversation). Backward compat check-pinned. New checks incl. THE bug-fix proof: scripted-HTTP stock actor turn-2 request == [system, user, assistant(tool_calls), tool(result), user].
- Lead independent verification: whole package builds (app-1's ChatSettingsView compiles inside it), 821 checks 0 failures.
- State: kernel core (M0-M8 + feedback seam) complete and green; eval-live smoke matrix running against post-fix build region; app-1 service file landed, wiring in progress; slice 6 tuning + slice 7 docs queued.

## 2026-11-15 — round 13 cont: SLICE 5 CLOSED — Merlin is in the app

- app-1 CLOSED: MerlinChatService 599 (kernel stack on the app's ACTIVE port/model — no second server; guardian+verifier ON; ledger-polled progress at 100ms; cancel at turn boundary, honest UI help), MerlinChecks4 443/9 checks, surgical hunks: ChatTab +7 (context modifier), ChatAdvancedSettingsSection +32 ("Agent engine" Merlin|Classic picker, default classic per AMENDMENT 3). Surface: right-click "Run as Merlin task" consumes composer draft; live monospace progress fence; "### Merlin run · <status>" outcome card. Legacy loop untouched. Post-fix MerlinActorWithFeedback shape honored (wrapper conforms — pinned by check).
- Deviations accepted: settings key declared in MerlinChatService.swift (Support.swift outside writable set + settings-law tests parse it as truth — move on default-flip); check-only overrides in buildRuntime (no-socket doctrine); monospace fallback instead of tool cards (M2 ledger deliberately stores no args).
- Lead verified earlier this round: whole package green, 830 checks 0 failures.
- Mission count: 7 slices closed (0,1,2,3+re-dispatch,4a,4b,5). Active: eval-live smoke. Queued: slice 6 tuning (needs smoke), slice 7 docs.

## 2026-11-15 — round 14: SLICE 4c-SMOKE CLOSED (environment-limited); depth wave dispatched (tuning, security audit, docs)

- eval-live CLOSED: reduced gate 6×2 on Spark-1.7B, port 8180. T01 PASS both modes (3t, 88s/65s) = pipeline proven end-to-end (kernel+actor+harness+scoring). 10/12 remaining cells = HARNESS_EVENT:wedge (server accept-then-silence signature, ~421s/601s stops, hit both modes equally — NOT a machinery verdict). Earlier same-day probes: T14-merlin textbook voluntary stop (BLOCKED.md → task_done 3/8), T12 recovery per design. Deliverables: out.txt/report.json(+per-mode)/NOTES.md/runs/ tree. Wedge mitigation codified: 420s request timeout, wall guard, one-retry-then-harness_event policy. Eval-validity catch: first attempt placed wire logs inside task workspace — model READ them; caught, moved to ~/Library/Caches/merlin-eval-wirelogs/, aborted run preserved. All 4 of its servers killed, ports verified down.
- Operator requested depth coverage ("more in depth not wide") — dispatched the final wave in parallel:
  1. tuning (a2c5e72c, slice 6): GLM per-tool-argument envelope branches (profile option), Spark reasoning_content re-probe + profile fix, wedge-retry policy codified in LiveDriver, kernel progress-callback seam (non-breaking Configuration.onEvent).
  2. security auditor (67677f30): adversarial review of ALL trust boundaries (workspace confinement, shell, JSContext, registry, verifier gaming, profile persistence, transcript-injection-to-human vector, harness ShellRunner) → SECURITY-REVIEW.md with enforced/detected/OPEN ranking + top-3 attack narratives + minimal fix list. Audit only, no fixes.
  3. docs (e928b8ba, slice 7): docs/merlin.md (operator+developer, 250-400 lines) + CHANGELOG unreleased Merlin entry (preserving prior uncommitted sections).
- Commit gate: after these three land + whole-package green, the Merlin commit/push awaits operator approval (irreversible action doctrine).

## 2026-11-15/16 — MISSION CLOSE-OUT: all 11 workers closed; final state verified

- SLICE 7 docs CLOSED: docs/merlin.md (291 lines: operator + developer + security posture deferring to SECURITY-REVIEW.md) + CHANGELOG `## [Unreleased] — Merlin agent kernel` at line 6 (insert-only proven: uniform +54 shift on 0.89.17/0.89.16; prior mission content preserved; version not bumped).
- SECURITY REVIEW CLOSED (audit-only): SECURITY-REVIEW.md 194 lines, 64 file:line citations, ~8,500 LOC across 27 files. ENFORCED: fs-tool path confinement (realpath incl. final symlink, write re-canonicalization), env-variable allowlist, output/time/call caps, literal fs_grep (no ReDoS), zero JSContext host exposure, eval seed-hash integrity. OPEN ranked: CRITICAL ledger-forgery via shell_run (ledger reservation covers fs tools only); HIGH shell_run unconfined + schema falsely advertises "network disabled" (+ grandchild-pipe hang via `x &`); HIGH js_eval infinite-loop = unrecoverable app DoS (cancel fires only at tool boundary); HIGH task_done rendered as live markdown in transcript = prompt-injection-to-human vector; plus verifier-prompt injection surface, eval command_ok executing model-authored files, APFS case-insensitive ledger-name bypass (MEDIUM), symlink TOCTOU (LOW). Minimal fix list included; FIXES ARE OPERATOR DECISIONS (not applied).
- Auditor path deviation handled by lead: deliverable landed at workspace-root .agents/ (wrong tree) — relocated into the repo mission folder, workspace .agents cleaned, no skills-tree drift.
- SLICE 6 tuning CLOSED: (1) GLM per-tool envelope grammar (.perToolSchemas) — NEGATIVE-CONTROL PROVEN: forced sloppy key emitted verbatim under sharedShape, unemittable under perToolSchemas (8/8 matrix); (2) Spark reasoning_content confirmed + floor 512→768 (probe-captured, counted in completion_tokens); (3) wedge policy codified (ServerSupervisor fresh-instance retry → permanent harness_event:wedge; lsof -sTCP:LISTEN bug found+fixed; both branches proven end-to-end); (4) MerlinKernel.Configuration.onEvent callback seam (fire-and-forget by type, exactly-once terminal, +2 checks).
- FINAL VERIFICATION (lead, twice): whole package builds; **Executed 838 checks, 0 failures**.
- DELIVERY STATE: engineering complete (kernel M0-M8 + actor/profiles + harness + app toggle + CLI + harness drivers + docs + CHANGELOG + evidence pack). REMAINING (operator decisions / next mission): (a) suite gate 14/14 on ≥2 models — requires quiet-box re-run (wedge is environmental; policy + retry machinery now in place); (b) security fixes for the CRITICAL/HIGH findings; (c) commit/push of the entire tree (incl. pre-mission slots patch); (d) media tools phase (post-core per Amendment 1).



















## 2026-11-15 evening — AMENDMENT 4: FULL-CLOSURE APPROVAL (operator: "approval for all the requests")

- Goal objective updated to closure scope: security fixes → eval gate on fixed tree → commit/push waves → conditional default-flip → media-tools staging.
- COMMIT WAVE 1 LANDED: 245b5c8 "fix(checks): per-port slot KV trees resolve inside the per-run store" — the pre-mission slots patch (8 files, +258/−54). Message notes the CHANGELOG carries the Merlin [Unreleased] section (file-level entanglement, declared). Not pushed yet — push after wave 2 lands.
- Dispatched security-hardening worker (c51fd595): SECURITY-REVIEW §3 items 1-5 — sandbox-exec confinement (workspace-write-only, no network, HOME→scratch, setpgid+kill(-pgid), bounded drain) with honest fallback if seatbelt unavailable; js_eval watchdog + MerlinChatService cancel-takeover (no more force-quit); schema honesty (kill the "network disabled" lie in ToolSchema/ToolRegistry/MerlinShell); case-fold ledger reservation; injection defanging (outcome summary plain-text, verifier first-line verdict + digest data-framing). Checks for every fix incl. a real confinement proof (curl/escape probes through the kernel path).
- Box state at dispatch: quiet (load 1.92, zero llama-servers) — eval re-run conditions good once hardening lands.

## 2026-11-15 night — CLOSURE EXECUTED: hardening landed, committed, pushed; eval gate launched

- Operator changed approval policy to never-ask + requested faster delivery with deeper orchestration. Lead re-sequenced: commit decoupled from eval verdict (850/0 is the shipping bar; the gate gates only the default-flip); media-phase plan staged in parallel (MEDIA-PHASE-PLAN.md: tts_say → image_gen → transcribe, each eval-gated, explicit non-goals).
- SECURITY WAVE 2 LANDED (c51fd595): all five §3 fixes — seatbelt-first shell confinement with runtime probe (screening fallback honest; the session's probe failure PROVEN to be Seatbelt no-nesting, not a macOS bug — three independent proofs), MerlinProcessGroup POSIX_SPAWN_SETPGROUP + kill(-pgid) ladder + bounded drain (mirrored into eval ShellRunner), js_eval watchdog + app cancel-takeover ("run did not return" — no more force-quit), injection defanging (outcome fenced inert + verifier BEGIN DATA framing + first-line verdict), case-folded ledger reservation. Schema honesty: modelFacingDescription() single-sources the tool description — the "network disabled" lie is gone. 850 checks 0 failures (lead-verified). Release build green (226s). Residual limitations documented in-code (js_eval thread leak pending a child-process target; textual ledger screen; screening-mode token-scan).
- COMMITS (pushed to 0xda7/kestrel main, c971109..be87169):
  - 245b5c8 fix(checks): slots patch (wave 1, pre-mission work).
  - 45cc425 feat(merlin): kernel + harness + tooling (33 files, +12,521).
  - e303fea feat(chat): Merlin app surfaces (toggle, task runner, injection-safe outcome rendering).
  - be87169 docs(merlin): runbook + CHANGELOG + full evidence pack (116 files).
- EVAL GATE LAUNCHED (eb5ec96e, background): full 14×2 matrix, sequential models (Spark-1.7B + Qwen3.5-9B priority), interleave + wedge-retry on, runs-root inside mission folder, GLM excluded unless time permits. Verdict per SCORING.md §5 on the committed tree.

## 2026-11-15 late night — RELEASE v0.90.0 CUT (operator: "update my kestrel version with the latest release")

- Version 0.89.17 → 0.90.0 (minor: big feature, no breaking changes). AboutTab.swift version + CHANGELOG [Unreleased]→[0.90.0] — 2026-11-16 with outcome-first intro stating the honest eval-gate-pending status. Commit d6bb1e2, tag v0.90.0, pushed — tag verified on remote (gh api: v0.90.0 @ d6bb1e2). Gates closed pre-tag: 850 checks 0 failures on the versioned tree; release product builds.
- DMG packaging dispatched (a0fefd4b) per release-contract last mile ("published is not installable"): build from tagged commit, mount-verify version + bundled llama-server, launch smoke. dist/ currently holds Kestrel-v0.87.9.dmg (two releases stale) — being replaced.
- Eval gate mid-flight on Spark (matrix 2 after a wedge-cascade abort preserved as INCIDENT-01: supervisor's 10s port-free window was shorter than the wedged server's SIGTERM latency — BUG-1 reported not fixed, tree-is-judged doctrine held; worker self-managed relaunch). Worker protocol performing as designed: honest per-cell outcomes, incidents preserved.
- Release scope decision recorded: the eval gate verdict gates ONLY the Merlin-default flip; the release ships the code (kernel + security wave, 850/0). Gate report + any default-flip follow in the gate worker's wake.

## 2026-11-15 late night — RELEASE PUBLISHED: v0.90.0 live on the update feed

- CI tag run 43808911178 SUCCESS: standard + noavx2 variants built, Developer-ID signed/notarized per repo secrets, Publish release step green. GitHub Release v0.90.0 live with Kestrel-v0.90.0.dmg + Kestrel-v0.90.0-noavx2.dmg + checksums.txt. Updater smoke: /releases/latest returns v0.90.0 with exactly those assets — installed Kestrels (0.87.x-0.89.x) will see the update.
- Local DMG (dist/Kestrel-v0.90.0.dmg, SHA-256 8dea1595…) remains the ad-hoc-signed local artifact; the CI artifacts are the feed-canonical ones.
- CI fast-gate failure on main (LiveWindowTruthTests engine-pinned check vs no engines on runner) fixed forward: 8d4aed4 — the test job now builds the vendored engines (cached) before the suite, 40-min budget. Root cause predates Merlin (Census W5-5 ordering vs the new 850-check full suite on pushes).
- Post-release [Unreleased] changelog section: will reopen with the next code change (gate-verdict/default-flip commit).

## 2026-11-16 — gate progress + fast-gate fix confirmed

- CI main-push run (94244d3): completed/success — the engines-prerequisite + vendored-path fix holds; the push fast gate is permanently green (850 checks incl. Merlin's 135 on every push now).
- Eval gate, Spark matrix 3: T01 ✔/✔ (3t both), **T02 merlin ✔(4t) vs baseline ✘(8t budget)** — first clean merlin-vs-baseline separation of the formal gate, on the axis the suite predicts (spine+ledger vs raw transcript). T03 merlin running. Wedge-retry restarts logged and self-managed.

## 2026-11-16 00:18 — gate tally checkpoint (16/28 cells)

- merlin 3✔ (T01 3t, T02 8t, T05 5t) vs baseline 2✔ (T01 3t, T05 8t) — merlin ahead + faster on shared passes (T05: 5t vs 8t).
- T03/T04/T06/T07 failed both modes; T04-b(1t)/T06-b(2t)/T07-b(1t)/T07-m(0t) budget-stops carry the wedge signature (wall-guard class, wedges.log).
- Worker eb5ec96e continues autonomously; GATE-REPORT.md lands with the formal §5 verdict. Delta so far: merlin +1 pass, −3 turns on shared passes.

## 2026-11-16 03:07 — GATE CLOSED: Spark-only verdict, FAIL (operator decision)

- Qwen leg found dead at 02:49 PT (llama-server :8302 "second interrupt, terminating"; watchdog quiet, port dead, no processes) at 6/28 cells. Operator chose "verdict on Spark only" — no re-run authorized; Qwen artifacts preserved under results/gate-Qwen3.5-9B/.
- Spark leg complete (28/28): merlin 4/14 (axes A✔ B✘ C✘ D✘ E✘) vs baseline 2/14 (all axes ✘, 12/14 budget-dead, wedge-eaten windows). Suite gate = 14/14 → **MERLIN GATE: FAIL**. Merlin-default flip NOT taken; Agent engine stays opt-in behind the toggle. GATE-REPORT.md written.
- Machinery signal (not gate): clean separations T02/T14, faster shared passes T05 (5t/148s vs 8t/451s); wedge retry recovered 9/11. Merlinspecific failure mode = 6 actor_failed cells (T03/T06/T08/T10/T11/T12) → next kernel work item.
- analyze.py schema bug found + fixed during report writing (report emits `pass`, analyzer read `passed` → false 0/14 both modes). Fixed analyzer verified against matrix-run.log ✔ lines and the runner's own summary table (4/14, 2/14 — agree).
- Uncommitted: journal.md, results/GATE-REPORT.md, gate-*/ evidence, analyze.py fix. No commit/push ordered for these yet.

## 2026-11-16 evening — actor_failed class closed: kernel survives parse-class actor failures

- **Root cause of the 6 actor_failed cells (the gate's "next kernel work item"):** every cell died to
  `[nativeTools] response carried no parseable tool calls` — the kernel treated ONE content-only
  completion as machinery death (MerlinKernel catch: instant `.failed`), while tool errors, guardian
  and verifier rejections all fed back correctively. Small models narrate instead of calling; several
  cells died mid-progress (T03 had reorganized half the workspace at turn 5).
- **Fix (MerlinKernel + LlamaServerActor):** `ActorError` now carries `parseFailure` / `responseExcerpt`
  / `finishReason`. Parse-class failures (server answered, no usable call) are ledgered as blockers,
  fed back through the new `receiveActorFailure` seam (offending narration as assistant turn +
  corrective instruction as user turn), bounded by the stop authority's repeat threshold (3 consecutive
  → honest `.failed`); any parsed batch resets the streak. Transport-class failures stay instantly
  fatal (harness owns restart). Empty-batch path untouched (checks rely on it).
- **Pinned by 6 new checks** (MerlinChecks3): survive-and-correct, threshold bound, streak reset,
  transport-fatal, error carries excerpt+finish_reason, transcript correction shape. Full suite:
  **860 checks, 0 failures** (was 850).
- **Live verification, 6 cells re-run on Spark (fresh-server protocols):** zero parse-class failures
  anywhere. T03 actor_failed@5t→budget@14t · T06 @12t→budget@14t · T10 @3t→**task_done@5t (voluntary)** ·
  T11 @4t→**task_done@9t (voluntary)** · T12 @9t→budget@14t · T08 → harness_event_wedge on all 3 attempts
  (the documented llama-server wedge class — engine defect, not kernel; cell unmeasurable until that
  class is fixed). Pass-rate still 0/6 on merits — honest: the 1.7B doesn't clear the suite; what
  changed is the machinery no longer kills runs prematurely.
- **Protocol note:** first fresh-server protocol had a bind race (3s pkill wait < the engine's
  documented SIGTERM latency — BUG-1 class); corrected script waits for port-free + verifies the
  listener pid is the launched pid.
- **Release hygiene (the 0.90.0 drift):** v0.90.0 shipped with VERSION=0.89.17 (hand-cut release
  bypassed release.sh's VERSION stamp; AboutTab was correct, only VERSION lagged). Reconciled:
  VERSION=0.90.1 + AboutTab=0.90.1 (exactly make-app.sh's post-release bump). New
  ReleaseHygieneChecks suite (4 checks) makes the drift class build-breaking: VERSION format,
  AboutTab==VERSION, CHANGELOG never stamps ahead of VERSION, newest stamped section has its tag
  (shallow-CI skip is explicit). Negative proof: regressing VERSION to 0.89.17 → 2 failures, exit 1,
  naming the drift. Restored; suite 860/0.
- Uncommitted: MerlinKernel.swift, LlamaServerActor.swift, MerlinChecks3.swift (+6 checks),
  ReleaseHygieneChecks.swift, CheckRegistry+Generated.swift, VERSION, AboutTab.swift. Evidence:
  results/actorfix-rerun/, results/actorfix-rerun-cells/, results/actorfix-rerun-fix/.
