#!/usr/bin/env python3
"""
Combine Datasets with ODEPE Preprocessing

Creates a combined CSV with:
- ODEPE (oracle best-solution selection)
- ODEPE_polish (oracle best-solution selection)
- AMIGO [0,10] bounds
- SciML
- AMIGO [0,100] bounds

All with single solution per row for easy analysis.

Usage:
    python combine_datasets.py \
        --october ../results/october_5_2025/result.csv \
        --september ../results/september_16_2025_search_bound_100/result.csv \
        --output combined_results.csv
"""

import pandas as pd
import numpy as np
import argparse
import sys
from pathlib import Path


def parse_result_column_multi(result_str):
    """Parse result column that may contain multiple solutions."""
    if pd.isna(result_str) or result_str == '' or result_str == '[]':
        return None

    try:
        result_list = eval(result_str)
        if not isinstance(result_list, list) or len(result_list) == 0:
            return None

        first_param = result_list[0]
        if not isinstance(first_param, list) or len(first_param) < 2:
            return None

        # Multi-solution format (ODEPE)
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
            return solutions, 'multi'
        else:
            # Single solution format
            solution = {}
            for item in result_list:
                if isinstance(item, list) and len(item) >= 2:
                    solution[item[0]] = float(item[1])
            return [solution], 'single'
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
    """Calculate mean relative error."""
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


def select_best_solution(solutions, true_params):
    """Select best solution using oracle (minimum error vs true params)."""
    if not solutions or len(solutions) == 0:
        return None

    best_error = np.inf
    best_solution = None

    for solution in solutions:
        error = calculate_error(solution, true_params)
        if error < best_error:
            best_error = error
            best_solution = solution

    return best_solution


def solution_to_result_string(solution):
    """Convert solution dict to result column string format."""
    if not solution:
        return "[]"

    result_list = [[param, str(value)] for param, value in solution.items()]
    return str(result_list)


def preprocess_odepe_row(row):
    """Preprocess an ODEPE row to select best solution."""
    # Parse solutions
    parsed = parse_result_column_multi(row['result'])
    if parsed is None:
        return row

    solutions, format_type = parsed

    # If already single solution, return as-is
    if format_type == 'single' or len(solutions) == 1:
        return row

    # Parse true parameters
    true_params = parse_true_parameters(row['true_parameters'])
    if not true_params:
        return row

    # Select best solution
    best_solution = select_best_solution(solutions, true_params)
    if not best_solution:
        return row

    # Create new row with single best solution
    new_row = row.copy()
    new_row['result'] = solution_to_result_string(best_solution)

    return new_row


