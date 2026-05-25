#!/usr/bin/env python3
"""Limited rank-strategy ablation on the M-truncated wallaby pool.

WHAT THIS SCRIPT DOES:
For each ODEPE wallaby cell, re-rank the M=1 or M=2 rows of `result.csv`
under :err_only, :sat_err, and :sat_neg1_err (S2 — the Wallaby default).
Report which row becomes "top-pick" under each strategy + per-strategy
top-pick success rate.

WHAT THIS SCRIPT DOES NOT DO — CRITICAL CAVEAT:
The consequential rank-strategy effect happens UPSTREAM of the M-truncation
cut. Wallaby's runs did not dump the pre-truncation candidate pool
(`dump_raw_candidates_path` was nil), so this offline ablation can only show
the truncation-step effect on the M=1/M=2 rows that already survived
clustering + ranking + diversity selection.

A proper rank-strategy ablation requires re-running with
`dump_raw_candidates_path` enabled, which is deferred to Quoll smoke/pilot.

References for the sort-key implementations:
  environments/ODEParameterEstimation/src/core/analysis_utils.jl:s2_sort_key
  Same file, lognorm_score and other rank helpers.

Outputs:
- results/wallaby_analysis/rank_strategy_topM/ablation.csv
- results/wallaby_analysis/rank_strategy_topM/ablation.md
"""

import csv
import json
import math
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "results"))
from _shared.branch_classifier import (  # noqa: E402
    max_rel_error,
    normalize_var_name,
)

BENCH = REPO_ROOT / "benchmark_wallaby_2026-05-17"
FILETREE = BENCH / "filetree"
HUGE_JSON = BENCH / "huge_json.json"
OUT_DIR = REPO_ROOT / "results" / "wallaby_analysis" / "rank_strategy_topM"

# Only the ODEPE variants — AMIGO2/SHADE return K=1 so there's no re-ranking.
METHODS = ["odepe_v2_polish", "odepe_v2_nopolish"]
METHOD_LABELS = {
    "odepe_v2_polish": "ODEPE-v2 (polish)",
    "odepe_v2_nopolish": "ODEPE-v2 (no polish)",
}
STRATEGIES = ["err_only", "sat_err", "sat_neg1_err"]
THRESHOLDS = (0.01, 0.10, 0.50)

# Lower bound used in ODEPE wallaby template (`opt_lb`); the saturation count
# checks parameters against [lb, ub] = [1e-5, 10.0] per wallaby's
# search_bounds. This matches s2_sort_key's saturation_count primitive.
LB = 1e-5
UB = 10.0


def load_huge_json() -> Dict[str, dict]:
    with open(HUGE_JSON) as f:
        data = json.load(f)
    return {c["id"]: c for c in data["instances"]}


def build_truth(instance: dict) -> Dict[str, float]:
    t: Dict[str, float] = {}
    t.update(instance.get("state_values", {}))
    t.update(instance.get("parameter_values", {}))
    return t


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


def saturation_count(row: Dict[str, float], lb: float, ub: float) -> int:
    """Mirror of ODEPE's `saturation_count`: count params strictly at the box edge
    (saturated on lb or ub) within numerical tolerance. ODEPE's implementation
    uses a relative tolerance; for re-ranking M=2 rows we use a strict
    "within 1% of bound" rule which is enough to break ties on rank between
    rows that one of which has saturated parameters.
    """
    n = 0
    for k, v in row.items():
        if not isinstance(v, (int, float)):
            continue
        if k in ("err", "branch_size", "post_polish_error", "polish_source_hc_idx"):
            continue
        if v <= lb * 1.01 or v >= ub * 0.99:
            n += 1
    return n


def is_untagged(row: Dict[str, float]) -> int:
    """Mirror of ODEPE's `is_untagged`: returns 1 if polish_source_hc_idx == -1
    (the candidate came from synthesis / aggregate provenance, not a tagged
    HC.jl root), else 0. Used in :sat_neg1_err to put `-1`-tagged rows last
    among same-saturation candidates.
    """
    val = row.get("polish_source_hc_idx", 0)
    return 1 if (val is not None and float(val) < -0.5) else 0


