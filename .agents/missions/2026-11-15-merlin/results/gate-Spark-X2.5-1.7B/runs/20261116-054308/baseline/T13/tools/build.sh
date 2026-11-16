#!/bin/sh
# Builds dist/bundle.txt from inputs/parts.txt
set -e
mkdir -p dist
sort inputs/parts.txt > dist/bundle.txt
echo "BUILD OK: dist/bundle.txt"
