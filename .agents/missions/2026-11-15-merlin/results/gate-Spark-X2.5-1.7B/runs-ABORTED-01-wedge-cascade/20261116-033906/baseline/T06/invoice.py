"""Totals a simple invoice. Prices are per unit, integers."""

PRICES = {"bolt": 3, "nut": 1, "washer": 2}


def invoice_total(items):
    """items: list of (part_name, quantity) tuples. Returns the total price."""
    total = 0
    for name, qty in items:
        total = total + PRICES[name] * qty
    return total
