#!/usr/bin/env python3
"""Three-way compare: 2026-05-06 (original) vs 2026-05-12 (rejected) vs 2026-05-13 (3rd rerun).

Per-cell: argmin-by-oracle-max-rel-err over all rows of result.csv, excluding
structurally unidentifiable variables (sourced from odepe_metadata.json's
best.all_unidentifiable per-system, falling back to {} if not available).

Outputs under results/numbat_analysis/three_way/:
  - accuracy_three_way.csv: per-cell oracle/n_rows/wall_s for each of 06/12/13
  - aggregate_three_way.csv: per-(system,run,noise) medians + success rates
  - regression_trajectory.csv: cells categorized by 06→12→13 trajectory
  - regression_callouts.md: every cell that's still worse than 06 by ≥ 5×, with note

Idempotent. Skips cells in 13 missing result.csv (treated as incomplete).
"""
import csv
import json
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH_06 = REPO / "benchmark_numbat_2026-05-06"
BENCH_12 = REPO / "benchmark_numbat_2026-05-12"
BENCH_13 = REPO / "benchmark_numbat_2026-05-13"
OUT_DIR = REPO / "results/numbat_analysis/three_way"
OUT_DIR.mkdir(parents=True, exist_ok=True)

ESTIMATORS = ("odepe_v2_polish", "odepe_v2_nopolish")


def normalize_col(c: str) -> str:
    return c[:-3] if c.endswith("(t)") else c


def read_csv_dicts(path: Path):
    with open(path) as f:
        r = csv.DictReader(f)
        return list(r), r.fieldnames or []


def load_huge_json(bench: Path):
    j = json.load(open(bench / "huge_json.json"))
    return {c["id"]: c for c in j["instances"]}


def read_non_id_per_system(bench: Path) -> dict:
    """{system_name: set(of_non_id_var_names_normalized)} from any cell's
    odepe_metadata.json[best][all_unidentifiable]. We assume non-id is a
    structural property of the system, so first hit wins."""
    out = {}
    for est in ESTIMATORS:
        rd = bench / "filetree" / f"{est}_run"
        if not rd.exists():
            continue
        for cell in rd.iterdir():
            md = cell / "odepe_metadata.json"
            if not md.exists():
                continue
            sn = cell.name.rsplit("_", 2)[0]
            if sn in out and out[sn]:
                continue
            try:
                d = json.load(open(md))
            except Exception:
                continue
            unid = d.get("best", {}).get("all_unidentifiable") or []
            new = {normalize_col(v) for v in unid}
            if sn not in out or (new and not out[sn]):
                out[sn] = new
    return out


def per_cell_oracle(result_csv: Path, truth_id_vars: dict):
    """Return (best_oracle, best_row, n_rows, row0_oracle) or None."""
    if not result_csv.exists():
        return None
    rows, fieldnames = read_csv_dicts(result_csv)
    if not rows:
        return None
    norm_fields = {normalize_col(c): c for c in fieldnames}

    def row_err(row):
        vals = []
        for v, tv in truth_id_vars.items():
            if v not in norm_fields:
                continue
            try:
                ev = float(row[norm_fields[v]])
            except (ValueError, TypeError, KeyError):
                continue
            if abs(tv) > 1e-15:
                vals.append(abs(ev - tv) / abs(tv))
            else:
                vals.append(abs(ev - tv))
        return max(vals) if vals else float("inf")

    errs = [row_err(r) for r in rows]
    best_i = min(range(len(errs)), key=lambda i: errs[i])
    return errs[best_i], best_i, len(rows), errs[0]


def load_wall(p: Path):
    if not p.exists():
        return None
    try:
        return float(p.read_text().strip().split()[0])
    except Exception:
        return None


