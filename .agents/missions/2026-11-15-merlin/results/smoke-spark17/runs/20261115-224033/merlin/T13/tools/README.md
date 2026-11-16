# tools/
build.sh — produces dist/bundle.txt. Requires inputs/parts.txt.
If inputs/parts.txt is missing, generate it first:
    python3 tools/gen_parts.py
gen_parts.py merges the fragments in inputs/raw/ and writes sorted lines to
inputs/parts.txt.
