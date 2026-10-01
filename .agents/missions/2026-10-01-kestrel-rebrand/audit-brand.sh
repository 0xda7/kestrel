#!/bin/bash
# Kestrel rebrand — brand residual audit.
# Counts remaining brand matches, splitting allowed exceptions from true residuals.
# Usage: bash audit-brand.sh [<path>...]
cd "$(dirname "$0")/../../.." || exit 1   # mission dir -> repo root

PATHS=("$@")
[ ${#PATHS[@]} -eq 0 ] && PATHS=(Sources Tests scripts docs patches reference .github Assets .zenodo.json AUTHORS.md CITATION.cff CONTRIBUTING.md README.md SECURITY.md make-app.sh icon-gen.swift)

total=0; exceptions=0; residuals=0
RES_FILE=$(mktemp)
for p in "${PATHS[@]}"; do
  [ -e "$p" ] || continue
  while IFS= read -r line; do
    total=$((total+1))
    if echo "$line" | grep -qE 'TOSH_[A-Z0-9_]+'; then exceptions=$((exceptions+1));
    elif echo "$line" | grep -qE '\btosh_[a-z0-9_]+'; then exceptions=$((exceptions+1));
    elif echo "$line" | grep -qiE 'llama\.cpp|stable-diffusion\.cpp|whisper\.cpp'; then exceptions=$((exceptions+1));
    else residuals=$((residuals+1)); echo "$line" >> "$RES_FILE"; fi
  done < <(grep -Rni --include='*' -e tosh -e TOSH "$p" 2>/dev/null | grep -v '^\.git' | grep -vE '\.(icns|png|jpg|jpeg|pdf|mov|wav|aiff|ico|iconset):')
done
echo "TOTAL_MATCH_LINES=$total"
echo "ALLOWED_EXCEPTIONS=$exceptions  (TOSH_ env / tosh_ symbols / upstream engine mentions)"
echo "TRUE_RESIDUALS=$residuals"
if [ "$residuals" -gt 0 ]; then echo "--- residual detail (first 80) ---"; head -80 "$RES_FILE"; fi
rm -f "$RES_FILE"
