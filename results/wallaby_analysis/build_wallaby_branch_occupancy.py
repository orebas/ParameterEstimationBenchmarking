#!/usr/bin/env python3
"""Wallaby branch-occupancy postprocessor.

For the 4 wallaby multiplicity-2 systems (daisy_mamil4, seir, slow_fast,
biohydrogenation), classify each method's returned candidates against truth
+ orbit (or cluster-distinctness fallback when orbit is None). Produce three
artifacts in `results/wallaby_analysis/branch_occupancy/`:

- branch_occupancy_per_cell.csv  : one row per (cell, method, returned_row)
- branch_occupancy_summary.md    : per-(system, noise) per-method rollup
- branch_occupancy_headline.csv  : per-method per-system aggregate

This is the hero-figure pipeline for the "ODEPE returns a calibrated branch
set vs K=1 optimizers return one branch" Paper 1 claim.

Reads existing Wallaby outputs only; no cluster spend.
"""

import csv
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "results"))
from _shared.branch_classifier import (  # noqa: E402
    BranchMetadata,
    compute_branch_metrics,
    get_branch_metadata,
    load_branch_metadata,
    normalize_var_name,
)

BENCH = REPO_ROOT / "benchmark_wallaby_2026-05-17"
FILETREE = BENCH / "filetree"
HUGE_JSON = BENCH / "huge_json.json"
SIDECAR = REPO_ROOT / "config" / "branch_metadata.json"
OUT_DIR = REPO_ROOT / "results" / "wallaby_analysis" / "branch_occupancy"

# Wallaby M=2 systems — the focus of this analysis.
M2_SYSTEMS = ["daisy_mamil4", "seir", "slow_fast", "biohydrogenation"]

# Estimator runs (= subdirectories of filetree/).
METHODS = ["odepe_v2_polish", "odepe_v2_nopolish", "amigo2", "odepe_shade"]
METHOD_LABELS = {
    "odepe_v2_polish": "ODEPE-v2 (polish)",
    "odepe_v2_nopolish": "ODEPE-v2 (no polish)",
    "amigo2": "AMIGO2",
    "odepe_shade": "SHADE+LM",
}

SUCCESS_THRESHOLD = 0.50  # @50% per E0/E3 protocol


def load_huge_json() -> Dict[str, dict]:
    with open(HUGE_JSON) as f:
        data = json.load(f)
    return {c["id"]: c for c in data["instances"]}


def build_truth(instance: dict) -> Dict[str, float]:
    """Merge state_values + parameter_values into one dict (paired with branch_orbit keys)."""
    t: Dict[str, float] = {}
    t.update(instance.get("state_values", {}))
    t.update(instance.get("parameter_values", {}))
    return t


def load_cell_unidentifiable(cell_dir: Path, fallback: set) -> set:
    """Per project memory: read all_unidentifiable from odepe_metadata.json[best]
    when present; fall back to huge_json's non_identifiable list otherwise.
    """
    meta_path = cell_dir / "odepe_metadata.json"
    if not meta_path.exists():
        return set(fallback)
    try:
        with open(meta_path) as f:
            m = json.load(f)
        au = m.get("best", {}).get("all_unidentifiable")
        if au is None:
            return set(fallback)
        return {normalize_var_name(v) for v in au}
    except (json.JSONDecodeError, OSError):
        return set(fallback)


