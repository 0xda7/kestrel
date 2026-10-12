#!/bin/zsh
# Runs the check suite locally: `swift run kestrel-checks`. Zero dependencies —
# no Xcode, no XCTest; the harness lives in Tests/Checks (see the mission
# journal 2026-10-12). Extra args are forwarded to swift run.
set -e
cd "$(dirname "$0")/.."
exec swift run --disable-sandbox kestrel-checks "$@"
