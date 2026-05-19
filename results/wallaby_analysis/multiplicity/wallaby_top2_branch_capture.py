#!/usr/bin/env python3
"""For the 3 multiplicity-2 systems (daisy_mamil4, seir, slow_fast):
in how many cells do the FIRST TWO rows of result.csv capture BOTH algebraic branches?

Definition of "different branches": rows 0 and 1 are far apart in identifiable
parameter space (MAD-normalized L∞ distance > THRESH), AND both have low err
(so they're both valid solutions, not row 1 being a junk row).

A cell "captures both branches in top-2" iff:
  - row 0 is near truth (max_rel_err < TRUTH_PASS)
  - row 1 is far from truth AND far from row 0 (i.e., a different branch)
  - row 1 has low err (it's a polished candidate, not noise)
"""
import csv, json, math, statistics
from pathlib import Path

REPO = Path("/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking")
WAL = REPO / "benchmark_wallaby_2026-05-17"

TARGETS = ['daisy_mamil4', 'seir', 'slow_fast']
ESTIMATORS = ['odepe_v2_polish', 'odepe_v2_nopolish']

# "Far apart in param space" — using max relative distance over identifiable axes
BRANCH_DIST_THRESH = 0.05  # 5% apart in any one identifiable axis
# row 0 near truth
TRUTH_PASS_TOP = 0.10  # 10% (coarse threshold per user's paper focus)
# row 1 has low err
LOW_ERR_THRESH = 1e-3

def norm(c): return c[:-3] if c.endswith("(t)") else c

def parse_rows(p):
    if not p.exists(): return [], []
    with open(p) as f: rows = list(csv.DictReader(f))
    raw = rows
    nrm = [{norm(k): v for k, v in r.items()} for r in rows]
    return nrm, raw

def get_unid(d):
    p = d / "odepe_metadata.json"
    if not p.exists(): return set()
    try:
        m = json.load(open(p))
        return set(norm(x) for x in m.get('best', {}).get('all_unidentifiable', []))
    except: return set()

def row_max_rel_err_vs_truth(row, truth, unid, axes):
    has = False; mx = 0.0
    for k in axes:
        if k in unid or k not in truth or k not in row: continue
        try: ev = float(row[k])
        except: continue
        if math.isnan(ev) or math.isinf(ev): continue
        tv = truth[k]
        rel = abs(ev - tv) / abs(tv) if abs(tv) > 1e-10 else abs(ev - tv)
        if rel > mx: mx = rel
        has = True
    return mx if has else None

def row_distance(r1, r2, unid, identifiable_axes):
    """Max rel distance between two rows on identifiable param axes."""
    has = False; mx = 0.0
    for k in identifiable_axes:
        if k in unid: continue
        if k not in r1 or k not in r2: continue
        try:
            v1 = float(r1[k]); v2 = float(r2[k])
        except: continue
        if any(math.isnan(v) or math.isinf(v) for v in (v1, v2)): continue
        denom = max(abs(v1), abs(v2), 1e-10)
        rel = abs(v1 - v2) / denom
        if rel > mx: mx = rel
        has = True
    return mx if has else None

def safe_err(raw_row):
    try:
        v = float(raw_row.get('err', 'inf'))
        if math.isnan(v) or math.isinf(v): return float('inf')
        return v
    except: return float('inf')

with open(WAL / "huge_json.json") as f: j = json.load(f)
truths = {inst['id']: {**inst['state_values'], **inst['parameter_values']} for inst in j['instances']}

print(f"{'system':<18} {'estimator':<22} {'both_in_top2':>14} {'row0_near_truth':>16} {'cells':>6}")
print("-" * 90)
detail_rows = []
for sys_name in TARGETS:
    cells_for_sys = sorted(cid for cid in truths if cid.startswith(sys_name + '_'))
    for est in ESTIMATORS:
        n_total = 0
        n_row0_near_truth = 0
        n_both_in_top2 = 0
        for cid in cells_for_sys:
            d = WAL / "filetree" / f"{est}_run" / cid
            if not (d / "wall_time_seconds.txt").exists(): continue
            n_total += 1
            nrm, raw = parse_rows(d / "result.csv")
            if len(nrm) < 2: continue
            truth = truths[cid]
            unid = get_unid(d)
            id_axes = set(nrm[0].keys()) & set(truth.keys())
            r0 = nrm[0]; r1 = nrm[1]
            raw0 = raw[0]; raw1 = raw[1]
            err0 = safe_err(raw0); err1 = safe_err(raw1)

            r0_to_truth = row_max_rel_err_vs_truth(r0, truth, unid, id_axes)
            r1_to_truth = row_max_rel_err_vs_truth(r1, truth, unid, id_axes)
            r0_to_r1 = row_distance(r0, r1, unid, id_axes)

            row0_near_truth = (r0_to_truth is not None and r0_to_truth <= TRUTH_PASS_TOP)
            if row0_near_truth: n_row0_near_truth += 1

            # Capture both branches: row0 near truth, row1 distant from row0 AND has low err
            different_branches = (row0_near_truth
                                  and r0_to_r1 is not None and r0_to_r1 > BRANCH_DIST_THRESH
                                  and err1 < LOW_ERR_THRESH)
            if different_branches:
                n_both_in_top2 += 1
            detail_rows.append({
                'cell': cid, 'est': est,
                'r0_to_truth': r0_to_truth, 'r1_to_truth': r1_to_truth,
                'r0_to_r1': r0_to_r1, 'err0': err0, 'err1': err1,
                'row0_near_truth': row0_near_truth, 'both_in_top2': different_branches,
            })
        print(f"{sys_name:<18} {est:<22} {n_both_in_top2:>9}/{n_total:>3}    {n_row0_near_truth:>11}/{n_total:>3}    {n_total:>4}")

# Per-cell detail for the 3 systems
print()
print("=== Per-cell detail (3 systems × 2 estimators) ===")
print(f"{'cell':<30} {'est':<22} {'r0~truth':>9} {'r1~truth':>9} {'r0~r1':>9} {'err0':>10} {'err1':>10} {'both?':>6}")
for d in detail_rows:
    rt = f"{d['r0_to_truth']:.2e}" if d['r0_to_truth'] is not None else 'NA'
    rrt = f"{d['r1_to_truth']:.2e}" if d['r1_to_truth'] is not None else 'NA'
    rrr = f"{d['r0_to_r1']:.2e}" if d['r0_to_r1'] is not None else 'NA'
    e0 = f"{d['err0']:.2e}"; e1 = f"{d['err1']:.2e}"
    bt = 'YES' if d['both_in_top2'] else ''
    print(f"{d['cell']:<30} {d['est']:<22} {rt:>9} {rrt:>9} {rrr:>9} {e0:>10} {e1:>10} {bt:>6}")
