#!/bin/zsh
# Strict dry-run for the llama.cpp patch series, mirroring build-engines.sh exactly:
# plain `git apply` in numeric order, stop at the first failure.
#   ./strict-apply-check.sh <ref>
set -u
cd "$(dirname "$0")/../../.."
ROOT="$PWD"
VENDOR="$ROOT/vendor/llama.cpp"
REF="$1"
TMP="$(mktemp -d)"
cleanup() { git -C "$VENDOR" worktree remove --force "$TMP/tree" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

git -C "$VENDOR" fetch -q origin 2>/dev/null
git -C "$VENDOR" worktree add -q --detach "$TMP/tree" "$REF" || { echo "cannot checkout $REF"; exit 2; }
TREE="$TMP/tree"

n=0
for patch in "$ROOT"/patches/llama/*.patch; do
    n=$((n+1))
    if ! git -C "$TREE" apply "$patch" 2>"$TMP/err"; then
        echo "STRICT-FAIL at patch #$n ($(basename "$patch")) on $REF"
        sed -n '1,3p' "$TMP/err"
        exit 1
    fi
done
echo "STRICT-CLEAN: all $n patches apply on $REF"
exit 0
