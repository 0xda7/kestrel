# Deep-Clean Mission — Kestrel full-version advancement

Runs after Phase 1 lands. One repo, one agent at a time; the supervisor
gates every round. Goal: the version an outside engineer reads and finds
nothing dead, nothing duplicated, nothing lying.

## Ruling (applies to every change)

- Nothing embedded, nothing hardcoded: no model brand, no fixed port, no
  path the UI can change. Capabilities bind to engine endpoints; models,
  ports, and routes are operator data.
- The multi-server / multi-instance architecture is the foundation —
  every capability must compose with N running servers, not just the
  primary.

## Lenses

1. **Duplicates and double implementations.** Structural similarity pass
   over Sources/: near-identical functions, copy-paste view blocks,
   parallel code paths doing one job (candidates to verify:
   `arguments` vs `routerArguments` in Server.swift; card rendering
   duplication in ServerDetailView/DashboardTab; repeated redaction and
   export logic in LogsTab/Benchmarks). Consolidate to one
   implementation, one owner.
2. **Dead code and unreachable states.** Everything the previous audit
   flagged plus a fresh sweep: unreferenced types/functions (grep-proven),
   unreachable UI branches (isSpanish-always-false remnants the audit's
   fixes may have left behind), leftover localization halves, unused
   assets and scripts. Delete; do not comment out.
3. **UI truth.** Every control does exactly what its label claims, on
   every card (primary AND added servers): inert toggles, badges that
   overstate, buttons with no effect, states that can never occur. Each
   lie is either wired to truth or removed.
4. **Bugs and vulnerabilities (fresh eyes).** Beyond the 28 confirmed
   findings already fixed: error paths that swallow failures silently,
   force-unwraps, unowned data races, anything that can hang the UI
   thread.
5. **Garbage files.** Repo root, scripts/, Assets/: files nothing
   references; duplicates of docs; stale fixtures.

## Method and gates

- Per-module rounds (Servers, Chat, App/UI, Laya→Decisions, Benchmarks,
  Scripts/Assets), one commit per module: "clean(<module>): <what died>".
- `nice -n 15 ./scripts/test.sh` green after EVERY module round — red
  stops the round until fixed; checks updated where behavior contracts
  changed.
- No functional regressions: capabilities verified by their existing
  checks; a check deleted only with its feature.
- Supervisor review between rounds; ship (build + install) only at the
  end, once, with the full suite green.
