#!/usr/bin/env python3
"""
Generate Summary Statistics

Creates concise summary tables from the combined dataset:
1. Overall performance by software
2. Performance by system (which systems are hardest?)
3. Performance by noise level (noise sensitivity)

Usage:
    python3 generate_summary_statistics.py [--input CSVFILE] [--output-dir DIR]

Defaults:
    --input combined_results_filtered.csv
    --output-dir summary_statistics/
"""

import pandas as pd
import numpy as np
import argparse
import sys
from pathlib import Path
import ast


def parse_result(result_str):
    """Parse result column to dictionary."""
    if pd.isna(result_str) or result_str == '' or result_str == '[]':
        return {}

    try:
        result_list = ast.literal_eval(result_str)
        return {item[0]: float(item[1]) for item in result_list if len(item) >= 2}
    except:
        return {}


def parse_true_params(params_str):
    """Parse true_parameters column."""
    if pd.isna(params_str) or params_str == '':
        return {}

    try:
        return ast.literal_eval(params_str)
    except:
        return {}


def calculate_relative_error(row):
    """Calculate mean relative error for a row."""
    estimated = parse_result(row['result'])
    true_params = parse_true_params(row['true_parameters'])

    if not estimated or not true_params:
        return np.nan

    common_params = set(estimated.keys()) & set(true_params.keys())
    if len(common_params) == 0:
        return np.nan

    errors = []
    for param in common_params:
        est_val = estimated[param]
        true_val = true_params[param]

        if abs(true_val) < 1e-10:
            errors.append(abs(est_val - true_val))
        else:
            errors.append(abs(est_val - true_val) / abs(true_val))

    return np.mean(errors)


def generate_overall_performance(df):
    """Generate overall performance summary by software."""

    stats = []

    for software in sorted(df['run'].unique()):
        subset = df[df['run'] == software]

        # Success rate
        success_count = subset['has_result'].sum()
        total = len(subset)
        success_rate = success_count / total * 100

        # Error statistics (only for successful runs)
        successful = subset[subset['has_result'] == True].copy()
        successful['error'] = successful.apply(calculate_relative_error, axis=1)

        # Remove invalid errors
        valid_errors = successful['error'].dropna()
        valid_errors = valid_errors[valid_errors != np.inf]

        mean_error = valid_errors.mean() if len(valid_errors) > 0 else np.nan
        median_error = valid_errors.median() if len(valid_errors) > 0 else np.nan

        # Timing statistics
        mean_time = successful['time'].mean() if 'time' in successful.columns else np.nan

        stats.append({
            'software': software,
            'success_count': int(success_count),
            'total_experiments': int(total),
            'success_rate_%': round(success_rate, 1),
            'mean_error': round(mean_error, 4) if not np.isnan(mean_error) else np.nan,
            'median_error': round(median_error, 6) if not np.isnan(median_error) else np.nan,
            'mean_time_sec': round(mean_time, 1) if not np.isnan(mean_time) else np.nan
        })

    return pd.DataFrame(stats)


def generate_performance_by_system(df):
    """Generate mean error by system and software."""

    # Calculate errors
    df_with_errors = df[df['has_result'] == True].copy()
    df_with_errors['error'] = df_with_errors.apply(calculate_relative_error, axis=1)

    # Pivot table: systems × software
    pivot = df_with_errors.pivot_table(
        values='error',
        index='name',
        columns='run',
        aggfunc='mean'
    )

    # Round and sort by overall difficulty (mean across software)
    pivot = pivot.round(4)
    pivot['mean_difficulty'] = pivot.mean(axis=1)
    pivot = pivot.sort_values('mean_difficulty', ascending=False)

    # Remove the helper column before returning
    result = pivot.drop('mean_difficulty', axis=1)
    result = result.reset_index()

    return result


def generate_performance_by_noise(df):
    """Generate mean error by noise level and software."""

    # Calculate errors
    df_with_errors = df[df['has_result'] == True].copy()
    df_with_errors['error'] = df_with_errors.apply(calculate_relative_error, axis=1)

    # Pivot table: noise × software
    pivot = df_with_errors.pivot_table(
        values='error',
        index='noise',
        columns='run',
        aggfunc='mean'
    )

    # Round and sort by noise level
    pivot = pivot.round(4)
    pivot = pivot.sort_index()
    pivot = pivot.reset_index()

    return pivot


