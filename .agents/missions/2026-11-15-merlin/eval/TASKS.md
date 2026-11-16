# MERLIN EVAL — Task Suite Specification (14 tasks, 5 axes)

**Mission:** 2026-11-15-merlin · **Suite:** `merlin-eval-v1` · **Status:** design (spec only)
**Machine-readable twin:** `tasks.json` (same directory). The two files are 1:1; `tasks.json` wins
on any accidental divergence, and this document is the rationale.

---

## 1. Purpose and design stance

This suite exists to prove the Merlin thesis: *the runtime supplies what small models lack —
memory, format discipline, verification — the model only reasons.* Therefore every task is
graded by a **mechanical gate**: file existence, file content, command exit codes, parsed JSON
fields, and regex counts. There is **no LLM judge, no human rubric, no style credit** anywhere
in the suite. A task is passed or failed by a shell one-liner's verdict.

Each axis isolates one structural small-model failure and each task names the Merlin systems
(M0–M8, plan.md §3) it stresses. The same suite runs twice per model — Merlin machinery ON and
a machinery-OFF baseline (see `SCORING.md` §7) — because the delta, not the absolute number, is
the mission claim.

## 2. Harness protocol (binding for every task)

| Rule | Value |
|---|---|
| Workspace | fresh sandbox dir per task, seeded from the task's `seed_files` before turn 1 |
| Turn | one model completion. Merlin executes up to **4 tool calls** per turn and returns all results before the next completion. `max_turns` counts model completions. |
| Tool surface | exactly the plan §3 surface: `fs_read`, `fs_write`, `fs_list`, `fs_grep`, `shell_run`, `js_eval`, `todo_write`, `todo_read`, `note_add`, `task_done` |
| Runtime | `python3` (stdlib only) and `/bin/sh` available inside the sandbox; no network, no network env |
| Completion contract | a run only finishes via `task_done`; harness records whether it came before the turn budget (voluntary) or the budget forced wrap-up |
| Immutability | tasks list `immutable_seeds`; the harness SHA-256-hashes those files at boot and re-verifies at scoring. Any drift fails the task outright. |
| Determinism | all seeded content is literal, static, and identical across repeats; nothing random, nothing time-dependent, no secrets |

## 3. Assertion kinds (the whole grading vocabulary)

| kind | params | pass condition |
|---|---|---|
| `file_exists` | `path`, `negated?` | file present at `path` (relative to workspace root); `negated:true` inverts — file must be **absent** |
| `file_contains` | `path`, `value` **or** `values`, `in_order?`, `ci?` | substring present (case-insensitive if `ci`); with `values` + `in_order:true` every value appears and in the given first-occurrence order |
| `command_ok` | `command` | `command` executed via `/bin/sh -c` from workspace root exits 0. Used read-only in this suite (`python3 check.py`, `test -s …`). |
| `json_field` | `path`, `field`, `equals`, `tolerance?` | file parses as JSON; dot-path lookup (`items.0.cost` = first array element) equals `equals`. Numbers compared with tolerance 1e-9; booleans/strings exact; no string↔number coercion. |
| `grep_count` | `path`, `pattern`, `count_gte?`, `count_lte?` | number of matching **lines** (`grep -E` extended regex) within `[count_gte, count_lte]` |

That is the complete grading language. Anything not expressible in these five kinds is out of
scope for this suite by design.

## 4. Difficulty tiers

- **Tier 1** — 1–2 tool actions, single artifact, no adaptation required.
- **Tier 2** — 3–8 actions, some reading/derivation, at most one adaptation.
- **Tier 3** — multi-iteration loop, cross-file join requiring reasoning, or chained failure adaptation.

No task exceeds 8 planned steps (mission constraint), so tier differences come from iteration
and reasoning depth, not horizon length.

## 5. Merlin systems under test (from plan.md §3)

| # | System | One-line mechanism |
|---|---|---|
| M0 | Task Spine | goal + plan sketch + last-result summary re-injected every turn |
| M1 | Constrained Actor | grammar-constrained tool-call JSON; malformed calls unemittable |
| M2 | Token-Efficient State | ledger + artifact files; ≤N-line summaries in context |
| M3 | Structured Memory | deterministic KV ledger + recall across turns |
| M4 | Guardian | post-condition checks; failures become explicit retry instructions |
| M5 | Verifier Persona | adversarial verify call at milestones; never trusts self-report |
| M6 | Stop Authority | turn budget + progress detector + completion contract |
| M7 | Retry Budgets | per-tool-class retry w/ backoff; retries never burn turn budget |
| M8 | Model Profiles | per-family prompt style, tool-call mode, thinking-tag handling |

