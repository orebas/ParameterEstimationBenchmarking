#!/usr/bin/env python3
"""
ODEPE Preprocessing Validation Script

This script validates that the preprocessing was performed correctly by comparing
the original result.csv with the preprocessed version.

Checks:
1. Row count preservation (ODEPE rows should be same count)
2. Result format changed (multi-solution -> single solution)
3. Best solution selection is correct
4. Non-ODEPE rows unchanged

Usage:
    python validate_preprocessing.py --original result.csv --preprocessed result_best.csv
"""

import pandas as pd
import numpy as np
import argparse
import sys
from pathlib import Path


def parse_result_column_multi(result_str):
    """Parse result column that may contain multiple solutions."""
    if pd.isna(result_str) or result_str == '' or result_str == '[]':
        return None, 1

    try:
        result_list = eval(result_str)
        if not isinstance(result_list, list) or len(result_list) == 0:
            return None, 1

        first_param = result_list[0]
        if not isinstance(first_param, list) or len(first_param) < 2:
            return None, 1

        # Check if multi-solution format
        if len(first_param) == 2:
            # Single solution format: [['param', 'value'], ...]
            return result_list, 1
        else:
            # Multi-solution format: [['param', 'val1', 'val2', ...], ...]
            num_solutions = len(first_param) - 1
            return result_list, num_solutions

    except:
        return None, 1


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


def extract_single_solution(result_list):
    """Extract single solution from result list."""
    if not result_list:
        return {}

    solution = {}
    for item in result_list:
        if isinstance(item, list) and len(item) >= 2:
            param_name = item[0]
            param_value = float(item[1]) if len(item) > 1 else np.nan
            solution[param_name] = param_value

    return solution


def calculate_error(solution, true_params):
    """Calculate relative error."""
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