def sort_key(row: Dict[str, float], strategy: str) -> Tuple[float, ...]:
    err = row.get("err")
    if err is None:
        err = float("inf")
    sat = saturation_count(row, LB, UB)
    untagged = is_untagged(row)
    if strategy == "err_only":
        return (err,)
    if strategy == "sat_err":
        return (sat, err)
    if strategy == "sat_neg1_err":
        return (sat, untagged, err)
    raise ValueError(f"Unknown strategy: {strategy}")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    instances = load_huge_json()

    # Per (method, strategy, threshold) -> {"n_cells", "n_top1_success"}
    counts: Dict[Tuple[str, str, float], Dict[str, int]] = defaultdict(
        lambda: {"n_cells": 0, "n_top1": 0}
    )
    # Track per-cell "did the strategy change row 0?"
    row0_swap: Dict[Tuple[str, str], int] = defaultdict(int)  # vs S2 default
    row0_swap_total: Dict[str, int] = defaultdict(int)  # multi-row cells per method

    n_total = 0

    for cell_id, instance in instances.items():
        truth = build_truth(instance)
        fallback_unid = {normalize_var_name(v) for v in instance.get("non_identifiable", [])}

        # Cross-method-uniform exclusion (same as in naive_all_param_table.py)
        odepe_polish_dir = FILETREE / "odepe_v2_polish_run" / cell_id
        odepe_nopolish_dir = FILETREE / "odepe_v2_nopolish_run" / cell_id
        cell_unid = load_cell_unidentifiable(odepe_polish_dir, fallback_unid)
        if not cell_unid:
            cell_unid = load_cell_unidentifiable(odepe_nopolish_dir, fallback_unid)

        for method in METHODS:
            cell_dir = FILETREE / f"{method}_run" / cell_id
            rows = load_result_rows(cell_dir)
            if not rows:
                for strategy in STRATEGIES:
                    for thresh in THRESHOLDS:
                        counts[(method, strategy, thresh)]["n_cells"] += 1
                continue

            # Re-rank under each strategy
            sorted_by_strat: Dict[str, List[int]] = {}
            for strategy in STRATEGIES:
                idx = list(range(len(rows)))
                idx.sort(key=lambda i: sort_key(rows[i], strategy))
                sorted_by_strat[strategy] = idx

            # Reference: existing wallaby row 0 (= what S2 chose at runtime).
            # The script-level "S2 default" = the row that's currently row 0
            # in the stored result.csv. We compare each strategy's pick against
            # this default to count swaps.
            default_pick = 0

            # Count multi-row cells (where swapping is meaningful)
            if len(rows) > 1:
                row0_swap_total[method] += 1

            for strategy in STRATEGIES:
                pick = sorted_by_strat[strategy][0]
                if strategy != "sat_neg1_err" and pick != default_pick and len(rows) > 1:
                    row0_swap[(method, strategy)] += 1
                err = max_rel_error(rows[pick], truth, exclude=cell_unid)
                for thresh in THRESHOLDS:
                    c = counts[(method, strategy, thresh)]
                    c["n_cells"] += 1
                    if err is not None and err <= thresh:
                        c["n_top1"] += 1

        n_total += 1

    # ----------------------------------------------------------------------
    # Write ablation.csv
    # ----------------------------------------------------------------------
    csv_path = OUT_DIR / "ablation.csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["method", "strategy", "threshold", "n_cells", "top1_success_rate"])
        for (method, strategy, thresh), b in sorted(counts.items()):
            n = b["n_cells"]
            w.writerow([
                METHOD_LABELS[method],
                strategy,
                thresh,
                n,
                f"{b['n_top1'] / n:.4f}" if n else "",
            ])
    print(f"Wrote {csv_path}")

    # ----------------------------------------------------------------------
    # Write ablation.md
    # ----------------------------------------------------------------------
    md_path = OUT_DIR / "ablation.md"
    lines: List[str] = []
    lines.append("# Rank-strategy ablation on M-truncated wallaby pool\n")
    lines.append("_Generated by `results/wallaby_analysis/rank_strategy_topM_ablation.py`._\n")
    lines.append("\n**SCOPE-LIMITED:** This ablation only re-ranks the M=1 or M=2 rows "
                 "that survived ODEPE's clustering + ranking + diversity selection "
                 "at runtime. The pre-truncation candidate pool (which is what the "
                 "rank strategy actually operates on inside ODEPE) was not dumped on "
                 "Wallaby. So this script shows only the **truncation-step** effect "
                 "of the rank strategy on a tiny pool (1 or 2 rows per cell).\n")
    lines.append("\nA proper rank-strategy ablation requires re-running with "
                 "`dump_raw_candidates_path` enabled. Deferred to Quoll smoke/pilot "
                 "per the publication roadmap.\n")

    lines.append("\n## Top-pick success rate under each strategy\n")
    for thresh in THRESHOLDS:
        lines.append(f"\n### Threshold = {thresh*100:.0f}%\n")
        lines.append("| Method | :err_only | :sat_err | :sat_neg1_err (default S2) |")
        lines.append("|---|---:|---:|---:|")
        for method in METHODS:
            line = f"| {METHOD_LABELS[method]} |"
            for strategy in STRATEGIES:
                c = counts.get((method, strategy, thresh))
                if c is None or c["n_cells"] == 0:
                    line += " — |"
                else:
                    rate = c["n_top1"] / c["n_cells"] * 100
                    line += f" {rate:.1f}% |"
            lines.append(line)

    lines.append("\n## Row-0 swap rate vs default S2 (multi-row cells only)\n")
    lines.append("Counts the M=2 cells (only multi-row cells matter for row-0 selection) "
                 "where the alternative strategy picks a DIFFERENT row 0 than the existing "
                 "result.csv (= S2 default).\n")
    lines.append("\n| Method | Multi-row cells | :err_only swap | :sat_err swap |")
    lines.append("|---|---:|---:|---:|")
    for method in METHODS:
        n_multi = row0_swap_total[method]
        line = f"| {METHOD_LABELS[method]} | {n_multi} |"
        for strategy in ("err_only", "sat_err"):
            n_swap = row0_swap[(method, strategy)]
            pct = n_swap / n_multi * 100 if n_multi else 0
            line += f" {n_swap} ({pct:.1f}%) |"
        lines.append(line)

    lines.append("\n## Interpretation\n")
    lines.append("\nIf the M=2 truncated pool is well-curated (the cluster step already "
                 "picked the M correct branches), then re-ranking those 2 rows under "
                 "different strategies just swaps WHICH of the M algebraic branches "
                 "becomes row 0 — both rows are likely truth-near, so the swap doesn't "
                 "change Best-of-branches @10% (= argmin over the 2 rows). It only "
                 "changes top-pick @10% (= row 0 only).\n")
    lines.append("\nThis is the limited effect that's observable here. The interesting "
                 "rank-strategy effect upstream — where a 700-candidate pool gets ranked "
                 "and the top 20 retained for clustering — is NOT visible from stored data. "
                 "Quoll smoke/pilot with `dump_raw_candidates_path` enabled will measure "
                 "this properly.\n")

    with open(md_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