M8 is partly harness-level (the profile is selected at run config), so tasks "stress" M8 where
profile choices change the outcome most: exact-argument tool calls (A-axis) and thinking-tag
handling during fix loops (C-axis). This is stated here so nobody later claims the suite
validates M8 end-to-end when it only exercises it.

## 6. Suite summary

| id | axis | tier | title | max turns | stresses |
|---|---|---|---|---|---|
| T01 | A | 1 | Read one field, report it | 6 | M1, M4, M8 |
| T02 | A | 1 | Locate the marker file | 8 | M1, M2, M4, M8 |
| T03 | B | 2 | Tidy into folders + index | 14 | M0, M2, M4 |
| T04 | B | 2 | Merge three CSVs + totals | 16 | M0, M2, M3, M4 |
| T05 | B | 2 | Apply config changes to a copy | 12 | M2, M3, M4 |
| T06 | C | 2 | Fix the invoice typo | 14 | M0, M4, M7, M8 |
| T07 | C | 3 | Fix the quote tool (two bugs) | 16 | M4, M5, M7, M8 |
| T08 | C | 3 | Fix the median edge case | 16 | M0, M4, M5, M7 |
| T09 | D | 2 | Final launch date + rollback owner | 16 | M1, M2, M3 |
| T10 | D | 3 | Build the restock plan (join) | 18 | M2, M3, M4, M5 |
| T11 | D | 2 | Rebuild the event timeline | 18 | M0, M2, M3 |
| T12 | E | 2 | Missing report, use the alternate | 14 | M3, M4, M5, M7 |
| T13 | E | 3 | Wrong path, broken build, fix the chain | 18 | M0, M4, M6, M7, M8 |
| T14 | E | 2 | The vault that cannot be opened | 8 | M0, M5, M6 |

Tier spread: 2 × tier-1, 8 × tier-2, 4 × tier-3. Axis spread: A=2, B=3, C=3, D=3, E=3.

---

## 7. AXIS A — single-tool precision (2 tasks)

Small models drift on exact arguments: wrong path, wrong field, invented values. A-axis
catches that with the narrowest possible loop: one precise read, one precise write.

### T01 — Read one field, report it

- **Axis / Tier:** A / 1 · **Max turns:** 6 · **Stresses:** M1 (exact `fs_read` + `fs_write` args), M4 (write postcondition), M8 (tool-call mode)

**Prompt (verbatim):**
```
Read config/settings.json and write the value of its "port" field into answer.txt.
answer.txt must contain just the number, nothing else.
```

**Seed files:**

`config/settings.json`
```json
{
  "service": "kestrel-report-gen",
  "port": 8085,
  "log_level": "info",
  "retries": 3
}
```

**Assertions:**
1. `file_exists` `answer.txt`
2. `file_contains` `answer.txt` value `"8085"`
3. `grep_count` `answer.txt` pattern `^8085$` count_gte 1 count_lte 1   (rejects "18085" or prose)

**Solver sketch:** `fs_read(config/settings.json)` → `fs_write(answer.txt, "8085")`. Two calls, one turn.

### T02 — Locate the marker file

- **Axis / Tier:** A / 1 · **Max turns:** 8 · **Stresses:** M1 (exact `fs_grep` args), M2 (result summary discipline), M4, M8

**Prompt (verbatim):**
```
Exactly one of the five .txt files in docs/ contains the string "K7-QX-4417".
Find it with a search and write that file's name (just the filename, for example
"alpha.txt") into marker.txt.
```

**Seed files:**

`docs/alpha.txt`
```
alpha: runbook draft, nothing flagged.
```
`docs/bravo.txt`
```
bravo: meeting followups, nothing flagged.
```
`docs/charlie.txt`
```
charlie: incident review
Marker: K7-QX-4417
status: resolved.
```
`docs/delta.txt`
```
delta: vendor list, nothing flagged.
```
`docs/echo.txt`
```
echo: onboarding notes, nothing flagged.
```

