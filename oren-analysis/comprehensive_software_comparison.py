#!/usr/bin/env python3
"""
Comprehensive Software Comparison Analysis

This script performs a complete analysis of parameter estimation software performance
across different datasets, search bounds, systems, and noise levels.

Usage:
    python comprehensive_software_comparison.py \
        --dataset ../results/october_5_2025/result.csv \
        --output analysis_results.md
"""

import pandas as pd
import numpy as np
import argparse
import sys
from pathlib import Path
from collections import defaultdict
import json


def parse_result_column_odepe(result_str):
    """Parse ODEPE result column with multiple solutions."""
    if pd.isna(result_str) or result_str == '' or result_str == '[]':
        return None

    try:
        result_list = eval(result_str)
        if not isinstance(result_list, list) or len(result_list) == 0:
            return None

        first_param = result_list[0]
        if not isinstance(first_param, list) or len(first_param) < 2:
            return None

        # Multi-solution format
        if len(first_param) > 2:
            param_names = [param_data[0] for param_data in result_list]
            num_solutions = len(first_param) - 1

            solutions = []
            for sol_idx in range(num_solutions):
                solution = {}
                for param_idx, param_name in enumerate(param_names):
                    try:
                        value_str = result_list[param_idx][sol_idx + 1]
                        solution[param_name] = float(value_str)
                    except:
                        solution[param_name] = np.nan
                solutions.append(solution)
            return solutions
        else:
            # Single solution format
            solution = {}
            for item in result_list:
                if isinstance(item, list) and len(item) >= 2:
                    solution[item[0]] = float(item[1])
            return [solution]
    except:
        return None


def parse_true_parameters(true_params_str):
    """Parse true_parameters column."""
    if pd.isna(true_params_str) or true_params_str == '':
        return {}
    try:
        if isinstance(true_params_str, dict):
            return true_params_str
        return eval(true_params_str)
    except:
        return {}


def calculate_error(solution, true_params, metric='relative'):
    """Calculate error between solution and true parameters."""
    common_params = set(solution.keys()) & set(true_params.keys())
    if len(common_params) == 0:
        return np.inf

    errors = []
    for param in common_params:
        est_val = solution[param]
        true_val = true_params[param]

        if np.isnan(est_val) or np.isnan(true_val):
            continue

        if metric == 'absolute':
            errors.append(abs(est_val - true_val))
        elif metric == 'relative':
            if abs(true_val) < 1e-10:
                errors.append(abs(est_val - true_val))
            else:
                errors.append(abs(est_val - true_val) / abs(true_val))

    return np.mean(errors) if len(errors) > 0 else np.inf


def select_best_odepe_solution(solutions, true_params):
    """Select best solution from ODEPE candidates."""
    if not solutions or len(solutions) == 0:
        return None, np.inf

    best_error = np.inf
    best_solution = None

    for solution in solutions:
        error = calculate_error(solution, true_params, 'relative')
        if error < best_error:
            best_error = error
            best_solution = solution

    return best_solution, best_error


def process_dataset(csv_file, verbose=False):
    """
    Process a result CSV file and extract analysis data.

    Returns: DataFrame with processed results including best ODEPE solutions
    """
    if verbose:
        print(f"Loading {csv_file}...")

    df = pd.read_csv(csv_file)

    if verbose:
        print(f"  Total rows: {len(df)}")

    # Process each row
    processed_data = []

    for idx, row in df.iterrows():
        # Parse true parameters
        true_params = parse_true_parameters(row['true_parameters'])

        # Check if ODEPE
        is_odepe = 'odepe' in str(row['software']).lower()

        if is_odepe:
            # Parse multiple solutions
            solutions = parse_result_column_odepe(row['result'])

            if solutions and len(solutions) > 1:
                # Select best solution
                best_solution, best_error = select_best_odepe_solution(solutions, true_params)
                num_solutions = len(solutions)
            elif solutions and len(solutions) == 1:
                best_solution = solutions[0]
                best_error = calculate_error(best_solution, true_params, 'relative')
                num_solutions = 1
            else:
                best_solution = None
                best_error = np.inf
                num_solutions = 0
        else:
            # Single solution software
            solutions = parse_result_column_odepe(row['result'])
            if solutions and len(solutions) > 0:
                best_solution = solutions[0]
                best_error = calculate_error(best_solution, true_params, 'relative')
                num_solutions = 1
            else:
                best_solution = None
                best_error = np.inf
                num_solutions = 0

        # Add to processed data
        processed_data.append({
            'id': row['id'],
            'index': row.get('index', idx),
            'name': row['name'],
            'software': row['software'],
            'run': row.get('run', row['software']),
            'noise': row['noise'],
            'finished': row['finished'],
            'has_result': row['has_result'],
            'time': row['time'] if not pd.isna(row['time']) else np.nan,
            'error': best_error if not np.isinf(best_error) else np.nan,
            'num_solutions': num_solutions,
            'is_odepe': is_odepe,
            'success': row['has_result'] and not np.isinf(best_error) and not np.isnan(best_error)
        })

    result_df = pd.DataFrame(processed_data)

    if verbose:
        print(f"  Processed rows: {len(result_df)}")
        print(f"  Successful results: {result_df['success'].sum()}")

    return result_df


