#!/usr/bin/env python3
"""
Parameter Bounds Analysis

Analyzes whether ODEPE's parameter estimates exceed various bounds,
and what happens to error if we apply AMIGO-style "hard bounding" (clamping).

This tests the hypothesis: Does AMIGO's poor performance with wide bounds
come from clamping parameters to bound edges?

Usage:
    python analyze_parameter_bounds.py --dataset ../results/october_5_2025/result.csv
"""

import pandas as pd
import numpy as np
import argparse
import sys
from pathlib import Path


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


def calculate_error_per_param(solution, true_params):
    """Calculate per-parameter relative errors."""
    common_params = set(solution.keys()) & set(true_params.keys())
    if len(common_params) == 0:
        return {}

    param_errors = {}
    for param in common_params:
        est_val = solution[param]
        true_val = true_params[param]

        if np.isnan(est_val) or np.isnan(true_val):
            continue

        if abs(true_val) < 1e-10:
            error = abs(est_val - true_val)
        else:
            error = abs(est_val - true_val) / abs(true_val)

        param_errors[param] = {
            'estimated': est_val,
            'true': true_val,
            'error': error
        }

    return param_errors


def clamp_solution(solution, max_value):
    """Clamp all parameter values to [0, max_value]."""
    clamped = {}
    for param, value in solution.items():
        clamped[param] = np.clip(value, 0, max_value)
    return clamped


def select_best_odepe_solution(solutions, true_params):
    """Select best solution from ODEPE candidates."""
    if not solutions or len(solutions) == 0:
        return None

    best_error = np.inf
    best_solution = None

    for solution in solutions:
        common_params = set(solution.keys()) & set(true_params.keys())
        if len(common_params) == 0:
            continue

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

        mean_error = np.mean(errors) if len(errors) > 0 else np.inf

        if mean_error < best_error:
            best_error = mean_error
            best_solution = solution

    return best_solution


def analyze_bounds(csv_file, software_filter='odepe'):
    """Main analysis function."""

    print(f"Loading {csv_file}...")
    df = pd.read_csv(csv_file)

    # Filter to specified software
    mask = df['software'].str.contains(software_filter, case=False, na=False)
    software_df = df[mask].copy()

    print(f"Total {software_filter} rows: {len(software_df)}")

    # Statistics collectors
    all_param_stats = []
    experiment_stats = []

    # Process each experiment
    for idx, row in software_df.iterrows():
        # Parse solutions
        solutions = parse_result_column_odepe(row['result'])
        if not solutions or len(solutions) == 0:
            continue

        # Parse true parameters
        true_params = parse_true_parameters(row['true_parameters'])
        if not true_params:
            continue

        # Select best solution
        best_solution = select_best_odepe_solution(solutions, true_params)
        if not best_solution:
            continue

        # Calculate original errors
        param_errors = calculate_error_per_param(best_solution, true_params)

        # Apply clamping
        clamped_1 = clamp_solution(best_solution, 1.0)
        clamped_10 = clamp_solution(best_solution, 10.0)

        # Calculate errors after clamping
        param_errors_clamp1 = calculate_error_per_param(clamped_1, true_params)
        param_errors_clamp10 = calculate_error_per_param(clamped_10, true_params)

        # Per-parameter analysis
        for param in param_errors.keys():
            est_val = param_errors[param]['estimated']
            true_val = param_errors[param]['true']
            orig_error = param_errors[param]['error']

            clamp1_error = param_errors_clamp1[param]['error'] if param in param_errors_clamp1 else np.nan
            clamp10_error = param_errors_clamp10[param]['error'] if param in param_errors_clamp10 else np.nan

            all_param_stats.append({
                'experiment': row['id'],
                'system': row['name'],
                'param': param,
                'estimated': est_val,
                'true': true_val,
                'exceeds_1': est_val > 1.0,
                'exceeds_10': est_val > 10.0,
                'true_exceeds_1': true_val > 1.0,
                'true_exceeds_10': true_val > 10.0,
                'error_original': orig_error,
                'error_clamp_1': clamp1_error,
                'error_clamp_10': clamp10_error
            })

        # Per-experiment summary
        original_errors = [param_errors[p]['error'] for p in param_errors]
        clamp1_errors = [param_errors_clamp1[p]['error'] for p in param_errors_clamp1]
        clamp10_errors = [param_errors_clamp10[p]['error'] for p in param_errors_clamp10]

        experiment_stats.append({
            'experiment': row['id'],
            'system': row['name'],
            'num_params': len(param_errors),
            'num_exceeds_1': sum(1 for p in param_errors.values() if p['estimated'] > 1.0),
            'num_exceeds_10': sum(1 for p in param_errors.values() if p['estimated'] > 10.0),
            'num_true_exceeds_1': sum(1 for p in param_errors.values() if p['true'] > 1.0),
            'num_true_exceeds_10': sum(1 for p in param_errors.values() if p['true'] > 10.0),
            'mean_error_original': np.mean(original_errors),
            'mean_error_clamp_1': np.mean(clamp1_errors),
            'mean_error_clamp_10': np.mean(clamp10_errors)
        })

    # Convert to DataFrames
    param_df = pd.DataFrame(all_param_stats)
    exp_df = pd.DataFrame(experiment_stats)

    return param_df, exp_df