**Assertions:**
1. `file_exists` `marker.txt`
2. `file_contains` `marker.txt` value `"charlie.txt"`
3. `grep_count` `marker.txt` pattern `charlie\.txt` count_gte 1 count_lte 1   (writing all five names fails the lte)

**Solver sketch:** one `fs_grep` for `K7-QX-4417` → `fs_write(marker.txt, "charlie.txt")`.

---

## 8. AXIS B — multi-step file operations (3 tasks)

The failure mode here is lost-the-plot drift across 4–7 operations. All three tasks build
exactly one artifact from several sequential fs operations, well inside the 8-step ceiling.

### T03 — Tidy into folders + index

- **Axis / Tier:** B / 2 · **Max turns:** 14 · **Stresses:** M0 (holds the 3-rule instruction across moves), M2 (ledger of what moved where), M4 (postconditions)

**Prompt (verbatim):**
```
Tidy this workspace. Move the two files whose names start with "meeting_notes" into
notes/, the two .csv files into data/, and the two .md files into docs/.
Then write index.md at the workspace root listing all six files by their new path,
one per line.
```

**Seed files (all flat in workspace root):**

`meeting_notes_monday.txt`
```
Meeting notes — Monday
- demo prep owner: Ada
- open risk: license renewal
```
`meeting_notes_tuesday.txt`
```
Meeting notes — Tuesday
- license renewed
- demo moved to Thursday
```
`sales_q1.csv`
```
month,units
jan,120
feb,135
mar,150
```
`sales_q2.csv`
```
month,units
apr,141
may,158
jun,163
```
`how_to_run.md`
```
# How to run
1. load config
2. start service
3. check /health
```
`api_reference.md`
```
# API reference
GET /health -> {"status":"ok"}
POST /run -> starts a job
```

**Assertions:**
1. `file_exists` each of: `notes/meeting_notes_monday.txt`, `notes/meeting_notes_tuesday.txt`, `data/sales_q1.csv`, `data/sales_q2.csv`, `docs/how_to_run.md`, `docs/api_reference.md`   (6 assertions)
2. `file_exists` **negated** for each of the six original root paths   (6 assertions — moves, not copies)
3. `grep_count` `index.md` pattern `meeting_notes_monday|meeting_notes_tuesday|sales_q1|sales_q2|how_to_run|api_reference` count_gte 6

**Solver sketch:** six moves (`fs_read`+`fs_write`+delete, or harness-provided move semantics via read/write and the harness accepting writes into new dirs; the reference path is 6 writes + index) — one artifact (`index.md`) at the end.

### T04 — Merge three CSVs + totals

- **Axis / Tier:** B / 2 · **Max turns:** 16 · **Stresses:** M0, M2 (numbers held in ledger, not context), M3 (running totals), M4

**Prompt (verbatim):**
```
The three CSVs in data/ each have the header "item,units". Write data/all_regions.csv
containing that header exactly once, followed by all six data rows from the three files.
Then write data/totals.json mapping each item name to its total units across all regions,
in the shape {"widget": <n>, "gadget": <n>, "sprocket": <n>}.
```

**Seed files:**

`data/region_west.csv`
```
item,units
widget,12
gadget,5
```
`data/region_east.csv`
```
item,units
widget,8
sprocket,7
```
`data/region_north.csv`
```
item,units
gadget,4
widget,3
```

**Assertions:**
1. `file_exists` `data/all_regions.csv`
2. `grep_count` `data/all_regions.csv` pattern `^(widget|gadget|sprocket),` count_gte 6 count_lte 6   (exactly the 6 rows; header and duplicates fail)
3. `json_field` `data/totals.json` field `widget` equals `23`
4. `json_field` `data/totals.json` field `gadget` equals `9`
5. `json_field` `data/totals.json` field `sprocket` equals `7`

**Solver sketch:** three reads, one write of 6 rows, arithmetic (12+8+3 / 5+4 / 7), one JSON write.

### T05 — Apply config changes to a copy

- **Axis / Tier:** B / 2 · **Max turns:** 12 · **Stresses:** M2, M3 (change list held across edits), M4 (writes new file without touching original)

**Prompt (verbatim):**
```
Apply every change in changes.md to app_config.json and write the result to
app_config.new.json. Leave app_config.json itself untouched.
```

**Seed files:**

