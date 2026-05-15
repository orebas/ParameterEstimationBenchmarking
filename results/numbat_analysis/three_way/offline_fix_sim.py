#!/usr/bin/env python3
"""Offline simulation of proposed fix variants, using existing polished_dump.csv
files from the 124-cell regression probe (100 polish dumps available).

For each cell, we compute the oracle-best max-rel-err that each variant would
deliver, then compare to:
  - current 13's actual result.csv (`o13`)
  - 06 baseline (`o06`)

Fix variants (all assume the err filter `branch_err_factor` is unchanged for
now — that's a separate axis we don't have data for):

  baseline:   current 13 (clustering + branch_top_k=20). Read from accuracy_three_way.
  fixA_K20:   skip _detect_branches, dedup with cluster_solutions@1e-5, sort by err, top-20
  fixA_K50:   same, top-50
  fixA_K100:  same, top-100
  fixA_K200:  same, top-200
  fixA_K500:  same, top-500
  noClust_K20: skip ALL clustering (no dedup), top-20
  noClust_K100: same, top-100

cluster_solutions distance metric (from analysis_utils.jl): max over all vars
of |x-y|/(|x|+|y|+1). Threshold 1e-5 = essentially "bit-identical convergences".
"""
import csv
import json
from pathlib import Path
from collections import Counter

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH_13 = REPO / "benchmark_numbat_2026-05-13"
PROBES = BENCH_13 / "probes"
ACCURACY = REPO / "results/numbat_analysis/three_way/accuracy_three_way.csv"
OUT_CSV = REPO / "results/numbat_analysis/three_way/offline_fix_sim.csv"
OUT_MD = REPO / "results/numbat_analysis/three_way/offline_fix_sim.md"

CLUSTERING_THRESHOLD = 1e-5


def normalize_col(c: str) -> str:
    if c.startswith("s::"): c = c[3:]
    if c.startswith("p::"): c = c[3:]
    return c[:-3] if c.endswith("(t)") else c


def load_truth_and_unident():
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


def get_vec(row, fieldnames):
    """Vector of (state+param) values used by cluster_solutions's solution_distance."""
    vec = []
    for c in fieldnames:
        if c.startswith("s::") or c.startswith("p::"):
            try: vec.append(float(row[c]))
            except: vec.append(0.0)
    return vec


def solution_dist(va, vb):
    """Max over components of |x-y|/(|x|+|y|+1) - matches Julia solution_distance."""
    return max(abs(x - y) / (abs(x) + abs(y) + 1.0) for x, y in zip(va, vb)) if va else float("inf")


def cluster_dedupe(rows, fieldnames, threshold=CLUSTERING_THRESHOLD):
    """Apply cluster_solutions-style greedy dedup. Keep first row of each cluster."""
    vecs = [get_vec(r, fieldnames) for r in rows]
    keep_idx = []
    kept_vecs = []
    for i, v in enumerate(vecs):
        merged = False
        for kv in kept_vecs:
            if solution_dist(v, kv) < threshold:
                merged = True
                break
        if not merged:
            keep_idx.append(i)
            kept_vecs.append(v)
    return [rows[i] for i in keep_idx]


