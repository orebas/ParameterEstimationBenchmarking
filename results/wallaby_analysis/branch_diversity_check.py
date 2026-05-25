#!/usr/bin/env python3
"""Branch-diversity sanity check on the M-truncated wallaby pool.

WHAT THIS DOES:
For each ODEPE wallaby cell with M >= 2 rows, verify that the stored M rows
ARE pairwise separated by the default branch_diversity_eps = 0.01 (L∞ in
identifiable parameter space). If they are: the selection step worked. If
not: the cell has a near-duplicate pair that the selection step let through.

WHAT THIS DOES NOT DO:
Replay the actual `select_branch_diverse_reps` algorithm — that needs the
pre-truncation pool of N > M candidates which was not dumped on Wallaby.
This script verifies the OUTPUT (the stored M rows) is diverse; it cannot
measure the diversity selection's effect at the truncation step.

Full branch-diversity ablation deferred to Quoll smoke/pilot with
`dump_raw_candidates_path` enabled.

Outputs:
- results/wallaby_analysis/branch_diversity_check/check.csv
- results/wallaby_analysis/branch_diversity_check/check.md
"""

import csv
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "results"))
from _shared.branch_classifier import (  # noqa: E402
    normalize_var_name,
    pairwise_max_rel_distance,
)

BENCH = REPO_ROOT / "benchmark_wallaby_2026-05-17"
FILETREE = BENCH / "filetree"
HUGE_JSON = BENCH / "huge_json.json"
OUT_DIR = REPO_ROOT / "results" / "wallaby_analysis" / "branch_diversity_check"

METHODS = ["odepe_v2_polish", "odepe_v2_nopolish"]
METHOD_LABELS = {
    "odepe_v2_polish": "ODEPE-v2 (polish)",
    "odepe_v2_nopolish": "ODEPE-v2 (no polish)",
}
EPS = 0.01  # ODEPE branch_diversity_eps default


def load_huge_json() -> Dict[str, dict]:
    with open(HUGE_JSON) as f:
        return {c["id"]: c for c in json.load(f)["instances"]}


def load_cell_unidentifiable(cell_dir: Path, fallback: set) -> set:
    meta = cell_dir / "odepe_metadata.json"
    if not meta.exists():
        return set(fallback)
    try:
        with open(meta) as f:
            m = json.load(f)
        au = m.get("best", {}).get("all_unidentifiable")
        if au is None:
            return set(fallback)
        return {normalize_var_name(v) for v in au}
    except (json.JSONDecodeError, OSError):
        return set(fallback)


