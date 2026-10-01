#!/bin/bash
# Step-7 gate: post-pass-1 verification battery (everything except swift build).
# Usage: bash gate-step7.sh
set -u
cd "$(dirname "$0")/../../.." || exit 1
PASS=0; FAIL=0
section(){ echo; echo "== $1 =="; }
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

section "G2 parse gate (all Swift sources)"
pfail=0
while IFS= read -r f; do
  swiftc -parse "$f" 2>/dev/null || { echo "  PARSE_FAIL: $f"; pfail=$((pfail+1)); }
done < <(find Sources Tests -name '*.swift')
[ "$pfail" -eq 0 ] && ok "swiftc -parse: 0 failures ($(find Sources Tests -name '*.swift' | wc -l | tr -d ' ') files)" || bad "parse failures: $pfail"

section "G3 brand residual audit (exception-aware)"
out=$(bash .agents/missions/2026-10-01-kestrel-rebrand/audit-brand.sh 2>&1)
echo "$out"
res=$(echo "$out" | grep -oE 'TRUE_RESIDUALS=[0-9]+' | cut -d= -f2)
[ "${res:-1}" -eq 0 ] && ok "zero true brand residuals" || bad "true brand residuals: $res"

section "G4 personal-detail sweep (zero tolerance)"
# v2: adds wallet/ORCID/youpay terms missed by per-agent contracts (journal gap lesson);
# counts Binary-file match lines from stale .build artifacts correctly.
pat='engeldelgado|engeldlgado|Engelbert|dev\.engel|engeldlgado@gmail\.com|TFUG271bbbQEmFu4wkFHyvNNkYRZC5JDUf|0009-0002-4277-6731|youpay\.me'
sweep() { grep -RniE "$pat" --include='*' . 2>/dev/null | grep -v '^\./\.git/' | grep -v '^\./\.build/' | grep -v '^Binary file \./\.build/' | grep -v '\.agents/missions/' | grep -vE '\.(icns|png|jpg|jpeg|pdf|mov|wav|aiff|ico|DS_Store):'; }
matches=$(sweep | wc -l | tr -d ' ')
[ "$matches" -eq 0 ] && ok "zero personal-detail lines outside mission records (extended pattern incl. wallet/ORCID/youpay)" || { bad "personal-detail lines: $matches"; sweep | head -20; }

section "G5 patch hunk integrity (renames only inside + lines)"
# v2: resolves git rename pairs (old path at HEAD vs new path on disk) instead of
# probing HEAD for a path that no longer exists there.
drift=0
while IFS= read -r line; do
  status=${line%%$'\t'*}
  path=${line#*$'\t'}
  old=""; new=""
  case "$status" in
    R*|C*) old="${path%%$'\t'*}"; new="${path#*$'\t'}" ;;
    *)     old="$path"; new="$path" ;;
  esac
  case "$new" in *.patch|*.diff) ;; *) continue ;; esac
  [ -f "$new" ] || continue
  before=$(git show "HEAD:$old" 2>/dev/null | grep -c '^@@')
  after=$(grep -c '^@@' "$new")
  [ "$before" != "$after" ] && { echo "  HUNK_DRIFT: $new ($before -> $after)"; drift=$((drift+1)); }
done < <(git diff --name-status HEAD)
[ "$drift" -eq 0 ] && ok "all patch hunk headers unchanged (rename-aware)" || bad "hunk drift in $drift patch files"

section "G6 package meta validity"
# v2: pyyaml and yq are unavailable on this host; ruby YAML proven (journal). Also fixes
# a&&b||c fallthrough that could double-count a PASS.
python3 -c "import json;json.load(open('.zenodo.json'))" 2>/dev/null && ok ".zenodo.json valid JSON" || bad ".zenodo.json invalid"
ruby -ryaml -e "YAML.load_file('CITATION.cff')" >/dev/null 2>&1 && ok "CITATION.cff valid YAML" || bad "CITATION.cff invalid"
ruby -ryaml -e "YAML.load_file('.github/workflows/build.yml')" >/dev/null 2>&1 && ok "build.yml valid YAML" || bad "build.yml invalid"

echo; echo "=========== GATE SUMMARY: PASS=$PASS FAIL=$FAIL ==========="
[ "$FAIL" -eq 0 ]
