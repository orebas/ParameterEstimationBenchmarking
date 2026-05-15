#!/usr/bin/env python3
"""For every completed regression probe, compute:
  - oracle err of every polished candidate (vs truth, id vars only)
  - sort by data-residual err
  - find the err-rank of the truth-best candidate

Outputs:
  - topk_needed.csv: one row per probe; columns:
      cell, run, system, noise, n_polished,
      best_oracle, best_oracle_rank, oracle_at_k20,
      oracle_at_k50, oracle_at_k100, oracle_at_k200,
      o06_baseline, o12_baseline
  - topk_needed.md: histogram of "k needed to beat 12 within 2×" and "to match 06 within 2×"
"""
import csv
import json
import os
from pathlib import Path
from collections import Counter

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH_13 = REPO / "benchmark_numbat_2026-05-13"
PROBES = BENCH_13 / "probes"
TRAJ = REPO / "results/numbat_analysis/three_way/regression_trajectory.csv"
ACCURACY_CSV = REPO / "results/numbat_analysis/three_way/accuracy_three_way.csv"
OUT_CSV = REPO / "results/numbat_analysis/three_way/topk_needed.csv"
OUT_MD = REPO / "results/numbat_analysis/three_way/topk_needed.md"


def normalize_col(c: str) -> str:
    return c[:-3] if c.endswith("(t)") else c


def load_truth_and_unident():
    """Returns:
        truth_by_id: id -> dict(var_name -> value) for IDENTIFIABLE vars only
    Uses non_id from accuracy_three_way.csv where it was already computed per system.
    """
    instances = json.load(open(BENCH_13 / "huge_json.json"))["instances"]
    inst_by_id = {c["id"]: c for c in instances}

    # Aggregate non_id per system from accuracy_three_way (already has non_id_vars col)
    non_id_by_sys = {}
    for r in csv.DictReader(open(ACCURACY_CSV)):
        sn = r["system"]
        if sn in non_id_by_sys:
            continue
        non_id_by_sys[sn] = set(v for v in (r["non_id_vars"] or "").split(";") if v)

    truth = {}
    for cid, inst in inst_by_id.items():
        sn = inst["name"]
        non_id = non_id_by_sys.get(sn, set())
        d = {}
        for v, val in (inst.get("state_values") or {}).items():
            if v not in non_id:
                d[v] = val
        for v, val in (inst.get("parameter_values") or {}).items():
            if v not in non_id:
                d[v] = val
        truth[cid] = d
    return truth


def row_oracle_err(row: dict, truth: dict, col_norm: dict):
    vals = []
    for v, tv in truth.items():
        if v not in col_norm:
            continue
        try:
            ev = float(row[col_norm[v]])
        except (ValueError, TypeError, KeyError):
            continue
        if abs(tv) > 1e-15:
            vals.append(abs(ev - tv) / abs(tv))
        else:
            vals.append(abs(ev - tv))
    return max(vals) if vals else float("inf")