def load_result_rows(cell_dir: Path) -> List[Dict[str, float]]:
    p = cell_dir / "result.csv"
    if not p.exists():
        return []
    with open(p, newline="") as f:
        reader = csv.DictReader(f)
        rows: List[Dict[str, float]] = []
        for raw in reader:
            row: Dict[str, float] = {}
            for k, v in raw.items():
                if v is None or v == "":
                    continue
                try:
                    row[k] = float(v)
                except (TypeError, ValueError):
                    pass
            if row:
                rows.append(row)
    return rows


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    instances = load_huge_json()

    per_method: Dict[str, Dict[str, int]] = defaultdict(
        lambda: {"n_mult_cells": 0, "n_diverse": 0, "n_near_dup": 0}
    )
    per_cell_rows: List[Dict] = []

    for cell_id, instance in instances.items():
        system = instance["name"]
        noise_label = cell_id.rsplit("_", 1)[1]
        fallback_unid = {normalize_var_name(v) for v in instance.get("non_identifiable", [])}

        # Uniform exclusion per cell
        odepe_polish_dir = FILETREE / "odepe_v2_polish_run" / cell_id
        odepe_nopolish_dir = FILETREE / "odepe_v2_nopolish_run" / cell_id
        cell_unid = load_cell_unidentifiable(odepe_polish_dir, fallback_unid)
        if not cell_unid:
            cell_unid = load_cell_unidentifiable(odepe_nopolish_dir, fallback_unid)

        for method in METHODS:
            cell_dir = FILETREE / f"{method}_run" / cell_id
            rows = load_result_rows(cell_dir)
            if len(rows) < 2:
                continue  # nothing to check
            # Check pairwise distance
            min_d = None
            for i in range(len(rows)):
                for j in range(i + 1, len(rows)):
                    d = pairwise_max_rel_distance(rows[i], rows[j], exclude=cell_unid)
                    if d is not None and (min_d is None or d < min_d):
                        min_d = d
            is_diverse = (min_d is not None and min_d >= EPS)
            per_method[method]["n_mult_cells"] += 1
            if is_diverse:
                per_method[method]["n_diverse"] += 1
            else:
                per_method[method]["n_near_dup"] += 1
            per_cell_rows.append({
                "system": system,
                "noise": noise_label,
                "instance": int(instance.get("index", 0)),
                "method": method,
                "n_rows": len(rows),
                "min_pairwise_distance": min_d if min_d is not None else "",
                "is_diverse": is_diverse,
            })

    # ----------------------------------------------------------------------
    # Write check.csv
    # ----------------------------------------------------------------------
    csv_path = OUT_DIR / "check.csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "system", "noise", "instance", "method", "n_rows",
            "min_pairwise_distance", "is_diverse",
        ])
        w.writeheader()
        for r in per_cell_rows:
            w.writerow(r)
    print(f"Wrote {csv_path} ({len(per_cell_rows)} multi-row cells)")

    # ----------------------------------------------------------------------
    # Write check.md
    # ----------------------------------------------------------------------
    md_path = OUT_DIR / "check.md"
    lines: List[str] = []
    lines.append("# Branch-diversity sanity check (Wallaby multi-row cells)\n")
    lines.append("_Generated by `results/wallaby_analysis/branch_diversity_check.py`._\n")
    lines.append("\nFor each ODEPE cell with M=2 rows, this script verifies that the "
                 f"two rows are pairwise separated by at least `branch_diversity_eps = {EPS}` "
                 "in identifiable parameter space (L∞ relative distance).\n")
    lines.append("\n**Scope-limited:** this is a sanity check on the M=2 OUTPUT, not a "
                 "replay of the diversity selection algorithm itself. The diversity "
                 "selection runs on a pre-truncation pool of N>>M candidates which was "
                 "not dumped on Wallaby. Full ablation deferred to Quoll smoke/pilot.\n")

    lines.append("\n## Summary\n")
    lines.append("| Method | Multi-row cells | Diverse (≥ eps) | Near-duplicate (< eps) |")
    lines.append("|---|---:|---:|---:|")
    for method in METHODS:
        b = per_method[method]
        n = b["n_mult_cells"]
        if n == 0:
            continue
        dpct = b["n_diverse"] / n * 100
        ndpct = b["n_near_dup"] / n * 100
        lines.append(
            f"| {METHOD_LABELS[method]} | {n} | {b['n_diverse']} ({dpct:.1f}%) | "
            f"{b['n_near_dup']} ({ndpct:.1f}%) |"
        )

    # Show worst near-duplicate cells
    near_dup_cells = [r for r in per_cell_rows if not r["is_diverse"]]
    near_dup_cells.sort(key=lambda r: r["min_pairwise_distance"] if isinstance(r["min_pairwise_distance"], (int, float)) else 0)

    if near_dup_cells:
        lines.append(f"\n## Near-duplicate cases (min pairwise distance < {EPS})\n")
        lines.append("These are cells where the diversity selection step let two near-duplicate "
                     "rows through. Worst offenders (smallest pairwise separation) first:\n")
        lines.append("\n| System | Noise | Inst | Method | min distance |")
        lines.append("|---|---|---:|---|---:|")
        for r in near_dup_cells[:20]:
            md = r["min_pairwise_distance"]
            if isinstance(md, float):
                md_str = f"{md:.2e}"
            else:
                md_str = str(md)
            lines.append(
                f"| {r['system']} | {r['noise']} | {r['instance']} | {r['method']} | {md_str} |"
            )
        if len(near_dup_cells) > 20:
            lines.append(f"\n_({len(near_dup_cells) - 20} more cells; see CSV.)_")
    else:
        lines.append("\nNo near-duplicate cases found. All multi-row outputs respect `branch_diversity_eps = 0.01`.\n")

    with open(md_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