`app_config.json`
```json
{
  "name": "relay",
  "retries": 2,
  "timeout_s": 30,
  "features": {
    "dark_mode": false,
    "telemetry": true
  }
}
```
`changes.md`
```
# Config changes — sprint 41
1. Set retries to 5.
2. Set timeout_s to 60.
3. Turn telemetry off (set it to false).
4. Do not change dark_mode.
```

**Assertions:**
1. `json_field` `app_config.new.json` field `retries` equals `5`
2. `json_field` `app_config.new.json` field `timeout_s` equals `60`
3. `json_field` `app_config.new.json` field `features.telemetry` equals `false`
4. `json_field` `app_config.new.json` field `features.dark_mode` equals `false`
5. `json_field` `app_config.json` field `retries` equals `2`   (original untouched)
6. immutable_seeds: `app_config.json`   (belt-and-braces with assertion 5)

**Solver sketch:** read both files, one write of the modified JSON under the new name.

---

## 9. AXIS C — code-fix loop (3 tasks)

The gate is real and non-negotiable: the seeded checker must exit 0. Each task seeds broken
code plus an immutable `check.py`. The loop is run-checker → read error → edit → re-run. The
three bugs are ordered by how much the agent must reason versus just obey the traceback:
T06's traceback names the bug, T07 needs two iterations, T08's checker output names the
symptom but not the cause.

### T06 — Fix the invoice typo

- **Axis / Tier:** C / 2 · **Max turns:** 14 · **Stresses:** M0 (loop kept on goal), M4 (checker as oracle), M7 (re-run budgeting), M8 (thinking-tag handling in loop models)

**Prompt (verbatim):**
```
Run "python3 check.py". It fails because invoice.py has a bug. Fix invoice.py so that
"python3 check.py" exits with code 0. Do not modify check.py. When the checker is green,
write a file fixed.txt containing the single word DONE.
```

**Seed files:**

`invoice.py`
```python
"""Totals a simple invoice. Prices are per unit, integers."""

PRICES = {"bolt": 3, "nut": 1, "washer": 2}


def invoice_total(items):
    """items: list of (part_name, quantity) tuples. Returns the total price."""
    total = 0
    for name, qty in items:
        total = total + PRICES[nmae] * qty
    return total
```
`check.py`
```python
"""CHECKER v1 — immutable. Exit 0 only when invoice_total is correct."""
import sys

from invoice import invoice_total

CASES = [
    ((("bolt", 2),), 6),
    ((("nut", 5), ("washer", 3)), 11),
    ((("bolt", 1), ("nut", 1), ("washer", 1)), 6),
    ((), 0),
]

failures = 0
for items, expected in CASES:
    got = invoice_total(list(items))
    if got != expected:
        print(f"FAIL invoice_total({list(items)}) expected {expected}, got {got}")
        failures += 1

if failures:
    print(f"{failures} case(s) failed")
    sys.exit(1)
print("ALL GREEN")
sys.exit(0)
```

**Assertions:**
1. `command_ok` `python3 check.py`   (the mechanical gate)
2. `file_contains` `fixed.txt` value `"DONE"`
3. immutable_seeds: `check.py`

**Solver sketch:** run checker → `NameError: name 'nmae'` → rename to `name` → re-run green → write fixed.txt. The traceback literally names the fix; what is tested is whether the loop closes.

### T07 — Fix the quote tool (two bugs)

- **Axis / Tier:** C / 3 · **Max turns:** 16 · **Stresses:** M4, M5 (verify before declaring done), M7, M8

**Prompt (verbatim):**
```
Run "python3 check.py". The pricing tool in quote.py is broken. Fix quote.py so that
"python3 check.py" exits with code 0. Do not modify check.py or config/pricing.json.
There may be more than one bug; keep fixing until the checker is green, then write a
file fixed.txt containing the single word DONE.
```

**Seed files:**

