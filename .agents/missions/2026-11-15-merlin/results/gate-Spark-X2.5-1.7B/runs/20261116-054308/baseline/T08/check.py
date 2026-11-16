"""CHECKER v1 — immutable. Exit 0 only when median() is correct."""
import sys

from stats import median

CASES = [
    ([1, 3, 4, 2, 5], 3),
    ([10, 20, 30, 40], 25),
    ([7], 7),
]

failures = 0
for values, expected in CASES:
    got = median(values)
    if got != expected:
        print(f"FAIL median({values}) expected {expected}, got {got}")
        failures += 1

if failures:
    print(f"{failures} case(s) failed")
    sys.exit(1)
print("ALL GREEN")
sys.exit(0)
