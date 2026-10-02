#!/bin/bash
# Kestrel gate: replays the recorded Anthropic SSE stream plus spec-shaped
# tool_use and OpenAI regression fixtures through the real
# ChatStreamAccumulator source. Green = every translation holds.
set -u
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/driver" scripts/anthropic_sse_driver.swift \
  Sources/Chat/ChatStreamProtocol.swift Sources/Chat/ChatParityModels.swift 2>"$out/err" || {
    echo "GATE RED: driver compile failed"; grep -E 'error' "$out/err" | head -5; exit 1; }
"$out/driver" scripts/fixtures/anthropic_sse.txt
