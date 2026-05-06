#!/usr/bin/env python3
"""Compare two benchmark runs to find differentiating instances.

Identifies cases where one estimation method succeeds and another fails,
enabling targeted investigation of method-specific strengths and weaknesses.

Usage:
    python compare_runs.py <benchmark_dir> <run_a> <run_b> [options]
    python compare_runs.py <benchmark_dir> --list-runs
"""

import os
import sys
import ast
import argparse
import numpy as np
import pandas as pd
from pathlib import Path

from shared import warn, info
from summarize_results import (
    parse_dict_string_must_succeed,
    parse_result_string,
    select_best_estimation,
    calculate_success_ratio_filtered,
    calculate_mean_relative_error_filtered,
    calculate_max_relative_error_filtered,
    filter_identifiable_parameters,
)


def parse_non_identifiable(s):
    """Parse the non_identifiable column into a list."""
    if pd.isna(s) or s == '' or s == 'nan' or s == 'NaN':
        return []
    try:
        result = ast.literal_eval(s)
        return result if isinstance(result, list) else []
    except Exception:
        return []


def list_available_runs(benchmark_dir):
    """Show available runs in result.csv and on disk."""
    benchmark_dir = Path(benchmark_dir)
    result_path = benchmark_dir / 'result.csv'

    if not result_path.exists():
        warn(f"No result.csv found in {benchmark_dir}")
        return

    df = pd.read_csv(result_path, index_col=0)
    runs_in_csv = sorted(df['run'].unique())

    print(f"\nRuns in result.csv ({result_path}):")
    for run in runs_in_csv:
        run_df = df[df['run'] == run]
        n_total = len(run_df)
        n_with_result = run_df['has_result'].sum()
        n_finished = run_df['finished'].sum()
        print(f"  {run:30s}  {n_total} instances, {int(n_finished)} finished, {int(n_with_result)} with results")

    # Scan filetree for runs on disk
    config_path = benchmark_dir / 'config' / 'config.json'
    if config_path.exists():
        import json
        with open(config_path) as f:
            config = json.load(f)
        filetree_dir = benchmark_dir / config.get('FILETREE', 'filetree')
    else:
        filetree_dir = benchmark_dir / 'filetree'

    if filetree_dir.exists():
        # Exclude known non-run directories
        skip = {'data_generation', 'data_original', 'data_noisy'}
        disk_runs = sorted([
            d.name for d in filetree_dir.iterdir()
            if d.is_dir() and d.name not in skip
        ])
        missing = [r for r in disk_runs if r not in runs_in_csv]
        if missing:
            print(f"\nRuns in {filetree_dir.name}/ but NOT in result.csv:")
            for run in missing:
                print(f"  {run:30s}  (run collect_results.py to include)")
    print()


def load_and_validate(benchmark_dir, run_a, run_b):
    """Load result.csv and validate that both runs exist."""
    benchmark_dir = Path(benchmark_dir)
    result_path = benchmark_dir / 'result.csv'

    if not result_path.exists():
        warn(f"No result.csv found in {benchmark_dir}")
        sys.exit(1)

    df = pd.read_csv(result_path, index_col=0)
    available_runs = sorted(df['run'].unique())

    for run in (run_a, run_b):
        if run not in available_runs:
            warn(f"Run '{run}' not found in result.csv.")
            print(f"  Available runs: {', '.join(available_runs)}")
            # Check if it exists on disk
            filetree_dir = benchmark_dir / 'filetree'
            if (filetree_dir / run).exists():
                print(f"  '{run}' exists in filetree/ — run collect_results.py to include it.")
            sys.exit(1)

    return df[df['run'].isin([run_a, run_b])].copy()


