#!/usr/bin/env python3
"""
Biohydrogenation Deep Dive: Analyze HC candidates from quokka benchmark.

This script analyzes the raw result.csv to understand:
1. Per-variable oracle errors (best candidate per variable independently)
2. Best joint candidate (min mean error across all identifiable vars)
3. Whether ANY candidate has all 9 identifiable vars within 10%
4. Candidate alignment: do per-variable bests co-occur?
"""

import csv
import ast
import sys
import os
from collections import defaultdict

RESULT_CSV = os.path.expanduser(
    "~/ParameterEstimationBenchmarking/benchmark_quokka_2026_03_05/result.csv"
)
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))

# Variables in the system
ALL_VARS = ["k5", "k6", "k7", "k8", "k9", "k10", "x4", "x5", "x6", "x7"]
# x7 is non-identifiable — exclude from scoring
ID_VARS = ["k5", "k6", "k7", "k8", "k9", "k10", "x4", "x5", "x6"]
THRESHOLD = 0.10  # 10% relative error


def parse_result_field(result_str):
    """Parse the result field which is a list of [varname, val1, val2, ...] lists."""
    try:
        data = ast.literal_eval(result_str)
    except (ValueError, SyntaxError):
        return None

    if not isinstance(data, list) or len(data) == 0:
        return None

    # data is like [['k5', '0.688', '0.687', ...], ['k6', ...], ...]
    var_candidates = {}
    n_candidates = None
    for row in data:
        if not isinstance(row, list) or len(row) < 2:
            continue
        varname = row[0]
        values = []
        for v in row[1:]:
            try:
                values.append(float(v))
            except (ValueError, TypeError):
                values.append(float('nan'))
        var_candidates[varname] = values
        if n_candidates is None:
            n_candidates = len(values)

    return var_candidates, n_candidates


def parse_true_values(true_str):
    """Parse true parameter/state dict string like {'k5': 0.688, ...}."""
    try:
        return ast.literal_eval(true_str)
    except (ValueError, SyntaxError):
        return {}


def relative_error(estimated, true_val):
    """Compute relative error."""
    if abs(true_val) < 1e-12:
        return abs(estimated)
    return abs(estimated - true_val) / abs(true_val)


def analyze_instance(row):
    """Analyze a single biohydrogenation ODEPE instance."""
    result_str = row["result"]
    parsed = parse_result_field(result_str)
    if parsed is None:
        return None

    var_candidates, n_candidates = parsed

    true_params = parse_true_values(row["true_parameters"])
    true_states = parse_true_values(row["true_states"])
    true_vals = {**true_params, **true_states}

    instance_id = row["id"]
    run = row["run"]

    # Per-variable analysis
    per_var_best_err = {}
    per_var_best_idx = {}

    for vn in ID_VARS:
        if vn not in var_candidates or vn not in true_vals:
            per_var_best_err[vn] = float('inf')
            per_var_best_idx[vn] = -1
            continue

        best_err = float('inf')
        best_idx = -1
        for i, est in enumerate(var_candidates[vn]):
            err = relative_error(est, true_vals[vn])
            if err < best_err:
                best_err = err
                best_idx = i

        per_var_best_err[vn] = best_err
        per_var_best_idx[vn] = best_idx

    # Joint analysis: for each candidate index, compute mean error across all id vars
    best_joint_mean = float('inf')
    best_joint_max = float('inf')
    best_joint_idx = -1
    n_all_good = 0

    if n_candidates and n_candidates > 0:
        for cand_idx in range(n_candidates):
            errors = []
            all_good = True
            for vn in ID_VARS:
                if vn not in var_candidates or vn not in true_vals:
                    all_good = False
                    continue
                if cand_idx >= len(var_candidates[vn]):
                    all_good = False
                    continue
                est = var_candidates[vn][cand_idx]
                err = relative_error(est, true_vals[vn])
                errors.append(err)
                if err > THRESHOLD:
                    all_good = False

            if all_good:
                n_all_good += 1

            if errors:
                mean_err = sum(errors) / len(errors)
                max_err = max(errors)
                if mean_err < best_joint_mean:
                    best_joint_mean = mean_err
                    best_joint_max = max_err
                    best_joint_idx = cand_idx

    # Compute alignment gap
    per_var_oracle_mean = sum(per_var_best_err[vn] for vn in ID_VARS) / len(ID_VARS)
    alignment_gap = best_joint_mean - per_var_oracle_mean if best_joint_mean < float('inf') else float('inf')

    return {
        "instance_id": instance_id,
        "run": run,
        "n_candidates": n_candidates or 0,
        "n_all_good": n_all_good,
        "per_var_best_err": per_var_best_err,
        "per_var_best_idx": per_var_best_idx,
        "per_var_oracle_mean": per_var_oracle_mean,
        "best_joint_mean": best_joint_mean,
        "best_joint_max": best_joint_max,
        "best_joint_idx": best_joint_idx,
        "alignment_gap": alignment_gap,
        "true_vals": true_vals,
    }


