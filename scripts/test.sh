#!/bin/zsh
# Runs the check suite locally: `swift run kestrel-checks`. Zero dependencies —
# no Xcode, no XCTest; the harness lives in Tests/Checks (see the mission
# journal 2026-10-12). Extra args are forwarded to swift run.
set -e
cd "$(dirname "$0")/.."
# Engine-pinned checks need the vendored engines (CI builds them first, see
# build.yml); on a fresh clone they fail confusingly without this warning (audit G12).
if [ ! -x vendor/llama.cpp/build-static/bin/llama-server ]; then
    echo "NOTE: engines not built — engine-pinned checks will fail. Run ./scripts/build-engines.sh first (CI does this before the suite)."
fi
exec swift run --disable-sandbox kestrel-checks "$@"
