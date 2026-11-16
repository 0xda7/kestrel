# MERLIN MEDIA-TOOLS PHASE — staged plan (do not build until hardened core ships)

**Status:** STAGED per plan Amendment 1/4. Code begins only after (a) security-hardening
lands green, (b) the eval gate passes, (c) the hardened Merlin core is committed and shipped
in at least one release.

## Why staged, not built

The legacy media surfaces died for structural reasons (DIAGNOSIS.md P2): video/image
generation shells out to `Resources/bin-image/sd-cli`, which does not exist in the repo;
TTS never existed; none of it was ever wired as agent tools. Rebuilding media as Merlin
tools on an unconfined shell would have compounded SECURITY-REVIEW N2 (unconfined process
spawn) — so the phase is gated on the hardened core by design.

## What gets built (three tools, one at a time, eval-gated each)

| Tool | Backend | Confined-by | First eval task |
|---|---|---|---|
| `image_gen` | bundled sd backend (vendored, exists in repo or clearly absent → tool refuses with "engine not installed" — never a silent stub) | sandbox-exec profile scoped to workspace + model dir, no network, GPU via allowed IOAccelerator family | T-M1: "generate a 512px image of a red cube; assert file exists + PNG magic + dimensions" |
| `tts_say` | macOS `say` (ships with the OS — zero vendored binary risk) rendered to an AIFF/WAV in-workspace | same profile, output file only | T-M2: "speak the first line of answer.txt into speech.wav; assert file exists + WAVE header + duration>1s" |
| `transcribe` | the app's existing Whisper path (Sources/Audio — already functional per DIAGNOSIS) exposed headless | same profile, read-only on the input file | T-M3: "transcribe speech.wav; assert transcript contains the seeded sentence" |

Each tool ships with: JSON schema (M1 grammar-compatible), Guardian post-conditions (file
exists + format magic bytes + size floor), profile notes, and one eval task per tool added as
merlin-eval-v2 (suite governance: v2 re-baselines — see SCORING.md §8).

## Sequence

1. (gate) hardened core shipped + eval gate green.
2. `tts_say` first (smallest risk: OS binary, no model weights, no GPU scheduling).
3. `image_gen` second — ONLY if a real backend binary lands in the repo (vendored or
   operator-installed with a documented path); the tool refuses honestly otherwise.
4. `transcribe` third (reuses a working app surface).
5. Each lands as its own commit with its eval task green before the next starts.

## Explicit non-goals for this phase

- No video generation until a vendored backend exists in-repo (the DIAGNOSIS finding stands:
  a UI that shells to a binary the repo doesn't ship is the exact failure pattern being
  eliminated).
- No network-fetching model weights at agent runtime — models are operator-provisioned.
- No new llama-server flags; media runs reuse the app's existing engine selection.
