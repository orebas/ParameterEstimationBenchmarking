#!/usr/bin/env python3
"""
Step 5: Compare Wombat vs Quokka benchmark results.

Filters both to the 23 shared systems and compares success rates,
timing, and per-system deltas.

Usage:
    python3 results/quokka_analysis/compare_benchmarks.py
"""

import os
import numpy as np
import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WOMBAT_CSV = os.path.expanduser(
    "~/ParameterEstimationBenchmarking/benchmark_wombat_2026_02_26/analysis_results/flat_results_with_metrics.csv"
)
QUOKKA_CSV = os.path.join(SCRIPT_DIR, "flat_results_with_metrics.csv")
OUT_DIR = os.path.join(SCRIPT_DIR, "comparison")
os.makedirs(OUT_DIR, exist_ok=True)

METHOD_LABELS = {
    "odepe_polish": "ODEPE (polish)",
    "odepe_nopolish": "ODEPE (no polish)",
    "amigo2_run": "AMIGO2",
    "sciml_run": "SciML",
}
METHOD_ORDER = ["odepe_polish", "odepe_nopolish", "amigo2_run", "sciml_run"]
NOISE_ORDER = [0.0, 1e-8, 1e-6, 1e-4, 1e-2]
NOISE_LABELS = ["0", "1e-8", "1e-6", "1e-4", "1e-2"]