def compute_instance_metrics(df, tolerance):
    """Compute success/failure and error metrics for each row.

    Reuses the parsing pipeline from summarize_results.py.
    """
    df['true_states_parsed'] = df['true_states'].apply(parse_dict_string_must_succeed)
    df['true_parameters_parsed'] = df['true_parameters'].apply(parse_dict_string_must_succeed)
    df['non_identifiable_parsed'] = df['non_identifiable'].apply(parse_non_identifiable)
    df['true_params_parsed'] = df.apply(
        lambda row: {**row['true_states_parsed'], **row['true_parameters_parsed']}, axis=1
    )
    df['estimation_candidates'] = df['result'].apply(parse_result_string)

    def get_best(row):
        candidates = row['estimation_candidates']
        true_params = row['true_params_parsed']
        if not candidates:
            return {}
        return select_best_estimation(true_params, candidates)

    df['estimated_params'] = df.apply(get_best, axis=1)

    df['is_successful'] = df.apply(
        lambda row: calculate_success_ratio_filtered(
            row['true_params_parsed'], row['estimated_params'],
            tolerance, row['non_identifiable_parsed']
        ), axis=1
    )
    df['mean_rel_error'] = df.apply(
        lambda row: calculate_mean_relative_error_filtered(
            row['true_params_parsed'], row['estimated_params'],
            row['non_identifiable_parsed']
        ), axis=1
    )
    df['max_rel_error'] = df.apply(
        lambda row: calculate_max_relative_error_filtered(
            row['true_params_parsed'], row['estimated_params'],
            row['non_identifiable_parsed']
        ), axis=1
    )
    return df


def build_comparison_table(df, run_a, run_b):
    """Pivot per-instance data into a comparison table with classification."""
    cols = ['id', 'name', 'noise', 'run', 'is_successful', 'mean_rel_error',
            'max_rel_error', 'time', 'true_params_parsed', 'estimated_params',
            'non_identifiable_parsed']
    df_a = df[df['run'] == run_a][cols].copy()
    df_b = df[df['run'] == run_b][cols].copy()

    merged = df_a.merge(df_b, on='id', suffixes=('_a', '_b'))

    def classify(row):
        a_ok = row['is_successful_a']
        b_ok = row['is_successful_b']
        if a_ok and b_ok:
            return 'both_success'
        elif not a_ok and not b_ok:
            return 'both_fail'
        elif a_ok and not b_ok:
            return 'a_only'
        else:
            return 'b_only'

    merged['classification'] = merged.apply(classify, axis=1)
    # Use name/noise from the _a side (identical for both)
    merged['name'] = merged['name_a']
    merged['noise'] = merged['noise_a']
    return merged


def print_summary(comp, run_a, run_b, tolerance):
    """Print a concise summary of where two runs diverge."""
    total = len(comp)
    counts = comp['classification'].value_counts()

    both_ok = counts.get('both_success', 0)
    both_fail = counts.get('both_fail', 0)
    a_only = counts.get('a_only', 0)
    b_only = counts.get('b_only', 0)

    print(f"\n{'='*70}")
    print(f"Comparison: {run_a} vs {run_b}  (tolerance={tolerance})")
    print(f"{'='*70}")
    print(f"\nOverall ({total} instances):")
    print(f"  Both succeed:    {both_ok:5d}  ({100*both_ok/total:5.1f}%)")
    print(f"  Both fail:       {both_fail:5d}  ({100*both_fail/total:5.1f}%)")
    print(f"  {run_a} only:  {a_only:5d}  ({100*a_only/total:5.1f}%)")
    print(f"  {run_b} only:  {b_only:5d}  ({100*b_only/total:5.1f}%)")

    # By noise level
    noise_levels = sorted(comp['noise'].unique())
    print(f"\nBy noise level:")
    header = f"  {'noise':>10s}  {'both_ok':>8s}  {'both_fail':>9s}  {run_a[:15]:>15s}  {run_b[:15]:>15s}  {'total':>5s}"
    print(header)
    print(f"  {'-'*len(header.strip())}")
    for noise in noise_levels:
        sub = comp[comp['noise'] == noise]
        c = sub['classification'].value_counts()
        n = len(sub)
        print(f"  {noise:>10.0e}  {c.get('both_success',0):>8d}  {c.get('both_fail',0):>9d}  "
              f"{c.get('a_only',0):>15d}  {c.get('b_only',0):>15d}  {n:>5d}")

    # By system (only those with divergences)
    divergent = comp[comp['classification'].isin(['a_only', 'b_only'])]
    if divergent.empty:
        print("\nNo differentiating instances found.")
        return

    print(f"\nBy system (only showing systems with divergences):")
    systems = sorted(divergent['name'].unique())
    header = f"  {'system':25s}  {'noise':>10s}  {run_a[:15]:>15s}  {run_b[:15]:>15s}"
    print(header)
    print(f"  {'-'*len(header.strip())}")
    for system in systems:
        sys_data = comp[comp['name'] == system]
        for noise in noise_levels:
            sub = sys_data[sys_data['noise'] == noise]
            c = sub['classification'].value_counts()
            a_cnt = c.get('a_only', 0)
            b_cnt = c.get('b_only', 0)
            if a_cnt > 0 or b_cnt > 0:
                n_total = len(sub)
                print(f"  {system:25s}  {noise:>10.0e}  {a_cnt:>11d}/{n_total:<3d}  {b_cnt:>11d}/{n_total:<3d}")
    print()