def generate_comparison_tables(df, output_lines):
    """Generate comprehensive comparison tables."""

    output_lines.append("## Software Performance Comparison\n")
    output_lines.append("### Overall Statistics by Software\n")

    # Group by software
    software_groups = df.groupby('run')

    table_data = []
    for software, group in software_groups:
        total = len(group)
        success = group['success'].sum()
        success_rate = (success / total * 100) if total > 0 else 0

        errors = group[group['success']]['error']
        mean_error = errors.mean() if len(errors) > 0 else np.nan
        median_error = errors.median() if len(errors) > 0 else np.nan

        times = group[group['success']]['time']
        mean_time = times.mean() if len(times) > 0 else np.nan

        table_data.append({
            'Software': software,
            'Total': total,
            'Success': success,
            'Success Rate': success_rate,
            'Mean Error': mean_error,
            'Median Error': median_error,
            'Mean Time (s)': mean_time
        })

    table_df = pd.DataFrame(table_data).sort_values('Mean Error')

    output_lines.append("| Software | Total | Success | Success Rate | Mean Error | Median Error | Mean Time (s) |")
    output_lines.append("|----------|-------|---------|--------------|------------|--------------|---------------|")

    for _, row in table_df.iterrows():
        output_lines.append(
            f"| {row['Software']:<15} | {row['Total']:>5} | {row['Success']:>7} | "
            f"{row['Success Rate']:>11.1f}% | {row['Mean Error']:>10.6f} | "
            f"{row['Median Error']:>12.6f} | {row['Mean Time (s)']:>13.2f} |"
        )

    output_lines.append("")

    # Statistics by system
    output_lines.append("### Performance by System\n")

    system_groups = df.groupby(['name', 'run'])
    system_summary = []

    for (system, software), group in system_groups:
        success = group['success'].sum()
        total = len(group)
        success_rate = (success / total * 100) if total > 0 else 0

        errors = group[group['success']]['error']
        mean_error = errors.mean() if len(errors) > 0 else np.nan

        system_summary.append({
            'System': system,
            'Software': software,
            'Success Rate': success_rate,
            'Mean Error': mean_error
        })

    system_df = pd.DataFrame(system_summary)

    # Pivot table for easier viewing
    pivot = system_df.pivot(index='System', columns='Software', values='Mean Error')

    output_lines.append("**Mean Error by System and Software:**\n")
    # Manual table formatting
    headers = ['System'] + list(pivot.columns)
    output_lines.append("| " + " | ".join(headers) + " |")
    output_lines.append("|" + "|".join(["-" * (len(h)+2) for h in headers]) + "|")
    for system in pivot.index:
        row_values = [system] + [f"{pivot.loc[system, col]:.6f}" if not pd.isna(pivot.loc[system, col]) else "N/A" for col in pivot.columns]
        output_lines.append("| " + " | ".join(row_values) + " |")
    output_lines.append("")

    # Statistics by noise level
    output_lines.append("### Performance by Noise Level\n")

    noise_groups = df.groupby(['noise', 'run'])
    noise_summary = []

    for (noise, software), group in noise_groups:
        success = group['success'].sum()
        total = len(group)
        success_rate = (success / total * 100) if total > 0 else 0

        errors = group[group['success']]['error']
        mean_error = errors.mean() if len(errors) > 0 else np.nan

        noise_summary.append({
            'Noise': noise,
            'Software': software,
            'Success Rate': success_rate,
            'Mean Error': mean_error
        })

    noise_df = pd.DataFrame(noise_summary)

    # Pivot table
    pivot = noise_df.pivot(index='Noise', columns='Software', values='Mean Error')

    output_lines.append("**Mean Error by Noise Level and Software:**\n")
    # Manual table formatting
    headers = ['Noise'] + list(pivot.columns)
    output_lines.append("| " + " | ".join(headers) + " |")
    output_lines.append("|" + "|".join(["-" * (len(h)+2) for h in headers]) + "|")
    for noise in pivot.index:
        row_values = [str(noise)] + [f"{pivot.loc[noise, col]:.6f}" if not pd.isna(pivot.loc[noise, col]) else "N/A" for col in pivot.columns]
        output_lines.append("| " + " | ".join(row_values) + " |")
    output_lines.append("")