def combine_datasets(october_file, september_file, output_file, verbose=False):
    """
    Combine datasets with specified software variants.

    From October: odepe, odepe_polish, amigo2_0_10, sciml
    From September: amigo2 (renamed to amigo2_0_100)
    """

    if verbose:
        print("Loading October dataset...")
    df_oct = pd.read_csv(october_file)

    if verbose:
        print("Loading September dataset...")
    df_sep = pd.read_csv(september_file)

    # Extract desired software from October
    if verbose:
        print("\nExtracting from October dataset:")

    oct_odepe = df_oct[df_oct['run'] == 'odepe'].copy()
    oct_odepe_polish = df_oct[df_oct['run'] == 'odepe_polish'].copy()
    oct_amigo_0_10 = df_oct[df_oct['run'] == 'amigo2_0_10'].copy()
    oct_sciml = df_oct[df_oct['run'] == 'sciml'].copy()

    if verbose:
        print(f"  odepe: {len(oct_odepe)} rows")
        print(f"  odepe_polish: {len(oct_odepe_polish)} rows")
        print(f"  amigo2_0_10: {len(oct_amigo_0_10)} rows")
        print(f"  sciml: {len(oct_sciml)} rows")

    # Extract AMIGO from September and rename
    if verbose:
        print("\nExtracting from September dataset:")

    sep_amigo = df_sep[df_sep['software'] == 'amigo2'].copy()
    # Rename to amigo2_0_100 to indicate [0,100] bounds
    sep_amigo['run'] = 'amigo2_0_100'

    if verbose:
        print(f"  amigo2 (renamed to amigo2_0_100): {len(sep_amigo)} rows")

    # Preprocess ODEPE variants (select best solution)
    if verbose:
        print("\nPreprocessing ODEPE (selecting best solutions)...")

    odepe_processed = []
    for idx, row in oct_odepe.iterrows():
        odepe_processed.append(preprocess_odepe_row(row))
    oct_odepe_final = pd.DataFrame(odepe_processed)

    if verbose:
        print(f"  Processed odepe: {len(oct_odepe_final)} rows")

    odepe_polish_processed = []
    for idx, row in oct_odepe_polish.iterrows():
        odepe_polish_processed.append(preprocess_odepe_row(row))
    oct_odepe_polish_final = pd.DataFrame(odepe_polish_processed)

    if verbose:
        print(f"  Processed odepe_polish: {len(oct_odepe_polish_final)} rows")

    # Combine all datasets
    if verbose:
        print("\nCombining datasets...")

    combined = pd.concat([
        oct_odepe_final,
        oct_odepe_polish_final,
        oct_amigo_0_10,
        oct_sciml,
        sep_amigo
    ], ignore_index=True)

    # Sort by experiment ID for easier reading
    if 'id' in combined.columns:
        combined = combined.sort_values(['id', 'run']).reset_index(drop=True)

    if verbose:
        print(f"\nTotal combined rows: {len(combined)}")
        print(f"Software variants: {combined['run'].unique().tolist()}")

    # Save
    if verbose:
        print(f"\nSaving to {output_file}...")

    combined.to_csv(output_file, index=False)

    if verbose:
        print("Done!")

    # Summary statistics
    print("\n" + "="*70)
    print("COMBINED DATASET SUMMARY")
    print("="*70)
    print(f"Total rows: {len(combined)}")
    print(f"\nRows per software variant:")
    for software in sorted(combined['run'].unique()):
        count = (combined['run'] == software).sum()
        print(f"  {software:<20}: {count:>4} rows")

    print(f"\nUnique experiments: {combined['id'].nunique()}")
    print(f"Systems: {combined['name'].nunique()}")
    print(f"Noise levels: {combined['noise'].nunique()}")

    # Check for successful results
    if 'has_result' in combined.columns:
        success_by_software = combined.groupby('run')['has_result'].agg(['sum', 'count'])
        success_by_software['rate'] = success_by_software['sum'] / success_by_software['count'] * 100
        print(f"\nSuccess rates:")
        for software in success_by_software.index:
            rate = success_by_software.loc[software, 'rate']
            count = success_by_software.loc[software, 'sum']
            total = success_by_software.loc[software, 'count']
            print(f"  {software:<20}: {count:>3}/{total:>3} ({rate:>5.1f}%)")

    print("="*70)
    print(f"\nOutput saved to: {output_file}")

    return combined


def main():
    parser = argparse.ArgumentParser(
        description='Combine datasets with ODEPE preprocessing',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
  python combine_datasets.py \\
    --october ../results/october_5_2025/result.csv \\
    --september ../results/september_16_2025_search_bound_100/result.csv \\
    --output combined_results.csv

This creates a combined CSV with:
  - odepe (best solution selected)
  - odepe_polish (best solution selected)
  - amigo2_0_10 (bounds [0,10])
  - sciml
  - amigo2_0_100 (bounds [0,100])
        """
    )

    parser.add_argument('--october', required=True,
                       help='October 2025 result.csv file')
    parser.add_argument('--september', required=True,
                       help='September 2025 result.csv file')
    parser.add_argument('--output', '-o', required=True,
                       help='Output combined CSV file')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Verbose output')

    args = parser.parse_args()

    # Validate inputs
    if not Path(args.october).exists():
        print(f"Error: October file not found: {args.october}")
        sys.exit(1)

    if not Path(args.september).exists():
        print(f"Error: September file not found: {args.september}")
        sys.exit(1)

    # Run combination
    combine_datasets(
        october_file=args.october,
        september_file=args.september,
        output_file=args.output,
        verbose=args.verbose
    )


if __name__ == '__main__':
    main()
