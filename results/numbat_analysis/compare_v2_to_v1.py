#!/usr/bin/env python3
"""Compare new (2026-05-12, branch-detection + SciML 3 stack) vs old (2026-05-06).

For the NEW benchmark, picks the oracle-best row from each cell's result.csv
(since the new pipeline puts residual-best at row 0; we want apples-to-apples
against the old pipeline's oracle-best row 0).

Joins against the old benchmark's flat_results_with_metrics.csv (already
contains oracle-best metrics, since the old pipeline's row 0 was oracle-sorted).

Outputs three tables under results/numbat_analysis/branch_detection_comparison/:
  - accuracy_per_cell.csv: cell-level new vs old max_rel_err + wall_time + n_rows
  - aggregate_per_system_noise.csv: per-(system, run, noise) summary
  - regression_callouts.md: cells where new is substantially worse than old

Skips cells in the new benchmark that haven't produced result.csv yet
(stragglers); they appear as "incomplete" in the per-cell table.
"""
import csv
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
BENCH_NEW = REPO / "benchmark_numbat_2026-05-12"
BENCH_OLD = REPO / "benchmark_numbat_2026-05-06"
OLD_FLAT = REPO / "results/numbat_analysis/flat_results_with_metrics.csv"
OUT_DIR = REPO / "results/numbat_analysis/branch_detection_comparison"
OUT_DIR.mkdir(parents=True, exist_ok=True)


def normalize_col(c: str) -> str:
    """Strip (t) suffix some cols carry."""
    return c[:-3] if c.endswith("(t)") else c


def read_csv(path: Path):
    """Tiny stdlib CSV reader → list of dicts."""
    with open(path) as f:
        r = csv.DictReader(f)
        return list(r), r.fieldnames or []


def load_huge_json(bench: Path):
    j = json.load(open(bench / "huge_json.json"))
    return {c["id"]: c for c in j["instances"]}


def per_cell_oracle_max_rel_err(result_csv: Path, truth_id_vars: dict):
    """For a result.csv with N rows, return:
      - best_oracle_max: minimum over rows of max_rel_err vs truth (id vars only)
      - best_row_idx: which row achieved it (0-based)
      - n_rows: total rows in result.csv
      - row0_oracle_max: max_rel_err of row 0 (residual-best under new pipeline)
    """
    rows, fieldnames = read_csv(result_csv)
    if not rows:
        return None
    norm_fields = {normalize_col(c): c for c in fieldnames}

    def row_max_rel_err(row):
        vals = []
        for var, tv in truth_id_vars.items():
            if var not in norm_fields:
                continue
            try:
                ev = float(row[norm_fields[var]])
            except (ValueError, TypeError, KeyError):
                continue
            if abs(tv) > 1e-15:
                vals.append(abs(ev - tv) / abs(tv))
            else:
                vals.append(abs(ev - tv))
        return max(vals) if vals else float("inf")

    errs = [row_max_rel_err(r) for r in rows]
    if not errs:
        return None
    best_i = min(range(len(errs)), key=lambda i: errs[i])
    return {
        "best_oracle_max": errs[best_i],
        "best_row_idx": best_i,
        "n_rows": len(rows),
        "row0_oracle_max": errs[0],
    }


def load_wall(p: Path):
    if not p.exists():
        return None
    try:
        return float(p.read_text().strip().split()[0])
    except Exception:
        return None


def read_non_id(bench: Path) -> dict:
    """Return {system_name: set(of_non_id_var_names_normalized)} from metadata."""
    out = {}
    for est in ("odepe_v2_polish", "odepe_v2_nopolish"):
        rd = bench / "filetree" / f"{est}_run"
        if not rd.exists():
            continue
        for cell in rd.iterdir():
            md = cell / "odepe_metadata.json"
            if not md.exists():
                continue
            sn = cell.name.rsplit("_", 2)[0]
            if sn in out:
                continue
            try:
                d = json.load(open(md))
            except Exception:
                continue
            unid = d.get("best", {}).get("all_unidentifiable") or []
            out[sn] = {normalize_col(v) for v in unid}
    return out