def generate_key_findings(df, output_lines):
    """Generate key findings section."""

    output_lines.append("## Key Findings\n")

    # Find best performing software overall
    software_stats = df.groupby('run').agg({
        'success': 'sum',
        'error': lambda x: x[x.notna()].mean()
    }).sort_values('error')

    best_software = software_stats.index[0]
    best_error = software_stats.loc[best_software, 'error']

    output_lines.append(f"### 1. Best Overall Performance: **{best_software}**\n")
    output_lines.append(f"   - Mean error: {best_error:.6f}")
    output_lines.append(f"   - Success count: {software_stats.loc[best_software, 'success']:.0f}")
    output_lines.append("")

    # AMIGO sensitivity analysis (if multiple AMIGO variants exist)
    amigo_variants = [s for s in df['run'].unique() if 'amigo' in s.lower()]

    if len(amigo_variants) > 1:
        output_lines.append("### 2. AMIGO Search Bound Sensitivity\n")

        for variant in sorted(amigo_variants):
            variant_df = df[df['run'] == variant]
            success_rate = (variant_df['success'].sum() / len(variant_df) * 100)
            mean_error = variant_df[variant_df['success']]['error'].mean()

            output_lines.append(f"   - **{variant}**: {success_rate:.1f}% success, {mean_error:.6f} mean error")

        output_lines.append("")

    # ODEPE solution analysis (if ODEPE exists)
    odepe_df = df[df['is_odepe']]

    if len(odepe_df) > 0:
        output_lines.append("### 3. ODEPE Multiple Solutions Analysis\n")

        multi_sol = odepe_df[odepe_df['num_solutions'] > 1]
        if len(multi_sol) > 0:
            avg_solutions = multi_sol['num_solutions'].mean()
            output_lines.append(f"   - Average candidate solutions per experiment: {avg_solutions:.1f}")
            output_lines.append(f"   - Experiments with multiple solutions: {len(multi_sol)}")

        for run in odepe_df['run'].unique():
            run_df = odepe_df[odepe_df['run'] == run]
            success_rate = (run_df['success'].sum() / len(run_df) * 100)
            mean_error = run_df[run_df['success']]['error'].mean()

            output_lines.append(f"   - **{run}**: {success_rate:.1f}% success, {mean_error:.6f} mean error")

        output_lines.append("")

    # System difficulty ranking
    output_lines.append("### 4. System Difficulty Ranking (by mean error across all software)\n")

    system_difficulty = df[df['success']].groupby('name')['error'].mean().sort_values(ascending=False)

    for idx, (system, error) in enumerate(system_difficulty.items(), 1):
        output_lines.append(f"   {idx}. **{system}**: {error:.6f}")

    output_lines.append("")


def analyze_dataset(csv_file, output_file=None, verbose=False):
    """Main analysis function."""

    output_lines = []

    # Header
    output_lines.append(f"# Software Performance Analysis\n")
    output_lines.append(f"**Dataset**: `{csv_file}`\n")
    output_lines.append(f"**Analysis Date**: 2025-11-11\n")
    output_lines.append("---\n")

    # Process data
    df = process_dataset(csv_file, verbose=verbose)

    # Overall statistics
    output_lines.append("## Dataset Overview\n")
    output_lines.append(f"- Total experiments: {len(df)}")
    output_lines.append(f"- Successful results: {df['success'].sum()} ({df['success'].sum()/len(df)*100:.1f}%)")
    output_lines.append(f"- Software variants: {df['run'].nunique()}")
    output_lines.append(f"- Systems: {df['name'].nunique()}")
    output_lines.append(f"- Noise levels: {df['noise'].nunique()}")
    output_lines.append("")

    # Generate key findings
    generate_key_findings(df, output_lines)

    # Generate comparison tables
    generate_comparison_tables(df, output_lines)

    # Save or print
    report = "\n".join(output_lines)

    if output_file:
        Path(output_file).write_text(report)
        print(f"Analysis saved to: {output_file}")
    else:
        print(report)

    return df


def main():
    parser = argparse.ArgumentParser(
        description='Comprehensive software performance analysis'
    )

    parser.add_argument('--dataset', '-d', required=True,
                       help='Path to result.csv file')
    parser.add_argument('--output', '-o',
                       help='Output markdown file (default: stdout)')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Verbose output')

    args = parser.parse_args()

    if not Path(args.dataset).exists():
        print(f"Error: Dataset not found: {args.dataset}")
        sys.exit(1)

    analyze_dataset(
        csv_file=args.dataset,
        output_file=args.output,
        verbose=args.verbose
    )


if __name__ == '__main__':
    main()