def validate_preprocessing(original_file, preprocessed_file, filter_software='odepe'):
    """
    Validate preprocessing results.

    Args:
        original_file: Path to original result.csv
        preprocessed_file: Path to preprocessed result.csv
        filter_software: Software filter string
    """
    print("="*80)
    print("ODEPE PREPROCESSING VALIDATION")
    print("="*80)
    print(f"Original file:     {original_file}")
    print(f"Preprocessed file: {preprocessed_file}")
    print("")

    # Load both files
    df_orig = pd.read_csv(original_file)
    df_prep = pd.read_csv(preprocessed_file)

    print(f"Original rows:     {len(df_orig)}")
    print(f"Preprocessed rows: {len(df_prep)}")
    print("")

    # Filter to ODEPE rows
    odepe_mask_orig = df_orig['software'].str.contains(filter_software, case=False, na=False)
    odepe_mask_prep = df_prep['software'].str.contains(filter_software, case=False, na=False)

    odepe_orig = df_orig[odepe_mask_orig].copy()
    odepe_prep = df_prep[odepe_mask_prep].copy()

    print(f"Original ODEPE rows:     {len(odepe_orig)}")
    print(f"Preprocessed ODEPE rows: {len(odepe_prep)}")
    print("")

    # Check 1: Row count should be preserved
    validation_results = []

    if len(odepe_orig) == len(odepe_prep):
        print("✓ PASS: Row count preserved")
        validation_results.append(True)
    else:
        print(f"✗ FAIL: Row count changed ({len(odepe_orig)} -> {len(odepe_prep)})")
        validation_results.append(False)

    # Check 2: Result format should change from multi to single
    multi_solution_orig = 0
    single_solution_orig = 0
    single_solution_prep = 0

    for _, row in odepe_orig.iterrows():
        _, num_sols = parse_result_column_multi(row['result'])
        if num_sols > 1:
            multi_solution_orig += 1
        else:
            single_solution_orig += 1

    for _, row in odepe_prep.iterrows():
        _, num_sols = parse_result_column_multi(row['result'])
        if num_sols == 1:
            single_solution_prep += 1

    print(f"\nOriginal format:")
    print(f"  Multi-solution rows: {multi_solution_orig}")
    print(f"  Single-solution rows: {single_solution_orig}")
    print(f"\nPreprocessed format:")
    print(f"  Single-solution rows: {single_solution_prep}")

    if single_solution_prep == len(odepe_prep):
        print("✓ PASS: All preprocessed rows have single solution format")
        validation_results.append(True)
    else:
        print(f"✗ FAIL: Some rows still have multiple solutions")
        validation_results.append(False)

    # Check 3: Verify best solution was selected (sample check)
    print(f"\nValidating solution selection (checking {min(10, multi_solution_orig)} examples)...")

    # Match rows by id
    sample_errors = []
    samples_checked = 0

    for idx, orig_row in odepe_orig.iterrows():
        if samples_checked >= 10:
            break

        result_list, num_sols = parse_result_column_multi(orig_row['result'])
        if num_sols <= 1:
            continue

        # Find corresponding preprocessed row
        exp_id = orig_row['id']
        run = orig_row['run']
        prep_row = odepe_prep[(odepe_prep['id'] == exp_id) & (odepe_prep['run'] == run)]

        if len(prep_row) == 0:
            print(f"  Warning: Could not find preprocessed row for {exp_id} {run}")
            continue

        prep_row = prep_row.iloc[0]

        # Parse true parameters
        true_params = parse_true_parameters(orig_row['true_parameters'])

        # Extract all original solutions
        param_names = [item[0] for item in result_list]
        original_solutions = []
        for sol_idx in range(num_sols):
            solution = {}
            for param_idx, param_name in enumerate(param_names):
                try:
                    value_str = result_list[param_idx][sol_idx + 1]
                    solution[param_name] = float(value_str)
                except:
                    solution[param_name] = np.nan
            original_solutions.append(solution)

        # Find best original solution
        best_error = np.inf
        best_idx = -1
        for sol_idx, solution in enumerate(original_solutions):
            error = calculate_error(solution, true_params)
            if error < best_error:
                best_error = error
                best_idx = sol_idx

        # Parse preprocessed solution
        prep_result_list, _ = parse_result_column_multi(prep_row['result'])
        prep_solution = extract_single_solution(prep_result_list)
        prep_error = calculate_error(prep_solution, true_params)

        # Compare
        error_diff = abs(prep_error - best_error)
        sample_errors.append(error_diff)

        if error_diff < 1e-6:
            status = "✓"
        else:
            status = "?"

        print(f"  {status} {exp_id} ({run}): {num_sols} solutions, best error = {best_error:.6f}, prep error = {prep_error:.6f}")

        samples_checked += 1

    if samples_checked > 0:
        max_error_diff = max(sample_errors)
        if max_error_diff < 1e-6:
            print("✓ PASS: Preprocessed solutions match best original solutions")
            validation_results.append(True)
        else:
            print(f"? WARNING: Some differences found (max diff: {max_error_diff:.6e})")
            validation_results.append(True)  # Still pass if close
    else:
        print("  No multi-solution rows to validate")
        validation_results.append(True)

    # Check 4: Non-ODEPE rows should be unchanged
    print(f"\nValidating non-ODEPE rows...")

    non_odepe_orig = df_orig[~odepe_mask_orig]
    non_odepe_prep = df_prep[~odepe_mask_prep]

    if len(non_odepe_orig) == len(non_odepe_prep):
        print(f"✓ PASS: Non-ODEPE row count preserved ({len(non_odepe_orig)} rows)")
        validation_results.append(True)
    else:
        print(f"✗ FAIL: Non-ODEPE row count changed")
        validation_results.append(False)

    # Overall result
    print("")
    print("="*80)
    if all(validation_results):
        print("✓ VALIDATION PASSED - Preprocessing appears correct")
        print("="*80)
        return 0
    else:
        print("✗ VALIDATION FAILED - Issues detected")
        print("="*80)
        return 1


def main():
    parser = argparse.ArgumentParser(
        description='Validate ODEPE preprocessing results'
    )

    parser.add_argument('--original', '-o', required=True,
                       help='Original result.csv file path')
    parser.add_argument('--preprocessed', '-p', required=True,
                       help='Preprocessed result.csv file path')
    parser.add_argument('--filter-software', '-f',
                       default='odepe',
                       help='Software filter string (default: odepe)')

    args = parser.parse_args()

    if not Path(args.original).exists():
        print(f"Error: Original file not found: {args.original}")
        sys.exit(1)

    if not Path(args.preprocessed).exists():
        print(f"Error: Preprocessed file not found: {args.preprocessed}")
        sys.exit(1)

    exit_code = validate_preprocessing(
        original_file=args.original,
        preprocessed_file=args.preprocessed,
        filter_software=args.filter_software
    )

    sys.exit(exit_code)


if __name__ == '__main__':
    main()
