# Kestrel Upgrade Plan — The Decision-Native AI Workbench

Supervision model: the Atomic agent builds; the supervisor (this session's
lead) approves every proposal before implementation and accepts nothing
that is not suite-green, built, and installed. Standard: code an outside
architect reads for inspiration — typed boundaries, no dead paths, every
capability reachable from the UI, every fix pinned by a check.

## Phase 1 — Native Decisions tab (the Laya product surface)

The service layer exists (LayaDecideService, /v1/systemone, opt-in chat
tool). Build the full UI:

- New "Decisions" section: document input (file picker + paste),
  question-set manager (create/edit/delete JSON sets in laya-questions,
  seeded Medical Triage), run button with live engine-card awareness.
- Decision cards rendered natively: choice with per-option confidence
  bars, yes/no with probability, anchored score — no terminal text.
- Port truth: read the Laya card's actual profile port (kills the 8098
  hardcode class permanently); health state derived from the card.
- Run history: every decision stored (document name, set, answers,
  confidence, timestamp) in Application Support/laya-runs.
- Export: CSV + JSON.
- Acceptance: checks for set CRUD, run persistence, port resolution,
  export shape; suite green; tab reachable and usable by hand.

## Phase 2 — Laya as the router (the cost engine)

- Incoming chat message → one Laya pass (~33 ms) decides: answer directly,
  local big model, or a remote provider route.
- Router question set is data (JSON), not code; the operator can retune
  routing without a build.
- Every routing decision logged beside the run (audit trail).
- Acceptance: routing decision check with a fixture response; fallback to
  local model on any Laya failure (never a dead chat).

## Phase 3 — Research mode (the crawl loop)

- Loop: fetch page → Laya decides follow/skip/extract → big model
  synthesizes the harvest. Budgeted (max pages, max depth) and logged.
- Same-loop capability for local folders: triage N documents against a
  set, deep-read the keepers only.
- Acceptance: loop bound respected under all outcomes; cancellation
  works mid-run; results exported.

## Phase 4 — Enterprise audit trail

- One decision log (chat tool runs, tab runs, router, research) with
  query, answers, confidence, model, timestamp; viewable, exportable,
  prunable by date. This is the compliance surface.

## Phase 5 — Capability verification sweep

- Re-run the audit workflow's capability lens against the finished
  product; every UI control verified wired; the operator manual updated
  to match shipped reality.

## Standing engineering rules (every phase)

1. No hardcoded values that a user can change in the UI — read the truth.
2. Every new capability: reachable from the UI, documented in the manual,
   pinned by at least one check that fails without it.
3. Nothing ships red: scripts/test.sh is the gate; make-app.sh + install
   is the ship step; both outputs shown.
4. No new entanglement: no shared state with other products, no hidden
   logins, no background processes the operator didn't start.
5. English only.
