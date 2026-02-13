#!/usr/bin/env python3
"""
ODEPE Solution Quality Analysis Script

This script analyzes the quality distribution of ODEPE's multiple candidate solutions.
For each experiment, it shows:
- Number of candidate solutions
- Error distribution across all candidates
- Best vs worst solution comparison
- Statistics by system and noise level

Usage:
    python analyze_odepe_solution_quality.py --input result.csv --output report.txt

    Optional:
    --detailed - Include per-experiment breakdowns
    --systems harmonic,hiv - Only analyze specific systems
"""

import pandas as pd
import numpy as np
import argparse
import sys
from pathlib import Path
from collections import defaultdict


def parse_result_column(result_str):
    """Parse ODEPE result column to extract all candidate solutions."""
    if pd.isna(result_str) or result_str == '' or result_str == '[]':
        return None

    try:
        result_list = eval(result_str)
        if not isinstance(result_list, list) or len(result_list) == 0:
            return None

        first_param = result_list[0]
        if not isinstance(first_param, list) or len(first_param) < 3:
            return None

        param_names = [param_data[0] for param_data in result_list]
        num_solutions = len(result_list[0]) - 1

        solutions = []
        for sol_idx in range(num_solutions):
            solution = {}
            for param_idx, param_name in enumerate(param_names):
                try:
                    value_str = result_list[param_idx][sol_idx + 1]
                    solution[param_name] = float(value_str)
                except (ValueError, IndexError):
                    solution[param_name] = np.nan
            solutions.append(solution)

        return solutions
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


def calculate_error(solution, true_params):
    """Calculate relative error between solution and true parameters."""
    common_params = set(solution.keys()) & set(true_params.keys())
    if len(common_params) == 0:
        return np.inf

    errors = []
    for param in common_params:
        est_val = solution[param]
        true_val = true_params[param]

        if np.isnan(est_val) or np.isnan(true_val):
            continue

        if abs(true_val) < 1e-10:
            errors.append(abs(est_val - true_val))
        else:
            errors.append(abs(est_val - true_val) / abs(true_val))

    return np.mean(errors) if len(errors) > 0 else np.inf