def main():
    print(f"Loading huge_json from {BENCH_13.name}...")
    instances = load_huge_json(BENCH_13)
    print(f"  {len(instances)} cells in huge_json")

    # Pool non-id from all three benchmarks (some systems may only have non-id
    # detected in newer runs due to bug fixes in odepe-side identifiability logic)
    non_id = {}
    for bench in (BENCH_13, BENCH_12, BENCH_06):
        per_bench = read_non_id_per_system(bench)
        for sn, vs in per_bench.items():
            if sn not in non_id or (vs and not non_id[sn]):
                non_id[sn] = vs
    flagged = sorted(s for s, v in non_id.items() if v)
    print(f"  systems with non-id flags: {flagged}")
    for s in flagged:
        print(f"    {s}: {sorted(non_id[s])}")

    rows_out = []
    incomplete_13 = 0
    for est in ESTIMATORS:
        for cell_id, inst in sorted(instances.items()):
            sn = inst["name"]
            non_id_set = non_id.get(sn, set())
            truth_id = {}
            for v, val in (inst.get("state_values") or {}).items():
                if v not in non_id_set:
                    truth_id[v] = val
            for v, val in (inst.get("parameter_values") or {}).items():
                if v not in non_id_set:
                    truth_id[v] = val

            def stats_for(bench: Path):
                cd = bench / "filetree" / f"{est}_run" / cell_id
                rcsv = cd / "result.csv"
                w = load_wall(cd / "wall_time_seconds.txt")
                o = per_cell_oracle(rcsv, truth_id)
                if o is None:
                    return None, None, None, None, w
                return o[0], o[1], o[2], o[3], w

            o06, br06, n06, r006, w06 = stats_for(BENCH_06)
            o12, br12, n12, r012, w12 = stats_for(BENCH_12)
            o13, br13, n13, r013, w13 = stats_for(BENCH_13)

            if o13 is None:
                incomplete_13 += 1

            rows_out.append({
                "system": sn,
                "run": est,
                "noise_label": cell_id.rsplit("_", 1)[1],
                "id": cell_id,
                "non_id_vars": ";".join(sorted(non_id_set)),
                # 06
                "o06": o06, "n06": n06, "w06": w06,
                # 12
                "o12": o12, "n12": n12, "w12": w12,
                # 13
                "o13": o13, "n13": n13, "w13": w13,
                # Trajectory flags
                "status_13": "ok" if o13 is not None else "incomplete",
            })

    out_path = OUT_DIR / "accuracy_three_way.csv"
    keys = list(rows_out[0].keys())
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows_out)
    print(f"wrote {out_path}  ({len(rows_out)} rows, {incomplete_13} incomplete in 13)")

    # === Aggregate per (system, run, noise) ===
    def median(xs):
        xs = sorted(x for x in xs if x is not None and x == x)
        if not xs:
            return None
        n = len(xs)
        return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])

    def safe_sum(xs):
        xs = [x for x in xs if x is not None and x == x]
        return sum(xs) if xs else None

    def succ_at(metrics, threshold):
        finite = [m for m in metrics if m is not None and m == m]
        if not finite:
            return None
        return sum(1 for m in finite if m < threshold) / len(finite)

    by_bucket = defaultdict(list)
    for r in rows_out:
        if r["status_13"] != "ok":
            continue
        by_bucket[(r["system"], r["run"], r["noise_label"])].append(r)

    agg = []
    for key in sorted(by_bucket.keys()):
        sn, run, nz = key
        cells = by_bucket[key]
        agg.append({
            "system": sn, "run": run, "noise_label": nz, "n": len(cells),
            "med_06": median([c["o06"] for c in cells]),
            "med_12": median([c["o12"] for c in cells]),
            "med_13": median([c["o13"] for c in cells]),
            "succ_1pct_06": succ_at([c["o06"] for c in cells], 0.01),
            "succ_1pct_12": succ_at([c["o12"] for c in cells], 0.01),
            "succ_1pct_13": succ_at([c["o13"] for c in cells], 0.01),
            "succ_01pct_06": succ_at([c["o06"] for c in cells], 0.001),
            "succ_01pct_12": succ_at([c["o12"] for c in cells], 0.001),
            "succ_01pct_13": succ_at([c["o13"] for c in cells], 0.001),
            "succ_10pct_06": succ_at([c["o06"] for c in cells], 0.10),
            "succ_10pct_12": succ_at([c["o12"] for c in cells], 0.10),
            "succ_10pct_13": succ_at([c["o13"] for c in cells], 0.10),
            "succ_50pct_06": succ_at([c["o06"] for c in cells], 0.50),
            "succ_50pct_12": succ_at([c["o12"] for c in cells], 0.50),
            "succ_50pct_13": succ_at([c["o13"] for c in cells], 0.50),
            "sum_wall_06": safe_sum([c["w06"] for c in cells]),
            "sum_wall_12": safe_sum([c["w12"] for c in cells]),
            "sum_wall_13": safe_sum([c["w13"] for c in cells]),
            "med_n13": median([c["n13"] for c in cells]),
        })
    out_path = OUT_DIR / "aggregate_three_way.csv"
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(agg[0].keys()))
        w.writeheader()
        w.writerows(agg)
    print(f"wrote {out_path}  ({len(agg)} buckets)")

    # === Regression trajectory: classify each cell ===
    traj_rows = []
    for r in rows_out:
        if r["status_13"] != "ok" or r["o06"] is None or r["o12"] is None:
            continue
        o06, o12, o13 = r["o06"], r["o12"], r["o13"]
        # Trajectory categories:
        if o12 > max(10 * o06, 1e-3) and o06 < 1.0:
            # 12 regressed vs 06
            if o13 < max(o12 / 5, 2 * o06):
                cat = "recovered_vs_12"  # 13 fixed it
            elif o13 < max(o12 / 2, o06 * 10):
                cat = "partial_recovery"
            else:
                cat = "persistent_regression"
        elif o13 > max(10 * o12, 1e-3) and o12 < 1.0:
            cat = "new_regression_vs_12"
        else:
            cat = "no_change"
        traj_rows.append({
            "id": r["id"], "run": r["run"], "system": r["system"], "noise": r["noise_label"],
            "o06": o06, "o12": o12, "o13": o13,
            "n06": r["n06"], "n12": r["n12"], "n13": r["n13"],
            "w06": r["w06"], "w12": r["w12"], "w13": r["w13"],
            "category": cat,
        })
    out_path = OUT_DIR / "regression_trajectory.csv"
    if traj_rows:
        with open(out_path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(traj_rows[0].keys()))
            w.writeheader()
            w.writerows(traj_rows)
        print(f"wrote {out_path}  ({len(traj_rows)} cells)")

    # Summary
    counts = defaultdict(int)
    for r in traj_rows:
        counts[r["category"]] += 1
    print()
    print("=== Trajectory summary ===")
    for c, n in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"  {c}: {n}")

    # === Headline summary ===
    print()
    print("=== Headline ===")
    completed_06 = sum(1 for r in rows_out if r["o06"] is not None)
    completed_12 = sum(1 for r in rows_out if r["o12"] is not None)
    completed_13 = sum(1 for r in rows_out if r["o13"] is not None)
    print(f"  cells with oracle: 06={completed_06}, 12={completed_12}, 13={completed_13}")
    print(f"  median oracle (overall):")
    print(f"    06: {median([r['o06'] for r in rows_out]):.3e}")
    print(f"    12: {median([r['o12'] for r in rows_out]):.3e}")
    o13_med = median([r["o13"] for r in rows_out if r["o13"] is not None])
    print(f"    13: {o13_med:.3e}" if o13_med else "    13: (no data)")

    for thr_lbl, thr in [("0.1%", 0.001), ("1%", 0.01), ("10%", 0.10), ("50%", 0.50), ("100%", 1.0)]:
        s06 = succ_at([r["o06"] for r in rows_out], thr)
        s12 = succ_at([r["o12"] for r in rows_out], thr)
        s13 = succ_at([r["o13"] for r in rows_out if r["o13"] is not None], thr)
        print(f"  success @ {thr_lbl}: 06={s06*100:.1f}%  12={s12*100:.1f}%  13={s13*100:.1f}%")

    # Wall time
    sw06 = safe_sum([r["w06"] for r in rows_out])
    sw12 = safe_sum([r["w12"] for r in rows_out])
    sw13 = safe_sum([r["w13"] for r in rows_out if r["w13"] is not None])
    print(f"  total wall (CPU-hr): 06={sw06/3600:.0f}, 12={sw12/3600:.0f}, 13={sw13/3600:.0f}")

if __name__ == "__main__":
    main()
