"""Compare each case's qualification receipt before and after the image change: validity and every named test outcome."""
import json, sys
before = json.load(open(sys.argv[1])); after = json.load(open(sys.argv[2]))
CONTROLS = ("reference_patch", "empty_patch", "partial_repair", "early_exit"); PARTS = ("hidden", "regression", "submission")
same = 0; rows = []
for case in sorted(before):
    b = (before[case] or {}).get("receipt"); a = (after.get(case) or {}).get("receipt")
    if not a: rows.append((case, "NO RECEIPT AFTER")); continue
    diffs = []; tests = 0
    if b.get("valid") != a.get("valid"): diffs.append(f'valid {b.get("valid")} -> {a.get("valid")}')
    for c in CONTROLS:
        if (b.get(c) or {}).get("passed") != (a.get(c) or {}).get("passed"): diffs.append(f'{c}.passed {(b.get(c) or {}).get("passed")} -> {(a.get(c) or {}).get("passed")}')
        for p in PARTS:
            bp = ((b.get(c) or {}).get(p) or {}); ap = ((a.get(c) or {}).get(p) or {})
            for field in ("passed", "completed", "returncode", "failure_phases", "failure_types", "exclusion_tags"):
                if bp.get(field) != ap.get(field): diffs.append(f"{c}.{p}.{field} differs")
            bt = bp.get("test_results") or {}; at = ap.get("test_results") or {}; tests += len(at)
            for t in sorted(set(bt) | set(at)):
                if bt.get(t) != at.get(t): diffs.append(f"{c}.{p}: {t[:90]}: {bt.get(t)} -> {at.get(t)}")
    image_changed = before[case].get("image") != after[case].get("image")
    rows.append((case, f'valid={a.get("valid")} image_changed={image_changed} named_outcomes={tests} ' + ("IDENTICAL" if not diffs else f"{len(diffs)} DIFFERENCES")))
    same += not diffs
    for d in diffs[:8]: rows.append(("", "   " + d))
for c, r in rows: print(f"{c:20s} {r}")
print(f"\n{same} of {len(before)} cases have identical outcomes")
