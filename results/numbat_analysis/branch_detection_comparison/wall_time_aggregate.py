#!/usr/bin/env python3
"""Investigation B: aggregate wall-time comparison.

Median was 1.11x (misleading because most cells were already fast). Sum tells a
different story; long-tail savings are the real win.

Inputs:
  accuracy_per_cell.csv

Outputs:
  wall_time_aggregate.csv  (per-bucket sums + ratios)
  wall_time_aggregate.md   (headline narrative)
"""
import csv
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
PER_CELL = HERE / "accuracy_per_cell.csv"
OUT_CSV = HERE / "wall_time_aggregate.csv"
OUT_MD = HERE / "wall_time_aggregate.md"


def to_float(s):
    try:
        return float(s) if s not in ("", None) else None
    except (TypeError, ValueError):
        return None


def main():
    with open(PER_CELL) as f:
        rows = list(csv.DictReader(f))

    # Filter to comparable cells (both new and old have wall time)
    paired = []
    for r in rows:
        nw = to_float(r.get("new_wall_s"))
        ow = to_float(r.get("old_wall_s"))
        if nw is None or ow is None:
            continue
        paired.append({**r, "_new_wall": nw, "_old_wall": ow})

    n = len(paired)
    sum_new = sum(p["_new_wall"] for p in paired)
    sum_old = sum(p["_old_wall"] for p in paired)
    saved = sum_old - sum_new

    # Speedup bucketing
    speedups = [(p, p["_old_wall"] / p["_new_wall"] if p["_new_wall"] > 0 else 0) for p in paired]
    long_tail = [(p, s) for p, s in speedups if s >= 5]
    moderate = [(p, s) for p, s in speedups if 1.5 <= s < 5]
    flat = [(p, s) for p, s in speedups if 0.7 <= s < 1.5]
    slower = [(p, s) for p, s in speedups if s < 0.7]

    saved_long_tail = sum(p["_old_wall"] - p["_new_wall"] for p, _ in long_tail)
    saved_moderate = sum(p["_old_wall"] - p["_new_wall"] for p, _ in moderate)
    saved_flat = sum(p["_old_wall"] - p["_new_wall"] for p, _ in flat)
    saved_slower = sum(p["_old_wall"] - p["_new_wall"] for p, _ in slower)  # negative

    # Per-bucket sums
    by_bucket = defaultdict(list)
    for p in paired:
        by_bucket[(p["system"], p["run"], p["noise_label"])].append(p)

    bucket_rows = []
    for key in sorted(by_bucket.keys()):
        sys_name, run, noise = key
        cells = by_bucket[key]
        s_new = sum(c["_new_wall"] for c in cells)
        s_old = sum(c["_old_wall"] for c in cells)
        bucket_rows.append({
            "system": sys_name,
            "run": run,
            "noise_label": noise,
            "n_cells": len(cells),
            "sum_new_wall_s": s_new,
            "sum_old_wall_s": s_old,
            "saved_s": s_old - s_new,
            "speedup": s_old / s_new if s_new > 0 else 0,
        })

    keys = list(bucket_rows[0].keys()) if bucket_rows else []
    with open(OUT_CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(bucket_rows)
    print(f"Wrote {OUT_CSV} ({len(bucket_rows)} buckets)")

    # Per-run summary
    by_run = defaultdict(list)
    for p in paired:
        by_run[p["run"]].append(p)

    # Top 10 highest-speedup buckets
    top_speed = sorted(bucket_rows, key=lambda b: -b["speedup"])[:10]
    # Top 10 biggest absolute savings (cpu-hours saved)
    top_savings = sorted(bucket_rows, key=lambda b: -b["saved_s"])[:10]
    # Worst slowdowns (negative savings)
    slowdowns = sorted([b for b in bucket_rows if b["saved_s"] < 0], key=lambda b: b["saved_s"])[:10]

    md = []
    md.append("# Investigation B — Wall-time aggregate")
    md.append("")
    md.append(f"**Comparable cells**: {n} (both new and old produced wall times)")
    md.append("")
    md.append("## Top-line")
    md.append("")
    md.append(f"- **Total new wall time**: {sum_new:.0f}s = **{sum_new/3600:.1f} CPU-hours**")
    md.append(f"- **Total old wall time**: {sum_old:.0f}s = **{sum_old/3600:.1f} CPU-hours**")
    md.append(f"- **Wall-time saved**: {saved:.0f}s = **{saved/3600:.1f} CPU-hours** ({saved/sum_old*100:.1f}% of old total)")
    md.append(f"- **Aggregate speedup ratio**: {sum_old/sum_new:.2f}× (vs median 1.11×)")
    md.append("")
    md.append("Note: aggregate speedup (sum old / sum new) is the right metric for 'did the rerun")
    md.append("actually save the cluster time?' Median misleads because most cells were already fast.")
    md.append("")
    md.append("## Where the savings come from")
    md.append("")
    md.append("| speedup bucket | n cells | total saved (CPU-hr) |")
    md.append("|----------------|--------:|---------------------:|")
    md.append(f"| long-tail (≥5×) | {len(long_tail)} | {saved_long_tail/3600:+.1f} |")
    md.append(f"| moderate (1.5–5×) | {len(moderate)} | {saved_moderate/3600:+.1f} |")
    md.append(f"| flat (0.7–1.5×) | {len(flat)} | {saved_flat/3600:+.1f} |")
    md.append(f"| slower (<0.7×) | {len(slower)} | {saved_slower/3600:+.1f} |")
    md.append("")
    md.append(f"The long-tail bucket ({len(long_tail)} cells) accounts for {saved_long_tail/saved*100:.0f}% of total savings.")
    md.append("")
    md.append("## Per-run aggregate")
    md.append("")
    md.append("| run | n | new total (hr) | old total (hr) | saved (hr) | ratio |")
    md.append("|-----|--:|---------------:|---------------:|-----------:|------:|")
    for run in sorted(by_run.keys()):
        cells = by_run[run]
        sn = sum(c["_new_wall"] for c in cells) / 3600
        so = sum(c["_old_wall"] for c in cells) / 3600
        md.append(f"| {run} | {len(cells)} | {sn:.1f} | {so:.1f} | {so-sn:+.1f} | {so/sn:.2f}× |")
    md.append("")

    md.append("## Top 10 highest-speedup buckets")
    md.append("")
    md.append("| system | run | noise | n | new tot | old tot | speedup |")
    md.append("|--------|-----|-------|--:|--------:|--------:|--------:|")
    for b in top_speed:
        md.append(f"| {b['system']} | {b['run']} | {b['noise_label']} | {b['n_cells']} | "
                  f"{b['sum_new_wall_s']/3600:.1f}h | {b['sum_old_wall_s']/3600:.1f}h | "
                  f"{b['speedup']:.1f}× |")
    md.append("")

    md.append("## Top 10 biggest absolute savings")
    md.append("")
    md.append("| system | run | noise | n | new tot | old tot | saved | speedup |")
    md.append("|--------|-----|-------|--:|--------:|--------:|------:|--------:|")
    for b in top_savings:
        md.append(f"| {b['system']} | {b['run']} | {b['noise_label']} | {b['n_cells']} | "
                  f"{b['sum_new_wall_s']/3600:.1f}h | {b['sum_old_wall_s']/3600:.1f}h | "
                  f"{b['saved_s']/3600:+.1f}h | {b['speedup']:.1f}× |")
    md.append("")

    if slowdowns:
        md.append("## Slowdowns (buckets where new is slower than old)")
        md.append("")
        md.append("| system | run | noise | n | new tot | old tot | saved | speedup |")
        md.append("|--------|-----|-------|--:|--------:|--------:|------:|--------:|")
        for b in slowdowns:
            md.append(f"| {b['system']} | {b['run']} | {b['noise_label']} | {b['n_cells']} | "
                      f"{b['sum_new_wall_s']/3600:.1f}h | {b['sum_old_wall_s']/3600:.1f}h | "
                      f"{b['saved_s']/3600:+.1f}h | {b['speedup']:.2f}× |")
    md.append("")

    OUT_MD.write_text("\n".join(md))
    print(f"Wrote {OUT_MD}")
    print()
    print("=== Headline ===")
    print(f"  new total: {sum_new/3600:.1f} CPU-hr")
    print(f"  old total: {sum_old/3600:.1f} CPU-hr")
    print(f"  saved:     {saved/3600:.1f} CPU-hr ({saved/sum_old*100:.1f}%)")
    print(f"  aggregate speedup: {sum_old/sum_new:.2f}×  (median 1.11× was misleading)")


if __name__ == "__main__":
    main()
