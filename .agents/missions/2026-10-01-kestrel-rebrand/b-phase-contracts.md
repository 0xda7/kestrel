# B-PHASE FIX CONTRACTS (step 8) — skeleton; failures injected at dispatch time

Dispatched ONLY after step-7 orchestrator gate produces the residual list.
Model: glm-5.3-flash (mechanical fixes on cheap tier). Three disjoint scopes.

## Shared preamble (all B agents)
You are B<2>N>, the fix pass for the Kestrel rebrand. Pass-1 agents missed or mishandled the items
below. Read .agents/missions/2026-10-01-kestrel-rebrand/agent-brief.md first — same mapping,
same HARD EXCEPTIONS (TOSH_ env names, tosh_ C symbols, upstream credits), same JSON return schema.
Fix EXACTLY the items in your list plus anything your own gate grep finds in your scope.
Do not touch files outside your scope. Do not run swift build/test. Do not commit.
Gate: re-run the greps from the brief on your scope; every remaining match classified.

## B1 — engine surfaces (patches/ + reference/ + scripts/)
Failure list: <injected at dispatch: A1 residuals + any patch-hunk violations>

## B2 — Swift application surfaces (Sources/** + Tests/ + Package.swift)
Failure list: <injected: A2/A3/A4 residuals + compile-break lines if any>

## B3 — meta/packaging surfaces (scripts/ .github/ docs/ Assets/ top-level meta)
Failure list: <injected: A5 residuals + Assets minified-asset flags>
