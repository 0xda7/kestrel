# Mission: Engine full audit + finish the legacy→kestrel rename (Hole 2)

Date: 2026-10-05. Operator request: "full audit the engine and fix hole 2 with the
correct and updated name kestrel", extended mid-mission with: check all Latch-developed
solution folders for the Pi agent (LLM Space) integration.

## Outcome sought

1. Evidence-backed audit of Kestrel-AIEngine: Swift sources, patch series,
   build/packaging pipeline — ranked findings, every finding with file:line.
2. Zero deprecated `legacy`/`uppercase legacy tokens` identifiers on live surfaces (patches, tests,
   vendored engine tree), renamed to `kestrel`/`KESTREL`. Historical records
   (CHANGELOG past releases, mission archives, reference/, the deleted
   `dev.engel.kestrel` domain note) keep original names by design — per the
   policy already written in CHANGELOG.md:55.
3. Verification gates: patch series still applies 92/92, engine rebuilds from the
   renamed patches, Swift package builds, test suite passes (tests are
   logic-only — verified safe, no GPU/model loads).

## Steps

| # | Step | Gate |
|---|------|------|
| 1 | Recon: pipeline map (build-engines.sh applies patches to pinned llama.cpp; vendor tree is ephemeral), naming surface | pipeline understood |
| 2 | Parallel audits: Swift sources, build/packaging, patch series (read-only subagents) | findings with file:line |
| 3 | Rename inventory, case-complete: lowercase kestrel_*/legacy-*, uppercase KESTREL_* (case-sensitive searches miss uppercase tokens — the inventory used case-insensitive matching) | every token classified |
| 4 | Execute rename: 44 repo files (41 patches+README, 3 Tests), vendored tree (205 files) + `legacy-moe/`→`kestrel-moe/` dir + test file; Macintosh excluded via lookbehind | zero live remnants |
| 5 | Gates: shared-hunks sha captured before/after; check-patch-series vs pin 957538960 = 92/92 clean; engine rebuild; swift build; swift test; test-kestrel-moe-cache target compiles | all green, outputs archived |
| 6 | Latch solutions sweep: Pi agent / LLM Space integration status per folder | verdicts with evidence |
| 7 | Deliver report; no install over the running app (operator gate) | report delivered |

## Constraints honored

- Read-only on operator processes/GPU; the running Kestrel.app and its engine are untouched.
- Builds run in-repo only; nothing is installed to /Applications.
- Budget: one engine rebuild (llama only; whisper/image share identically-renamed
  shared-metal hunks), one swift build + test.