`config/pricing.json`
```json
{
  "currency": "EUR",
  "discount_pct": 25,
  "items": {"bolt": 5, "nut": 2}
}
```
`quote.py`
```python
"""Quote tool: subtotal minus discount, rounded to 2 decimals."""
import json

CFG = json.load(open("config/pricing.json"))


def quote(cart):
    subtotal = sum(CFG["items"][name] * qty for name, qty in cart)
    discount = subtotal * CFG["discount"]
    return round(subtotal - discount, 2)
```
`check.py`
```python
"""CHECKER v1 — immutable. Exit 0 only when quote() is correct."""
import sys

from quote import quote

CASES = [
    ([("bolt", 8)], 30.0),
    ([("nut", 15)], 22.5),
    ([], 0.0),
]

failures = 0
for cart, expected in CASES:
    got = quote(cart)
    if got != expected:
        print(f"FAIL quote({cart}) expected {expected}, got {got}")
        failures += 1

if failures:
    print(f"{failures} case(s) failed")
    sys.exit(1)
print("ALL GREEN")
sys.exit(0)
```

**Bug chain (deterministic):** run 1 → `KeyError: 'discount'` (seeded key is `discount_pct`). Fix the key → run 2 → `FAIL quote([('bolt', 8)]) expected 30.0, got -960.0` (discount line lacks the `/ 100`). Fix the formula (`subtotal * CFG["discount_pct"] / 100`) → run 3 green. All arithmetic is exact in binary floating point (30.0, 22.5, 0.0), so the checker is not flaky.

**Assertions:**
1. `command_ok` `python3 check.py`
2. `file_contains` `fixed.txt` value `"DONE"`
3. immutable_seeds: `check.py`, `config/pricing.json`

### T08 — Fix the median edge case

- **Axis / Tier:** C / 3 · **Max turns:** 16 · **Stresses:** M0, M4, M5, M7 — the checker names the symptom (`expected 25, got 30`) but not the cause; the agent must read the code and know the even-length median rule (no trivia beyond standard library semantics)

**Prompt (verbatim):**
```
Run "python3 check.py". stats.py has a bug in median(). Fix stats.py so that
"python3 check.py" exits with code 0. Do not modify check.py. When it is green,
write a file fixed.txt containing the single word DONE.
```

**Seed files:**

`stats.py`
```python
"""Median of a list of numbers."""


def median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        raise ValueError("empty list")
    return s[n // 2]
```
`check.py`
```python
"""CHECKER v1 — immutable. Exit 0 only when median() is correct."""
import sys

from stats import median

CASES = [
    ([1, 3, 4, 2, 5], 3),
    ([10, 20, 30, 40], 25),
    ([7], 7),
]

failures = 0
for values, expected in CASES:
    got = median(values)
    if got != expected:
        print(f"FAIL median({values}) expected {expected}, got {got}")
        failures += 1

if failures:
    print(f"{failures} case(s) failed")
    sys.exit(1)
print("ALL GREEN")
sys.exit(0)
```

**Bug chain:** the odd-length case passes; `median([10, 20, 30, 40])` returns `30` instead of `25`. Fix: even length → `(s[n // 2 - 1] + s[n // 2]) / 2`. A wrong "fix" that averages wrongly (e.g. `s[n // 2] / 2`) keeps failing with fresh evidence each run.

**Assertions:**
1. `command_ok` `python3 check.py`
2. `file_contains` `fixed.txt` value `"DONE"`
3. immutable_seeds: `check.py`

---

## 10. AXIS D — retrieval + synthesis (3 tasks)

Facts are scattered across 5–10 small files with deliberate distractors. The synthesized
answer file must contain exact required strings — greppable, no judge. This axis is where
M2/M3 earn their keep: without ledger/memory the model must hold facts in a melting context.

### T09 — Final launch date + rollback owner

- **Axis / Tier:** D / 2 · **Max turns:** 16 · **Stresses:** M1, M2 (six files read without context melt), M3 (superseded-date reasoning requires remembering the earlier note)

**Prompt (verbatim):**
```
The team's notes are in notes/, plus roster.md and decisions_log.md at the workspace
root. What launch date did the team finally settle on, and who owns the rollback plan?
Write launch_decision.md answering both: include the exact date in YYYY-MM-DD form and
the owner's full name.
```

**Seed files:**

