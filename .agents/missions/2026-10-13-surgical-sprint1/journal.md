# Journal — Surgical Sprint 1 (2026-10-13)

Mission: `.agents/missions/2026-10-13-surgical-sprint1/plan.md` · Branch: `surgical-mvp`
Executor: atomic agent (GLM-5.3-Flash) · Operator: Northlatch Labs

## Baseline

- `swift run --disable-sandbox kestrel-checks` on clean `surgical-mvp`: **350 checks, 0 failures** (exit 0).
- Pattern references read before any code: `Tests/SecretRedactionTests.swift` (CheckCase + `__checkSet`
  shape), `Tests/Checks/CheckSupport.swift` (harness, assert names, runner), 
  `Tests/Checks/CheckRegistry+Generated.swift`, `Sources/App/NSRegularExpression+Literal.swift`
  (constant-pattern idiom), `Sources/Models/ModelName.swift` (static-data style), and
  `~/KimiK3_Nvidia/Kestrel-Surgical/docs/product-spec.md` (naming: Kestrel Surgical / MedKit, Apache-2.0).

## Deliverables landed (one commit each)

1. `ca7453e` feat(surgical): v0 procedure library — `Sources/Surgical/ProcedureLibrary.swift`
2. `93755cf` feat(surgical): op-note builder — `Sources/Surgical/OpNoteBuilder.swift`
3. `71debb8` feat(surgical): Safe Harbor v0 de-identifier — `Sources/Surgical/DeIdentifier.swift`
4. `713709d` test(surgical): 41-check suite + registry entry — `Tests/SurgicalChecks.swift`, `Tests/Checks/CheckRegistry+Generated.swift`

## Check runs (kestrel-checks, `swift run --disable-sandbox`)

| When | Result |
|---|---|
| baseline, clean tree | 350 checks, 0 failures |
| after ProcedureLibrary + OpNoteBuilder | 350 checks, 0 failures |
| after DeIdentifier | 350 checks, 0 failures |
| after SurgicalChecks + registry (2 compile-error repair rounds) | 391 checks, 0 failures |
| final pre-journal run | **391 checks, 0 failures** (350 prior + 41 new) |

Repair rounds on the check suite (honest log): `ImplantRecord` fixture calls missing
optional arguments → gave `ImplantRecord` an explicit init with `nil` defaults;
`Substring`/`String` mismatch in the finding-range assert → wrapped in `String(...)`;
first attempt at the init fix put it in an extension and collided with the synthesized
memberwise init → moved into the struct body. One wrong-line edit anchored on a stale
line number; stopped, re-read, repaired both touched lines.

## Decisions (interpretations the plan left open)

- **Augmentation laterality = `.required`.** The plan lists laterality for nine
  procedures and omits augmentation; required matches reduction and clinical
  practice (implants without a documented side are a wrong-site hazard).
- **CPT codes: unambiguous singles only.** `nil` for septorhinoplasty,
  rhytidectomy, liposuction, and lesion excision — they are component- or
  variant-coded (site, primary/secondary, behavior), and a plausible wrong
  suggestion is worse than none. Abdominoplasty carries 15847 (matches its
  plication declaration).
- **Parenthetical procedure fields beyond implants/tourniquet are scoped out.**
  Specimen weight, graft, aspiration volume, plication, and lesion size/margins
  have no slot in the planned `OpNote` struct; they are v1+ note content.
  `requiresImplantFields` is true only for augmentation, the one procedure the
  plan ties to "implant fields".
- **EBL is universally declared.** "EBL/tourniquet only included when the
  procedure declares the field": tourniquet gates on `requiresTourniquetField`;
  the planned property list has no EBL flag and every op note documents blood
  loss, so EBL rides whenever dictated.
- **Laterality resolution matrix.** required + absent/invalid → throw
  `OpNoteError.missingLaterality` (exactly per plan, never guess); optional +
  absent → "Not documented"; `.none` → "Not applicable" even when dictated (the
  library declaration wins over dictation noise); optional + invalid → also
  throws, because silently filing an unrecognized side as "Not documented"
  hides a dictation error.
- **Absent text sections render "Not dictated"** so a signing surgeon sees the
  gap rather than a printed-looking empty section.
- **ZIP detection is labeled-ZIP or bare ZIP+4 only.** A bare 5-digit rule would
  swallow CPT codes like 19325. ZIP → first three digits + `**` and age →
  `[AGE>89]` in every mode: both are pinned class rules in the plan, not mode
  behaviors.
- **dateShift draws 1–30 days with a random sign** (0 excluded — a 0-day shift
  is a silent no-op), one draw per `process` call so all dates move together;
  non-date identifiers get mask treatment in dateShift mode; yearless dates
  shift through an anchor year and render without one.
- **reviewCandidate rule (deterministic):** mid-sentence isolated capitalized
  tokens with lowercase words on both sides, minus a month/org-suffix stoplist.
  Flagged, never scrubbed; "The Mayo Clinic" passes untouched because the next
  word is capitalized/stoplisted.
- **"lot" needs a colon or "number/no."** ("lot" is ordinary English);
  "MRN"/"medical record"/"serial" are distinctive enough for a bare label.
- **Registry entry appended last** — the list's tail is its append order and the
  header says regenerate by hand.
- **`import CryptoKit` in DeIdentifier** despite "pure Foundation": first-party
  system framework (repo precedent in three files), required for SHA-256, no
  Package.swift change. The file stays UI-free and Kestrel-type-free for the
  kestrel-medkit extraction, with the Apache-2.0 header noted as planned.

## Deviations from the plan

None of substance. The four work items, headers, SPDX markers, commit
granularity, branch, and verification cadence follow the plan as written; all
open points above are documented interpretations, not scope changes. No
changes under `Sources/Main/`, none to `Package.swift`, no network/LLM/UI code.

## Scope check (done definition)

`git diff main --stat` after the journal commit shows exactly:
`Sources/Surgical/**` (3 files), `Tests/SurgicalChecks.swift`,
`Tests/Checks/CheckRegistry+Generated.swift`, and this mission folder with
`plan.md` + `journal.md`. Nothing else.
