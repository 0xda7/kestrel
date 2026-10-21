# MISSION: Flawless Kestrel — the Perfected Operator Request

## The operator's request, VERBATIM (2026-10-14)

> "i need to fix the audit, i need the Kestrel engine to work flawlessly
> end to end ...every line of code needs to be written, done and
> delivered tested and secured. is this clear ? The functions that
> current Kestrel has need to be left as they are. Do not modify, do not
> cripple and do not fuck up what i am asking."

## Perfected into engineering requirements

### R1 — Close the audit completely
Every finding from the 2026-10-14 audit (28 confirmed; 27 code-fixed,
1 open) is verified closed **in the installed build**, each with its
receipt: the check that pins it, and where applicable the on-disk or
runtime evidence. The single open item — live verification of the agent
boot fix — is closed with a real end-to-end run and its captured output.

### R2 — The engine works flawlessly end to end
Every existing user-facing flow is traced from UI to engine and back,
and verified: server start/stop on any card, model load and switch,
chat send/stream/stop, the context bar's accounting, tool calls,
providers, logs. Defects found on these paths are fixed as
**behavior-preserving corrections** — the flaw is removed, the function
stays exactly as it is.

### R3 — Every line delivered, tested, secured
- Nothing is declared done that is not in the repo, compiled by the
  green check suite, built by make-app.sh, and installed.
- Security posture re-verified after all fixes: file permissions on
  every secret path, argv/env redaction in every log surface, loopback
  binding rules, no credential leakage between processes.
- Each fix adds or extends a check that fails without it.

### R4 — FUNCTION FREEZE (the operator's hard constraint)
- **No feature modifications. No renames. No removals. No new
  capabilities. No restructuring.** Existing functions are left as they
  are.
- Allowed edits: bug fixes, security hardening, dead-path corrections
  that cannot change reachable behavior, test additions, docs that
  match shipped reality.
- Any proposed change that would alter user-visible behavior is
  ESCALATED to the operator with the exact diff — never applied
  unilaterally.

## Execution order

1. Suite baseline: `scripts/test.sh` green on the current HEAD.
2. Audit closure verification pass (R1) with receipts.
3. End-to-end flow verification (R2); flaw list; behavior-preserving
   fixes under R4, each with a pinning check.
4. Security re-verification (R3).
5. Ship once: suite green → `make-app.sh` → install → report with every
   receipt.

## Completion definition (nothing less counts)

Suite green; app built and installed; audit closed with receipts;
flows verified; every fix pinned by a check; zero behavior changes
beyond defect correction; operator report with evidence for every claim.