`notes/2026-11-03_standup.md`
```
# Standup 2026-11-03
- ship target currently 2026-11-28 (tentative)
- Priya flagged crash on empty payload
```
`notes/2026-11-05_standup.md`
```
# Standup 2026-11-05
- crash fixed, regression suite green
- date talk deferred to Friday
```
`notes/2026-11-07_standup.md`
```
# Standup 2026-11-07
- DECISION: launch date review moved to 11-10
- rollback plan owner to be confirmed against roster.md
```
`notes/2026-11-10_standup.md`
```
# Standup 2026-11-10
- DECISION: launch moves to 2026-12-08
- rollback plan owner confirmed in roster.md
```
`roster.md`
```
# Roster
- Priya Nair — reliability lead, owns the rollback plan
- Tomás Vega — release manager
- Lin Wei — QA
```
`decisions_log.md`
```
# Decisions log
2026-11-07: launch date review pending
2026-11-10: launch date set — see standup 11-10
```

**Assertions:**
1. `file_exists` `launch_decision.md`
2. `file_contains` `launch_decision.md` values `["2026-12-08", "Priya Nair"]`   (both strings required)

**Solver sketch:** grep `DECISION` → read 11-10 standup → read roster → write answer. The distractor `2026-11-28` (superseded) punishes answer-from-first-hit.

### T10 — Build the restock plan (join)

- **Axis / Tier:** D / 3 · **Max turns:** 18 · **Stresses:** M2, M3, M4, M5 (verify totals before `task_done`) — a three-source join: catalog prices × supplier names × order quantities

**Prompt (verbatim):**
```
Build restock_plan.json in the workspace root by joining three sources:
catalog/parts.csv (unit prices), suppliers/*.md (which supplier carries which part),
and orders/order_a.csv + orders/order_b.csv (quantities).
Required exact shape, items sorted by part_id ascending:

{"items": [{"part_id": "P-101", "qty": <qty total across orders>, "supplier": "<ACME or NOVA>", "cost": <qty * unit_price>}, ...], "grand_total": <sum of costs>}

supplier must be the uppercase company name (ACME or NOVA).
```

**Seed files:**

`catalog/parts.csv`
```
part_id,name,unit_price
P-101,sensor,40
P-102,cable,6
P-103,bracket,9
```
`suppliers/acme.md`
```
# ACME Supply
Supplies parts: P-101, P-103
Lead time: 5 days
```
`suppliers/nova.md`
```
# NOVA Parts Co
Supplies parts: P-102
Lead time: 2 days
```
`orders/order_a.csv`
```
part_id,qty
P-101,3
P-102,10
```
`orders/order_b.csv`
```
part_id,qty
P-103,4
```

**Ground truth (deterministic):** P-101 → qty 3, ACME, cost 120 · P-102 → qty 10, NOVA, cost 60 · P-103 → qty 4, ACME, cost 36 · grand_total 216.

**Assertions:**
1. `json_field` `restock_plan.json` field `items.0.part_id` equals `"P-101"`
2. `json_field` `restock_plan.json` field `items.0.qty` equals `3`
3. `json_field` `restock_plan.json` field `items.0.supplier` equals `"ACME"`
4. `json_field` `restock_plan.json` field `items.0.cost` equals `120`
5. `json_field` `restock_plan.json` field `items.1.supplier` equals `"NOVA"`
6. `json_field` `restock_plan.json` field `items.1.cost` equals `60`
7. `json_field` `restock_plan.json` field `items.2.cost` equals `36`
8. `json_field` `restock_plan.json` field `grand_total` equals `216`

### T11 — Rebuild the event timeline

- **Axis / Tier:** D / 2 · **Max turns:** 18 · **Stresses:** M0 (instruction precision held across 8 files), M2, M3 — includes a format trap: an `EVENT=` mention that is *not* at line start must be excluded

**Prompt (verbatim):**
```
Four files in logs/ contain lines that START with "EVENT=". Write timeline.md in the
workspace root with those four events in chronological order, one per line, each line
formatted exactly: <timestamp> <EVENT-ID>   (timestamp first, then the ID that follows
"EVENT=", e.g. "2026-11-12T09:14Z BUILD-START"). Ignore any EVENT mention that is not
at the start of a line.
```

**Seed files:**