def format_table_markdown(df, title):
    """Format DataFrame as markdown table."""
    lines = [f"### {title}\n"]

    # Header
    headers = df.columns.tolist()
    lines.append("| " + " | ".join(str(h) for h in headers) + " |")
    lines.append("|" + "|".join(["-" * (len(str(h)) + 2) for h in headers]) + "|")

    # Rows
    for _, row in df.iterrows():
        formatted_row = []
        for val in row:
            if pd.isna(val):
                formatted_row.append("N/A")
            elif isinstance(val, float):
                # Smart formatting based on magnitude
                if abs(val) < 0.001 and val != 0:
                    formatted_row.append(f"{val:.2e}")
                else:
                    formatted_row.append(f"{val:.4f}".rstrip('0').rstrip('.'))
            else:
                formatted_row.append(str(val))
        lines.append("| " + " | ".join(formatted_row) + " |")

    lines.append("")
    return "\n".join(lines)


def generate_summary_markdown(overall, by_system, by_noise, output_dir):
    """Generate markdown summary document."""

    lines = [
        "# Summary Statistics",
        "",
        "**Generated from**: `combined_results_filtered.csv`",
        "",
        "This document provides high-level summary statistics for the benchmark results.",
        "",
        "---",
        "",
        format_table_markdown(overall, "Overall Performance by Software"),
        "**Interpretation**:",
        "- `success_rate_%`: Percentage of experiments that completed successfully",
        "- `mean_error`: Mean relative error (lower is better)",
        "- `median_error`: Median relative error (lower is better, less sensitive to outliers)",
        "- `mean_time_sec`: Average computation time in seconds",
        "",
        "---",
        "",
        format_table_markdown(by_system, "Mean Error by System"),
        "**Interpretation**:",
        "- Each cell shows mean relative error for that system-software combination",
        "- Systems sorted by difficulty (hardest systems first)",
        "- Lower values indicate better performance",
        "",
        "---",
        "",
        format_table_markdown(by_noise, "Mean Error by Noise Level"),
        "**Interpretation**:",
        "- Each cell shows mean relative error for that noise level-software combination",
        "- Noise levels: 0.0 (no noise) to 1e-2 (high noise)",
        "- Shows how robust each software is to measurement noise",
        "",
        "---",
        "",
        "**Files**:",
        "- `overall_performance.csv` - Overall statistics by software",
        "- `performance_by_system.csv` - Mean error by system",
        "- `performance_by_noise.csv` - Mean error by noise level",
        "- `SUMMARY.md` - This document (human-readable version)",
    ]

    output_file = Path(output_dir) / "SUMMARY.md"
    output_file.write_text("\n".join(lines))
    print(f"  Created: {output_file}")


def main():
    parser = argparse.ArgumentParser(
        description='Generate summary statistics from combined dataset'
    )

    parser.add_argument('--input', '-i', default='combined_results_filtered.csv',
                       help='Input CSV file (default: combined_results_filtered.csv)')
    parser.add_argument('--output-dir', '-o', default='summary_statistics',
                       help='Output directory (default: summary_statistics/)')

    args = parser.parse_args()

    # Check input exists
    if not Path(args.input).exists():
        print(f"Error: Input file not found: {args.input}")
        sys.exit(1)

    # Create output directory
    output_dir = Path(args.output_dir)
    output_dir.mkdir(exist_ok=True)

    print(f"Loading {args.input}...")
    df = pd.read_csv(args.input)
    print(f"  {len(df)} rows loaded")
    print(f"  {df['run'].nunique()} software variants")
    print(f"  {df['name'].nunique()} systems")
    print(f"  {df['noise'].nunique()} noise levels")
    print()

    # Generate summaries
    print("Generating summary statistics...")

    print("  1. Overall performance by software...")
    overall = generate_overall_performance(df)
    overall_file = output_dir / "overall_performance.csv"
    overall.to_csv(overall_file, index=False)
    print(f"     Saved: {overall_file}")

    print("  2. Performance by system...")
    by_system = generate_performance_by_system(df)
    by_system_file = output_dir / "performance_by_system.csv"
    by_system.to_csv(by_system_file, index=False)
    print(f"     Saved: {by_system_file}")

    print("  3. Performance by noise level...")
    by_noise = generate_performance_by_noise(df)
    by_noise_file = output_dir / "performance_by_noise.csv"
    by_noise.to_csv(by_noise_file, index=False)
    print(f"     Saved: {by_noise_file}")

    print("  4. Markdown summary...")
    generate_summary_markdown(overall, by_system, by_noise, output_dir)

    print()
    print("=" * 70)
    print("SUMMARY STATISTICS GENERATED")
    print("=" * 70)
    print(f"Output directory: {output_dir}/")
    print(f"Files created: 4 (3 CSVs + 1 markdown)")
    print()
    print("Quick view - Overall Performance:")
    print(overall.to_string(index=False))
    print("=" * 70)


if __name__ == '__main__':
    main()
