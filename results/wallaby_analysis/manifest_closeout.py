#!/usr/bin/env python3
"""Write the [completed] block of benchmark_wallaby_2026-05-17/MANIFEST.toml.

Aggregates per-cell wall_time + has_result counts across the 4 estimators
into the closeout stats. Idempotent — re-running overwrites only the
[completed] section.
"""
import json
import sys
from pathlib import Path
from collections import defaultdict

REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "src"))

from manifest import write_manifest

BENCH = REPO / "benchmark_wallaby_2026-05-17"
ESTIMATORS = ("odepe_v2_polish", "odepe_v2_nopolish", "odepe_shade", "amigo2")


def main():
    config = json.load(open(BENCH / "config" / "config.json"))

    # Aggregate per-estimator stats.
    per_est = {}
    total_wall_seconds = 0.0
    grand_results = 0
    grand_walls = 0
    branch_size_gt1 = 0
    terminal_fallback_firings = 0
    cells_with_metadata = 0
    polish_maxtime_exceeded = 0

    for est in ESTIMATORS:
        rd = BENCH / "filetree" / f"{est}_run"
        if not rd.exists():
            continue
        cells = list(rd.iterdir())
        n_cells = len(cells)
        n_result = sum(1 for c in cells if (c / "result.csv").exists())
        wall_sum = 0.0
        wall_n = 0
        for c in cells:
            wt = c / "wall_time_seconds.txt"
            if wt.exists():
                try:
                    wall_sum += float(wt.read_text().strip().split()[0])
                    wall_n += 1
                except Exception:
                    pass
            md = c / "odepe_metadata.json"
            if md.exists():
                try:
                    d = json.load(open(md))
                    cells_with_metadata += 1
                    best = d.get("best") or {}
                    bs = best.get("branch_size") or 0
                    if bs > 1:
                        branch_size_gt1 += 1
                    if d.get("was_terminal_fallback") or best.get("was_terminal_fallback"):
                        terminal_fallback_firings += 1
                    if best.get("polish_maxtime_exceeded"):
                        polish_maxtime_exceeded += 1
                except Exception:
                    pass

        per_est[est] = {
            "n_cells_expected": n_cells,
            "n_result_landed": n_result,
            "n_missing": n_cells - n_result,
            "total_wall_seconds": wall_sum,
            "total_wall_hours": round(wall_sum / 3600.0, 1),
            "n_wall_recorded": wall_n,
        }
        total_wall_seconds += wall_sum
        grand_results += n_result
        grand_walls += wall_n

    completion_stats = {
        "n_estimators": len(per_est),
        "total_cells_expected": sum(p["n_cells_expected"] for p in per_est.values()),
        "total_result_landed": grand_results,
        "total_missing": sum(p["n_missing"] for p in per_est.values()),
        "total_wall_seconds_all_estimators": round(total_wall_seconds, 0),
        "total_wall_hours_all_estimators": round(total_wall_seconds / 3600.0, 1),
        "cells_with_metadata": cells_with_metadata,
        "cells_with_branch_size_gt1": branch_size_gt1,
        "terminal_fallback_firings": terminal_fallback_firings,
        "polish_maxtime_exceeded_count": polish_maxtime_exceeded,
    }
    for est, stats in per_est.items():
        for k, v in stats.items():
            completion_stats[f"{est}_{k}"] = v

    write_manifest(
        benchmark_dir=BENCH,
        config=config,
        software_list=list(ESTIMATORS),
        phase="completed",
        completion_stats=completion_stats,
    )

    print(f"wrote [completed] section to {BENCH / 'MANIFEST.toml'}")
    print()
    print(f"Summary:")
    for k, v in completion_stats.items():
        if "_" in k and not any(k.startswith(e + "_") for e in ESTIMATORS):
            print(f"  {k}: {v}")
    print()
    print(f"Per-estimator:")
    for est, stats in per_est.items():
        print(f"  {est}:")
        for k, v in stats.items():
            print(f"    {k}: {v}")


if __name__ == "__main__":
    main()