`logs/app_log_01.txt`
```
2026-11-12T08:55Z service boot ok
EVENT=BUILD-START ts=2026-11-12T09:14Z
2026-11-12T09:15Z compile flags: -O2
```
`logs/app_log_02.txt` (distractor file)
```
2026-11-12T09:30Z cache warm
note from archive: EVENT=LEGACY-PURGE ts=2026-09-01T00:00Z
2026-11-12T09:31Z healthy
```
`logs/app_log_03.txt`
```
2026-11-12T10:01Z runner spawned
EVENT=TEST-RUN ts=2026-11-12T10:02Z
2026-11-12T10:20Z 142 tests passed
```
`logs/app_log_04.txt`
```
2026-11-12T10:30Z lint clean
2026-11-12T10:44Z artifact cached
```
`logs/app_log_05.txt`
```
2026-11-12T13:00Z courier manifest ready
EVENT=SHIP-OUT ts=2026-11-12T13:05Z
2026-11-12T13:06Z tracking KS-8841
```
`logs/app_log_06.txt`
```
2026-11-12T12:10Z docs generated
```
`logs/app_log_07.txt`
```
2026-11-12T11:40Z signing service reachable
EVENT=PACK-SIGNED ts=2026-11-12T11:47Z
2026-11-12T11:48Z sha256 recorded
```
`logs/app_log_08.txt`
```
2026-11-12T13:30Z quiet period
```

**Assertions:**
1. `file_exists` `timeline.md`
2. `file_contains` `timeline.md` values `["2026-11-12T09:14Z BUILD-START", "2026-11-12T10:02Z TEST-RUN", "2026-11-12T11:47Z PACK-SIGNED", "2026-11-12T13:05Z SHIP-OUT"]` `in_order:true`   (order + format enforced; the `EVENT=X ts=Y` echo format fails this)
3. `grep_count` `timeline.md` pattern `LEGACY-PURGE` count_lte 0   (decoy excluded)

---

## 11. AXIS E — recovery-from-error (3 tasks)

The first obvious action fails on every E task. What is graded is the adaptation, and — in
T14 — the discipline to stop instead of thrashing. These tasks are the reason Stop Authority
exists, so one of them is deliberate loop bait.

### T12 — Missing report, use the alternate

- **Axis / Tier:** E / 2 · **Max turns:** 14 · **Stresses:** M3 (remember the README redirect), M4 (read failure surfaced, not papered over), M5, M7 (fs_read error → classify → alternate)

**Prompt (verbatim):**
```
Append a line to summary.txt in the exact form "TOTAL UNITS: <number>", where <number>
is the sum of the units column of data/report.csv. Do not create report.csv.
```

**Seed files (note: `data/report.csv` is deliberately NOT seeded):**

`data/report_v2.csv`
```
item,units
alpha,4
beta,9
```
`data/README.md`
```
# data/README
report.csv was corrupted during sync and archived off-machine on 2026-11-01.
It is NOT recoverable here. Use report_v2.csv instead — same schema:
column 1 = item name, column 2 = units.
```
`summary.txt`
```
# summary
```

**Failure chain:** `fs_read(data/report.csv)` → not found → `fs_list(data/)` reveals README + v2 → README states v1 unrecoverable → use v2 → total 13.

**Assertions:**
1. `file_contains` `summary.txt` value `"TOTAL UNITS: 13"`
2. `file_exists` `data/report.csv` **negated**   (fabricating the missing file fails)
3. immutable_seeds: `data/README.md`

### T13 — Wrong path, broken build, fix the chain

- **Axis / Tier:** E / 3 · **Max turns:** 18 · **Stresses:** M0 (goal kept through three failures), M4, M6 (budget pressure with three dead ends), M7, M8 (shell tool-call mode)

**Prompt (verbatim):**
```
Run the build script build.sh at the workspace root to produce the release bundle.
If anything fails, get the build to succeed anyway, and make sure dist/bundle.txt
exists with the sorted part names, one per line.
```

The prompt's path claim is deliberately wrong: `build.sh` lives in `tools/`, and it fails
once more before succeeding (missing generated input).

**Seed files:**

`tools/build.sh`
```sh
#!/bin/sh
# Builds dist/bundle.txt from inputs/parts.txt
set -e
mkdir -p dist
sort inputs/parts.txt > dist/bundle.txt
echo "BUILD OK: dist/bundle.txt"
```
`tools/gen_parts.py`
```python
"""Merges the fragments in inputs/raw/ (fixed order a, b, c) and writes the sorted
lines to inputs/parts.txt."""
import pathlib

raw = pathlib.Path("inputs/raw")
lines = []
for name in ("a.txt", "b.txt", "c.txt"):
    lines += (raw / name).read_text().splitlines()
out = pathlib.Path("inputs")
out.mkdir(exist_ok=True)
(out / "parts.txt").write_text("\n".join(sorted(lines)) + "\n")
print("wrote inputs/parts.txt")
```
`tools/README.md`
```
# tools/
build.sh — produces dist/bundle.txt. Requires inputs/parts.txt.
If inputs/parts.txt is missing, generate it first:
    python3 tools/gen_parts.py
gen_parts.py merges the fragments in inputs/raw/ and writes sorted lines to
inputs/parts.txt.
```
`inputs/raw/a.txt`
```
delta
alpha
```
`inputs/raw/b.txt`
```
charlie
bravo
```
`inputs/raw/c.txt`
```
echo
```

