#!/usr/bin/env python3
"""Self-contained, re-runnable processor for the quoll-broad benchmark.

Scans every arm (local filetree AND cloud results), computes parameter-recovery
error vs the huge_json truth, and marks anything without a result (pending / stuck /
crashed) as a FAILURE. Re-run any time to pick up stragglers.

Output:
  benchmark_quoll_broad_2026-05-29/analysis/per_cell.csv   (one row per arm x cell)
  benchmark_quoll_broad_2026-05-29/analysis/summary.txt    (per-system/arm rollup)
"""
import json, glob, os, re, csv, statistics, sys
from collections import defaultdict, Counter

BENCH = "benchmark_quoll_broad_2026-05-29"
ARMS  = ["odepe_v2_polish", "odepe_v2_nopolish", "odepe_shade", "amigo2"]
LOC   = f"{BENCH}/filetree"
SUCCESS_THRESH = 0.10   # max-rel-err below this counts as "recovered"

inst = {i["id"]: i for i in json.load(open(f"{BENCH}/huge_json.json"))["instances"]}

def find_result(arm, cell):
    p = f"{LOC}/{arm}_run/{cell}/result.csv"
    if os.path.exists(p) and os.path.getsize(p) > 0:
        return p, "local"
    g = sorted(glob.glob(f"cloud/hetzner/results/broad/*/benchmark_*/filetree/{arm}_run/{cell}/result.csv"))
    g = [x for x in g if os.path.getsize(x) > 0]
    return (g[0], "cloud") if g else (None, None)

def best_recovery(cell, path):
    """Return (best_max_rel, best_median_rel, n_params, n_rows) over the reported
    candidate rows, picking the row with the smallest max-rel-err (best candidate)."""
    I = inst[cell]
    true_p = I["parameter_values"]                       # {name: value}
    nonid  = {str(x).replace("(t)", "") for x in I.get("non_identifiable", [])}
    try:
        rows = list(csv.DictReader(open(path)))
    except Exception:
        return None
    if not rows:
        return None
    best = None
    for row in rows:
        rel = []
        for pname, tval in true_p.items():
            if pname in nonid:
                continue
            v = row.get(pname)
            if v is None:
                v = row.get(pname + "(t)")
            if v is None or v == "":
                continue
            try:
                ev = float(v)
            except ValueError:
                continue
            rel.append(abs(ev - float(tval)) / max(abs(float(tval)), 1e-9))
        if rel:
            mx = max(rel)
            if best is None or mx < best[0]:
                best = (mx, statistics.median(rel), len(rel), len(rows))
    return best

def parse_cell(cell):
    m = re.match(r"^(.+)_(\d+)_([0-9a-z]+)$", cell)
    return (m.group(1), int(m.group(2)), m.group(3)) if m else (cell, -1, "?")

# ---- per-cell pass ----
per_cell = []
for arm in ARMS:
    for cell, I in inst.items():
        system, trial, noise = parse_cell(cell)
        path, src = find_result(arm, cell)
        if path is None:
            per_cell.append(dict(arm=arm, system=system, noise=noise, trial=trial, cell=cell,
                                 status="FAILURE", source="", max_rel="", median_rel="",
                                 n_params="", n_rows="", recovered=0))
            continue
        rec = best_recovery(cell, path)
        if rec is None:
            per_cell.append(dict(arm=arm, system=system, noise=noise, trial=trial, cell=cell,
                                 status="PARSE_FAIL", source=src, max_rel="", median_rel="",
                                 n_params="", n_rows="", recovered=0))
            continue
        mx, med, npar, nrow = rec
        per_cell.append(dict(arm=arm, system=system, noise=noise, trial=trial, cell=cell,
                             status="DONE", source=src, max_rel=mx, median_rel=med,
                             n_params=npar, n_rows=nrow, recovered=int(mx < SUCCESS_THRESH)))

os.makedirs(f"{BENCH}/analysis", exist_ok=True)
with open(f"{BENCH}/analysis/per_cell.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(per_cell[0].keys()))
    w.writeheader(); w.writerows(per_cell)

# ---- summary ----
def fnum(rows, key):
    vals = [r[key] for r in rows if r["status"] == "DONE" and r[key] != ""]
    return statistics.median(vals) if vals else float("nan")

lines = []
tot = len(per_cell)
done = [r for r in per_cell if r["status"] == "DONE"]
fail = [r for r in per_cell if r["status"] == "FAILURE"]
pf   = [r for r in per_cell if r["status"] == "PARSE_FAIL"]
lines.append(f"=== quoll-broad processed @ rerun (4 arms x {len(inst)} cells = {tot}) ===")
lines.append(f"DONE={len(done)}  FAILURE(no result)={len(fail)}  PARSE_FAIL={len(pf)}")
lines.append(f"recovered (max-rel < {SUCCESS_THRESH}): {sum(r['recovered'] for r in done)}/{len(done)} of DONE\n")
lines.append("by ARM:  done/total   recov/done   med(max_rel)   med(median_rel)")
for arm in ARMS:
    a = [r for r in per_cell if r["arm"] == arm]
    ad = [r for r in a if r["status"] == "DONE"]
    lines.append(f"  {arm:20} {len(ad):4}/{len(a):<5}  {sum(r['recovered'] for r in ad):4}/{len(ad):<5}  {fnum(ad,'max_rel'):>9.3g}   {fnum(ad,'median_rel'):>9.3g}")
lines.append("\nby SYSTEM (odepe_v2_polish):  done/total  recov  med(max_rel)  med(median_rel)   [median_rel = typical-param recovery]")
pol = [r for r in per_cell if r["arm"] == "odepe_v2_polish"]
for system in sorted({r["system"] for r in pol}, key=lambda s: -(fnum([r for r in pol if r["system"]==s and r["status"]=="DONE"],'max_rel') or 0)):
    s = [r for r in pol if r["system"] == system]
    sd = [r for r in s if r["status"] == "DONE"]
    rec = sum(r["recovered"] for r in sd)
    lines.append(f"  {system:42} {len(sd):3}/{len(s):<4} {rec:3}  {fnum(sd,'max_rel'):>8.3g}  {fnum(sd,'median_rel'):>10.3g}")

summary = "\n".join(lines)
open(f"{BENCH}/analysis/summary.txt", "w").write(summary + "\n")
print(summary)
print(f"\nwrote {BENCH}/analysis/per_cell.csv ({tot} rows) + summary.txt")
