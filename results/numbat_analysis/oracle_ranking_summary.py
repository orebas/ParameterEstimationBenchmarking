#!/usr/bin/env python3
"""Summarize oracle-ranking audit. Two views:

1. ALL cells: rank distribution + top-K capture rate.
2. ANSWER-BEARING cells (truth_best_oracle < 0.01): the cells where ODEPE
   actually found a near-truth answer. These are the ones where the cheat matters.
"""
from pathlib import Path
import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
df = pd.read_csv(HERE / "oracle_ranking_audit.csv")
print(f"=== Loaded {len(df)} cells ===\n")


def kpi(d, label):
    if d.empty:
        print(f"  ({label}: 0 cells)")
        return
    pct = d["rank_truth_best_by_residual"].quantile([0.50, 0.75, 0.90]).round(1)
    print(f"  {label:30s} N={len(d):>3d}  median={pct[0.5]:>5.0f}  p75={pct[0.75]:>5.0f}  p90={pct[0.9]:>5.0f}")
    for K in (1, 5, 10, 20, 50, 100):
        rate = d[f"top_K_{K}"].mean() * 100
        print(f"      top-{K:>3d}: {rate:5.1f}%")


print("=" * 60)
print("VIEW 1: All cells")
print("=" * 60)
kpi(df, "all-noise")
for nl in ["0", "1em8", "1em6", "1em4", "1em2"]:
    kpi(df[df.noise_label == nl], f"noise={nl}")

print()
print("=" * 60)
print("VIEW 2: Answer-bearing cells (truth_best_oracle < 0.01)")
print("=" * 60)
ans = df[df.truth_best_oracle_max_rel_err < 0.01]
print(f"\n{len(ans)}/{len(df)} cells have a near-truth candidate (max_rel_err < 1%)\n")
kpi(ans, "answer-bearing")
for nl in ["0", "1em8", "1em6", "1em4", "1em2"]:
    kpi(ans[ans.noise_label == nl], f"noise={nl}")

print()
print("=" * 60)
print("Per-system rank distribution (answer-bearing only)")
print("=" * 60)
sys_summary = ans.groupby("system").agg(
    n_cells=("rank_truth_best_by_residual", "count"),
    median_rank=("rank_truth_best_by_residual", "median"),
    max_rank=("rank_truth_best_by_residual", "max"),
    top_10=("top_K_10", "mean"),
    top_20=("top_K_20", "mean"),
    top_100=("top_K_100", "mean"),
).sort_values("median_rank", ascending=False)
sys_summary[["top_10", "top_20", "top_100"]] *= 100
print(sys_summary.round(1).to_string())

print()
print("=" * 60)
print("Per-system rank distribution (ALL cells)")
print("=" * 60)
sys_all = df.groupby("system").agg(
    n=("rank_truth_best_by_residual", "count"),
    median=("rank_truth_best_by_residual", "median"),
    max=("rank_truth_best_by_residual", "max"),
).sort_values("median", ascending=False)
print(sys_all.round(1).to_string())

print()
print("=" * 60)
print("Cells where the cheat matters MOST (high rank + good truth)")
print("=" * 60)
worst = df[df.truth_best_oracle_max_rel_err < 0.1].nlargest(15, "rank_truth_best_by_residual")
cols = ["cell_id", "n_rows", "rank_truth_best_by_residual",
        "truth_best_oracle_max_rel_err", "residual_best_oracle_max_rel_err"]
print(worst[cols].to_string(index=False))

print()
print("=" * 60)
print("How often does residual-best == truth-best (top-1 capture)?")
print("=" * 60)
cap1 = df[df.top_K_1 == 1]
print(f"  All cells:           {len(cap1):>3d}/{len(df)}  ({len(cap1)/len(df)*100:.1f}%)")
cap1_ans = ans[ans.top_K_1 == 1]
print(f"  Answer-bearing only: {len(cap1_ans):>3d}/{len(ans)}  ({len(cap1_ans)/len(ans)*100:.1f}%)")
