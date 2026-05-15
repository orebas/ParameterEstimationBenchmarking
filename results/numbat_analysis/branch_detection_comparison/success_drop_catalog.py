#!/usr/bin/env python3
"""Investigation A: catalog the success-rate drops.

Per-(system × run × noise) success at multiple thresholds, new vs old + delta.
Plus a cell-level list of cells that flipped (old succeeded, new failed; and rescues).

Inputs:
  accuracy_per_cell.csv  (already computed by compare_v2_to_v1.py)

Outputs (in this dir):
  success_drop_per_bucket.csv
  success_flips.csv
  success_drop_summary.md
"""
import csv
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent

PER_CELL = HERE / "accuracy_per_cell.csv"
OUT_BUCKETS = HERE / "success_drop_per_bucket.csv"
OUT_FLIPS = HERE / "success_flips.csv"
OUT_SUMMARY = HERE / "success_drop_summary.md"

THRESHOLDS = [0.001, 0.01, 0.1, 0.5]


def to_float(s):
    try:
        return float(s) if s not in ("", None) else None
    except (TypeError, ValueError):
        return None


def main():
    with open(PER_CELL) as f:
        rows = list(csv.DictReader(f))
    print(f"Loaded {len(rows)} cells")

    # Filter to cells where BOTH new and old have an oracle err (so success is comparable)
    paired = []
    for r in rows:
        new = to_float(r.get("new_oracle_max"))
        old = to_float(r.get("old_oracle_max"))
        if new is None or old is None:
            continue
        paired.append({
            **r,
            "_new": new,
            "_old": old,
        })
    print(f"  {len(paired)} cells have both new and old oracle err (the comparable set)")

    # Buckets
    by_bucket = defaultdict(list)
    for r in paired:
        by_bucket[(r["system"], r["run"], r["noise_label"])].append(r)

    bucket_rows = []
    for key in sorted(by_bucket.keys()):
        sys_name, run, noise = key
        cells = by_bucket[key]
        n = len(cells)
        row = {
            "system": sys_name,
            "run": run,
            "noise_label": noise,
            "n_cells": n,
        }
        for thresh in THRESHOLDS:
            nlbl = f"{thresh:g}".replace("0.", "")  # "001", "01", "1", "5"
            n_new_pass = sum(1 for c in cells if c["_new"] < thresh)
            n_old_pass = sum(1 for c in cells if c["_old"] < thresh)
            row[f"new_succ_{nlbl}"] = n_new_pass / n
            row[f"old_succ_{nlbl}"] = n_old_pass / n
            row[f"delta_pp_{nlbl}"] = (n_new_pass - n_old_pass) / n * 100
        bucket_rows.append(row)

    keys = list(bucket_rows[0].keys()) if bucket_rows else []
    with open(OUT_BUCKETS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(bucket_rows)
    print(f"Wrote {OUT_BUCKETS}  ({len(bucket_rows)} buckets)")

    # Cell-level flips
    flips = []
    for r in paired:
        for thresh in THRESHOLDS:
            new_pass = r["_new"] < thresh
            old_pass = r["_old"] < thresh
            if new_pass and not old_pass:
                flips.append({
                    "direction": "rescue",
                    "threshold": thresh,
                    "id": r["id"],
                    "system": r["system"],
                    "run": r["run"],
                    "noise_label": r["noise_label"],
                    "new_oracle": r["_new"],
                    "old_oracle": r["_old"],
                })
            elif old_pass and not new_pass:
                flips.append({
                    "direction": "regression",
                    "threshold": thresh,
                    "id": r["id"],
                    "system": r["system"],
                    "run": r["run"],
                    "noise_label": r["noise_label"],
                    "new_oracle": r["_new"],
                    "old_oracle": r["_old"],
                })

    keys = list(flips[0].keys()) if flips else []
    with open(OUT_FLIPS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(flips)
    print(f"Wrote {OUT_FLIPS}  ({len(flips)} flip records across all thresholds)")

    # Headline summary
    def overall_succ(thresh, side):
        passes = sum(1 for r in paired if r[f"_{side}"] < thresh)
        return passes / len(paired) * 100 if paired else 0.0

    n_buckets_lost = sum(1 for b in bucket_rows if b["delta_pp_01"] < -5)
    n_buckets_won = sum(1 for b in bucket_rows if b["delta_pp_01"] > 5)
    n_buckets_flat = len(bucket_rows) - n_buckets_lost - n_buckets_won

    # Top regressing buckets at 1% threshold
    lost_buckets = sorted(bucket_rows, key=lambda b: b["delta_pp_01"])[:15]
    won_buckets = sorted(bucket_rows, key=lambda b: -b["delta_pp_01"])[:10]

    # Per-noise summary
    by_noise = defaultdict(list)
    for r in paired:
        by_noise[r["noise_label"]].append(r)

    md = []
    md.append("# Investigation A — Success-rate drop catalog")
    md.append("")
    md.append(f"**Comparable cell pairs**: {len(paired)}  (cells where both new and old have a finite oracle err)")
    md.append("")
    md.append("## Top-line success rates")
    md.append("")
    md.append("| threshold | new | old | delta (pp) |")
    md.append("|----------:|----:|----:|-----------:|")
    for t in THRESHOLDS:
        ns, os_ = overall_succ(t, "new"), overall_succ(t, "old")
        md.append(f"| {t*100:g}% | {ns:.1f}% | {os_:.1f}% | {ns - os_:+.1f} |")
    md.append("")

    md.append("## Per-noise summary (success @ 1%)")
    md.append("")
    md.append("| noise | n | new | old | delta (pp) |")
    md.append("|-------|--:|----:|----:|-----------:|")
    for noise in sorted(by_noise.keys()):
        cells = by_noise[noise]
        n = len(cells)
        ns = sum(1 for c in cells if c["_new"] < 0.01) / n * 100
        os_ = sum(1 for c in cells if c["_old"] < 0.01) / n * 100
        md.append(f"| {noise} | {n} | {ns:.1f}% | {os_:.1f}% | {ns - os_:+.1f} |")
    md.append("")

    md.append("## Per-run summary (success @ 1%)")
    md.append("")
    md.append("| run | n | new | old | delta (pp) |")
    md.append("|-----|--:|----:|----:|-----------:|")
    by_run = defaultdict(list)
    for r in paired:
        by_run[r["run"]].append(r)
    for run in sorted(by_run.keys()):
        cells = by_run[run]
        n = len(cells)
        ns = sum(1 for c in cells if c["_new"] < 0.01) / n * 100
        os_ = sum(1 for c in cells if c["_old"] < 0.01) / n * 100
        md.append(f"| {run} | {n} | {ns:.1f}% | {os_:.1f}% | {ns - os_:+.1f} |")
    md.append("")

    md.append(f"## Bucket-level shape (per {len(bucket_rows)} buckets)")
    md.append("")
    md.append(f"- Buckets where new lost > 5pp at 1%: **{n_buckets_lost}**")
    md.append(f"- Buckets where new won > 5pp at 1%: **{n_buckets_won}**")
    md.append(f"- Buckets within ±5pp: {n_buckets_flat}")
    md.append("")

    md.append("## Top 15 most-regressed buckets (success @ 1%)")
    md.append("")
    md.append("| system | run | noise | n | new | old | delta (pp) |")
    md.append("|--------|-----|-------|--:|----:|----:|-----------:|")
    for b in lost_buckets:
        md.append(f"| {b['system']} | {b['run']} | {b['noise_label']} | {b['n_cells']} | "
                  f"{b['new_succ_01']*100:.0f}% | {b['old_succ_01']*100:.0f}% | {b['delta_pp_01']:+.0f} |")
    md.append("")

    md.append("## Top 10 most-improved buckets (success @ 1%)")
    md.append("")
    md.append("| system | run | noise | n | new | old | delta (pp) |")
    md.append("|--------|-----|-------|--:|----:|----:|-----------:|")
    for b in won_buckets:
        if b["delta_pp_01"] <= 0:
            continue
        md.append(f"| {b['system']} | {b['run']} | {b['noise_label']} | {b['n_cells']} | "
                  f"{b['new_succ_01']*100:.0f}% | {b['old_succ_01']*100:.0f}% | {b['delta_pp_01']:+.0f} |")
    md.append("")

    # Cell-flip counts at each threshold
    md.append("## Flip counts (per threshold)")
    md.append("")
    md.append("| threshold | regressions (old✓→new✗) | rescues (old✗→new✓) | net |")
    md.append("|----------:|------------------------:|--------------------:|----:|")
    for t in THRESHOLDS:
        r_count = sum(1 for f in flips if f["threshold"] == t and f["direction"] == "regression")
        res_count = sum(1 for f in flips if f["threshold"] == t and f["direction"] == "rescue")
        md.append(f"| {t*100:g}% | {r_count} | {res_count} | {res_count - r_count:+d} |")
    md.append("")

    OUT_SUMMARY.write_text("\n".join(md))
    print(f"Wrote {OUT_SUMMARY}")
    print()
    print("=== Headline ===")
    for t in THRESHOLDS:
        ns, os_ = overall_succ(t, "new"), overall_succ(t, "old")
        print(f"  success @ {t*100:g}%: new {ns:.1f}%  old {os_:.1f}%  Δ {ns - os_:+.1f} pp")


if __name__ == "__main__":
    main()