def main():
    print("=" * 70)
    print("  Biohydrogenation Candidate Analysis (Quokka Benchmark)")
    print("=" * 70)

    # Read all biohydrogenation noise=0 ODEPE rows
    results = []
    with open(RESULT_CSV, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if (row["name"] == "biohydrogenation" and
                row["noise"] == "0.0" and
                row["run"] in ("odepe_polish", "odepe_nopolish") and
                row["has_result"] == "True"):
                analysis = analyze_instance(row)
                if analysis is not None:
                    results.append(analysis)

    print(f"\nFound {len(results)} biohydrogenation noise=0 ODEPE rows")

    # Per-instance analysis
    for r in results:
        print(f"\n{'─' * 60}")
        print(f"Instance: {r['instance_id']} ({r['run']})")
        print(f"  Candidates: {r['n_candidates']}")
        print(f"  Candidates with ALL {len(ID_VARS)} id vars < {THRESHOLD*100:.0f}%: {r['n_all_good']}")
        print(f"  Best joint candidate: idx={r['best_joint_idx']}, "
              f"mean_err={r['best_joint_mean']:.6f}, max_err={r['best_joint_max']:.6f}")
        print(f"  Per-variable oracle mean: {r['per_var_oracle_mean']:.6f}")
        print(f"  Alignment gap: {r['alignment_gap']:.6f}")

        print(f"\n  {'Var':<6} {'True':>8} {'BestErr':>10} {'BestIdx':>8} {'<10%':>6}")
        print(f"  {'─'*6} {'─'*8} {'─'*10} {'─'*8} {'─'*6}")
        for vn in ID_VARS:
            true_v = r['true_vals'].get(vn, float('nan'))
            best_err = r['per_var_best_err'].get(vn, float('inf'))
            best_idx = r['per_var_best_idx'].get(vn, -1)
            good = "YES" if best_err < THRESHOLD else "NO"
            print(f"  {vn:<6} {true_v:8.4f} {best_err:10.6f} {best_idx:8d} {good:>6}")

        # Show unique best indices
        unique_indices = set(r['per_var_best_idx'].values())
        print(f"\n  Per-variable bests from {len(unique_indices)} different candidates: "
              f"{sorted(unique_indices)}")

    # Summary table across all instances
    print(f"\n{'=' * 70}")
    print("  SUMMARY TABLE")
    print(f"{'=' * 70}")

    print(f"\n{'Instance':<30} {'Run':<16} {'#Cand':>6} {'#Good':>6} {'JointMean':>10} {'OracleMean':>11} {'Gap':>8}")
    print(f"{'─'*30} {'─'*16} {'─'*6} {'─'*6} {'─'*10} {'─'*11} {'─'*8}")
    for r in results:
        print(f"{r['instance_id']:<30} {r['run']:<16} {r['n_candidates']:>6} "
              f"{r['n_all_good']:>6} {r['best_joint_mean']:>10.6f} "
              f"{r['per_var_oracle_mean']:>11.6f} {r['alignment_gap']:>8.6f}")

    # Per-variable summary: how often is each variable the bottleneck?
    print(f"\n{'=' * 70}")
    print("  PER-VARIABLE FAILURE ANALYSIS")
    print(f"{'=' * 70}")

    var_fail_count = defaultdict(int)
    var_total_count = defaultdict(int)
    var_err_sums = defaultdict(float)

    for r in results:
        for vn in ID_VARS:
            var_total_count[vn] += 1
            best_err = r['per_var_best_err'].get(vn, float('inf'))
            if best_err > THRESHOLD:
                var_fail_count[vn] += 1
            if best_err < float('inf'):
                var_err_sums[vn] += best_err

    print(f"\n{'Var':<6} {'FailRate':>10} {'AvgBestErr':>12} {'Category':>20}")
    print(f"{'─'*6} {'─'*10} {'─'*12} {'─'*20}")
    for vn in ID_VARS:
        n_total = var_total_count[vn]
        n_fail = var_fail_count[vn]
        avg_err = var_err_sums[vn] / max(n_total, 1)
        rate = f"{n_fail}/{n_total}"
        if avg_err < 0.001:
            cat = "Always correct"
        elif avg_err < 0.05:
            cat = "Usually correct"
        elif avg_err < 0.5:
            cat = "Sometimes wrong"
        else:
            cat = "Always wrong"
        print(f"{vn:<6} {rate:>10} {avg_err:>12.6f} {cat:>20}")

    # Write detailed CSV
    csv_out_path = os.path.join(OUTPUT_DIR, "candidate_analysis.csv")
    with open(csv_out_path, "w", newline="") as f:
        writer = csv.writer(f)
        header = ["instance_id", "run", "n_candidates", "n_all_good",
                  "best_joint_mean", "best_joint_max", "per_var_oracle_mean", "alignment_gap"]
        for vn in ID_VARS:
            header.extend([f"{vn}_best_err", f"{vn}_best_idx"])
        writer.writerow(header)

        for r in results:
            row_data = [
                r["instance_id"], r["run"], r["n_candidates"], r["n_all_good"],
                f"{r['best_joint_mean']:.8f}", f"{r['best_joint_max']:.8f}",
                f"{r['per_var_oracle_mean']:.8f}", f"{r['alignment_gap']:.8f}",
            ]
            for vn in ID_VARS:
                row_data.append(f"{r['per_var_best_err'].get(vn, float('inf')):.8f}")
                row_data.append(str(r['per_var_best_idx'].get(vn, -1)))
            writer.writerow(row_data)

    print(f"\nDetailed CSV written to: {csv_out_path}")
    print("\nDone.")


if __name__ == "__main__":
    main()