def analyze_solution_quality(input_file, output_file=None, detailed=False,
                            filter_systems=None, filter_software='odepe'):
    """
    Analyze ODEPE solution quality distribution.

    Args:
        input_file: Path to result.csv
        output_file: Path to output report (None = stdout)
        detailed: Include per-experiment details
        filter_systems: List of system names to analyze (None = all)
        filter_software: Software filter string
    """
    # Load data
    df = pd.read_csv(input_file)

    # Filter to ODEPE rows
    odepe_mask = df['software'].str.contains(filter_software, case=False, na=False)
    odepe_df = df[odepe_mask].copy()

    # Filter by systems if specified
    if filter_systems:
        odepe_df = odepe_df[odepe_df['name'].isin(filter_systems)]

    # Analysis results
    all_stats = []
    by_system = defaultdict(list)
    by_noise = defaultdict(list)
    by_run = defaultdict(list)

    # Process each experiment
    for idx, row in odepe_df.iterrows():
        solutions = parse_result_column(row['result'])

        if solutions is None or len(solutions) <= 1:
            continue

        true_params = parse_true_parameters(row['true_parameters'])

        # Calculate error for each solution
        errors = [calculate_error(sol, true_params) for sol in solutions]
        valid_errors = [e for e in errors if not np.isinf(e)]

        if len(valid_errors) == 0:
            continue

        # Statistics for this experiment
        stats = {
            'id': row['id'],
            'name': row['name'],
            'noise': row['noise'],
            'run': row['run'],
            'num_solutions': len(solutions),
            'best_error': np.min(valid_errors),
            'worst_error': np.max(valid_errors),
            'median_error': np.median(valid_errors),
            'mean_error': np.mean(valid_errors),
            'std_error': np.std(valid_errors),
            'best_idx': np.argmin(errors),
            'improvement_ratio': np.max(valid_errors) / np.min(valid_errors) if np.min(valid_errors) > 0 else np.inf
        }

        all_stats.append(stats)
        by_system[row['name']].append(stats)
        by_noise[row['noise']].append(stats)
        by_run[row['run']].append(stats)

    # Generate report
    report_lines = []
    report_lines.append("="*80)
    report_lines.append("ODEPE SOLUTION QUALITY ANALYSIS")
    report_lines.append("="*80)
    report_lines.append(f"Input file: {input_file}")
    report_lines.append(f"Total ODEPE rows: {len(odepe_df)}")
    report_lines.append(f"Rows with multiple solutions: {len(all_stats)}")
    report_lines.append("")

    if len(all_stats) == 0:
        report_lines.append("No experiments with multiple solutions found.")
        report = "\n".join(report_lines)
        if output_file:
            Path(output_file).write_text(report)
        else:
            print(report)
        return

    # Overall statistics
    report_lines.append("-" * 80)
    report_lines.append("OVERALL STATISTICS")
    report_lines.append("-" * 80)
    report_lines.append(f"Number of solutions per experiment:")
    report_lines.append(f"  Min:     {min(s['num_solutions'] for s in all_stats)}")
    report_lines.append(f"  Max:     {max(s['num_solutions'] for s in all_stats)}")
    report_lines.append(f"  Mean:    {np.mean([s['num_solutions'] for s in all_stats]):.1f}")
    report_lines.append(f"  Median:  {np.median([s['num_solutions'] for s in all_stats]):.0f}")
    report_lines.append("")

    report_lines.append(f"Best solution error (across all experiments):")
    best_errors = [s['best_error'] for s in all_stats]
    report_lines.append(f"  Min:     {np.min(best_errors):.6f}")
    report_lines.append(f"  Max:     {np.max(best_errors):.6f}")
    report_lines.append(f"  Mean:    {np.mean(best_errors):.6f}")
    report_lines.append(f"  Median:  {np.median(best_errors):.6f}")
    report_lines.append("")

    report_lines.append(f"Improvement ratio (worst/best error per experiment):")
    improvements = [s['improvement_ratio'] for s in all_stats if not np.isinf(s['improvement_ratio'])]
    if improvements:
        report_lines.append(f"  Min:     {np.min(improvements):.2f}x")
        report_lines.append(f"  Max:     {np.max(improvements):.2f}x")
        report_lines.append(f"  Mean:    {np.mean(improvements):.2f}x")
        report_lines.append(f"  Median:  {np.median(improvements):.2f}x")
        report_lines.append(f"  (Ratio > 1 means selecting best solution matters)")
    report_lines.append("")

    # By system
    report_lines.append("-" * 80)
    report_lines.append("STATISTICS BY SYSTEM")
    report_lines.append("-" * 80)
    report_lines.append(f"{'System':<20} {'Count':<8} {'Avg Solutions':<15} {'Avg Best Error':<15} {'Avg Improvement':<15}")
    report_lines.append("-" * 80)

    for system in sorted(by_system.keys()):
        stats_list = by_system[system]
        avg_solutions = np.mean([s['num_solutions'] for s in stats_list])
        avg_best_error = np.mean([s['best_error'] for s in stats_list])
        valid_improvements = [s['improvement_ratio'] for s in stats_list if not np.isinf(s['improvement_ratio'])]
        avg_improvement = np.mean(valid_improvements) if valid_improvements else 0

        report_lines.append(
            f"{system:<20} {len(stats_list):<8} {avg_solutions:<15.1f} "
            f"{avg_best_error:<15.6f} {avg_improvement:<15.2f}x"
        )
    report_lines.append("")

    # By noise level
    report_lines.append("-" * 80)
    report_lines.append("STATISTICS BY NOISE LEVEL")
    report_lines.append("-" * 80)
    report_lines.append(f"{'Noise':<10} {'Count':<8} {'Avg Solutions':<15} {'Avg Best Error':<15} {'Avg Improvement':<15}")
    report_lines.append("-" * 80)

    for noise in sorted(by_noise.keys()):
        stats_list = by_noise[noise]
        avg_solutions = np.mean([s['num_solutions'] for s in stats_list])
        avg_best_error = np.mean([s['best_error'] for s in stats_list])
        valid_improvements = [s['improvement_ratio'] for s in stats_list if not np.isinf(s['improvement_ratio'])]
        avg_improvement = np.mean(valid_improvements) if valid_improvements else 0

        report_lines.append(
            f"{noise:<10} {len(stats_list):<8} {avg_solutions:<15.1f} "
            f"{avg_best_error:<15.6f} {avg_improvement:<15.2f}x"
        )
    report_lines.append("")

    # By run (odepe vs odepe_polish)
    report_lines.append("-" * 80)
    report_lines.append("STATISTICS BY RUN TYPE")
    report_lines.append("-" * 80)
    report_lines.append(f"{'Run':<15} {'Count':<8} {'Avg Solutions':<15} {'Avg Best Error':<15} {'Avg Improvement':<15}")
    report_lines.append("-" * 80)

    for run in sorted(by_run.keys()):
        stats_list = by_run[run]
        avg_solutions = np.mean([s['num_solutions'] for s in stats_list])
        avg_best_error = np.mean([s['best_error'] for s in stats_list])
        valid_improvements = [s['improvement_ratio'] for s in stats_list if not np.isinf(s['improvement_ratio'])]
        avg_improvement = np.mean(valid_improvements) if valid_improvements else 0

        report_lines.append(
            f"{run:<15} {len(stats_list):<8} {avg_solutions:<15.1f} "
            f"{avg_best_error:<15.6f} {avg_improvement:<15.2f}x"
        )
    report_lines.append("")

    # Detailed per-experiment output
    if detailed:
        report_lines.append("-" * 80)
        report_lines.append("DETAILED PER-EXPERIMENT BREAKDOWN")
        report_lines.append("-" * 80)

        for stats in sorted(all_stats, key=lambda x: x['best_error']):
            report_lines.append(f"\nExperiment: {stats['id']}")
            report_lines.append(f"  System: {stats['name']}, Noise: {stats['noise']}, Run: {stats['run']}")
            report_lines.append(f"  Number of solutions: {stats['num_solutions']}")
            report_lines.append(f"  Best solution (index {stats['best_idx']}): error = {stats['best_error']:.6f}")
            report_lines.append(f"  Worst solution: error = {stats['worst_error']:.6f}")
            report_lines.append(f"  Median error: {stats['median_error']:.6f}")
            report_lines.append(f"  Mean error: {stats['mean_error']:.6f} ± {stats['std_error']:.6f}")
            if not np.isinf(stats['improvement_ratio']):
                report_lines.append(f"  Improvement ratio: {stats['improvement_ratio']:.2f}x")

    report_lines.append("")
    report_lines.append("="*80)

    # Output report
    report = "\n".join(report_lines)

    if output_file:
        Path(output_file).write_text(report)
        print(f"Report saved to: {output_file}")
    else:
        print(report)


def main():
    parser = argparse.ArgumentParser(
        description='Analyze ODEPE solution quality distribution',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument('--input', '-i', required=True,
                       help='Input result.csv file path')
    parser.add_argument('--output', '-o',
                       help='Output report file path (default: stdout)')
    parser.add_argument('--detailed', '-d', action='store_true',
                       help='Include detailed per-experiment breakdown')
    parser.add_argument('--systems', '-s',
                       help='Comma-separated list of systems to analyze (default: all)')
    parser.add_argument('--filter-software', '-f',
                       default='odepe',
                       help='Software filter string (default: odepe)')

    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"Error: Input file not found: {args.input}")
        sys.exit(1)

    filter_systems = args.systems.split(',') if args.systems else None

    analyze_solution_quality(
        input_file=args.input,
        output_file=args.output,
        detailed=args.detailed,
        filter_systems=filter_systems,
        filter_software=args.filter_software
    )


if __name__ == '__main__':
    main()
