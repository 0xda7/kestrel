#!/bin/zsh
# One-shot release: stamps the CHANGELOG section for the current VERSION,
# commits the bump if needed, tags and pushes. CI publishes the DMG from
# the tag and takes the release body from that CHANGELOG section.
set -e
cd "$(dirname "$0")/.."

V="$(cat VERSION)"

if git rev-parse -q --verify "refs/tags/v$V" > /dev/null; then
    echo "tag v$V already exists; bump VERSION (./make-app.sh) first" >&2
    exit 1
fi

if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    sed -i '' "s/^## \[Unreleased\]/## [$V] - $(date +%F)/" CHANGELOG.md
fi
if ! grep -q "^## \[$V\]" CHANGELOG.md; then
    echo "CHANGELOG.md has no '## [$V]' section and no '## [Unreleased]' to stamp" >&2
    exit 1
fi

# AppInfo.version now reads the bundle's CFBundleShortVersionString (stamped from
# VERSION by make-app.sh); the literal below is only the CLI-checks fallback and the
# sed target. Stamp it here too so a release can never ship mislabeled (v0.89.1 and
# v0.90.0 both shipped mislabeled because the old constant was edited by hand).
sed -i '' "s/static let versionFallback = \"[^\"]*\"/static let versionFallback = \"$V\"/" Sources/App/AboutTab.swift
# Post-condition: the stamp must have matched.
grep -q "static let versionFallback = \"$V\"" Sources/App/AboutTab.swift || {
    echo "error: failed to stamp version $V into Sources/App/AboutTab.swift" >&2; exit 1; }

git add CHANGELOG.md VERSION Sources/App/AboutTab.swift
git diff --cached --quiet || git commit -m "release: $V"

# annotated so the tag is a real object and tag.gpgsign can sign it; a lightweight tag cannot be
git tag -a "v$V" -m "Kestrel v$V"
git push origin main "v$V"
echo "released v$V"
