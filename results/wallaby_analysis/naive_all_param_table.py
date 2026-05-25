#!/usr/bin/env python3
"""Naive-all-parameter cautionary supplement (E5 in the experiment matrix).

Re-score wallaby cells WITHOUT the SI-derived `all_unidentifiable` exclusion
to show how the headline numbers shift if a researcher (incorrectly) reports
relative-error metrics over ALL parameters including the structurally
unidentifiable ones. The principled approach is to exclude unidentifiable
axes uniformly across methods (which is what the main analysis does); this
table demonstrates why that matters.

Reads existing wallaby outputs only. No cluster spend.

Outputs:
- results/wallaby_analysis/naive_all_param/comparison.csv
- results/wallaby_analysis/naive_all_param/comparison.md
"""

import csv
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Tuple

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "results"))
from _shared.branch_classifier import (  # noqa: E402
    max_rel_error,
    normalize_var_name,
)

BENCH = REPO_ROOT / "benchmark_wallaby_2026-05-17"
FILETREE = BENCH / "filetree"
HUGE_JSON = BENCH / "huge_json.json"
OUT_DIR = REPO_ROOT / "results" / "wallaby_analysis" / "naive_all_param"

METHODS = ["odepe_v2_polish", "odepe_v2_nopolish", "amigo2", "odepe_shade"]
METHOD_LABELS = {
    "odepe_v2_polish": "ODEPE-v2 (polish)",
    "odepe_v2_nopolish": "ODEPE-v2 (no polish)",
    "amigo2": "AMIGO2",
    "odepe_shade": "SHADE+LM",
}