def print_detail(comp, run_a, run_b, show_params):
    """Print each differentiating instance with investigation detail."""
    for label, classification, winner, loser in [
        (f"{run_a} succeeds, {run_b} fails", 'a_only', '_a', '_b'),
        (f"{run_b} succeeds, {run_a} fails", 'b_only', '_b', '_a'),
    ]:
        subset = comp[comp['classification'] == classification].sort_values(['name', 'noise'])
        if subset.empty:
            print(f"\n--- {label}: (none) ---\n")
            continue

        print(f"\n{'='*70}")
        print(f"  {label}  ({len(subset)} instances)")
        print(f"{'='*70}")

        for i, (_, row) in enumerate(subset.iterrows(), 1):
            winner_run = run_a if winner == '_a' else run_b
            loser_run = run_b if winner == '_a' else run_a

            print(f"\n[{i}] {row['id']}  (system: {row['name']}, noise: {row['noise']:.0e})")
            print(f"    {winner_run:30s}  SUCCESS  mean_err={row[f'mean_rel_error{winner}']:.4f}  "
                  f"max_err={row[f'max_rel_error{winner}']:.4f}  "
                  f"time={row[f'time{winner}']:.1f}s" if pd.notna(row[f'time{winner}']) else
                  f"    {winner_run:30s}  SUCCESS  mean_err={row[f'mean_rel_error{winner}']:.4f}  "
                  f"max_err={row[f'max_rel_error{winner}']:.4f}  time=N/A")
            print(f"    {loser_run:30s}  FAIL     mean_err={row[f'mean_rel_error{loser}']:.4f}  "
                  f"max_err={row[f'max_rel_error{loser}']:.4f}  "
                  f"time={row[f'time{loser}']:.1f}s" if pd.notna(row[f'time{loser}']) else
                  f"    {loser_run:30s}  FAIL     mean_err={row[f'mean_rel_error{loser}']:.4f}  "
                  f"max_err={row[f'max_rel_error{loser}']:.4f}  time=N/A")

            if show_params:
                true_params = row[f'true_params_parsed{winner}']
                est_winner = row[f'estimated_params{winner}']
                est_loser = row[f'estimated_params{loser}']
                non_id = set(row[f'non_identifiable_parsed{winner}'])

                print(f"    {'parameter':15s}  {'true':>10s}  {winner_run[:12]:>12s}  {'err%':>8s}  "
                      f"{loser_run[:12]:>12s}  {'err%':>8s}")
                for param in sorted(true_params.keys()):
                    if param in non_id:
                        tag = " (non-id)"
                    else:
                        tag = ""
                    true_val = float(true_params[param])
                    w_val = float(est_winner.get(param, float('nan'))) if est_winner else float('nan')
                    l_val = float(est_loser.get(param, float('nan'))) if est_loser else float('nan')
                    w_err = abs(w_val - true_val) / abs(true_val) * 100 if abs(true_val) > 1e-15 and not np.isnan(w_val) else float('nan')
                    l_err = abs(l_val - true_val) / abs(true_val) * 100 if abs(true_val) > 1e-15 and not np.isnan(l_val) else float('nan')
                    print(f"    {param+tag:15s}  {true_val:>10.4f}  {w_val:>12.4f}  {w_err:>7.1f}%  "
                          f"{l_val:>12.4f}  {l_err:>7.1f}%")
    print()