def load_result_rows(cell_dir: Path) -> List[Dict[str, float]]:
    """Read result.csv -> list of {colname: float} dicts."""
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

    sidecar = load_branch_metadata(SIDECAR)
    instances = load_huge_json()

    per_cell_rows: List[Dict[str, Any]] = []
    # rollup keyed by (system, noise, method)
    summary_acc: Dict[Tuple[str, str, str], Dict[str, Any]] = defaultdict(
        lambda: {
            "n_cells": 0,
            "hit_any": 0,
            "distinct_sum": 0,
            "duplicate_sum": 0.0,
            "coverage_sum": 0.0,
            "n_candidates_sum": 0,
            "n_cells_with_candidates": 0,
        }
    )
    # headline keyed by (system, method)
    headline_acc: Dict[Tuple[str, str], Dict[str, Any]] = defaultdict(
        lambda: {
            "n_cells": 0,
            "hit_any": 0,
            "distinct_sum": 0,
            "duplicate_sum": 0.0,
            "coverage_sum": 0.0,
            "n_candidates_sum": 0,
            "n_cells_with_candidates": 0,
        }
    )

    instance_ids = sorted(instances.keys())
    print(f"Loading {len(instance_ids)} wallaby instances; "
          f"filtering to {len(M2_SYSTEMS)} M=2 systems.")

    for cell_id, instance in instances.items():
        system = instance["name"]
        if system not in M2_SYSTEMS:
            continue
        noise_val = float(instance.get("noise", 0.0)) if "noise" in instance else None
        # Wallaby cell IDs end in noise mnemonic (e.g., daisy_mamil4_0_1em4); use that
        # instead of the missing huge_json noise field for grouping.
        noise_label = cell_id.rsplit("_", 1)[1]
        truth = build_truth(instance)
        fallback_unid = {
            normalize_var_name(v) for v in instance.get("non_identifiable", [])
        }
        metadata = get_branch_metadata(system, sidecar)

        for method in METHODS:
            cell_dir = FILETREE / f"{method}_run" / cell_id
            if not cell_dir.exists():
                continue
            unid = load_cell_unidentifiable(cell_dir, fallback_unid)
            rows = load_result_rows(cell_dir)
            if not rows:
                # No result: count this cell in n_cells but with no candidates
                key3 = (system, noise_label, method)
                summary_acc[key3]["n_cells"] += 1
                headline_acc[(system, method)]["n_cells"] += 1
                per_cell_rows.append({
                    "system": system,
                    "noise": noise_label,
                    "instance": int(instance.get("index", 0)),
                    "method": method,
                    "row_idx": -1,
                    "n_returned": 0,
                    "expected_M": metadata.algebraic_multiplicity,
                    "expected_M_physical": metadata.physical_multiplicity_positive_bounds,
                    "orbit_type": "none" if metadata.branch_orbit is None else metadata.branch_orbit.get("type", "none"),
                    "assigned_orbit_index": "",
                    "max_rel_error": "",
                    "hit_at_50": "",
                    "distinct_branch_hits": 0,
                    "duplicate_branch_fraction": "",
                    "branch_coverage_fraction": 0.0,
                    "cluster_distinct_count": 0,
                })
                continue

            m = compute_branch_metrics(
                rows, truth, metadata, exclude=unid,
                success_threshold=SUCCESS_THRESHOLD,
            )

            # One per-cell summary row, but emit one detail row per returned candidate.
            for i, (assigned, err) in enumerate(zip(m.assigned_branches, m.per_candidate_err)):
                per_cell_rows.append({
                    "system": system,
                    "noise": noise_label,
                    "instance": int(instance.get("index", 0)),
                    "method": method,
                    "row_idx": i,
                    "n_returned": m.n_candidates,
                    "expected_M": m.expected_M,
                    "expected_M_physical": m.expected_M_physical,
                    "orbit_type": m.orbit_type,
                    "assigned_orbit_index": assigned,
                    "max_rel_error": err if err is not None else "",
                    "hit_at_50": (err is not None and err <= SUCCESS_THRESHOLD),
                    "distinct_branch_hits": m.distinct_branch_hits,
                    "duplicate_branch_fraction": m.duplicate_branch_fraction,
                    "branch_coverage_fraction": m.branch_coverage_fraction,
                    "cluster_distinct_count": m.cluster_distinct_count,
                })

            # Accumulate per-cell into rollups (one accumulation per cell, not per row)
            for acc in (summary_acc[(system, noise_label, method)], headline_acc[(system, method)]):
                acc["n_cells"] += 1
                acc["hit_any"] += int(m.hit_any_branch)
                acc["distinct_sum"] += m.distinct_branch_hits
                acc["duplicate_sum"] += m.duplicate_branch_fraction
                acc["coverage_sum"] += m.branch_coverage_fraction
                acc["n_candidates_sum"] += m.n_candidates
                if m.n_candidates > 0:
                    acc["n_cells_with_candidates"] += 1

    # ----------------------------------------------------------------------
    # Write per_cell.csv
    # ----------------------------------------------------------------------
    per_cell_path = OUT_DIR / "branch_occupancy_per_cell.csv"
    fields = [
        "system", "noise", "instance", "method", "row_idx", "n_returned",
        "expected_M", "expected_M_physical", "orbit_type",
        "assigned_orbit_index", "max_rel_error", "hit_at_50",
        "distinct_branch_hits", "duplicate_branch_fraction",
        "branch_coverage_fraction", "cluster_distinct_count",
    ]
    with open(per_cell_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in per_cell_rows:
            w.writerow(r)
    print(f"Wrote {per_cell_path} ({len(per_cell_rows)} rows)")

    # ----------------------------------------------------------------------
    # Write headline.csv
    # ----------------------------------------------------------------------
    headline_path = OUT_DIR / "branch_occupancy_headline.csv"
    headline_fields = [
        "system", "method", "n_cells", "hit_any_branch_rate",
        "mean_distinct_branch_hits", "mean_duplicate_branch_fraction",
        "mean_branch_coverage_fraction", "mean_n_returned",
    ]
    with open(headline_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=headline_fields)
        w.writeheader()
        for system in M2_SYSTEMS:
            for method in METHODS:
                acc = headline_acc.get((system, method))
                if acc is None or acc["n_cells"] == 0:
                    continue
                n = acc["n_cells"]
                n_with = acc["n_cells_with_candidates"]
                w.writerow({
                    "system": system,
                    "method": METHOD_LABELS[method],
                    "n_cells": n,
                    "hit_any_branch_rate": f"{acc['hit_any'] / n:.4f}",
                    "mean_distinct_branch_hits": f"{acc['distinct_sum'] / max(n, 1):.4f}",
                    "mean_duplicate_branch_fraction": f"{acc['duplicate_sum'] / max(n_with, 1):.4f}",
                    "mean_branch_coverage_fraction": f"{acc['coverage_sum'] / max(n, 1):.4f}",
                    "mean_n_returned": f"{acc['n_candidates_sum'] / max(n, 1):.2f}",
                })
    print(f"Wrote {headline_path}")

    # ----------------------------------------------------------------------
    # Write summary.md
    # ----------------------------------------------------------------------
    summary_path = OUT_DIR / "branch_occupancy_summary.md"
    lines = []
    lines.append("# Wallaby branch occupancy — M=2 systems\n")
    lines.append(f"_Generated by `results/wallaby_analysis/build_wallaby_branch_occupancy.py`._\n")
    lines.append(f"\nSuccess threshold: max-relative-error ≤ {SUCCESS_THRESHOLD} on identifiable axes "
                 f"(per-cell `all_unidentifiable` excluded).\n")
    lines.append("\nFor wallaby M=2 systems we use cluster-distinctness (orbit=null in the sidecar) "
                 "because the algebraic transformations are non-permutation scale-pair invariances "
                 "rather than clean label permutations. See `config/branch_metadata.json` notes "
                 "and `environments/ODEParameterEstimation/repro/multiplicity_complete_2026_05_19/"
                 "branch_transformations.txt`.\n")

    lines.append("\n## Headline rollup (across all noise levels)\n")
    lines.append("| System | Method | n_cells | hit-any-branch | mean distinct | mean duplicate | mean coverage | mean #returned |")
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
    with open(headline_path) as f:
        r = csv.DictReader(f)
        for row in r:
            lines.append(
                f"| {row['system']} | {row['method']} | {row['n_cells']} | "
                f"{float(row['hit_any_branch_rate'])*100:.1f}% | "
                f"{row['mean_distinct_branch_hits']} | "
                f"{float(row['mean_duplicate_branch_fraction'])*100:.1f}% | "
                f"{float(row['mean_branch_coverage_fraction'])*100:.1f}% | "
                f"{row['mean_n_returned']} |"
            )

    lines.append("\n## Per-(system, noise) breakdown\n")
    for system in M2_SYSTEMS:
        md = get_branch_metadata(system, sidecar)
        lines.append(f"\n### {system}  "
                     f"(algebraic M={md.algebraic_multiplicity}, "
                     f"physical M={md.physical_multiplicity_positive_bounds})\n")
        if md.notes:
            lines.append(f"_{md.notes}_\n")
        lines.append("| Noise | Method | n | hit-any | mean distinct | mean duplicate | mean coverage |")
        lines.append("|---|---|---:|---:|---:|---:|---:|")
        for noise in ["0", "1em8", "1em6", "1em4", "1em2"]:
            for method in METHODS:
                acc = summary_acc.get((system, noise, method))
                if acc is None or acc["n_cells"] == 0:
                    continue
                n = acc["n_cells"]
                n_with = acc["n_cells_with_candidates"]
                lines.append(
                    f"| {noise} | {METHOD_LABELS[method]} | {n} | "
                    f"{acc['hit_any']/n*100:.1f}% | "
                    f"{acc['distinct_sum']/max(n,1):.2f} | "
                    f"{acc['duplicate_sum']/max(n_with,1)*100:.1f}% | "
                    f"{acc['coverage_sum']/max(n,1)*100:.1f}% |"
                )

    with open(summary_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Wrote {summary_path}")


if __name__ == "__main__":
    main()
