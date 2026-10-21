# Mission C2 — Typed settings IO registry (W4 drift class): implementation report

Repo: ~/KimiK3_Nvidia/Kestrel-AIEngine, main, base 152d5d9 → final 478d3c9. NO push. Tree clean.

## Commits (4, conventional, one logical fix each, D8 trailers on all; User-preference trailer on the final)

1. `d178b7e` test(settings): pin seeded type-drift RED on pre-conversion readers
   - TypedSettingsDriftTests (4 checks): W4-7 gate drill ("on" under apiKeyEnabled → gate un-armed),
     ctx "garbage"/port "9999", VAD "0.35", loadVision "off".
   - RED evidence on pre-conversion code: `Executed 473 checks, 6 failures` — exactly the 4 new drift
     checks (6 assert lines); 469 baseline all green. Recorded in the commit body.
2. `23dcea5` fix(servers): keep the API-key gate armed under settings type drift (W4-7)
   - SettingsNumericCoercion → full registry machinery: Kind (+bool/boolFailSafe/stringArray/
     stringDictionary), typed readers int/double/bool(+IfPresent), once-per-key drift reporting
     (AppLog.settings, OSAllocatedUnfairLock), Bool migration/import incl. gate fail-safe.
   - ServerSettings.apiKeyGateArmed(defaults:) — the gate's one decision point; activeAPIKey() and
     the Bonjour TXT "auth: bearer" route through it; fromDefaults int/bool helpers route through
     the registry (all ~50 call sites unchanged). All Bool states registered (42+gate).
   - Gate pins GREEN (drill closed); numeric pins still RED by design (next commit registers them).
3. `3196d1f` refactor(settings): full key→Kind registry for every numeric/Bool reader (W4-1..W4-10)
   - Registry grows to 101 keys (36 Int, 22 Double, 42 Bool, 1 boolFailSafe gate).
   - Readers converted: fromDefaults (+splitGroupSize), Hardware ctx (W4-2), ImageGen legacyConfig
     (W4-3, present-only overrides → defaults single-sourced in ImageInstanceConfig members),
     Audio VAD (W4-4), tri-state chatAutoCompact/updateAutoCheck (W4-5), agentTools/jsSandbox
     (W4-6), forcePrivateBuffers/imagenCleanupOnClose (W4-8/9), as?-fallback group (W4-10), plus
     multiGPU/autoStart/routerMode found by the completeness sweep.
   - Single-sourced defaults: ServerSettings.defaultCtx (16384, fromDefaults+Hardware),
     ChatDefaults.agenticMaxTurns (10, reader + 2 @AppStorage + 2 reset writers), VAD view
     literals → AudioVADProfile.balanced.calibration.
   - TypedSettingsRegistryTests (9 checks) incl. the completeness contract (expected set ==
     Set(registry.keys), derived from every typed read shape incl. multi-line calls).
4. `478d3c9` fix(settings): surface drift in stringArray/dictionary readers (W4-11)
   - 12 collection keys registered (5 stringArray, 7 stringDictionary); 23 read sites converted
     (Support 1, Server 17 incl. the two-line dflashWarningAcknowledged calls, Models 5).
   - Absent stays silent-empty (legitimate); drift reported + empty; migration removes; import drops.
   - Completeness contract grows to 113 keys; 2 new checks.

## Gate evidence

- **swift build**: full clean rebuild (`.build/x86_64-apple-macosx/debug` removed) exit 0.
  **Zero NEW warnings**: 43 distinct warning sites before and after (matches the C1-recorded
  baseline); none in any changed line (the Updates/Support/Hardware warnings are the pre-existing
  init(cString:)/actor-isolation sites, line-shifted by insertions).
- **kestrel-checks green TWICE on the final commit** (`478d3c9`): `Executed 487 checks, 0 failures`
  — run twice (469 baseline + 18 new: 7 TypedSettingsDriftTests + 11 TypedSettingsRegistryTests).
  A third double-run pair on content-identical pre-amend commit e6edcc7 also 487/0 ×2.
