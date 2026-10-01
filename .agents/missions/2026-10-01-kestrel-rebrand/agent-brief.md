# REBRAND CONTRACT — read fully before editing anything (all agents)

## Mission
ToshLLM 0.87.9 → **Kestrel** by Northlatch Labs. Mechanical, surgical brand-surface rename.
Product spec must not change. You are one of several agents working on DISJOINT file sets —
touch ONLY the files in your scope. Other agents are working simultaneously elsewhere in the tree.

## Canonical mapping (apply exactly, case-consistent)

| Find | Replace |
|------|---------|
| `ToshLLM` | `Kestrel` |
| `Toshllm` | `Kestrel` |
| `toshllm` | `kestrel` |
| `ToshLLMS` / odd casings of toshllm | normalize to `Kestrel` (flag if ambiguous) |
| `ToshGEMM` | `KestrelGEMM` |
| `toshgemm` | `kestrelgemm` |
| `ToshDropdown`, `Tosh<Word>` (Swift identifiers) | `Kestrel<Word>` |
| `dev.engel.toshllm` | `com.northlatchlabs.kestrel` |
| `engeldlgado/toshllm` (GitHub path) | `northlatchlabs/kestrel` |
| `github.com/engeldlgado` | `github.com/northlatchlabs` |
| `toshllm.com` | `northlatchlabs.com/kestrel` |
| `engeldlgado@gmail.com` | `opensource@northlatchlabs.com` |
| `Engelbert Delgado` / `engeldelgado` / `engeldlgado` (any case) | `Northlatch Labs` / `northlatchlabs` (see attribution — 100% personal-detail removal) |
| `engeldlgado` (any other occurrence) | `northlatchlabs` |
| standalone `Tosh` / `tosh` (brand usage) | `Kestrel` / `kestrel` case-consistent |

## HARD EXCEPTIONS — never change these strings
1. `TOSH_` environment variable names (e.g. `TOSH_FA_AMD`, `TOSH_MGPU_PEER`, `TOSH_VERSION`,
   `TOSH_ARCH`, `TOSH_NO_AVX2`, `TOSH_BIN`, `TOSH_CB_PROFILE` …). These are the documented engine
   interface. If a line reads `TOSH_VERSION=0.82 ./make-app.sh`, the `TOSH_VERSION` stays.
2. `tosh_` C identifiers/symbols/functions in .c/.h/.patch/.swift C-bridge code (e.g. `tosh_cbp_`,
   `tosh_device_mem_report`, `g_tosh_d2h_ns`).
3. The GPL-3.0 license body in `LICENSE` (nobody edits LICENSE's text; header attribution handled
   by orchestrator only).
4. Upstream project names and credits: llama.cpp, stable-diffusion.cpp, whisper.cpp, and their
   authors.
5. Binary files: .icns, .png, .jpg, .pdf, .mov, .wav, .aiff — report them, never edit.
6. `VERSION` file content (0.87.9) — version stays.
7. Git-commit hashes, PR/issue URLs pointing at github.com/engeldlgado/toshllm/issues|pull —
   the URL HOST/path prefix changes per mapping (engeldlgado/toshllm → northlatchlabs/kestrel);
   the issue NUMBERS stay.

## Attribution policy (for files that assert authorship/copyright) — ZERO PERSONAL DETAILS
- The operator's personal names/addresses must NOT appear anywhere: `Engelbert Delgado`,
  `engeldelgado`, `engeldlgado`, `engeldlgado@gmail.com`, `dev.engel.*`. Replace with:
  - authorship/copyright assertions → **Northlatch Labs**
  - licence/contact address → **opensource@northlatchlabs.com**
  - personal GitHub `github.com/engeldlgado` → **github.com/northlatchlabs**
  - author fields in .cff/.zenodo/JSON metadata → "Northlatch Labs" (given/family name fields:
    collapse sensibly, e.g. name: "Northlatch Labs", or remove person fields per format rules)
- PRESERVE third-party contributor credits (e.g. malzzz, chafey, FreQRiDeR, guylough, playexit,
  urfin78, Slice) and upstream project credits (llama.cpp, stable-diffusion.cpp, whisper.cpp).
  Those people are not the operator; their credit stays.

## Mechanics rules
- Text-file edits only. Preserve file mode, line endings, trailing newline exactly.
- In .patch files: edit ONLY text inside existing + lines (and file header comments);
  never alter hunk headers (@@), - lines, or line counts. If a brand string appears in a context
  line (space-prefixed), LEAVE IT (context must match upstream).
- In Swift: renaming an identifier (e.g. `ToshDropdown`) requires renaming ALL references in your
  scope; if a reference lives outside your scope, rename yours and LIST the out-of-scope file in
  your report under "crossrefs" (orchestrator reconciles).
- Do not reformat, re-wrap, or "improve" anything else. One change type only: the brand mapping.
- No dependency, build-flag, or logic changes. No version bumps.

## Return schema (exactly this shape)
```json
{
  "verdict": "done | partial | blocked",
  "files_changed": ["..."],
  "files_flagged_binary": ["..."],
  "residuals_left": [{"file":"...","line":N,"text":"...","reason":"exception|ambiguity"}],
  "crossrefs": ["files outside my scope that reference my renamed identifiers"],
  "notes": ["..."]
}
```

## Gate preview (applies to you)
- `grep -rinE 'tosh' <your scope>` shows ZERO matches outside: TOSH_ env names, tosh_ C symbols,
  upstream credits. Count them and report the exact list with reasons.
- Your file set's syntax intact: for .swift files, `swiftc -parse <file>` passes.
- `git diff --stat` for your scope shows only brand-line changes.

## Environment notes
- Workspace: /Users/admin/KimiK3_Nvidia/toshllm-main (git repo, baseline commit 28b653d).
- Mission dir: .agents/missions/2026-10-01-kestrel-rebrand/ (plan.md, journal.md).
- Do NOT run swift build/test (orchestrator owns gates; parallel builds corrupt each other).
- Do NOT git commit — orchestrator owns commits.