def main():
    print(f"Loading huge_json from new bench dir...")
    instances = load_huge_json(BENCH_NEW)
    print(f"  {len(instances)} cells")

    # Use the new bench's discovered non-id (it's bigger; the old run's
    # synth-aggregate bug dropped these to []).
    print(f"Discovering non-id parameters from metadata...")
    non_id = read_non_id(BENCH_NEW)
    print(f"  systems with non-id flags: {sorted(s for s, v in non_id.items() if v)}")

    # Load old flat metrics (already has oracle-best max_rel_err for each cell)
    print(f"Loading old flat metrics: {OLD_FLAT}")
    old_rows, _ = read_csv(OLD_FLAT)
    # Index by (run, id)
    old_by_key = {}
    for r in old_rows:
        if r["run"] not in ("odepe_v2_polish", "odepe_v2_nopolish"):
            continue
        old_by_key[(r["run"], r["id"])] = r

    # Walk new benchmark cells
    per_cell = []
    n_incomplete = 0
    for est in ("odepe_v2_polish", "odepe_v2_nopolish"):
        run_dir = BENCH_NEW / "filetree" / f"{est}_run"
        if not run_dir.exists():
            continue
        for cell_dir in sorted(run_dir.iterdir()):
            cell_id = cell_dir.name
            if cell_id not in instances:
                continue
            inst = instances[cell_id]
            sys_name = inst["name"]
            non_id_set = non_id.get(sys_name, set())

            truth_id_vars = {}
            for v, val in (inst.get("state_values") or {}).items():
                if v not in non_id_set:
                    truth_id_vars[v] = val
            for v, val in (inst.get("parameter_values") or {}).items():
                if v not in non_id_set:
                    truth_id_vars[v] = val

            result_csv = cell_dir / "result.csv"
            if not result_csv.exists():
                n_incomplete += 1
                per_cell.append({
                    "system": sys_name,
                    "run": est,
                    "noise_label": cell_id.rsplit("_", 1)[1],
                    "id": cell_id,
                    "status_new": "incomplete",
                })
                continue

            stats = per_cell_oracle_max_rel_err(result_csv, truth_id_vars)
            wall = load_wall(cell_dir / "wall_time_seconds.txt")

            old = old_by_key.get((est, cell_id), {})
            old_max = old.get("max_rel_error")
            try:
                old_max_f = float(old_max) if old_max not in ("", None) else None
            except (TypeError, ValueError):
                old_max_f = None
            try:
                old_wall_f = float(old.get("time", "")) if old.get("time", "") else None
            except (TypeError, ValueError):
                old_wall_f = None

            per_cell.append({
                "system": sys_name,
                "run": est,
                "noise_label": cell_id.rsplit("_", 1)[1],
                "id": cell_id,
                "status_new": "ok" if stats else "empty_result",
                "new_oracle_max": (stats["best_oracle_max"] if stats else None),
                "new_n_rows": (stats["n_rows"] if stats else None),
                "new_row0_oracle_max": (stats["row0_oracle_max"] if stats else None),
                "new_best_row_idx": (stats["best_row_idx"] if stats else None),
                "new_wall_s": wall,
                "old_oracle_max": old_max_f,
                "old_wall_s": old_wall_f,
                "old_n_rows": int(old.get("n_solutions", 0)) if old.get("n_solutions", "").isdigit() else None,
            })

    # Write per-cell csv
    out_per_cell = OUT_DIR / "accuracy_per_cell.csv"
    keys = list(per_cell[0].keys())
    with open(out_per_cell, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(per_cell)
    print(f"  wrote {out_per_cell}  ({len(per_cell)} rows, {n_incomplete} incomplete)")

    # Aggregate per (system, run, noise)
    def median(xs):
        xs = sorted(x for x in xs if x is not None and x == x)
        if not xs:
            return None
        n = len(xs)
        return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])

    def mean(xs):
        xs = [x for x in xs if x is not None and x == x]
        return sum(xs) / len(xs) if xs else None

    by_bucket = defaultdict(list)
    for r in per_cell:
        if r.get("status_new") != "ok":
            continue
        by_bucket[(r["system"], r["run"], r["noise_label"])].append(r)

    agg_rows = []
    for key in sorted(by_bucket.keys()):
        sys_name, run, noise = key
        cells = by_bucket[key]
        new_max = [c["new_oracle_max"] for c in cells]
        old_max = [c["old_oracle_max"] for c in cells]
        new_wall = [c["new_wall_s"] for c in cells]
        old_wall = [c["old_wall_s"] for c in cells]
        new_rows = [c["new_n_rows"] for c in cells]

        # success-at-X is over the cells in this bucket
        def succ(metrics, threshold):
            ok = [m for m in metrics if m is not None and m < threshold]
            return len(ok) / max(1, len([m for m in metrics if m is not None]))

        agg_rows.append({
            "system": sys_name,
            "run": run,
            "noise_label": noise,
            "n_cells": len(cells),
            "new_med_oracle_max": median(new_max),
            "old_med_oracle_max": median(old_max),
            "new_mean_oracle_max": mean(new_max),
            "old_mean_oracle_max": mean(old_max),
            "new_med_wall_s": median(new_wall),
            "old_med_wall_s": median(old_wall),
            "new_med_n_rows": median(new_rows),
            "new_succ_10pct": succ(new_max, 0.1),
            "old_succ_10pct": succ(old_max, 0.1),
            "new_succ_1pct": succ(new_max, 0.01),
            "old_succ_1pct": succ(old_max, 0.01),
        })

    out_agg = OUT_DIR / "aggregate_per_system_noise.csv"
    keys = list(agg_rows[0].keys()) if agg_rows else []
    with open(out_agg, "w", newline="") as f:
        if keys:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(agg_rows)
    print(f"  wrote {out_agg}  ({len(agg_rows)} bucket rows)")

    # Regression callouts: cells where new is >10x worse than old and old was OK
    callouts = []
    for r in per_cell:
        if r.get("status_new") != "ok":
            continue
        if r["new_oracle_max"] is None or r["old_oracle_max"] is None:
            continue
        if r["old_oracle_max"] > 1.0:  # old was already bad; not a regression
            continue
        if r["new_oracle_max"] > r["old_oracle_max"] * 10 and r["new_oracle_max"] > 0.01:
            callouts.append(r)

    with open(OUT_DIR / "regression_callouts.csv", "w", newline="") as f:
        keys = ["id", "run", "system", "noise_label", "new_oracle_max", "old_oracle_max",
                "new_wall_s", "old_wall_s", "new_n_rows"]
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        w.writerows(callouts)
    print(f"  wrote {OUT_DIR / 'regression_callouts.csv'}  ({len(callouts)} regression cells)")

    # Top-line numbers
    all_new = [r["new_oracle_max"] for r in per_cell if r.get("status_new") == "ok" and r["new_oracle_max"] is not None]
    all_old = [r["old_oracle_max"] for r in per_cell if r.get("status_new") == "ok" and r["old_oracle_max"] is not None]
    all_new_wall = [r["new_wall_s"] for r in per_cell if r.get("status_new") == "ok" and r["new_wall_s"]]
    all_old_wall = [r["old_wall_s"] for r in per_cell if r.get("status_new") == "ok" and r["old_wall_s"]]
    all_new_rows = [r["new_n_rows"] for r in per_cell if r.get("status_new") == "ok" and r["new_n_rows"]]

    print()
    print("=== HEADLINE ===")
    print(f"  cells analyzed: {len(all_new)} (of 2300 possible; {n_incomplete} still running)")
    print(f"  oracle_max_rel_err:  new median={median(all_new):.3e}   old median={median(all_old):.3e}")
    print(f"  wall_time_seconds:   new median={median(all_new_wall):.0f}s  old median={median(all_old_wall):.0f}s  speedup={median(all_old_wall)/median(all_new_wall):.2f}x")
    print(f"  n_solutions returned: new median={median(all_new_rows):.0f}  (old typical ~500-2000)")
    print(f"  success @ 10pct: new={sum(1 for x in all_new if x < 0.1)/len(all_new)*100:.1f}%  old={sum(1 for x in all_old if x < 0.1)/len(all_old)*100:.1f}%")
    print(f"  success @  1pct: new={sum(1 for x in all_new if x < 0.01)/len(all_new)*100:.1f}%  old={sum(1 for x in all_old if x < 0.01)/len(all_old)*100:.1f}%")
    print()
    print(f"  Run-level breakdown:")
    for est in ("odepe_v2_polish", "odepe_v2_nopolish"):
        nr = [r["new_oracle_max"] for r in per_cell if r.get("status_new") == "ok" and r["run"] == est]
        olr = [r["old_oracle_max"] for r in per_cell if r.get("status_new") == "ok" and r["run"] == est and r["old_oracle_max"] is not None]
        print(f"    {est}: new median={median(nr):.3e} (n={len(nr)}) old median={median(olr):.3e} (n={len(olr)})")


if __name__ == "__main__":
    main()
