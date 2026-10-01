# A4b CONTRACT — App/DesignSystem/Settings/Dashboard/Tests/Package.swift (RE-DISPATCH)

**Previous attempt:** A4 (f3f77ba3) exhausted context before mutating anything.
**Root cause:** whole-file reads. **Fix in contract:** NEVER read a file wholesale.
Work per line: `grep -n -i tosh <file>` → edit each matched line via its exact text.

## Scope (exact, from orchestrator census 03:28)
Brand lines needing rename (count = renamable `tosh` lines, NOT total):

| File | Lines | Notes |
|------|-------|-------|
| Package.swift | 3 | name+target `ToshLLM`→`Kestrel`; testTarget `ToshLLMTests`→`KestrelTests`; paths `Sources`/`Tests` UNTOUCHED |
| Sources/Settings/SettingsTab.swift | 26 | includes 18 `ToshDropdown` uses → `KestrelDropdown` |
| Sources/App/Docs.swift | 22 | |
| Tests/ToshLLMTests.swift | 16 | |
| Sources/App/Support.swift | 11 | lines 279+573: `"dev.engel.toshllm"` → `"com.northlatchlabs.kestrel"` |
| Sources/App/AboutTab.swift | 11 | |
| Sources/DesignSystem/Views.swift | 7 | |
| Sources/App/ToshLLMApp.swift | 6 | struct `ToshLLMApp`→`KestrelApp` |
| Sources/App/MenuBarLabel.swift | 5 | |
| Tests/AudioVideoExportIntegrationTests.swift | 4 | |
| Sources/DesignSystem/RichContentBlocks.swift | 4 | |
| Tests/ModelDetectionTests.swift | 3 | |
| Sources/DesignSystem/GlassStyle.swift | 3 | |
| Sources/App/ToshLLMLogo.swift | 3 | `ToshLLMLogo`→`KestrelLogo` |
| Sources/App/Donate.swift | 3 | |
| Tests/ToshLLMTests/*.swift (several) | 2 each | |
| Sources/DesignSystem/ToshDropdown.swift | decl | line 9 `struct ToshDropdown<...>` → `struct KestrelDropdown<...>` — closes the 15 use-sites A2 already renamed |

## Renames (git mv — do these FIRST, then edit contents)
1. `git mv Tests/ToshLLMTests.swift Tests/KestrelTests.swift`
2. `git mv Tests/ToshLLMTests Tests/KestrelTests` (subdirectory)
3. `git mv Sources/App/ToshLLMApp.swift Sources/App/KestrelApp.swift`
4. `git mv Sources/App/ToshLLMLogo.swift Sources/App/KestrelLogo.swift`
5. `git mv Sources/DesignSystem/ToshDropdown.swift Sources/DesignSystem/KestrelDropdown.swift`

## Import fix (mechanical, all 18 files)
`@testable import ToshLLM` → `@testable import Kestrel` (list provided in census output:
BenchmarkShareReview, SpecMetrics, ToolSupport, ModelFamilyGroup, ChatCapability, DraftFilter,
MTPHeadDiscovery, GPUPeerGroup, MaskEditor, SubtitleLayout, ToshLLMTests(→KestrelTests),
ServerNavigation, LogPresentation, ModelUpdate, AudioVideoExportIntegration, ServerModelSelection,
Markdown, ModelDetection).

## Copyright headers (ALL scope files)
Line 2 pattern `Engelbert Delgado <engeldlgado@gmail.com>` → `Northlatch Labs <opensource@northlatchlabs.com>`
(60 personal-detail lines census-verified in scope; SPDX GPL line untouched).

## Canonical mapping (same as agent-brief.md)
ToshLLM→Kestrel · toshllm→kestrel · ToshGEMM→KestrelGEMM · Tosh<Word>→Kestrel<Word> ·
ToshDropdown→KestrelDropdown · dev.engel.toshllm→com.northlatchlabs.kestrel ·
engeldlgado→northlatchlabs · email→opensource@northlatchlabs.com

## HARD EXCEPTIONS (grep -i tosh WILL match these; leave byte-identical)
`TOSH_*` env names · `tosh_*` C symbols · `Hackintosh` (upstream context) · LICENSE body ·
VERSION file. Persistence/keychain keys renamed per clean-cut decision (breaking change, recorded):
rename them; list any old key names you touch in `notes`.

## Gates (run at end, report outputs)
1. `grep -RniE 'tosh' Sources/App Sources/DesignSystem Sources/Dashboard Sources/Settings Tests Package.swift | grep -vE 'TOSH_[A-Z0-9_]+' | grep -vE '\btosh_[a-z0-9_]+\b' | grep -v Hackintosh` → expect 0
2. `grep -RniE 'engeldelgado|engeldlgado|Engelbert|dev\.engel' <same scope>` → expect 0
3. `xcrun swiftc -parse` every changed .swift file → 0 failures
4. `git diff --check` → clean
5. NO swift build, NO swift test, NO commit (orchestrator owns build gate).

## Return schema (same JSON as agent-brief.md)
{verdict, files_changed, files_flagged_binary, residuals_left, crossrefs, notes}
Crossref candidates to NOTE (not edit): scripts/CI referencing test paths or bundle names = A5's scope.
Process files in DESCENDING size order (Package.swift first, then SettingsTab, Docs, …) so maximum
work is banked if you run low. If nearing exhaustion, stop and return partial with verdict "partial".
