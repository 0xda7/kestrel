# Mission — Surgical Sprint 1: `Sources/Surgical/` module + checks

Branch: `surgical-mvp` (you are on it; branched from `main` @ v0.89.5+, clean tree)
Date: 2026-10-13 · Operator: Northlatch Labs · Executor: atomic agent
Supervisor gate: `swift run --disable-sandbox kestrel-checks` all green, no main-branch changes.

## Purpose
Kestrel is growing a specialty product: **Kestrel Surgical**, a local-first AI
copilot for plastic surgery (spec: `~/KimiK3_Nvidia/Kestrel-Surgical/docs/product-spec.md`).
This sprint lands the deterministic foundation: procedure library, op-note
builder, de-identifier v0, and their check suite. **No LLM calls, no network,
no UI work this sprint** — pure data structures + logic + tests.

## Deliverables (all under `Sources/Surgical/`, license headers per file)

### 1. `ProcedureLibrary.swift` — product code (SPDX: `LicenseRef-Commercial`)
- `struct SurgicalProcedure: Sendable, Codable, Identifiable`: `id`, `name`,
  `synonyms: [String]`, `bodyRegion`, `laterality: LateralityKind` (`.none`, `.optional`, `.required`),
  `requiresImplantFields: Bool`, `requiresTourniquetField: Bool`, `cptCode: String?`.
- `enum ProcedureLibrary` with `static let all: [SurgicalProcedure]` — exactly these 10:
  1. Augmentation mammoplasty (implant fields: type/size/profile/manufacturer/lot)
  2. Reduction mammoplasty (laterality required; specimen weight field)
  3. Mastopexy (laterality optional)
  4. Septorhinoplasty (laterality none; graft field)
  5. Blepharoplasty (laterality optional — bilateral common)
  6. Rhytidectomy (laterality none)
  7. Liposuction (laterality optional; aspiration volume field)
  8. Abdominoplasty (laterality none; plication field)
  9. Excision of skin lesion with primary closure (laterality required; lesion size/margins fields)
  10. Carpal tunnel release (laterality required; tourniquet field)
- Lookup API: `static func find(_ query: String) -> SurgicalProcedure?` —
  case-insensitive match on name or synonyms, whitespace/dash-insensitive.

### 2. `OpNoteBuilder.swift` — product code (`LicenseRef-Commercial`)
- `struct OpNote: Sendable, Codable`: sections — `preopDiagnosis`, `postopDiagnosis`,
  `procedureName`, `laterality`, `implants: [ImplantRecord]?`, `ebmL: Int?`,
  `tourniquetMinutes: Int?`, `complications`, `dressing`, `disposition`.
- `struct ImplantRecord: Sendable, Codable`: kind, size, profile?, manufacturer?, lot?
- `enum OpNoteBuilder`: `static func build(procedure: SurgicalProcedure, dictated: OpNoteFragments) -> OpNote`
  where `OpNoteFragments` carries free-text values per section (what a dictation
  pass would yield). Rules:
  - Laterality validation: if procedure requires laterality and fragment is
    absent/invalid → throw `OpNoteError.missingLaterality` (do not guess).
  - EBL/tourniquet only included when the procedure declares the field.
  - Output must be renderable: `func renderedPlainText() -> String` producing a
    conventional operative-note layout (one labeled line per present section).

### 3. `DeIdentifier.swift` — MedKit-bound code (**SPDX: `Apache-2.0`**, header comment marks it for future extraction as `kestrel-medkit`)
- `enum DeIdMode`: `.mask` (e.g. `[NAME]`), `.redact` (fixed-width `████` block),
  `.hash` (first 8 hex of SHA-256, stable per entity string within a run),
  `.dateShift` (dates shifted by a consistent random offset per run, ±≤30 days).
- `struct DeIdentifier` with `static func process(_ text: String, mode: DeIdMode) -> DeIdResult`
  returning `scrubbed: String` + `findings: [DeIdFinding]` (`kind`, `range`, `original`).