**Failure chain (all deterministic):** ① `sh build.sh` at root → not found. ② locate `tools/build.sh`, run → `sort: inputs/parts.txt: No such file or directory`. ③ read `tools/README.md` → run `python3 tools/gen_parts.py` → run build → green. (Inlining the merge into a hand-written build is acceptable recovery; the artifact assertions below still decide.)

**Assertions:**
1. `file_exists` `inputs/parts.txt`
2. `file_exists` `dist/bundle.txt`
3. `command_ok` `test -s dist/bundle.txt`   (non-empty)
4. `file_contains` `dist/bundle.txt` values `["alpha", "bravo", "charlie", "delta", "echo"]` `in_order:true`
5. `grep_count` `dist/bundle.txt` pattern `^(alpha|bravo|charlie|delta|echo)$` count_gte 5 count_lte 5

### T14 — The vault that cannot be opened (Stop Authority bait)

- **Axis / Tier:** E / 2 · **Max turns:** 8 (deliberately tight) · **Stresses:** M6 (the task IS the Stop Authority test), M0 (keep the actual goal in view), M5

**Prompt (verbatim):**
```
Read secure/vault.txt and write its first line to vault_line.txt.
If the content cannot be obtained, write BLOCKED.md (one sentence: what is missing and
why) and finish. Do not create vault_line.txt and do not create secure/vault.txt.
```

**Seed files (note: there is no `secure/` directory — the target does not exist):**

`policy.md`
```
# Workspace access policy
secure/vault.txt requires biometric enrollment.
Biometric enrollment is unavailable in sandboxed workspaces.
No alternate copy of vault.txt exists.
```

**Why it is bait:** every turn spent re-reading `secure/vault.txt`, re-listing, or "fixing"
the path is a wasted turn; the seeded `max_turns: 8` means a thrashing model fails on budget
without ever reaching `task_done`, while a model that reads `policy.md` (or simply accepts the
second read failure) finishes in ~4 turns with a clean, evidence-citing stop. The pass/fail
split between those two behaviors is exactly the M6 delta, measured mechanically: harness
turn count + `task_done` timing + the assertions below.

**Assertions:**
1. `file_exists` `BLOCKED.md`
2. `file_contains` `BLOCKED.md` value `"vault"` `ci:true`
3. `file_exists` `vault_line.txt` **negated**
4. `file_exists` `secure/vault.txt` **negated**
5. Harness-level: `task_done` declared **within** the 8-turn budget (voluntary stop). Budget-exhaustion wrap-up fails the task.

---

## 12. What this suite deliberately does NOT grade

- No LLM judge, no human rubric, no partial credit for "looked reasonable".
- No prose quality, no explanation style, no politeness of failure messages.
- No world knowledge: every answer is derivable from seeded bytes (median-even-length rule is
  standard-library semantics, the only exception, and it is tier-3 by design).
- No network, no secrets, no time-dependent content, no randomness.

## 13. Constraints honored (mission brief)

| Constraint | How the suite honors it |
|---|---|
| Solvable by a capable 8B with good scaffolding | tier-1/2 tasks are 2–8 mechanical steps; tier-3 tasks need at most standard-library reasoning; every prompt is self-contained and unambiguous |
| No long-horizon planning (>8 steps) | longest reference solution is T03 at 7 operations |
| No internet | sandbox has no network env; no assertion depends on anything external |
| Deterministic seeds | every file is literal static text; checker arithmetic chosen to be exact in IEEE-754 (T07) |
| ≤ ~20 files, ≤ ~2KB each | max files per task is 8 (T11); largest seed file is ~700 bytes |
| Machine-checkable only | grading vocabulary is exactly the five assertion kinds in §3 |