- **Sabotage drill (i)** — remove one registry entry (ubatch):
  `FAIL TypedSettingsRegistryTests.testRegistryIsComplete` (diff names the missing key: add:
  ["ubatch"]) AND `FAIL testMigrationRewritesNumericsTyped` (key stopped migrating — the W4
  recurrence made visible). Restored → 485/0. Run at commit 3.
- **Sabotage drill (ii)** — demote apiKeyEnabled to plain .bool:
  `FAIL TypedSettingsDriftTests.testAPIKeyGateStaysArmedUnderDrift` (via activeAPIKey),
  `FAIL testGateDecisionFailsSafe` (×3 strings), `FAIL testGateMigrationAndImportFailSafe`
  (garbage migrated to off). Restored → 485/0.
- **Sweeps**: zero direct `.bool/.integer/.double(forKey: SettingsKeys…)`, `as? Bool/Int/Double`,
  `stringArray/dictionary(forKey: SettingsKeys…)` reads remain outside the registry.

## Key discovery (recorded in code comments + commit bodies)

Foundation's UserDefaults readers PARSE what they can: bool(forKey:) recognizes only true/yes/1
(so "on" — the classic legacy-true spelling — reads FALSE: the un-arming vector); integer/double
coerce numeric strings (engine runs "9999" while the @AppStorage UI shows 8080 — the chatTemp
split-brain class); everything else silently zeros. Both silent paths are now reported; drift
yields the declared default (or fails SAFE for the gate). Probed empirically; probe results in the
d178b7e commit body.

## §E re-derivation result

Discrepancy vs the task's list: `dflashWarningAcknowledged` (multi-line stringArray read,
Server.swift:2703/2725) was missing — registered and converted. No other differences: registry
final = 113 keys = 36 Int + 22 Double + 42 Bool + 1 boolFailSafe + 5 stringArray + 7
stringDictionary. benchAdvanced (dead, W7-1) deliberately NOT registered. parseBool accepts
true/false/1/0 case-insensitively (Foundation's "yes" parsing deliberately not honored — a
migration honors only this app's writer spellings; documented in code).

## Acceptance-criteria mapping

1. build 0 exit, 0 new warnings (43=43); checks 487/0 twice on 478d3c9 ✓
2. W4-7 first: pin RED on pre-conversion (d178b7e, 473/6) → GREEN after (23dcea5+), drift reported
   (testGateDecisionFailsSafe asserts reportedDriftKeys) ✓ — census drill closed
3. Full registry W4-1..W4-10, tri-state preserved (testTriStateBoolAbsentMeansTrue), duplicated
   defaults single-sourced (chatAgenticMaxTurns → ChatDefaults.agenticMaxTurns; ctx →
   ServerSettings.defaultCtx; ImageGen member defaults; VAD balanced profile) ✓
4. W4-11 typed readers surface drift (testStringArrayDriftSurfaces/testDictionaryDriftSurfaces) ✓
5. migrateMistypedNumerics iterates the full registry (Bool/collections handled; pinned);
   SettingsArchive import routes through typedImportValue for all registered keys (plumbing
   unchanged at SettingsArchive.swift:39; testImportRoutesThroughRegistry + import-drop check) ✓
6. Completeness check with sabotage drill (i) RED-proof ✓
7. Conventional commits, D8 trailers ×4, User-preference trailer on final; no push; no version
   bumps; `git status --porcelain` empty ✓

## Deferred / out of scope (noticed, not touched)

- W4-12/liveCtx → W5-3 live-window fallback (census cross-ref; C5 owns it).
- W5-2 slot-persistence launch-truth reads (persistCache/faAmd/loadVision are now drift-safe but
  still read-time, not launch-truth).
- The 43 pre-existing warning sites (baseline; e.g. Tests 'try must precede await', Support
  init(cString:) deprecations).
- benchAdvanced dead key (W7-1) and the W7-2 legacy imagen* keys still declared (legacyConfig is
  now the registry-typed sole reader, as the census conversion requires).
- UserDefaults.synchronize-based persistence of the kestrel-checks process domain (pins clean up
  via defer + tearDown; verified by repeat green runs).
