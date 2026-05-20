#!/usr/bin/env python3
"""Per-cell callouts: cells where wallaby is materially off 06.

Reads accuracy_five_way.csv (built by five_way_compare.py) and emits
per_cell_callouts.md flagging cells where wallaby's oracle is:

  - ≥10× worse than 06's oracle (regression)
  - missing in wallaby but ok in 06 (cell-level OOM/timeout)

Plus a smaller "improvements" section: wallaby ≥3× better than 06.

The list is grouped by system, then by (estimator, noise) within system.
"""
import csv
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
ACC = REPO / "results/wallaby_analysis/accuracy_five_way.csv"
OUT = REPO / "results/wallaby_analysis/per_cell_callouts.md"


def parse_float(s):
    if s is None or s == "":
        return None
    try:
        v = float(s)
        if v != v:  # NaN
            return None
        return v
    except (ValueError, TypeError):
        return None


def main():
    rows = list(csv.DictReader(open(ACC)))
    regressions = []   # wallaby ≥10× worse than 06
    incompletes = []   # wallaby missing, 06 had it
    improvements = []  # wallaby ≥3× better than 06
    catastrophes = []  # wallaby > 1 (>100% error)

    for r in rows:
        o06 = parse_float(r["o06"])
        owb = parse_float(r["owb"])

        if o06 is not None and owb is None:
            incompletes.append(r)
            continue

        if o06 is None or owb is None:
            continue

        if owb > 1.0 and o06 < 0.1:
            catastrophes.append((r, owb / max(o06, 1e-15)))
        elif owb > 10 * max(o06, 1e-10):
            regressions.append((r, owb / max(o06, 1e-15)))
        elif o06 > 3 * max(owb, 1e-10) and o06 > 1e-3:
            improvements.append((r, o06 / max(owb, 1e-15)))

    def fmt_row(r, ratio=None):
        suffix = f" (×{ratio:.0f})" if ratio is not None else ""
        return f"  - `{r['id']}` / {r['run']}: 06={parse_float(r['o06']):.2e} → wallaby={parse_float(r['owb']) if parse_float(r['owb']) else 'MISSING':.2e}{suffix}"

    def group_by_system(items):
        g = defaultdict(list)
        for item in items:
            r = item[0] if isinstance(item, tuple) else item
            g[r["system"]].append(item)
        return g

    out = []
    out.append("# Per-cell callouts — wallaby vs 06 baseline")
    out.append("")
    out.append("Generated from `accuracy_five_way.csv` (oracle metric: argmin over all")
    out.append("rows of result.csv on identifiable axes).")
    out.append("")
    out.append("## Summary counts")
    out.append("")
    out.append(f"- **{len(catastrophes)}** catastrophic regressions (wallaby > 100% rel-error while 06 < 10%)")
    out.append(f"- **{len(regressions)}** material regressions (wallaby ≥10× worse than 06)")
    out.append(f"- **{len(incompletes)}** missing in wallaby but completed in 06")
    out.append(f"- **{len(improvements)}** improvements (wallaby ≥3× better than 06, with 06 above 1e-3)")
    out.append("")

    out.append("## Catastrophic regressions")
    out.append("")
    if catastrophes:
        for sn, items in sorted(group_by_system(catastrophes).items()):
            out.append(f"### {sn}")
            for r, ratio in sorted(items, key=lambda x: -x[1]):
                o06 = parse_float(r["o06"])
                owb = parse_float(r["owb"])
                out.append(f"  - `{r['id']}` / `{r['run']}`: 06={o06:.2e}, wallaby={owb:.2e} (×{ratio:.0f})")
            out.append("")
    else:
        out.append("None.")
        out.append("")

    out.append("## Material regressions (≥10×)")
    out.append("")
    if regressions:
        for sn, items in sorted(group_by_system(regressions).items()):
            out.append(f"### {sn}")
            for r, ratio in sorted(items, key=lambda x: -x[1]):
                o06 = parse_float(r["o06"])
                owb = parse_float(r["owb"])
                out.append(f"  - `{r['id']}` / `{r['run']}`: 06={o06:.2e}, wallaby={owb:.2e} (×{ratio:.0f})")
            out.append("")
    else:
        out.append("None.")
        out.append("")

    out.append("## Missing in wallaby")
    out.append("")
    if incompletes:
        for sn, items in sorted(group_by_system(incompletes).items()):
            out.append(f"### {sn}")
            for r in items:
                o06 = parse_float(r["o06"])
                out.append(f"  - `{r['id']}` / `{r['run']}`: 06={o06:.2e}, wallaby=MISSING")
            out.append("")
    else:
        out.append("None.")
        out.append("")

    out.append("## Improvements (≥3×, with 06 above 1e-3)")
    out.append("")
    if improvements:
        for sn, items in sorted(group_by_system(improvements).items()):
            out.append(f"### {sn}")
            for r, ratio in sorted(items, key=lambda x: -x[1]):
                o06 = parse_float(r["o06"])
                owb = parse_float(r["owb"])
                out.append(f"  - `{r['id']}` / `{r['run']}`: 06={o06:.2e}, wallaby={owb:.2e} (×{ratio:.0f} better)")
            out.append("")
    else:
        out.append("None.")
        out.append("")

    OUT.write_text("\n".join(out))
    print(f"wrote {OUT}")
    print(f"  catastrophic: {len(catastrophes)}")
    print(f"  regressions:  {len(regressions)}")
    print(f"  incompletes:  {len(incompletes)}")
    print(f"  improvements: {len(improvements)}")


if __name__ == "__main__":
    main()