- Detect these Safe Harbor classes v0 (deterministic regex + rules only):
  - SSN (ddd-dd-dddd), phone (US formats incl. dashes/dots/spaces), fax (labeled),
    email, IPv4, URL, MRN (labeled "MRN"/"MR #"/"medical record"), dates in ≥ 8
    formats (ISO, US long/short, "dd Mon yyyy", "Mon dd, yyyy", yyyy/mm/dd, dd.mm.yyyy, "Month dd"),
    device serial (labeled "serial"/"lot"), ZIP>3 digits → keep first 3 + `**`,
    ages ≥ 90 (number followed by "y/o"/"year-old"/"years old" ≥ 90 → `[AGE>89]`),
    person names v0: honorific-prefixed names (`Dr.`, `Mr.`, `Mrs.`, `Ms.`, `Pt.`),
    plus a passed-in `knownNames: Set<String>` roster (caller-supplied).
    Ambiguous capitalized tokens are NOT removed (precision over recall v0 — findings list may flag them as `.reviewCandidate`).
- All findings carry the class kind for auditability. Pure Foundation; no AppKit.

### 4. `Tests/SurgicalChecks.swift` — check suite (GPL header like other test files)
- `final class SurgicalChecks: CheckCase` — **≥ 25 checks** covering:
  - library: all 10 present, id uniqueness, synonym lookup (≥ 5 cases incl.
    "breast aug", "tummy tuck", "facelift", "eyelid lift", "carpal tunnel"),
    laterality declarations correct per procedure;
  - op-note builder: happy path, laterality-missing throws, laterality-invalid
    throws, implant fields gated by `requiresImplantFields`, tourniquet gated,
    renderedPlainText contains labels and values (≥ 3 cases), round-trip Codable;
  - de-ID: one check per identifier class (≥ 12), each asserting both the
    scrubbed output no longer contains the identifier AND the finding is
    reported with correct kind; plus: each mode behaves as specified (mask vs
    redact vs hash stability — same input → same hash in one run; date-shift
    preserves ordering and stays within ±30d); precision case: "Dr. Smith
    performed..." scrubbed but "The Mayo Clinic" style org names untouched;
    age boundary (89 untouched, 90 scrubbed); ZIP keeps 3 digits.
- Register in `Tests/Checks/CheckRegistry+Generated.swift` (hand-maintained;
  insert `("SurgicalChecks", SurgicalChecks.__checkSet),` keeping deterministic
  order — append in the same relative position as the file list you see).

### Pattern references (read these first, copy the idioms exactly)
- Check-case style: `Tests/SecretRedactionTests.swift` (class shape, `__checkSet`
  construction at file bottom, XCTest-named asserts).
- Registry: `Tests/Checks/CheckRegistry+Generated.swift`.
- Header style: every existing `Sources/**` file (copyright + SPDX first lines).
  Surgical product files: `SPDX-License-Identifier: LicenseRef-Commercial`;
  DeIdentifier: `Apache-2.0`; tests: GPL-3.0-or-later like siblings.

## Hard constraints
1. Swift 6 language mode + StrictConcurrency already apply — no `@unchecked
   Sendable` unless genuinely required; statics must be `let` immutable data.
2. Pure Foundation. No UI, no network, no LLM, no changes under `Sources/Main/`,
   no Package.swift change (`Sources/Surgical/` is already inside KestrelCore's path).
3. All fixture data synthetic. No real-looking PHI beyond obvious fakes
   (`555-01-2345`, `john.doe@example.invalid`).
4. Do not touch `main`. Commit only on `surgical-mvp`. Conventional commits
   (`feat(surgical): …`), one logical commit per deliverable.
5. Comments: engineering constraints only, match repo density (sparse).

## Verification (run after every deliverable; final run before done)
```bash
swift run --disable-sandbox kestrel-checks   # ALL suites green incl. SurgicalChecks
```
If bare CLT can't build for any reason, fall back to:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` first,
then rerun checks. `swift test` is optional extra.

## Done definition
- 4 new files + registry edit committed on `surgical-mvp`.
- kestrel-checks green: prior 350 checks still pass + ≥ 25 new SurgicalChecks.
- `git diff main --stat` shows only: `Sources/Surgical/**`, `Tests/SurgicalChecks.swift`,
  `Tests/Checks/CheckRegistry+Generated.swift`, this mission folder, journal.
- Journal: append `.agents/missions/2026-10-13-surgical-sprint1/journal.md` —
  decisions, deviations, check-run counts (before/after totals).