def generate_report(param_df, exp_df, output_file=None):
    """Generate analysis report."""

    lines = []
    lines.append("="*80)
    lines.append("PARAMETER BOUNDS ANALYSIS")
    lines.append("Testing AMIGO's Hard-Bounding Hypothesis")
    lines.append("="*80)
    lines.append("")

    # Overall statistics
    lines.append("## OVERALL STATISTICS")
    lines.append("")

    total_params = len(param_df)
    lines.append(f"Total parameter estimates analyzed: {total_params}")
    lines.append("")

    # How many estimates exceed bounds?
    pct_exceed_1 = (param_df['exceeds_1'].sum() / total_params * 100)
    pct_exceed_10 = (param_df['exceeds_10'].sum() / total_params * 100)

    lines.append("### ODEPE Estimated Values:")
    lines.append(f"  Parameters with estimate > 1:  {param_df['exceeds_1'].sum()} ({pct_exceed_1:.1f}%)")
    lines.append(f"  Parameters with estimate > 10: {param_df['exceeds_10'].sum()} ({pct_exceed_10:.1f}%)")
    lines.append("")

    # How many TRUE parameters exceed bounds?
    pct_true_exceed_1 = (param_df['true_exceeds_1'].sum() / total_params * 100)
    pct_true_exceed_10 = (param_df['true_exceeds_10'].sum() / total_params * 100)

    lines.append("### TRUE Parameter Values:")
    lines.append(f"  Parameters with true value > 1:  {param_df['true_exceeds_1'].sum()} ({pct_true_exceed_1:.1f}%)")
    lines.append(f"  Parameters with true value > 10: {param_df['true_exceeds_10'].sum()} ({pct_true_exceed_10:.1f}%)")
    lines.append("")
    lines.append("  NOTE: Config specifies true params in [0.1, 0.9]")
    lines.append("        So true params should NOT exceed 1.0")
    lines.append("")

    # Error analysis
    lines.append("### ERROR ANALYSIS:")
    lines.append("")

    mean_orig = param_df['error_original'].mean()
    mean_clamp1 = param_df['error_clamp_1'].mean()
    mean_clamp10 = param_df['error_clamp_10'].mean()

    lines.append(f"  Original ODEPE error:          {mean_orig:.6f}")
    lines.append(f"  After clamping to [0, 1]:      {mean_clamp1:.6f} ({mean_clamp1/mean_orig:.2f}× original)")
    lines.append(f"  After clamping to [0, 10]:     {mean_clamp10:.6f} ({mean_clamp10/mean_orig:.2f}× original)")
    lines.append("")

    if mean_clamp1 > mean_orig:
        lines.append(f"  ⚠️  Clamping to [0,1] INCREASES error by {(mean_clamp1/mean_orig - 1)*100:.1f}%")
    else:
        lines.append(f"  ✓ Clamping to [0,1] doesn't hurt (error stays same or decreases)")

    lines.append("")

    # Per-experiment analysis
    lines.append("## PER-EXPERIMENT STATISTICS")
    lines.append("")

    exp_with_exceed_1 = (exp_df['num_exceeds_1'] > 0).sum()
    exp_with_exceed_10 = (exp_df['num_exceeds_10'] > 0).sum()
    total_exp = len(exp_df)

    lines.append(f"Total experiments: {total_exp}")
    lines.append(f"Experiments where ANY parameter estimate > 1:  {exp_with_exceed_1} ({exp_with_exceed_1/total_exp*100:.1f}%)")
    lines.append(f"Experiments where ANY parameter estimate > 10: {exp_with_exceed_10} ({exp_with_exceed_10/total_exp*100:.1f}%)")
    lines.append("")

    # Mean errors per experiment
    lines.append("Mean error across all experiments:")
    lines.append(f"  Original: {exp_df['mean_error_original'].mean():.6f}")
    lines.append(f"  Clamp to [0,1]: {exp_df['mean_error_clamp_1'].mean():.6f}")
    lines.append(f"  Clamp to [0,10]: {exp_df['mean_error_clamp_10'].mean():.6f}")
    lines.append("")

    # By system
    lines.append("## ERROR BY SYSTEM")
    lines.append("")

    system_stats = exp_df.groupby('system').agg({
        'mean_error_original': 'mean',
        'mean_error_clamp_1': 'mean',
        'mean_error_clamp_10': 'mean',
        'num_exceeds_1': 'sum',
        'num_exceeds_10': 'sum'
    }).sort_values('mean_error_original')

    lines.append("| System | Original Error | Clamp [0,1] | Clamp [0,10] | #Params>1 | #Params>10 |")
    lines.append("|--------|----------------|-------------|--------------|-----------|------------|")

    for system in system_stats.index:
        row = system_stats.loc[system]
        lines.append(
            f"| {system:<18} | {row['mean_error_original']:>14.6f} | "
            f"{row['mean_error_clamp_1']:>11.6f} | {row['mean_error_clamp_10']:>12.6f} | "
            f"{row['num_exceeds_1']:>9.0f} | {row['num_exceeds_10']:>10.0f} |"
        )

    lines.append("")

    # Key insights
    lines.append("## KEY INSIGHTS")
    lines.append("")

    if pct_true_exceed_1 > 1:
        lines.append(f"⚠️  WARNING: {pct_true_exceed_1:.1f}% of TRUE parameters exceed 1.0")
        lines.append("   This contradicts config.json which specifies PARAM_INTERVAL=[0.1, 0.9]")
        lines.append("")

    if pct_exceed_1 > 50:
        lines.append(f"⚠️  ODEPE estimates {pct_exceed_1:.1f}% of parameters > 1.0")
        lines.append("   This suggests ODEPE is finding parameters outside [0,1] bounds")
        lines.append("")

    if mean_clamp1 > mean_orig * 1.1:
        lines.append(f"⚠️  Clamping to [0,1] increases error by {(mean_clamp1/mean_orig - 1)*100:.1f}%")
        lines.append("   This suggests AMIGO's hard-bounding IS hurting performance")
        lines.append("")
    elif mean_clamp1 <= mean_orig * 1.05:
        lines.append("✓ Clamping to [0,1] doesn't significantly hurt ODEPE")
        lines.append("  This suggests AMIGO's poor performance with wide bounds")
        lines.append("  is NOT due to hard-bounding, but rather search space size")
        lines.append("")

    lines.append("="*80)

    report = "\n".join(lines)

    if output_file:
        Path(output_file).write_text(report)
        print(f"\nReport saved to: {output_file}")
    else:
        print(report)


def main():
    parser = argparse.ArgumentParser(
        description='Analyze parameter bounds and hard-bounding effects'
    )

    parser.add_argument('--dataset', '-d', required=True,
                       help='Path to result.csv file')
    parser.add_argument('--output', '-o',
                       help='Output report file (default: stdout)')
    parser.add_argument('--software', '-s', default='odepe',
                       help='Software to analyze (default: odepe)')

    args = parser.parse_args()

    if not Path(args.dataset).exists():
        print(f"Error: Dataset not found: {args.dataset}")
        sys.exit(1)

    param_df, exp_df = analyze_bounds(args.dataset, args.software)
    generate_report(param_df, exp_df, args.output)


if __name__ == '__main__':
    main()
