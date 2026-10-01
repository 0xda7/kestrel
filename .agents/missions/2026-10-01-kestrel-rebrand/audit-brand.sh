#!/bin/bash
# Kestrel rebrand — brand residual audit.
# Counts remaining brand matches, splitting allowed exceptions from true residuals.
# v2: implements the FULL plan exception list (was: 3 of 8; g_tosh_* symbols and
# tosh-moe.h includes were misclassified as residuals).
# Usage: bash audit-brand.sh [<path>...]
cd "$(dirname "$0")/../../.." || exit 1   # mission dir -> repo root

PATHS=("$@")
[ ${#PATHS[@]} -eq 0 ] && PATHS=(Sources Tests scripts docs patches reference .github Assets .zenodo.json AUTHORS.md CITATION.cff CONTRIBUTING.md README.md SECURITY.md make-app.sh icon-gen.swift)

total=0; exceptions=0; residuals=0; binaries=0
RES_FILE=$(mktemp)
BIN_FILE=$(mktemp)
for p in "${PATHS[@]}"; do
  [ -e "$p" ] || continue
  while IFS= read -r line; do
    if echo "$line" | grep -q '^Binary file .* matches'; then
      binaries=$((binaries+1)); echo "$line" >> "$BIN_FILE"; total=$((total+1)); continue   # operator-gate art (screenshots, DS_Store): tracked, not text-fixable
    fi
    total=$((total+1))
    if echo "$line" | grep -qE 'TOSH_[A-Z0-9_]+'; then exceptions=$((exceptions+1));            # TOSH_* env / -D defines
    elif echo "$line" | grep -qE 'tosh_[a-z0-9_]+'; then exceptions=$((exceptions+1));          # tosh_* C symbols (incl. g_tosh_*)
    elif echo "$line" | grep -qE 'tosh[.-]moe'; then exceptions=$((exceptions+1));              # tosh-moe/ module: paths, headers, tests, tosh.moe.stage
    elif echo "$line" | grep -qiE 'hackintosh|macintosh'; then exceptions=$((exceptions+1));    # hardware-context words containing "tosh"
    elif echo "$line" | grep -qE 'toshllm_'; then exceptions=$((exceptions+1));                 # legacy image-filename prefix (historical data on disk)
    elif echo "$line" | grep -qE 'fullRuleNameToShort|menuItemToShelf|textToShelf|scriptToShelf|bitstoshortreal|4tosHsPR4'; then exceptions=$((exceptions+1)); # JS/base64 false positives
    elif echo "$line" | grep -qiE 'llama\.cpp|stable-diffusion\.cpp|whisper\.cpp'; then exceptions=$((exceptions+1)); # upstream engine mentions
    else residuals=$((residuals+1)); echo "$line" >> "$RES_FILE"; fi
  done < <(grep -Rni --include='*' -e tosh -e TOSH "$p" 2>/dev/null | grep -v '^\.git' | grep -vE '\.(icns|png|jpg|jpeg|pdf|mov|wav|aiff|ico|iconset):')
done
echo "TOTAL_MATCH_LINES=$total"
echo "BINARY_ART_MATCHES=$binaries  (operator-gate: screenshots/DS_Store need replacement art from operator's machine)"
echo "ALLOWED_EXCEPTIONS=$exceptions  (TOSH_ env / tosh_ symbols / tosh-moe module / Hackintosh|Macintosh / toshllm_ legacy prefix / JS false positives / upstream mentions)"
echo "TRUE_RESIDUALS=$residuals"
if [ "$binaries" -gt 0 ]; then echo "--- binary art (operator gate, first 20) ---"; head -20 "$BIN_FILE"; fi
if [ "$residuals" -gt 0 ]; then echo "--- residual detail (first 80) ---"; head -80 "$RES_FILE"; fi
rm -f "$RES_FILE" "$BIN_FILE"
