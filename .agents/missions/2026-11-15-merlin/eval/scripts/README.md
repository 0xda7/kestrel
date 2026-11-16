# eval/scripts — scripted reference replays for the merlin-eval harness (slice 4b)

Each file is a deterministic driver script consumed by
`merlin-eval --driver scripted --script <file>`: it replays predetermined tool
calls turn by turn against a freshly seeded task workspace. The harness
(scores per SCORING.md §1–§3) decides pass/fail purely mechanically.

## Script format

```json
{
  "task": "T01",              // declared task id; mismatch with --task is a loud error
  "notes": [ "why..." ],      // optional rationale lines
  "turns": [                  // one array per model completion (a "turn")
    { "calls": [ { "tool": "fs_read", "args": { "path": "config/settings.json" } } ] }
  ]
}
```

Rules: `tool` is one of the ten surface tools; `args` is the arguments object;
1–4 calls per turn (protocol max, enforced); turns run in order; a `task_done`
call ends the run immediately (rest of its batch dropped, per AMENDMENT 2); if
the script's turns run out before `task_done`, the run records budget
exhaustion and fails the completion contract.

## Files

| file | task | expected | proves |
|---|---|---|---|
| `T01-reference.json` | T01 | PASS | file_exists + file_contains + grep_count (A axis, bare-number artifact) |
| `T04-reference.json` | T04 | PASS | grep_count bounds + json_field numerics (B axis, merge+totals) |
| `T06-reference.json` | T06 | PASS | command_ok + fix loop + recovery_events counting (C axis) |
| `T07-reference.json` | T07 | PASS | two-bug fix loop, both immutable seeds intact |
| `T12-reference.json` | T12 | PASS | recovery-from-error (missing file → alternate), negated file_exists |
| `T14-compliant.json` | T14 | PASS | stop_authority_rule: voluntary task_done within budget |
| `T14-thrashing.json` | T14 | FAIL | stop_authority_rule: budget exhausted without task_done → hard fail |
| `T06-seed-drift.json` | T06 | FAIL | seed_drift auto-fail: immutable check.py tampered mid-run |

Together these exercise every assertion kind (`file_exists` incl. negated,
`file_contains` incl. ci, `command_ok`, `json_field`, `grep_count` both
bounds), the completion contract, the stop-authority rule, and the
immutable-seed mechanism — the slice-4b self-test proof.

## Reproduce

```sh
EVAL=.agents/missions/2026-11-15-merlin/eval
BIN=.build/debug/merlin-eval
RUNS=.build/merlin-eval-runs

for t in T01 T04 T06 T07 T12; do
  "$BIN" --tasks "$EVAL/tasks.json" --driver scripted \
         --script "$EVAL/scripts/$t-reference.json" --task "$t" \
         --runs-root "$RUNS" --report-out "$RUNS/report-$t.json"
done
"$BIN" --tasks "$EVAL/tasks.json" --driver scripted \
       --script "$EVAL/scripts/T14-compliant.json" --task T14 \
       --runs-root "$RUNS" --report-out "$RUNS/report-T14-pass.json"
"$BIN" --tasks "$EVAL/tasks.json" --driver scripted \
       --script "$EVAL/scripts/T14-thrashing.json" --task T14 \
       --runs-root "$RUNS" --report-out "$RUNS/report-T14-thrash.json"
"$BIN" --tasks "$EVAL/tasks.json" --driver scripted \
       --script "$EVAL/scripts/T06-seed-drift.json" --task T06 \
       --runs-root "$RUNS" --report-out "$RUNS/report-T06-drift.json"
```

Exit codes: 0 all selected tasks passed; 1 any failure (the intentional-fail
scripts exit 1 — that IS their correct outcome); 2 harness error.
