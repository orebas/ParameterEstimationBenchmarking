#!/usr/bin/env python3
"""
ODEPE Results Preprocessing Script

This script processes ODEPE result.csv files to select the best solution from
multiple candidate solutions returned by ODEPE.

ODEPE returns multiple candidate solutions (like multiple roots of a polynomial).
Each row in result.csv contains all candidate solutions embedded in the 'result'
column. This script:
1. Parses the embedded solutions from each ODEPE row
2. Calculates error for each candidate solution vs true parameters
3. Selects the best (minimum error) solution
4. Outputs a new CSV with one solution per row

Usage:
    python preprocess_odepe_results.py --input result.csv --output result_best.csv

    Optional:
    --error-metric {absolute,relative,combined} - Error calculation method
    --filter-software odepe - Only process specific software (default: all odepe*)
    --verbose - Print detailed progress
"""

import pandas as pd
import numpy as np
import json
import argparse
import sys
from pathlib import Path


def parse_result_column(result_str):
    """
    Parse the ODEPE result column to extract all candidate solutions.

    Input format: String representation of list of lists:
    "[['param1', 'val1_sol1', 'val1_sol2', ...], ['param2', 'val2_sol1', 'val2_sol2', ...], ...]"

    Returns:
        List of dicts, one per solution: [{'param1': val1, 'param2': val2, ...}, ...]
        Returns None if parsing fails or only one solution exists
    """
    if pd.isna(result_str) or result_str == '' or result_str == '[]':
        return None

    try:
        # Parse the string representation to actual list
        result_list = eval(result_str)

        if not isinstance(result_list, list) or len(result_list) == 0:
            return None

        # Check if this is ODEPE format (list of lists with multiple values per parameter)
        # vs single solution format (list of [name, value] pairs)
        first_param = result_list[0]
        if not isinstance(first_param, list) or len(first_param) < 2:
            return None

        # If only 2 elements [name, value], it's a single solution, not ODEPE multi-solution
        if len(first_param) == 2:
            return None

        # Extract parameter names
        param_names = [param_data[0] for param_data in result_list]

        # Get number of solutions (all parameters should have same number)
        num_solutions = len(result_list[0]) - 1  # -1 for parameter name

        # Verify all parameters have same number of solutions
        for param_data in result_list:
            if len(param_data) - 1 != num_solutions:
                print(f"Warning: Inconsistent solution counts across parameters")
                return None

        # Reconstruct each solution as a dictionary
        solutions = []
        for sol_idx in range(num_solutions):
            solution = {}
            for param_idx, param_name in enumerate(param_names):
                # Convert string to float, handle potential parsing issues
                try:
                    value_str = result_list[param_idx][sol_idx + 1]  # +1 to skip param name
                    solution[param_name] = float(value_str)
                except (ValueError, IndexError) as e:
                    print(f"Warning: Could not parse value for {param_name}, solution {sol_idx}: {e}")
                    solution[param_name] = np.nan
            solutions.append(solution)

        return solutions

    except Exception as e:
        print(f"Error parsing result column: {e}")
        print(f"Result string: {result_str[:200]}...")
        return None


def parse_true_parameters(true_params_str):
    """
    Parse the true_parameters column to get ground truth values.

    Input format: String representation of dict:
    "{'param1': 0.123, 'param2': 0.456, ...}"

    Returns:
        Dict of parameter names to true values
    """
    if pd.isna(true_params_str) or true_params_str == '':
        return {}

    try:
        # Handle both dict and string representations
        if isinstance(true_params_str, dict):
            return true_params_str
        return eval(true_params_str)
    except Exception as e:
        print(f"Error parsing true parameters: {e}")
        return {}


def calculate_error(solution, true_params, metric='relative'):
    """
    Calculate error between estimated solution and true parameters.

    Args:
        solution: Dict of estimated parameter values
        true_params: Dict of true parameter values
        metric: 'absolute', 'relative', or 'combined'

    Returns:
        Float error value (lower is better)
    """
    # Find common parameters (solution may have state variables too)
    common_params = set(solution.keys()) & set(true_params.keys())

    if len(common_params) == 0:
        return np.inf

    errors = []
    for param in common_params:
        est_val = solution[param]
        true_val = true_params[param]

        if np.isnan(est_val) or np.isnan(true_val):
            errors.append(np.inf)
            continue

        if metric == 'absolute':
            errors.append(abs(est_val - true_val))
        elif metric == 'relative':
            if abs(true_val) < 1e-10:  # Avoid division by zero
                errors.append(abs(est_val - true_val))
            else:
                errors.append(abs(est_val - true_val) / abs(true_val))
        elif metric == 'combined':
            # Combined metric: average of absolute and relative
            abs_err = abs(est_val - true_val)
            rel_err = abs_err / abs(true_val) if abs(true_val) > 1e-10 else abs_err
            errors.append((abs_err + rel_err) / 2)

    # Return mean error across all parameters
    return np.mean(errors) if len(errors) > 0 else np.inf


def select_best_solution(solutions, true_params, metric='relative'):
    """
    Select the best solution from a list of candidate solutions.

    Args:
        solutions: List of solution dicts
        true_params: Dict of true parameter values
        metric: Error metric to use

    Returns:
        Tuple of (best_solution_dict, best_solution_index, error)
    """
    if not solutions or len(solutions) == 0:
        return None, -1, np.inf

    best_idx = -1
    best_error = np.inf
    best_solution = None

    for idx, solution in enumerate(solutions):
        error = calculate_error(solution, true_params, metric)
        if error < best_error:
            best_error = error
            best_idx = idx
            best_solution = solution

    return best_solution, best_idx, best_error


