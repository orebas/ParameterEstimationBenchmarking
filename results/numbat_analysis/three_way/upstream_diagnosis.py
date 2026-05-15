#!/usr/bin/env python3
"""For cells fixA K=100 can't recover (oracle > 2× of 06), look at raw_candidates.csv
to figure out WHY the truth-near candidate isn't in the polished list.

Three diagnoses per such cell:
  A) Truth-near candidate exists in raw_candidates.csv AND would pass err filter
     (raw_err < 100 × min_finite_raw_err)
     → polishing should have found it; some other step (pre-polish clustering?) loses it
  B) Truth-near candidate exists in raw but FAILS err filter (raw_err > 100×min)
     → branch_err_factor widening would help
  C) No truth-near candidate in raw at all (best raw oracle far from 06)
     → HC missed the basin; needs upstream fix (column scaling etc.)
"""
import csv, json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH_13 = REPO / "benchmark_numbat_2026-05-13"
PROBES = BENCH_13 / "probes"
SIM = REPO / "results/numbat_analysis/three_way/offline_fix_sim.csv"
ACCURACY = REPO / "results/numbat_analysis/three_way/accuracy_three_way.csv"
OUT_CSV = REPO / "results/numbat_analysis/three_way/upstream_diagnosis.csv"

def normalize_col(c: str) -> str:
    if c.startswith("s::"): c = c[3:]
    if c.startswith("p::"): c = c[3:]
    return c[:-3] if c.endswith("(t)") else c

def load_truth():
    hj = json.load(open(BENCH_13 / "huge_json.json"))
    inst_by_id = {c["id"]: c for c in hj["instances"]}
    non_id_by_sys = {}
    for r in csv.DictReader(open(ACCURACY)):
        sn = r["system"]
        if sn in non_id_by_sys: continue
        non_id_by_sys[sn] = set(v for v in (r["non_id_vars"] or "").split(";") if v)
    truth = {}
    for cid, inst in inst_by_id.items():
        non_id = non_id_by_sys.get(inst["name"], set())
        d = {v: val for v, val in (inst.get("state_values") or {}).items() if v not in non_id}
        d.update({v: val for v, val in (inst.get("parameter_values") or {}).items() if v not in non_id})
        truth[cid] = d
    return truth

def row_oracle(row, truth, col_norm):
    vals = []
    for v, tv in truth.items():
        if v not in col_norm: continue
        try: ev = float(row[col_norm[v]])
        except: continue
        vals.append(abs(ev - tv) / abs(tv) if abs(tv) > 1e-15 else abs(ev - tv))
    return max(vals) if vals else float("inf")

def main():
    truth_by_id = load_truth()
    sim_rows = list(csv.DictReader(open(SIM)))

    # Find unrecovered cells (fixA K=100 > 2× of 06)
    unrec = []
    for r in sim_rows:
        try:
            o06 = float(r["o06"]) if r["o06"] else None
            fixA = float(r["fixA_K100"])
            if o06 and fixA > 2 * max(o06, 1e-10):
                unrec.append(r)
        except: pass

    print(f"Cells where fixA K=100 fails to recover within 2× of 06: {len(unrec)}\n")

    diag_rows = []
    for sim in unrec:
        cell = sim["cell"]; run = sim["run"]
        probe = PROBES / f"{run}__{cell}" / "dump"
        raw_csv = probe / "raw_candidates.csv"
        if not raw_csv.exists(): continue
        truth = truth_by_id.get(cell, {})
        if not truth: continue

        with open(raw_csv) as f:
            reader = csv.DictReader(f)
            fns = reader.fieldnames
            raws = list(reader)
        if not raws: continue

        col_norm = {normalize_col(c): c for c in fns}
        def err_of(r):
            try: return float(r.get("err") or "inf")
            except: return float("inf")

        # Compute oracle for each raw
        oracles = [row_oracle(r, truth, col_norm) for r in raws]
        errs = [err_of(r) for r in raws]

        # Best raw oracle
        best_raw_oracle = min(oracles)
        best_raw_idx = oracles.index(best_raw_oracle)
        # Its err
        best_raw_err = errs[best_raw_idx]

        # Min finite err in raw list
        finite_errs = [e for e in errs if e < 1e10]
        min_err = min(finite_errs) if finite_errs else float("inf")
        # branch_err_factor cutoff
        cutoff_100 = 100 * min_err
        cutoff_1000 = 1000 * min_err
        cutoff_1e6 = 1e6 * min_err

        passes_100 = best_raw_err <= cutoff_100
        passes_1000 = best_raw_err <= cutoff_1000
        passes_1e6 = best_raw_err <= cutoff_1e6

        o06 = float(sim["o06"])
        diagnosis = (
            "C_truth_not_in_raw" if best_raw_oracle > 2 * max(o06, 1e-10) else
            "B_err_filter_drops" if not passes_100 else
            "A_polish_or_pre_clustering_loses"
        )

        diag_rows.append({
            "cell": cell, "run": run, "system": sim["system"], "noise": sim["noise"],
            "o06": o06, "o13": sim["o13"], "fixA_K100": sim["fixA_K100"],
            "n_raw": len(raws),
            "best_raw_oracle": best_raw_oracle,
            "best_raw_err": best_raw_err,
            "min_err": min_err,
            "err_ratio": best_raw_err / min_err if min_err > 0 else float("inf"),
            "passes_branch_err_100": passes_100,
            "passes_branch_err_1000": passes_1000,
            "passes_branch_err_1e6": passes_1e6,
            "diagnosis": diagnosis,
        })

    diag_rows.sort(key=lambda r: (r["diagnosis"], r["cell"]))
    if diag_rows:
        with open(OUT_CSV, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(diag_rows[0].keys()))
            w.writeheader()
            w.writerows(diag_rows)
    print(f"wrote {OUT_CSV}  ({len(diag_rows)} cells diagnosed)\n")

    # Summary
    from collections import Counter
    c = Counter(r["diagnosis"] for r in diag_rows)
    print("=== Diagnosis distribution ===")
    for k, n in c.most_common():
        print(f"  {k}: {n}")

    print()
    print("=== If we bump branch_err_factor to 1000 or 1e6, how many B-diagnosed cells flip? ===")
    n_b_pass1000 = sum(1 for r in diag_rows if r["diagnosis"] == "B_err_filter_drops" and r["passes_branch_err_1000"])
    n_b_pass1e6 = sum(1 for r in diag_rows if r["diagnosis"] == "B_err_filter_drops" and r["passes_branch_err_1e6"])
    n_b_total = c.get("B_err_filter_drops", 0)
    print(f"  cells where widening to 1000 would let truth-near through: {n_b_pass1000}/{n_b_total}")
    print(f"  cells where widening to 1e6 would let truth-near through:   {n_b_pass1e6}/{n_b_total}")

    print()
    print("=== Per-cell detail ===")
    print(f"{'diag':>30s}  {'cell':40s} {'o06':>10s} {'fixA':>10s} {'raw_o':>10s} {'err/min':>10s}")
    for r in diag_rows[:30]:
        print(f"  {r['diagnosis']:>28s}  {r['cell']:40s} {r['o06']:>10.2e} {float(r['fixA_K100']):>10.2e} {r['best_raw_oracle']:>10.2e} {r['err_ratio']:>10.1e}")

if __name__ == "__main__":
    main()
