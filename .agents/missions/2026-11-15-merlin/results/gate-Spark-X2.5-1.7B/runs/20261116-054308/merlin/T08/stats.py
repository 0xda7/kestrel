"""Median of a list of numbers."""


def median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        raise ValueError("empty list")
    return s[n // 2]