def main():
    truth_by_id = load_truth_and_unident()
    baseline = {}
    for r in csv.DictReader(open(ACCURACY)):
        baseline[(r["id"], r["run"])] = {
            "system": r["system"], "noise": r["noise_label"],
            "o06": float(r["o06"]) if r["o06"] else None,
            "o12": float(r["o12"]) if r["o12"] else None,
            "o13": float(r["o13"]) if r["o13"] else None,
            "n13": int(r["n13"]) if r["n13"] else None,
        }

    rows_out = []
    for probe_dir in sorted(PROBES.iterdir()):
        dump = probe_dir / "dump" / "polished_dump.csv"
        if not dump.exists(): continue
        name = probe_dir.name
        if "__" not in name: continue
        run, cell = name.split("__", 1)
        truth = truth_by_id.get(cell, {})
        if not truth: continue

        with open(dump) as f:
            reader = csv.DictReader(f)
            fieldnames = reader.fieldnames
            polished = list(reader)
        if not polished: continue

        col_norm = {normalize_col(c): c for c in fieldnames}

        def err_of(r):
            try: return float(r.get("err") or r.get("post_polish_error") or "inf")
            except: return float("inf")

        # Sort by err
        polished_sorted = sorted(polished, key=err_of)

        # Fix A: dedup then top-K
        deduped = cluster_dedupe(polished_sorted, fieldnames)

        def best_oracle_top_k(rows, K):
            top = rows[:K]
            return min(row_oracle(r, truth, col_norm) for r in top) if top else float("inf")

        bl = baseline.get((cell, run), {})
        rec = {
            "cell": cell, "run": run, "system": bl.get("system", ""), "noise": bl.get("noise", ""),
            "n_polished": len(polished),
            "n_deduped": len(deduped),
            "o06": bl.get("o06"), "o12": bl.get("o12"), "o13": bl.get("o13"),
            "n13": bl.get("n13"),
        }
        for K in [20, 50, 100, 200, 500]:
            rec[f"fixA_K{K}"] = best_oracle_top_k(deduped, K)
            rec[f"noClust_K{K}"] = best_oracle_top_k(polished_sorted, K)
        rows_out.append(rec)

    # Write CSV
    with open(OUT_CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows_out[0].keys()))
        w.writeheader()
        w.writerows(rows_out)
    print(f"wrote {OUT_CSV}  ({len(rows_out)} cells)")

    # === Summary tables ===
    def pct(n, d): return f"{n*100/d:.0f}%" if d else "?"

    n = len(rows_out)
    n_have_06 = sum(1 for r in rows_out if r["o06"])

    md = ["# Offline fix simulation\n\n"]
    md.append(f"**Source**: {n} probe cells from 124-cell regression set (polished_dump.csv pre-clustering).\n\n")

    # baseline summary
    o13s = [r["o13"] for r in rows_out if r["o13"] is not None]
    md.append(f"## Baseline (current 13)\n")
    md.append(f"- Median oracle on these probe cells: **{sorted(o13s)[len(o13s)//2]:.2e}**\n")
    md.append(f"- Cells within 2× of 06: {sum(1 for r in rows_out if r['o06'] and r['o13'] and r['o13'] < 2*max(r['o06'], 1e-10))}/{n_have_06} = {pct(sum(1 for r in rows_out if r['o06'] and r['o13'] and r['o13'] < 2*max(r['o06'], 1e-10)), n_have_06)}\n\n")

    md.append("## Recovery to within 2× of 06\n\n")
    md.append("| variant | n recovered | % |\n|---|---|---|\n")
    # baseline current 13
    n_curr = sum(1 for r in rows_out if r["o06"] and r["o13"] and r["o13"] < 2*max(r["o06"], 1e-10))
    md.append(f"| current 13 (clustering + top_k=20) | {n_curr}/{n_have_06} | {pct(n_curr, n_have_06)} |\n")
    for K in [20, 50, 100, 200, 500]:
        n_a = sum(1 for r in rows_out if r["o06"] and r[f"fixA_K{K}"] < 2*max(r["o06"], 1e-10))
        md.append(f"| fixA K={K} (dedup@1e-5 + top-K) | {n_a}/{n_have_06} | {pct(n_a, n_have_06)} |\n")
    for K in [20, 50, 100, 200, 500]:
        n_b = sum(1 for r in rows_out if r["o06"] and r[f"noClust_K{K}"] < 2*max(r["o06"], 1e-10))
        md.append(f"| noClust K={K} (sort polished, top-K) | {n_b}/{n_have_06} | {pct(n_b, n_have_06)} |\n")

    md.append("\n## Improvement over current 13 (≥2× better)\n\n")
    md.append("| variant | n improved | % |\n|---|---|---|\n")
    for K in [20, 50, 100, 200, 500]:
        n_a = sum(1 for r in rows_out if r["o13"] and r["o13"] > 0 and r[f"fixA_K{K}"] < r["o13"] / 2)
        md.append(f"| fixA K={K} | {n_a}/{n} | {pct(n_a, n)} |\n")
    for K in [20, 50, 100, 200, 500]:
        n_b = sum(1 for r in rows_out if r["o13"] and r["o13"] > 0 and r[f"noClust_K{K}"] < r["o13"] / 2)
        md.append(f"| noClust K={K} | {n_b}/{n} | {pct(n_b, n)} |\n")

    md.append("\n## fixA vs noClust at same K (does cluster_solutions dedup hurt?)\n\n")
    md.append("| K | fixA better than noClust | fixA equal | fixA worse |\n|---|---|---|---|\n")
    for K in [20, 50, 100, 200, 500]:
        better = sum(1 for r in rows_out if r[f"fixA_K{K}"] < r[f"noClust_K{K}"] * 0.9)
        worse = sum(1 for r in rows_out if r[f"fixA_K{K}"] > r[f"noClust_K{K}"] * 1.1)
        equal = n - better - worse
        md.append(f"| {K} | {better} | {equal} | {worse} |\n")

    # Headline
    md.append("\n## Headline\n\n")
    n_a100 = sum(1 for r in rows_out if r["o06"] and r["fixA_K100"] < 2*max(r["o06"], 1e-10))
    md.append(f"- **fixA K=100** recovers {n_a100}/{n_have_06} = {pct(n_a100, n_have_06)} of probe cells to 2× of 06\n")
    n_b100 = sum(1 for r in rows_out if r["o06"] and r["noClust_K100"] < 2*max(r["o06"], 1e-10))
    md.append(f"- **noClust K=100** recovers {n_b100}/{n_have_06} = {pct(n_b100, n_have_06)} (essentially same as fixA — dedup@1e-5 only catches identical convergences)\n")
    md.append(f"- vs current 13's {n_curr}/{n_have_06} = {pct(n_curr, n_have_06)} on the same cells\n\n")
    md.append(f"## Median n_deduped (cells get this many candidates if we apply cluster_solutions only)\n\n")
    nds = sorted(r["n_deduped"] for r in rows_out)
    md.append(f"- min={nds[0]}, p25={nds[len(nds)//4]}, median={nds[len(nds)//2]}, p75={nds[3*len(nds)//4]}, max={nds[-1]}\n\n")
    md.append(f"## Median n_polished (cells get this many candidates with NO dedup)\n\n")
    nps = sorted(r["n_polished"] for r in rows_out)
    md.append(f"- min={nps[0]}, p25={nps[len(nps)//4]}, median={nps[len(nps)//2]}, p75={nps[3*len(nps)//4]}, max={nps[-1]}\n")

    OUT_MD.write_text("".join(md))
    print(f"wrote {OUT_MD}")
    print()
    print("".join(md))


if __name__ == "__main__":
    main()