THRESHOLDS = (0.01, 0.10, 0.50)


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


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    instances = load_huge_json()

    # rows: (method, exclude_unid?, threshold) -> count of successes / total
    counts: Dict[Tuple[str, bool, float], Dict[str, int]] = defaultdict(
        lambda: {"n_cells": 0, "n_top1": 0, "n_bob": 0}
    )

    # Note which systems have any non-empty `all_unidentifiable`; this is where
    # the naive-vs-principled metric differs.
    systems_with_unid: set = set()

    for cell_id, instance in instances.items():
        system = instance["name"]
        truth = build_truth(instance)
        fallback_unid = {normalize_var_name(v) for v in instance.get("non_identifiable", [])}

        # Cross-method uniform exclusion: ODEPE polish writes the canonical
        # `all_unidentifiable`. Apply that same set to AMIGO2/SHADE so the
        # principled-metric comparison is fair across methods (per project memory:
        # exclusions must be uniform across methods per cell, not per-method).
        odepe_polish_dir = FILETREE / "odepe_v2_polish_run" / cell_id
        odepe_nopolish_dir = FILETREE / "odepe_v2_nopolish_run" / cell_id
        cell_unid = load_cell_unidentifiable(odepe_polish_dir, fallback_unid)
        if not cell_unid:
            cell_unid = load_cell_unidentifiable(odepe_nopolish_dir, fallback_unid)
        if cell_unid:
            systems_with_unid.add(system)

        for method in METHODS:
            cell_dir = FILETREE / f"{method}_run" / cell_id
            if not cell_dir.exists():
                continue
            unid = cell_unid  # uniform across methods
            rows = load_result_rows(cell_dir)
            if not rows:
                # cell with no result still counts toward n_cells
                for excl in (True, False):
                    for thresh in THRESHOLDS:
                        counts[(method, excl, thresh)]["n_cells"] += 1
                continue

            # top-1 = row 0
            err_top1_excl = max_rel_error(rows[0], truth, exclude=unid)
            err_top1_naive = max_rel_error(rows[0], truth, exclude=set())
            # best-of-branches = min over rows of max-rel-error
            errs_excl = [max_rel_error(r, truth, exclude=unid) for r in rows]
            errs_naive = [max_rel_error(r, truth, exclude=set()) for r in rows]
            errs_excl = [e for e in errs_excl if e is not None]
            errs_naive = [e for e in errs_naive if e is not None]
            err_bob_excl = min(errs_excl) if errs_excl else None
            err_bob_naive = min(errs_naive) if errs_naive else None

            for excl, et, eb in (
                (True, err_top1_excl, err_bob_excl),
                (False, err_top1_naive, err_bob_naive),
            ):
                for thresh in THRESHOLDS:
                    bucket = counts[(method, excl, thresh)]
                    bucket["n_cells"] += 1
                    if et is not None and et <= thresh:
                        bucket["n_top1"] += 1
                    if eb is not None and eb <= thresh:
                        bucket["n_bob"] += 1

    # ----------------------------------------------------------------------
    # Write comparison.csv: long-format
    # ----------------------------------------------------------------------
    csv_path = OUT_DIR / "comparison.csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "method", "exclude_unidentifiable", "threshold",
            "n_cells", "top1_success_rate", "bob_success_rate",
        ])
        for (method, excl, thresh), b in sorted(counts.items()):
            n = b["n_cells"]
            w.writerow([
                METHOD_LABELS[method],
                "yes" if excl else "no",
                thresh,
                n,
                f"{b['n_top1'] / n:.4f}" if n else "",
                f"{b['n_bob'] / n:.4f}" if n else "",
            ])
    print(f"Wrote {csv_path}")

    # ----------------------------------------------------------------------
    # Write comparison.md
    # ----------------------------------------------------------------------
    md_path = OUT_DIR / "comparison.md"
    lines: List[str] = []
    lines.append("# Naive-all-parameter cautionary supplement\n")
    lines.append("_Generated by `results/wallaby_analysis/naive_all_param_table.py`._\n")
    lines.append("\nThe main wallaby analysis excludes per-cell `all_unidentifiable` "
                 "(read from `odepe_metadata.json[best]`) from the relative-error "
                 "calculation. This is the principled approach: SI labels these "
                 "axes as structurally unidentifiable, so scoring against them "
                 "would penalize all methods for math, not algorithm quality.\n")
    lines.append("\nThis table shows what the headline numbers would look like "
                 "if a researcher (incorrectly) included ALL truth axes:\n")

    lines.append("\n## Side-by-side comparison\n")
    for thresh in THRESHOLDS:
        lines.append(f"\n### Threshold = {thresh*100:.0f}%\n")
        lines.append("| Method | Top-pick (excl unid) | Top-pick (naive) | Δ | BoB (excl unid) | BoB (naive) | Δ |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|")
        for method in METHODS:
            b_excl = counts[(method, True, thresh)]
            b_naive = counts[(method, False, thresh)]
            n = b_excl["n_cells"]
            if n == 0:
                continue
            top_excl = b_excl["n_top1"] / n * 100
            top_naive = b_naive["n_top1"] / n * 100
            bob_excl = b_excl["n_bob"] / n * 100
            bob_naive = b_naive["n_bob"] / n * 100
            lines.append(
                f"| {METHOD_LABELS[method]} | "
                f"{top_excl:.1f}% | {top_naive:.1f}% | {top_naive - top_excl:+.1f}pp | "
                f"{bob_excl:.1f}% | {bob_naive:.1f}% | {bob_naive - bob_excl:+.1f}pp |"
            )

    lines.append(
        "\n## Why this matters\n"
        "\nThe `exclude unid` column is what the paper reports and what was used "
        "in the main wallaby tables. The `naive` column is what you would get if "
        "you ignored SI's identifiability analysis. The delta column shows the "
        "shift; a more negative delta means including unidentifiable axes drags "
        "the headline number down further (because the unidentifiable axes can "
        "have arbitrarily large relative errors without affecting the method's "
        "actual quality on the things it CAN identify).\n"
    )
    lines.append(
        "\nThe same exclusion set is applied uniformly to every method per cell, "
        "so the comparison stays fair: if `all_unidentifiable = {x7}` for a "
        "biohydrogenation cell, then `x7` is excluded for ODEPE-polish, "
        "ODEPE-nopolish, AMIGO2, and SHADE+LM equally. This is documented in "
        "the baseline fairness memo.\n"
    )

    n_systems_unid = len(systems_with_unid)
    lines.append(
        f"\nAcross the {len(instances)} wallaby instances, "
        f"{n_systems_unid} of 23 systems have a non-empty `all_unidentifiable` set "
        f"for at least some cells (so the naive vs principled choice MATTERS for "
        f"those systems).\n"
    )
    lines.append(
        f"\nSystems with `all_unidentifiable` non-empty in at least one cell: "
        f"{', '.join(sorted(systems_with_unid)) if systems_with_unid else '(none)'}.\n"
    )

    with open(md_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
