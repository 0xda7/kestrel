"""Merges the fragments in inputs/raw/ (fixed order a, b, c) and writes the sorted
lines to inputs/parts.txt."""
import pathlib

raw = pathlib.Path("inputs/raw")
lines = []
for name in ("a.txt", "b.txt", "c.txt"):
    lines += (raw / name).read_text().splitlines()
out = pathlib.Path("inputs")
out.mkdir(exist_ok=True)
(out / "parts.txt").write_text("\n".join(sorted(lines)) + "\n")
print("wrote inputs/parts.txt")