def export_comparison(comp, run_a, run_b, output_dir):
    """Write comparison CSVs for downstream analysis."""
    output_dir = Path(output_dir)
    os.makedirs(output_dir, exist_ok=True)

    prefix = f"comparison_{run_a}_vs_{run_b}"

    # Columns to export (drop parsed dicts which don't serialize cleanly)
    export_cols = ['id', 'name', 'noise', 'classification',
                   'is_successful_a', 'is_successful_b',
                   'mean_rel_error_a', 'mean_rel_error_b',
                   'max_rel_error_a', 'max_rel_error_b',
                   'time_a', 'time_b']

    # Full table
    full_path = output_dir / f"{prefix}_full.csv"
    comp[export_cols].to_csv(full_path, index=False)
    info(f"Wrote {full_path}")

    # A-only
    a_only = comp[comp['classification'] == 'a_only'][export_cols]
    a_path = output_dir / f"{prefix}_a_only.csv"
    a_only.to_csv(a_path, index=False)
    info(f"Wrote {a_path} ({len(a_only)} rows)")

    # B-only
    b_only = comp[comp['classification'] == 'b_only'][export_cols]
    b_path = output_dir / f"{prefix}_b_only.csv"
    b_only.to_csv(b_path, index=False)
    info(f"Wrote {b_path} ({len(b_only)} rows)")

    # Pivot: system x noise -> count of differentiating instances
    divergent = comp[comp['classification'].isin(['a_only', 'b_only'])]
    if not divergent.empty:
        pivot = divergent.pivot_table(
            index='name', columns='noise', values='classification',
            aggfunc='count', fill_value=0
        )
        pivot_path = output_dir / f"{prefix}_by_system_noise.csv"
        pivot.to_csv(pivot_path)
        info(f"Wrote {pivot_path}")
    print()


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare two benchmark runs to find differentiating instances.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  %(prog)s benchmark_bilby_2026_03_09 --list-runs
  %(prog)s benchmark_bilby_2026_03_09 amigo2_run odepe_nopolish
  %(prog)s benchmark_bilby_2026_03_09 amigo2_run odepe_nopolish --mode detail --noise 0
  %(prog)s benchmark_bilby_2026_03_09 amigo2_run odepe_multipoint --mode detail --system crauste --show-params
  %(prog)s benchmark_bilby_2026_03_09 amigo2_run odepe_nopolish --mode export
""")
    parser.add_argument("benchmark_dir", help="Path to benchmark directory")
    parser.add_argument("run_a", nargs='?', help="First run name")
    parser.add_argument("run_b", nargs='?', help="Second run name")
    parser.add_argument("--tolerance", type=float, default=0.1,
                        help="Relative error tolerance for success (default: 0.1)")
    parser.add_argument("--noise", type=float, nargs='+',
                        help="Filter to specific noise levels")
    parser.add_argument("--system", type=str, nargs='+',
                        help="Filter to specific ODE system names")
    parser.add_argument("--mode", choices=['summary', 'detail', 'export'],
                        default='summary', help="Output mode (default: summary)")
    parser.add_argument("--list-runs", action='store_true',
                        help="List available runs and exit")
    parser.add_argument("--output-dir", type=str, default=None,
                        help="Directory for CSV export (default: <benchmark_dir>/analysis_results/)")
    parser.add_argument("--show-params", action='store_true',
                        help="In detail mode, show per-parameter true vs estimated values")
    return parser.parse_args()


def main():
    args = parse_args()

    if args.list_runs:
        list_available_runs(args.benchmark_dir)
        return

    if args.run_a is None or args.run_b is None:
        warn("Both run_a and run_b are required (or use --list-runs)")
        sys.exit(1)

    df = load_and_validate(args.benchmark_dir, args.run_a, args.run_b)

    # Apply filters
    if args.noise is not None:
        df = df[df['noise'].isin(args.noise)]
    if args.system is not None:
        df = df[df['name'].isin(args.system)]

    if df.empty:
        warn("No instances match the given filters.")
        sys.exit(0)

    info(f"Computing metrics for {len(df)} rows...")
    df = compute_instance_metrics(df, args.tolerance)
    comp = build_comparison_table(df, args.run_a, args.run_b)

    if comp.empty:
        warn("No paired instances found for these two runs.")
        sys.exit(0)

    if args.mode == 'summary':
        print_summary(comp, args.run_a, args.run_b, args.tolerance)
    elif args.mode == 'detail':
        print_summary(comp, args.run_a, args.run_b, args.tolerance)
        print_detail(comp, args.run_a, args.run_b, args.show_params)
    elif args.mode == 'export':
        output_dir = args.output_dir or str(Path(args.benchmark_dir) / 'analysis_results')
        print_summary(comp, args.run_a, args.run_b, args.tolerance)
        export_comparison(comp, args.run_a, args.run_b, output_dir)


if __name__ == "__main__":
    main()
