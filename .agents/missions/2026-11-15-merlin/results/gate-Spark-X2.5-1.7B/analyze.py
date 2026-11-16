#!/usr/bin/env python3
"""Summarize one interleaved gate run: scorecards + wedge census.
Usage: analyze.py <run-root> <wedge-log-dir>(=runroot)"""
import json, sys, os, collections
root = sys.argv[1]
out = []
for mode in ("merlin","baseline"):
    p = os.path.join(root, f"report-{mode}.json")
    if not os.path.exists(p): continue
    r = json.load(open(p))
    tasks = r.get("tasks") or r.get("scores") or []
    # report schema emits `pass` (bool); older analyzer read `passed` and scored
    # every cell False — 2026-11-16 gate report incident. Accept both.
    def _passed(t): return bool(t.get("pass", t.get("passed", False)))
    passed = sum(1 for t in tasks if _passed(t))
    axes = collections.defaultdict(lambda: [0,0])
    for t in tasks:
        axes[t.get("axis","?")][1] += 1
        if _passed(t): axes[t.get("axis","?")][0] += 1
    ax_str = " ".join(f"{a}{'OK' if v[0]==v[1] and v[1]>0 else 'FAIL'}" for a,v in sorted(axes.items()))
    ends = collections.Counter(t.get("end_reason") or t.get("endReason") or "?" for t in tasks)
    out.append(f"{mode}: {passed}/{len(tasks)}  axes: {ax_str}  end_reasons: {dict(ends)}")
# wedge census from wedges.log
for mode in ("merlin","baseline"):
    wl = os.path.join(root, mode, "wedges.log")
    if os.path.exists(wl):
        ev = collections.Counter()
        for line in open(wl):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 4:
                ev[parts[3]] += 1
        out.append(f"wedges[{mode}]: {dict(ev)}")
print("\n".join(out))
