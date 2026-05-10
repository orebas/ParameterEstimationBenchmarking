#!/usr/bin/env python3
"""
Step 5: Compare Quokka vs Bilby benchmark results.

Filters both to shared systems and compares success rates,
timing, and per-system deltas.

Note: Quokka uses multiplicative noise; Bilby uses additive noise.

Usage:
    python3 results/bilby_analysis/compare_benchmarks.py
"""

import os
import numpy as np
import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
QUOKKA_CSV = os.path.expanduser(
    "~/ParameterEstimationBenchmark-local/results/quokka_analysis/flat_results_with_metrics.csv"
)
BILBY_CSV = os.path.join(SCRIPT_DIR, "flat_results_with_metrics.csv")
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
    q = pd.read_csv(QUOKKA_CSV)
    b = pd.read_csv(BILBY_CSV)
    print(f"  Quokka: {len(q)} rows, {q['name'].nunique()} systems")
    print(f"  Bilby:  {len(b)} rows, {b['name'].nunique()} systems")

    # Filter to shared systems
    shared_systems = sorted(set(q["name"].unique()) & set(b["name"].unique()))
    print(f"  Shared systems: {len(shared_systems)}")
    q = q[q["name"].isin(shared_systems)].copy()
    b = b[b["name"].isin(shared_systems)].copy()
    print(f"  Quokka filtered: {len(q)} rows")
    print(f"  Bilby filtered:  {len(b)} rows")

    # 1. Overall success rates per method
    rows = []
    for m in METHOD_ORDER:
        q_succ = q[q["run"] == m]["success_at_10pct"].mean() * 100
        b_succ = b[b["run"] == m]["success_at_10pct"].mean() * 100
        q_time = q[q["run"] == m]["time"].median()
        b_time = b[b["run"] == m]["time"].median()
        q_s1 = q[q["run"] == m]["success_at_1pct"].mean() * 100
        b_s1 = b[b["run"] == m]["success_at_1pct"].mean() * 100
        q_s50 = q[q["run"] == m]["success_at_50pct"].mean() * 100
        b_s50 = b[b["run"] == m]["success_at_50pct"].mean() * 100
        rows.append({
            "method": METHOD_LABELS[m],
            "quokka_success_1pct": q_s1,
            "bilby_success_1pct": b_s1,
            "delta_1pct": b_s1 - q_s1,
            "quokka_success_10pct": q_succ,
            "bilby_success_10pct": b_succ,
            "delta_10pct": b_succ - q_succ,
            "quokka_success_50pct": q_s50,
            "bilby_success_50pct": b_s50,
            "delta_50pct": b_s50 - q_s50,
            "quokka_median_time": q_time,
            "bilby_median_time": b_time,
            "time_delta": b_time - q_time,
        })
    overall_df = pd.DataFrame(rows)
    overall_df.to_csv(os.path.join(OUT_DIR, "overall_method_comparison.csv"), index=False)
    print("\n--- Overall Method Comparison ---")
    for _, r in overall_df.iterrows():
        d = r["delta_10pct"]
        sign = "+" if d >= 0 else ""
        print(f"  {r['method']:20s}  quokka={r['quokka_success_10pct']:.1f}%  bilby={r['bilby_success_10pct']:.1f}%  delta={sign}{d:.1f} pp")

    # 2. Per-system delta in success@10%
    rows = []
    for sys_name in shared_systems:
        for m in METHOD_ORDER:
            q_s = q[(q["name"] == sys_name) & (q["run"] == m)]["success_at_10pct"].mean() * 100
            b_s = b[(b["name"] == sys_name) & (b["run"] == m)]["success_at_10pct"].mean() * 100
            rows.append({
                "system": sys_name,
                "method": METHOD_LABELS[m],
                "quokka_success_10pct": q_s,
                "bilby_success_10pct": b_s,
                "delta_pp": b_s - q_s,
            })
    per_system_df = pd.DataFrame(rows)
    per_system_df.to_csv(os.path.join(OUT_DIR, "per_system_delta.csv"), index=False)

    # 3. Method x noise breakdown
    rows = []
    for m in METHOD_ORDER:
        for noise in NOISE_ORDER:
            q_s = q[(q["run"] == m) & (q["noise"] == noise)]["success_at_10pct"].mean() * 100
            b_s = b[(b["run"] == m) & (b["noise"] == noise)]["success_at_10pct"].mean() * 100
            nl = f"{noise:g}" if noise > 0 else "0"
            rows.append({
                "method": METHOD_LABELS[m],
                "noise": nl,
                "quokka_success_10pct": q_s,
                "bilby_success_10pct": b_s,
                "delta_pp": b_s - q_s,
            })
    noise_df = pd.DataFrame(rows)
    noise_df.to_csv(os.path.join(OUT_DIR, "method_noise_comparison.csv"), index=False)

    # 4. Biggest improvements and regressions
    biggest_improvements = per_system_df.nlargest(10, "delta_pp")
    biggest_regressions = per_system_df.nsmallest(10, "delta_pp")

    # 5. Timing comparison
    timing_rows = []
    for m in METHOD_ORDER:
        q_t = q[q["run"] == m]["time"]
        b_t = b[b["run"] == m]["time"]
        timing_rows.append({
            "method": METHOD_LABELS[m],
            "quokka_median": q_t.median(),
            "bilby_median": b_t.median(),
            "quokka_mean": q_t.mean(),
            "bilby_mean": b_t.mean(),
            "median_delta": b_t.median() - q_t.median(),
            "speedup_factor": q_t.median() / b_t.median() if b_t.median() > 0 else np.nan,
        })
    timing_df = pd.DataFrame(timing_rows)
    timing_df.to_csv(os.path.join(OUT_DIR, "timing_comparison.csv"), index=False)

    # Generate markdown report
    report = f"""# Quokka vs Bilby Benchmark Comparison

**Generated:** 2026-03-10
**Quokka:** benchmark_quokka_2026_03_05 ({len(shared_systems)} shared systems, multiplicative noise)
**Bilby:** benchmark_bilby_2026_03_09 ({len(shared_systems)} systems, additive noise)

**Note:** Different random parameter instances and different noise models are used in each benchmark,
so this is a statistical comparison (not paired). Quokka uses multiplicative noise; Bilby uses additive noise.

---

## Overall Success@10% by Method

| Method | Quokka | Bilby | Delta |
|--------|--------|-------|-------|
"""
    for _, r in overall_df.iterrows():
        d = r["delta_10pct"]
        sign = "+" if d >= 0 else ""
        report += f"| {r['method']} | {r['quokka_success_10pct']:.1f}% | {r['bilby_success_10pct']:.1f}% | {sign}{d:.1f} pp |\n"

    report += f"""
---

## Timing Comparison

| Method | Quokka Median (s) | Bilby Median (s) | Delta (s) | Speedup |
|--------|-------------------|-------------------|-----------|---------|
"""
    for _, r in timing_df.iterrows():
        report += f"| {r['method']} | {r['quokka_median']:.0f} | {r['bilby_median']:.0f} | {r['median_delta']:+.0f} | {r['speedup_factor']:.2f}x |\n"

    report += f"""
---

## Biggest Improvements (Bilby vs Quokka)

| System | Method | Quokka | Bilby | Delta |
|--------|--------|--------|-------|-------|
"""
    for _, r in biggest_improvements.iterrows():
        report += f"| {r['system']} | {r['method']} | {r['quokka_success_10pct']:.1f}% | {r['bilby_success_10pct']:.1f}% | +{r['delta_pp']:.1f} pp |\n"

    report += f"""
## Biggest Regressions (Bilby vs Quokka)

| System | Method | Quokka | Bilby | Delta |
|--------|--------|--------|-------|-------|
"""
    for _, r in biggest_regressions.iterrows():
        report += f"| {r['system']} | {r['method']} | {r['quokka_success_10pct']:.1f}% | {r['bilby_success_10pct']:.1f}% | {r['delta_pp']:.1f} pp |\n"

    report += f"""
---

## Method x Noise Breakdown

| Method | Noise | Quokka | Bilby | Delta |
|--------|-------|--------|-------|-------|
"""
    for _, r in noise_df.iterrows():
        d = r["delta_pp"]
        sign = "+" if d >= 0 else ""
        report += f"| {r['method']} | {r['noise']} | {r['quokka_success_10pct']:.1f}% | {r['bilby_success_10pct']:.1f}% | {sign}{d:.1f} pp |\n"

    report += f"""
---

## Summary

- **{len(shared_systems)} shared systems** compared across both benchmarks.
- **Noise model difference:** Quokka uses multiplicative noise, Bilby uses additive noise.
- Per-system deltas range from {per_system_df['delta_pp'].min():.1f} pp to +{per_system_df['delta_pp'].max():.1f} pp.
- Mean delta across all (system, method) pairs: {per_system_df['delta_pp'].mean():+.1f} pp.
- Differences reflect both random sampling variation and the change in noise model.
"""

    report_path = os.path.join(OUT_DIR, "COMPARISON_REPORT.md")
    with open(report_path, "w") as f:
        f.write(report)
    print(f"\nReport saved to: {report_path}")
    print(f"CSVs saved to: {OUT_DIR}/")


if __name__ == "__main__":
    main()