def format_solution_as_result_string(solution):
    """
    Format a single solution dict back into result column string format.

    Args:
        solution: Dict of parameter names to values

    Returns:
        String in format "[['param1', 'value1'], ['param2', 'value2'], ...]"
    """
    if not solution:
        return "[]"

    result_list = [[param, str(value)] for param, value in solution.items()]
    return str(result_list)


def preprocess_odepe_results(input_file, output_file, error_metric='relative',
                            filter_software='odepe', verbose=False):
    """
    Main preprocessing function.

    Args:
        input_file: Path to input result.csv
        output_file: Path to output preprocessed CSV
        error_metric: Error calculation method
        filter_software: Only process rows where software contains this string
        verbose: Print detailed progress
    """
    print(f"Loading {input_file}...")
    df = pd.read_csv(input_file)

    print(f"Total rows: {len(df)}")

    # Filter to ODEPE rows
    odepe_mask = df['software'].str.contains(filter_software, case=False, na=False)
    odepe_rows = df[odepe_mask].copy()
    other_rows = df[~odepe_mask].copy()

    print(f"ODEPE rows to process: {len(odepe_rows)}")
    print(f"Other rows (pass through): {len(other_rows)}")

    # Statistics
    total_processed = 0
    total_solutions = 0
    multi_solution_count = 0
    errors = []

    # Process each ODEPE row
    processed_rows = []
    for idx, row in odepe_rows.iterrows():
        # Parse candidate solutions
        solutions = parse_result_column(row['result'])

        if solutions is None or len(solutions) <= 1:
            # Single solution or parsing failed - keep as-is
            processed_rows.append(row)
            total_processed += 1
            continue

        # Multiple solutions found
        multi_solution_count += 1
        total_solutions += len(solutions)

        # Parse true parameters
        true_params = parse_true_parameters(row['true_parameters'])

        # Select best solution
        best_solution, best_idx, best_error = select_best_solution(
            solutions, true_params, error_metric
        )

        errors.append(best_error)

        if verbose:
            print(f"\nRow {idx} ({row['id']}):")
            print(f"  Found {len(solutions)} candidate solutions")
            print(f"  Selected solution {best_idx} with error {best_error:.6f}")

        # Create new row with best solution
        new_row = row.copy()
        new_row['result'] = format_solution_as_result_string(best_solution)
        processed_rows.append(new_row)
        total_processed += 1

    # Combine processed ODEPE rows with other rows
    result_df = pd.concat([pd.DataFrame(processed_rows), other_rows], ignore_index=True)

    # Sort by original index to maintain order
    # (Note: this assumes the unnamed index column exists)
    if 'Unnamed: 0' in result_df.columns:
        result_df = result_df.sort_values('Unnamed: 0').reset_index(drop=True)

    # Save output
    print(f"\nSaving to {output_file}...")
    result_df.to_csv(output_file, index=False)

    # Print summary statistics
    print("\n" + "="*60)
    print("PREPROCESSING SUMMARY")
    print("="*60)
    print(f"Total rows processed: {total_processed}")
    print(f"Rows with multiple solutions: {multi_solution_count}")
    print(f"Total candidate solutions evaluated: {total_solutions}")
    if multi_solution_count > 0:
        print(f"Average solutions per experiment: {total_solutions/multi_solution_count:.1f}")
    if errors:
        print(f"\nBest solution errors:")
        print(f"  Mean: {np.mean(errors):.6f}")
        print(f"  Median: {np.median(errors):.6f}")
        print(f"  Min: {np.min(errors):.6f}")
        print(f"  Max: {np.max(errors):.6f}")
    print(f"\nOutput saved to: {output_file}")
    print("="*60)


def main():
    parser = argparse.ArgumentParser(
        description='Preprocess ODEPE results to select best solution from multiple candidates',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Process October 2025 dataset
  python preprocess_odepe_results.py \\
    --input ../results/october_5_2025/result.csv \\
    --output ../results/october_5_2025/result_odepe_best.csv

  # Process with absolute error metric
  python preprocess_odepe_results.py \\
    --input result.csv \\
    --output result_best.csv \\
    --error-metric absolute \\
    --verbose
        """
    )

    parser.add_argument('--input', '-i', required=True,
                       help='Input result.csv file path')
    parser.add_argument('--output', '-o', required=True,
                       help='Output preprocessed CSV file path')
    parser.add_argument('--error-metric', '-e',
                       choices=['absolute', 'relative', 'combined'],
                       default='relative',
                       help='Error calculation method (default: relative)')
    parser.add_argument('--filter-software', '-f',
                       default='odepe',
                       help='Only process rows where software contains this string (default: odepe)')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Print detailed progress for each row')

    args = parser.parse_args()

    # Validate input file exists
    if not Path(args.input).exists():
        print(f"Error: Input file not found: {args.input}")
        sys.exit(1)

    # Run preprocessing
    preprocess_odepe_results(
        input_file=args.input,
        output_file=args.output,
        error_metric=args.error_metric,
        filter_software=args.filter_software,
        verbose=args.verbose
    )


if __name__ == '__main__':
    main()
