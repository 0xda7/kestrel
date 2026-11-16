"""CHECKER v1 — immutable. Exit 0 only when quote() is correct."""
import sys

from quote import quote

CASES = [
    ([("bolt", 8)], 30.0),
    ([("nut", 15)], 22.5),
    ([], 0.0),
]

failures = 0
for cart, expected in CASES:
    got = quote(cart)
    if got != expected:
        print(f"FAIL quote({cart}) expected {expected}, got {got}")
        failures += 1

if failures:
    print(f"{failures} case(s) failed")
    sys.exit(1)
print("ALL GREEN")
sys.exit(0)
