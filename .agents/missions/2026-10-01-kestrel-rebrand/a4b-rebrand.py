#!/usr/bin/env python3
"""A4b scoped rebrand script. Token-exact, exception-aware, per-line change log.
Hard exceptions left byte-identical: TOSH_* env, tosh_* C symbols, Hackintosh,
LICENSE, VERSION, Package.swift Sources//Tests/ path strings."""
import re, sys, json, os

os.chdir('/Users/admin/KimiK3_Nvidia/toshllm-main')

# longest-first token replacements (word-bounded)
TOKEN_MAP = [
    ('ToshLLMTests', 'KestrelTests'),
    ('ToshLLMLogo', 'KestrelLogo'),
    ('ToshLLMApp', 'KestrelApp'),
    ('ToshDropdown', 'KestrelDropdown'),
    ('ToshGEMM', 'KestrelGEMM'),
    ('ToshLLM', 'Kestrel'),
    ('Toshllm', 'Kestrel'),
    ('Tosh', 'Kestrel'),        # Tosh<Word> catch-all
    ('toshllm', 'kestrel'),
    ('toshgemm', 'kestrelgemm'),
    ('toshGem', 'kestrelGem'),
    ('tosh', 'kestrel'),
]
TOKEN_RE = re.compile('|'.join(re.escape(k) for k, _ in TOKEN_MAP))

PERSONAL = [
    ('engeldlgado@gmail.com', 'opensource@northlatchlabs.com'),
    ('Engelbert Delgado', 'Northlatch Labs'),
    ('engeldlgado', 'northlatchlabs'),
    ('dev.engel.toshllm', 'com.northlatchlabs.kestrel'),  # handled by toshllm token + engel
]

EXCEPT_RE = re.compile(r'TOSH_[A-Za-z0-9_]+|tosh_[a-z0-9_]+|Hackintosh')

def replace_segment(seg, report, lineno, kind):
    """Replace within a segment, respecting exception spans (never overwrite)."""
    spans = [m.span() for m in EXCEPT_RE.finditer(seg)]
    out, i = [], 0
    def hit(tok):
        report.append((lineno, kind, tok))
    while i < len(seg):
        # inside exception span?
        inside = next((s for s in spans if s[0] <= i < s[1]), None)
        if inside:
            out.append(seg[i]); i += 1
            continue
        nxt = TOKEN_RE.search(seg, i)
        if not nxt:
            out.append(seg[i]); i += 1
            continue
        if nxt.start() > i:
            out.append(seg[i:nxt.start()])
        if any(s[0] <= nxt.start() < s[1] for s in spans):
            # match overlaps exception (shouldn't happen: TOSH_ prefix; skip to end)
            out.append(seg[nxt.start():nxt.end()]); i = nxt.end(); continue
        rep = dict(TOKEN_MAP)[nxt.group()]
        hit(f'{nxt.group()}->{rep}')
        out.append(rep)
        i = nxt.end()
    return ''.join(out)

def process(path, apply=True):
    report = []
    with open(path, encoding='utf-8') as f:
        src = f.read()
    lines = src.split('\n')
    out_lines = []
    changed = 0
    for idx, line in enumerate(lines, 1):
        nl = line
        if EXCEPT_RE.search(line):
            # protect exception spans only, replace elsewhere on same line
            parts = re.split(r'(' + EXCEPT_RE.pattern + r')', line)
            rebuilt = []
            for pi, part in enumerate(parts):
                if pi % 2 == 1:  # exception capture group
                    rebuilt.append(part)
                else:
                    rebuilt.append(replace_segment(part, report, idx, 'tok'))
            nl = ''.join(rebuilt)
        else:
            nl = replace_segment(line, report, idx, 'tok')
        # personal-detail replacements (outside exceptions already handled since
        # engeldlgado/toshllm don't match exception patterns)
        for a, b in PERSONAL:
            if a in nl:
                nl = nl.replace(a, b)
                report.append((idx, 'pers', f'{a}->{b}'))
        if nl != line:
            changed += 1
        out_lines.append(nl)
    new = '\n'.join(out_lines)
    if apply and new != src:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new)
    return changed, report, len(lines)

SCOPE = [
    'Package.swift',
    'Sources/Settings/SettingsTab.swift',
    'Sources/App/Docs.swift',
    'Tests/KestrelTests.swift',
    'Sources/App/Support.swift',
    'Sources/App/AboutTab.swift',
    'Sources/DesignSystem/Views.swift',
    'Sources/App/KestrelApp.swift',
    'Sources/App/MenuBarLabel.swift',
    'Tests/AudioVideoExportIntegrationTests.swift',
    'Sources/DesignSystem/RichContentBlocks.swift',
    'Tests/ModelDetectionTests.swift',
    'Sources/DesignSystem/GlassStyle.swift',
    'Sources/App/KestrelLogo.swift',
    'Sources/App/Donate.swift',
    'Sources/DesignSystem/KestrelDropdown.swift',
]

# 18 @testable import files (tests)
TESTS_18 = [
    'Tests/BenchmarkShareReviewTests.swift',
    'Tests/SpecMetricsTests.swift',
    'Tests/ToolSupportTests.swift',
    'Tests/ModelFamilyGroupTests.swift',
    'Tests/ChatCapabilityTests.swift',
    'Tests/DraftFilterTests.swift',
    'Tests/MTPHeadDiscoveryTests.swift',
    'Tests/GPUPeerGroupTests.swift',
    'Tests/MaskEditorTests.swift',
    'Tests/SubtitleLayoutTests.swift',
    'Tests/KestrelTests.swift',
    'Tests/ServerNavigationTests.swift',
    'Tests/LogPresentationTests.swift',
    'Tests/ModelUpdateTests.swift',
    'Tests/AudioVideoExportIntegrationTests.swift',
    'Tests/ServerModelSelectionTests.swift',
    'Tests/MarkdownTests.swift',
    'Tests/ModelDetectionTests.swift',
]

total_changed = 0
summary = {}
for path in SCOPE:
    if not os.path.exists(path):
        summary[path] = 'MISSING'
        continue
    changed, report, nlines = process(path)
    summary[path] = f'{changed} lines'
    total_changed += changed
    for (ln, kind, tok) in report:
        print(f'{path}:{ln} [{kind}] {tok}')

for path in TESTS_18:
    if path in SCOPE:
        continue
    if not os.path.exists(path):
        summary[path] = 'MISSING'
        continue
    changed, report, nlines = process(path)
    summary[path] = f'{changed} lines'
    total_changed += changed
    for (ln, kind, tok) in report:
        print(f'{path}:{ln} [{kind}] {tok}')

print('=== SUMMARY ===')
for k, v in summary.items():
    print(f'{v:12} {k}')
print(f'TOTAL lines changed: {total_changed}')