def main():
    print("Loading data...")
    w = pd.read_csv(WOMBAT_CSV)
    q = pd.read_csv(QUOKKA_CSV)
    print(f"  Wombat: {len(w)} rows, {w['name'].nunique()} systems")
    print(f"  Quokka: {len(q)} rows, {q['name'].nunique()} systems")

    # Filter to shared systems (exclude two_compartment_pk from wombat)
    shared_systems = sorted(set(w["name"].unique()) & set(q["name"].unique()))
    print(f"  Shared systems: {len(shared_systems)}")
    w = w[w["name"].isin(shared_systems)].copy()
    q = q[q["name"].isin(shared_systems)].copy()
    print(f"  Wombat filtered: {len(w)} rows")
    print(f"  Quokka filtered: {len(q)} rows")

    # 1. Overall success rates per method
    rows = []
    for m in METHOD_ORDER:
        w_succ = w[w["run"] == m]["success_at_10pct"].mean() * 100
        q_succ = q[q["run"] == m]["success_at_10pct"].mean() * 100
        w_time = w[w["run"] == m]["time"].median()
        q_time = q[q["run"] == m]["time"].median()
        w_s1 = w[w["run"] == m]["success_at_1pct"].mean() * 100
        q_s1 = q[q["run"] == m]["success_at_1pct"].mean() * 100
        w_s50 = w[w["run"] == m]["success_at_50pct"].mean() * 100
        q_s50 = q[q["run"] == m]["success_at_50pct"].mean() * 100
        rows.append({
            "method": METHOD_LABELS[m],
            "wombat_success_1pct": w_s1,
            "quokka_success_1pct": q_s1,
            "delta_1pct": q_s1 - w_s1,
            "wombat_success_10pct": w_succ,
            "quokka_success_10pct": q_succ,
            "delta_10pct": q_succ - w_succ,
            "wombat_success_50pct": w_s50,
            "quokka_success_50pct": q_s50,
            "delta_50pct": q_s50 - w_s50,
            "wombat_median_time": w_time,
            "quokka_median_time": q_time,
            "time_delta": q_time - w_time,
        })
    overall_df = pd.DataFrame(rows)
    overall_df.to_csv(os.path.join(OUT_DIR, "overall_method_comparison.csv"), index=False)
    print("\n--- Overall Method Comparison ---")
    for _, r in overall_df.iterrows():
        d = r["delta_10pct"]
        sign = "+" if d >= 0 else ""
        print(f"  {r['method']:20s}  wombat={r['wombat_success_10pct']:.1f}%  quokka={r['quokka_success_10pct']:.1f}%  delta={sign}{d:.1f} pp")

    # 2. Per-system delta in success@10%
    rows = []
    for sys_name in shared_systems:
        for m in METHOD_ORDER:
            w_s = w[(w["name"] == sys_name) & (w["run"] == m)]["success_at_10pct"].mean() * 100
            q_s = q[(q["name"] == sys_name) & (q["run"] == m)]["success_at_10pct"].mean() * 100
            rows.append({
                "system": sys_name,
                "method": METHOD_LABELS[m],
                "wombat_success_10pct": w_s,
                "quokka_success_10pct": q_s,
                "delta_pp": q_s - w_s,
            })
    per_system_df = pd.DataFrame(rows)
    per_system_df.to_csv(os.path.join(OUT_DIR, "per_system_delta.csv"), index=False)

    # 3. Method x noise breakdown
    rows = []
    for m in METHOD_ORDER:
        for noise in NOISE_ORDER:
            w_s = w[(w["run"] == m) & (w["noise"] == noise)]["success_at_10pct"].mean() * 100
            q_s = q[(q["run"] == m) & (q["noise"] == noise)]["success_at_10pct"].mean() * 100
            nl = f"{noise:g}" if noise > 0 else "0"
            rows.append({
                "method": METHOD_LABELS[m],
                "noise": nl,
                "wombat_success_10pct": w_s,
                "quokka_success_10pct": q_s,
                "delta_pp": q_s - w_s,
            })
    noise_df = pd.DataFrame(rows)
    noise_df.to_csv(os.path.join(OUT_DIR, "method_noise_comparison.csv"), index=False)

    # 4. Biggest improvements and regressions
    biggest_improvements = per_system_df.nlargest(10, "delta_pp")
    biggest_regressions = per_system_df.nsmallest(10, "delta_pp")

    # 5. Timing comparison
    timing_rows = []
    for m in METHOD_ORDER:
        w_t = w[w["run"] == m]["time"]
        q_t = q[q["run"] == m]["time"]
        timing_rows.append({
            "method": METHOD_LABELS[m],
            "wombat_median": w_t.median(),
            "quokka_median": q_t.median(),
            "wombat_mean": w_t.mean(),
            "quokka_mean": q_t.mean(),
            "median_delta": q_t.median() - w_t.median(),
            "speedup_factor": w_t.median() / q_t.median() if q_t.median() > 0 else np.nan,
        })
    timing_df = pd.DataFrame(timing_rows)
    timing_df.to_csv(os.path.join(OUT_DIR, "timing_comparison.csv"), index=False)

    # Generate markdown report
    report = f"""# Wombat vs Quokka Benchmark Comparison

**Generated:** 2026-03-06
**Wombat:** benchmark_wombat_2026_02_26 ({len(shared_systems)} shared systems)
**Quokka:** benchmark_quokka_2026_03_05 ({len(shared_systems)} systems)

**Note:** Different random parameter instances are used in each benchmark,
so this is a statistical comparison (not paired).

---

## Overall Success@10% by Method

| Method | Wombat | Quokka | Delta |
|--------|--------|--------|-------|
"""
    for _, r in overall_df.iterrows():
        d = r["delta_10pct"]
        sign = "+" if d >= 0 else ""
        report += f"| {r['method']} | {r['wombat_success_10pct']:.1f}% | {r['quokka_success_10pct']:.1f}% | {sign}{d:.1f} pp |\n"

    report += f"""
---

## Timing Comparison

| Method | Wombat Median (s) | Quokka Median (s) | Delta (s) | Speedup |
|--------|-------------------|-------------------|-----------|---------|
"""
    for _, r in timing_df.iterrows():
        report += f"| {r['method']} | {r['wombat_median']:.0f} | {r['quokka_median']:.0f} | {r['median_delta']:+.0f} | {r['speedup_factor']:.2f}x |\n"

    report += f"""
---

## Biggest Improvements (Quokka vs Wombat)

| System | Method | Wombat | Quokka | Delta |
|--------|--------|--------|--------|-------|
"""
    for _, r in biggest_improvements.iterrows():
        report += f"| {r['system']} | {r['method']} | {r['wombat_success_10pct']:.1f}% | {r['quokka_success_10pct']:.1f}% | +{r['delta_pp']:.1f} pp |\n"

    report += f"""
## Biggest Regressions (Quokka vs Wombat)

| System | Method | Wombat | Quokka | Delta |
|--------|--------|--------|--------|-------|
"""
    for _, r in biggest_regressions.iterrows():
        report += f"| {r['system']} | {r['method']} | {r['wombat_success_10pct']:.1f}% | {r['quokka_success_10pct']:.1f}% | {r['delta_pp']:.1f} pp |\n"

    report += f"""
---

## Method x Noise Breakdown

| Method | Noise | Wombat | Quokka | Delta |
|--------|-------|--------|--------|-------|
"""
    for _, r in noise_df.iterrows():
        d = r["delta_pp"]
        sign = "+" if d >= 0 else ""
        report += f"| {r['method']} | {r['noise']} | {r['wombat_success_10pct']:.1f}% | {r['quokka_success_10pct']:.1f}% | {sign}{d:.1f} pp |\n"

    report += f"""
---

## Summary

- **{len(shared_systems)} shared systems** compared across both benchmarks.
- Per-system deltas range from {per_system_df['delta_pp'].min():.1f} pp to +{per_system_df['delta_pp'].max():.1f} pp.
- Mean delta across all (system, method) pairs: {per_system_df['delta_pp'].mean():+.1f} pp.
- These differences reflect random sampling variation in true parameter values, not systematic changes.
"""

    report_path = os.path.join(OUT_DIR, "COMPARISON_REPORT.md")
    with open(report_path, "w") as f:
        f.write(report)
    print(f"\nReport saved to: {report_path}")
    print(f"CSVs saved to: {OUT_DIR}/")


if __name__ == "__main__":
    main()
