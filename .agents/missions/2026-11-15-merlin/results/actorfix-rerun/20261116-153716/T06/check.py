"""CHECKER v1 — immutable. Exit 0 only when invoice_total is correct."""
import sys

from invoice import invoice_total

CASES = [
    ((("bolt", 2),), 6),
    ((("nut", 5), ("washer", 3)), 11),
    ((("bolt", 1), ("nut", 1), ("washer", 1)), 6),
    ((), 0),
]

failures = 0
for items, expected in CASES:
    got = invoice_total(list(items))
    if got != expected:
        print(f"FAIL invoice_total({list(items)}) expected {expected}, got {got}")
        failures += 1

if failures:
    print(f"{failures} case(s) failed")
    sys.exit(1)
print("ALL GREEN")
sys.exit(0)
