"""Quote tool: subtotal minus discount, rounded to 2 decimals."""
import json

CFG = json.load(open("config/pricing.json"))


def quote(cart):
    subtotal = sum(CFG["items"][name] * qty for name, qty in cart)
    discount = subtotal * CFG["discount"]
    return round(subtotal - discount, 2)