def main():
    truth_by_id = load_truth_and_unident()

    # Baselines from the accuracy_three_way table
    baseline = {}
    for r in csv.DictReader(open(ACCURACY_CSV)):
        key = (r["id"], r["run"])
        baseline[key] = {
            "system": r["system"],
            "noise": r["noise_label"],
            "o06": float(r["o06"]) if r["o06"] else None,
            "o12": float(r["o12"]) if r["o12"] else None,
            "o13": float(r["o13"]) if r["o13"] else None,
            "n13": int(r["n13"]) if r["n13"] else None,
        }

    # Walk probe dirs
    rows_out = []
    n_completed, n_no_dump, n_no_result = 0, 0, 0
    for probe in sorted(PROBES.iterdir()):
        dump = probe / "dump" / "polished_dump.csv"
        # probe dir name shape: "<run>__<cell_id>"
        name = probe.name
        if "__" not in name:
            continue
        run, cell_id = name.split("__", 1)

        if not dump.exists():
            if (probe / "dump" / "result.csv").exists():
                n_no_dump += 1
            else:
                n_no_result += 1
            continue
        n_completed += 1

        truth = truth_by_id.get(cell_id, {})
        if not truth:
            continue

        # Read polished_dump.csv
        try:
            polished = list(csv.DictReader(open(dump)))
        except Exception:
            continue
        if not polished:
            continue

        # Determine column names. polished_dump.csv has cols like "polish_idx,
        # polish_source_hc_idx, s::theta_m(t), ..., p::Jm, ..., err, post_polish_error"
        # Strip the s:: / p:: prefixes so we can match truth keys.
        def strip_prefix(c):
            if c.startswith("s::"): return c[3:]
            if c.startswith("p::"): return c[3:]
            return c
        first_row = polished[0]
        fieldnames = list(first_row.keys())
        col_norm = {normalize_col(strip_prefix(c)): c for c in fieldnames}

        # Sort by err ascending
        def err_of(r):
            try: return float(r.get("err") or r.get("post_polish_error") or "inf")
            except: return float("inf")

        polished_sorted = sorted(polished, key=err_of)

        # Compute oracle for each
        oracles = []
        for r in polished_sorted:
            oracles.append(row_oracle_err(r, truth, col_norm))

        best_oracle = min(oracles)
        best_rank = oracles.index(best_oracle) + 1  # 1-based

        def best_at_k(K):
            if K >= len(oracles): return min(oracles)
            return min(oracles[:K])

        bl = baseline.get((cell_id, run), {})
        rows_out.append({
            "cell": cell_id,
            "run": run,
            "system": bl.get("system", ""),
            "noise": bl.get("noise", ""),
            "n_polished": len(polished_sorted),
            "best_oracle": best_oracle,
            "best_oracle_rank": best_rank,
            "oracle_at_k20": best_at_k(20),
            "oracle_at_k50": best_at_k(50),
            "oracle_at_k100": best_at_k(100),
            "oracle_at_k200": best_at_k(200),
            "oracle_at_k500": best_at_k(500),
            "o06": bl.get("o06"),
            "o12": bl.get("o12"),
            "o13": bl.get("o13"),
        })

    if not rows_out:
        print(f"No completed probes yet (no_dump={n_no_dump}, no_result={n_no_result}).")
        return

    rows_out.sort(key=lambda r: (r["system"], r["noise"], r["cell"]))
    with open(OUT_CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows_out[0].keys()))
        w.writeheader()
        w.writerows(rows_out)

    print(f"Probes scanned: completed={n_completed}, no_dump={n_no_dump}, no_result={n_no_result}")
    print(f"wrote {OUT_CSV}  ({len(rows_out)} probes with polish_dump)")

    # Summary buckets
    print()
    print("=== Distribution of best_oracle_rank (1-based err-rank of truth-best) ===")
    ranks = [r["best_oracle_rank"] for r in rows_out]
    buckets = Counter()
    for r in ranks:
        if r <= 20: buckets["≤20 (k20 catches)"] += 1
        elif r <= 50: buckets["21-50"] += 1
        elif r <= 100: buckets["51-100"] += 1
        elif r <= 200: buckets["101-200"] += 1
        elif r <= 500: buckets["201-500"] += 1
        else: buckets[">500"] += 1
    for b in ["≤20 (k20 catches)", "21-50", "51-100", "101-200", "201-500", ">500"]:
        print(f"  {b}: {buckets.get(b, 0)}")

    # How many cells does each K save vs current 13 (top_k=20)?
    print()
    print(f"=== For each K, count of probe cells where best_at_k(K) is materially better than current 13 (≥2× improvement) ===")
    for K in [20, 50, 100, 200, 500]:
        n_improved = 0
        for r in rows_out:
            o13 = r.get("o13")
            if o13 is None or o13 <= 0: continue
            ok = best_at_k(K) if False else r[f"oracle_at_k{K}"]
            if ok < o13 / 2: n_improved += 1
        print(f"  K={K:3d}: would improve {n_improved}/{len(rows_out)} cells by ≥2×")

    # How many recover the 06 baseline (within 2×)?
    print()
    print(f"=== For each K, count of probe cells where best_at_k(K) is within 2× of 06 ===")
    for K in [20, 50, 100, 200, 500]:
        n_match_06 = 0
        n_have_06 = 0
        for r in rows_out:
            o06 = r.get("o06")
            if o06 is None: continue
            n_have_06 += 1
            ok = r[f"oracle_at_k{K}"]
            if ok < max(2 * o06, 1e-10): n_match_06 += 1
        print(f"  K={K:3d}: {n_match_06}/{n_have_06} probe cells within 2× of 06")


if __name__ == "__main__":
    main()
