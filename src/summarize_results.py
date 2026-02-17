#!/usr/bin/env python3
import os
import sys
import re
import json
import tqdm
import numpy as np
import shlex
import subprocess
import chevron
from pprint import pprint
from subprocess import Popen, PIPE
import shutil
import pandas as pd

# Global configuration for number display precision
DISPLAY_DIGITS = 4

pd.set_option("display.precision", DISPLAY_DIGITS)
pd.set_option('display.float_format', f'{{:.{DISPLAY_DIGITS}f}}'.format)
import argparse
from datetime import datetime
from pathlib import Path
from termcolor import colored
from shared import warn, info, get_settings, AVAILABLE_SOFTWARE
import ast
import math

def parse_dict_string_must_succeed(s):
    assert not pd.isna(s) and not s == '', "Input string is empty or NaN"
    result = ast.literal_eval(s)
    assert result, f"Parsed parameter string is empty: '{s}'"
    return result

def parse_result_string(s):
    """Parse result string and return all possible estimation results
    
    Returns a list of dictionaries, where each dictionary represents one complete
    estimation result. The i-th element in each parameter's value list corresponds 
    to the i-th estimation result.
    """
    if pd.isna(s) or s == 'nan' or s == 'NaN' or s == '':
        return []  # Empty list for missing data
    result = ast.literal_eval(s)
    
    # Format: [['k5', '0.539', '0.540'], ['k6', '0.672', '0.673'], ...] - multiple estimation results
    # First, collect all parameters and their values
    param_values = {}
    
    for item in result:
        assert len(item) > 0
        if len(item) >= 2:  # At least parameter name and one value
            param = item[0]
            values = [float(v) for v in item[1:]]  # Convert all values to float
            param_values[param] = values
        elif len(item) == 1:
            # Just parameter name without values - estimation failed for this parameter
            continue
    
    if not param_values:
        return []
    
    # Create estimation results where i-th result uses i-th value from each parameter
    estimation_results = []
    for i in range(len(next(iter(param_values.values())))):
        result_dict = {}
        for param, values in param_values.items():
            result_dict[param] = values[i]  
        estimation_results.append(result_dict)
    
    return estimation_results

def select_best_estimation(true_params, estimation_results):
    """Select the best estimation result from multiple candidates based on closeness to true values
    
    Args:
        true_params: Dictionary of true parameter values
        estimation_results: List of dictionaries, each representing one estimation result
    
    Returns:
        Best estimation result dictionary, or empty dict if no valid results
    """
    assert true_params and estimation_results, "True parameters and estimation results must be provided"

    best_result = {}
    best_score = float('inf')
    
    for result in estimation_results:
        # Calculate score based on relative error to true values
        score = 0.0

        assert set(true_params.keys()) == set(result.keys()), "True parameters and estimation result keys must match"
        common_params = set(true_params.keys())
                    
        for param in common_params:
            true_val = float(true_params[param])
            est_val = float(result[param])
            assert abs(true_val) > 1e-15, f"True value for '{param}' is too small: {true_val}"
            rel_error = abs(est_val - true_val) / abs(true_val)
            score += rel_error
                            
        if score < best_score:
            best_score = score
            best_result = result
    
    return best_result

def log_invalid_estimation(row, reason, results_dir, counter=None, limit=5, software_filter=None):
    """Log information about invalid estimation results with clickable path"""
    
    model_name = row.get('name', 'unknown')
    software = row.get('software', 'unknown')
    row_id = row.get('id', 'unknown')
    run = row.get('run', 'unknown')
    
    # Check if software should be logged based on filter
    if software_filter is not None and software not in software_filter:
        return  # Skip logging for this software
    
    # Determine script extension based on software
    # Most software uses Julia (.jl), except for some that use MATLAB (.m)
    if software.lower() in ['amigo2', 'iqm']:  # Add other MATLAB-based software here if needed
        script_ext = '.m'
    else:
        script_ext = '.jl'  # Default to Julia for most software
    
    # Create the correct path: $RESULTS/filetree/$SOFTWARE/$ID/script.m (or .jl)
    script_path = f"{results_dir}/filetree/{run}/{row_id}/script{script_ext}"
    abs_script_path = os.path.abspath(script_path)
    
    # Only show detailed output for first few failures (or all if limit=0), then just count
    show_detailed = (limit == 0) or (counter is None) or (counter['count'] < limit)
    
    if show_detailed:
        print(f"⚠️  Invalid estimation result:")
        print(f"   Model: {model_name}")
        print(f"   Software: {software}")
        print(f"   Row ID: {row_id}")
        print(f"   Reason: {reason}")
        print(f"   Script file: {abs_script_path}")
        print()
    
    if counter is not None:
        counter['count'] += 1
        if limit > 0 and counter['count'] == limit:
            print("⚠️  (Suppressing further detailed invalid result logs, will show summary at end)")
            print()

def filter_identifiable_parameters(true_params, estimated_params, non_identifiable_list):
    """Filter out non-identifiable parameters from both true and estimated parameters"""
    if not non_identifiable_list:
        return true_params, estimated_params
    
    # Convert non_identifiable_list to set for faster lookup
    non_identifiable_set = set(non_identifiable_list) if isinstance(non_identifiable_list, list) else set()
    
    # Filter true parameters
    filtered_true_params = {k: v for k, v in true_params.items() if k not in non_identifiable_set}
    
    # Filter estimated parameters
    filtered_estimated_params = {k: v for k, v in estimated_params.items() if k not in non_identifiable_set}
    
    return filtered_true_params, filtered_estimated_params

def calculate_relative_median_error_filtered(true_params, estimated_params, non_identifiable_list):
    """Calculate relative median error excluding non-identifiable parameters"""
    filtered_true, filtered_estimated = filter_identifiable_parameters(
        true_params, estimated_params, non_identifiable_list
    )
    if not filtered_true:  # If all parameters are non-identifiable
        return np.nan
    return calculate_relative_median_error(filtered_true, filtered_estimated)

def calculate_mean_relative_error_filtered(true_params, estimated_params, non_identifiable_list):
    """Calculate relative mean error excluding non-identifiable parameters"""
    filtered_true, filtered_estimated = filter_identifiable_parameters(
        true_params, estimated_params, non_identifiable_list
    )
    if not filtered_true:  # If all parameters are non-identifiable
        return np.nan
    return calculate_mean_relative_error(filtered_true, filtered_estimated)

def calculate_rmse_filtered(true_params, estimated_params, non_identifiable_list):
    """Calculate RMSE excluding non-identifiable parameters"""
    filtered_true, filtered_estimated = filter_identifiable_parameters(
        true_params, estimated_params, non_identifiable_list
    )
    if not filtered_true:  # If all parameters are non-identifiable
        return np.nan
    return calculate_rmse(filtered_true, filtered_estimated)

def calculate_success_ratio_filtered(true_params, estimated_params, tolerance, non_identifiable_list):
    """Calculate success ratio excluding non-identifiable parameters"""
    filtered_true, filtered_estimated = filter_identifiable_parameters(
        true_params, estimated_params, non_identifiable_list
    )
    if not filtered_true:  # If all parameters are non-identifiable
        return True  # Consider as successful if there are no identifiable parameters to check
    return calculate_success_ratio(filtered_true, filtered_estimated, tolerance)

def calculate_max_relative_error_filtered(true_params, estimated_params, non_identifiable_list):
    """Calculate maximum relative error excluding non-identifiable parameters"""
    filtered_true, filtered_estimated = filter_identifiable_parameters(
        true_params, estimated_params, non_identifiable_list
    )
    if not filtered_true:
        return np.nan
    return calculate_max_relative_error(filtered_true, filtered_estimated)

def calculate_relative_median_error(true_params, estimated_params):
    """Calculate relative median error between true and estimated parameters"""
    assert true_params, "True parameters must be provided"

    if not estimated_params:
        return 1. # np.nan

    assert set(true_params.keys()) == set(estimated_params.keys()), "True parameters and estimated parameters must have the same keys"
    errors = []
    for param in true_params.keys():
        true_val = float(true_params[param])
        est_val = float(estimated_params[param])
        assert abs(true_val) >= 1e-10, f"True parameter value for '{param}' is too small: {true_val}"            
        errors.append(abs(est_val - true_val) / abs(true_val))
    
    return np.median(errors)

def calculate_mean_relative_error(true_params, estimated_params):
    """Calculate relative mean error between true and estimated parameters"""
    assert true_params, "True parameters must be provided"

    if not estimated_params:
        return 1.0 # np.nan  # 1.0

    assert set(true_params.keys()) == set(estimated_params.keys()), "True parameters and estimated parameters must have the same keys"
    errors = []
    for param in true_params.keys():
        true_val = float(true_params[param])
        est_val = float(estimated_params[param])
        assert abs(true_val) >= 1e-10, f"True parameter value for '{param}' is too small: {true_val}"            
        errors.append(abs(est_val - true_val) / abs(true_val))

    return np.mean(errors)

def calculate_rmse(true_params, estimated_params):
    """Calculate Root Mean Square Error between true and estimated parameters"""
    assert true_params, "True parameters must be provided"

    if not estimated_params:
        return 1.0 # np.nan   # 1.0

    assert set(true_params.keys()) == set(estimated_params.keys()), "True parameters and estimated parameters must have the same keys"
    errors = []
    for param in true_params.keys():
        true_val = float(true_params[param])
        est_val = float(estimated_params[param])
        assert abs(true_val) >= 1e-10, f"True parameter value for '{param}' is too small: {true_val}"            
        errors.append((true_val - est_val) ** 2)

    return math.sqrt(sum(errors) / len(errors))

def calculate_success_ratio(true_params, estimated_params, tolerance=0.1):
    """Check if estimation is successful (all parameters within tolerance)"""
    assert true_params, "True parameters must be provided"

    if not estimated_params:
        return False

    assert set(true_params.keys()) == set(estimated_params.keys()), "True parameters and estimated parameters must have the same keys"
    for param in true_params.keys():
        true_val = float(true_params[param])
        est_val = float(estimated_params[param])
        assert abs(true_val) >= 1e-10, f"True parameter value for '{param}' is too small: {true_val}"            
        rel_error = abs(est_val - true_val) / abs(true_val)
        if rel_error > tolerance:
            return False

    return True

def calculate_max_relative_error(true_params, estimated_params):
    """Calculate maximum relative error between true and estimated parameters"""
    assert true_params, "True parameters must be provided"

    if not estimated_params:
        return np.nan

    assert set(true_params.keys()) == set(estimated_params.keys()), "True parameters and estimated parameters must have the same keys"
    errors = []
    for param in true_params.keys():
        true_val = float(true_params[param])
        est_val = float(estimated_params[param])
        assert abs(true_val) >= 1e-10, f"True parameter value for '{param}' is too small: {true_val}"            
        errors.append(abs(est_val - true_val) / abs(true_val))

    return max(errors)

def validate_parameter_coverage(true_params, estimated_params):
    """Validate that all true parameters are covered in estimated parameters"""
    # If true parameters are empty, this is a data issue
    if not true_params:
        raise ValueError("True parameters dictionary is empty - this indicates a data problem")
    
    # If estimated parameters are empty, this represents a failed estimation
    if not estimated_params:
        return False  # Return False to indicate failed estimation, don't raise error
    
    # Check that all true parameters are present in estimated parameters
    # (estimated parameters may contain additional values like initial states)
    true_param_set = set(true_params.keys())
    estimated_param_set = set(estimated_params.keys())
    
    missing_in_estimated = true_param_set - estimated_param_set
    
    if missing_in_estimated:
        error_msg = f"Missing parameters in estimation results:\n"
        error_msg += f"  True parameters: {sorted(true_param_set)}\n"
        error_msg += f"  Estimated parameters: {sorted(estimated_param_set)}\n"
        error_msg += f"  Missing in estimated: {sorted(missing_in_estimated)}"
        
        raise AssertionError(error_msg)
    
    return True

def create_accuracy_tables(df, args):
    """Create CSV tables showing various statistics by software"""
    
    statistics = getattr(args, 'statistics', ['all'])
    tolerance = args.tolerance
    results_dir = str(args.dir)
    log_limit = args.log_limit
    log_software = getattr(args, 'log_software', None)
    
    df['true_states_parsed'] = df['true_states'].apply(parse_dict_string_must_succeed)
    df['true_parameters_parsed'] = df['true_parameters'].apply(parse_dict_string_must_succeed)
    
    # Parse non-identifiable parameters if the column exists
    def parse_non_identifiable(s):
        if pd.isna(s) or s == '' or s == 'nan' or s == 'NaN':
            return []
        try:
            result = ast.literal_eval(s)
            return result if isinstance(result, list) else []
        except:
            return []
    df['non_identifiable_parsed'] = df['non_identifiable'].apply(parse_non_identifiable)
   
    df['true_params_parsed'] = df.apply(
        lambda row: {**row['true_states_parsed'], **row['true_parameters_parsed']}, axis=1
    )
    df['estimation_candidates'] = df['result'].apply(parse_result_string)
    
    invalid_results_counter = {'count': 0}
   
    def select_and_log_best_estimation(row):
        candidates = row['estimation_candidates']
        true_params = row['true_params_parsed']
       
        if not candidates:
            log_invalid_estimation(row, "No valid estimation candidates found - parsing failed", results_dir, invalid_results_counter, log_limit, log_software)
            return {}
        
        best_result = select_best_estimation(true_params, candidates)
        
        if not best_result:
            log_invalid_estimation(row, "No estimation candidate matched true parameters", results_dir, invalid_results_counter, log_limit, log_software)
        
        return best_result
    
    df['estimated_params_parsed'] = df.apply(select_and_log_best_estimation, axis=1)
    
    def validate_and_log_parameter_coverage(row):
        try:
            return validate_parameter_coverage(
                row['true_params_parsed'], 
                row['estimated_params_parsed']
            )
        except AssertionError as e:
            log_invalid_estimation(row, f"Parameter validation failed: {str(e)}", results_dir, invalid_results_counter, log_limit, log_software)
            return False
        except Exception as e:
            log_invalid_estimation(row, f"Unexpected error during validation: {str(e)}", results_dir, invalid_results_counter, log_limit, log_software)
            return False
    
    df['params_valid'] = df.apply(validate_and_log_parameter_coverage, axis=1)
    
    if invalid_results_counter['count'] > 0:
        print(f"📊 Summary: Found {invalid_results_counter['count']} invalid estimation results")
        print("   See detailed logs above for script paths to investigate")
        print()
    
    if 'median' in statistics:
        df['relative_median_error'] = df.apply(
            lambda row: calculate_relative_median_error_filtered(
                row['true_params_parsed'], 
                row['estimated_params_parsed'],
                row['non_identifiable_parsed']
            ), axis=1
        )
    
    if 'mean' in statistics:
        df['relative_mean_error'] = df.apply(
            lambda row: calculate_mean_relative_error_filtered(
                row['true_params_parsed'], 
                row['estimated_params_parsed'],
                row['non_identifiable_parsed']
            ), axis=1
        )
    
    if 'rmse' in statistics:
        df['rmse'] = df.apply(
            lambda row: calculate_rmse_filtered(
                row['true_params_parsed'], 
                row['estimated_params_parsed'],
                row['non_identifiable_parsed']
            ), axis=1
        )
    
    if 'success_ratio' in statistics:
        df['is_successful'] = df.apply(
            lambda row: calculate_success_ratio_filtered(
                row['true_params_parsed'], 
                row['estimated_params_parsed'],
                tolerance,
                row['non_identifiable_parsed']
            ), axis=1
        )
    
    if 'max' in statistics:
        df['max_relative_error'] = df.apply(
            lambda row: calculate_max_relative_error_filtered(
                row['true_params_parsed'], 
                row['estimated_params_parsed'],
                row['non_identifiable_parsed']
            ), axis=1
        )
    
    run_list = sorted(df['run'].unique())
    noise_levels = sorted(df['noise'].unique())
    systems = sorted(df['name'].unique())

    statistic_to_column = {
        'median': 'relative_median_error',
        'mean': 'relative_mean_error',
        'rmse': 'rmse',
        'success_ratio': 'is_successful',
        'max': 'max_relative_error'
    }

    for statistic in statistics:
        for run in args.run:
            software_df = df[df['run'] == run].copy()

            value_column = statistic_to_column[statistic]
            
            
            # Create pivot table: rows = models, columns = noise levels
            if statistic == 'success_ratio':
                accuracy_table = software_df.groupby(['name', 'noise'])[value_column].agg([
                    lambda x: f"{x.sum() / len(x) * 100}%",
                    'count'
                ]).round(DISPLAY_DIGITS)

                accuracy_table.columns = ['success_percentage', 'total_runs']
                accuracy_table = accuracy_table['success_percentage'].unstack(fill_value=np.nan)
            else:
                # Choose aggregation method based on statistic type
                if statistic == 'max':
                    agg_method = 'max'
                else:
                    agg_method = 'median'
                    
                accuracy_table = software_df.groupby(['name', 'noise'])[value_column].agg([
                    agg_method, 'count'
                ]).round(DISPLAY_DIGITS)

                accuracy_table = accuracy_table[agg_method].unstack(fill_value=np.nan)
            
            # Reorder columns by noise level
            accuracy_table = accuracy_table.reindex(columns=noise_levels, fill_value=np.nan)
            noise_columns = {col: f"{col:.0e}" for col in accuracy_table.columns}
            accuracy_table = accuracy_table.rename(columns=noise_columns)
            
            # Save the table
            filename = f"software_{run}_{statistic}_relative_errors.csv"
            accuracy_table.to_csv(filename)
            
            print(f"\n{statistic.title()} Table for {run}:")
            print("="*60)
            print(accuracy_table.to_string())
            print()

    # Generate noise-level tables: rows = systems, columns = software
    for statistic in statistics:
        value_column = statistic_to_column[statistic]
        
        for noise_level in noise_levels:
            noise_df = df[df['noise'] == noise_level].copy()
            
            if statistic == 'success_ratio':
                # For success ratio, calculate percentage of successful runs
                noise_table = noise_df.groupby(['name', 'run'])[value_column].agg([
                    lambda x: round(x.sum() / len(x) * 100, DISPLAY_DIGITS)  # success percentage
                ]).round(DISPLAY_DIGITS)
                noise_table.columns = ['success_percentage']
                noise_table = noise_table['success_percentage'].unstack(fill_value=0.0)
            else:
                # Choose aggregation method based on statistic type
                if statistic == 'max':
                    agg_method = 'max'
                else:
                    agg_method = 'median'
                    
                noise_table = noise_df.groupby(['name', 'run'])[value_column].agg(agg_method).round(DISPLAY_DIGITS)
                noise_table = noise_table.unstack(fill_value=np.nan)
            
            # Reorder columns by software list to ensure consistent ordering
            noise_table = noise_table.reindex(columns=run_list, fill_value=np.nan)
            
            # Save the table (without has_result and total_runs columns for these tables)
            noise_str = f"{noise_level:.0e}"
            filename = f"noise_{noise_str}_{statistic}_by_system.csv"
            noise_table.to_csv(filename)

            print(f"\n{statistic.title()} by System and Software (Noise Level: {noise_str}):")
            print("="*80)
            print(noise_table.to_string())
            print()
    
    # Additional table: for each software, rows=systems, columns=noise levels, entries=number of estimation results
    for run in args.run:
        software_df = df[df['run'] == run].copy()
        
        # Calculate overall stats for this software (Estimation Counts tables should have these columns)
        software_has_result = software_df.groupby('name')['has_result'].sum()
        software_total_runs = software_df.groupby('name').size()
        
        software_overall_stats = pd.DataFrame({
            'has_result': software_has_result,
            'total_runs': software_total_runs,
        })
        
        # Count number of estimation results per system and noise level with mean and std
        def format_mean_std(x):
            counts = x.apply(len)
            mean_val = counts.mean()
            std_val = counts.std()
            if pd.isna(std_val):
                std_val = 0.0
            return f"{mean_val:.{1}f} ± {std_val:.{1}f}"
        
        count_table = software_df.groupby(['name', 'noise'])['estimation_candidates'].apply(format_mean_std).unstack(fill_value="0.0 ± 0.0")
        # Reorder columns by noise_levels for consistency
        count_table = count_table.reindex(columns=noise_levels, fill_value="0.0 ± 0.0")
        noise_columns = {col: f"{col:.0e}" for col in count_table.columns}
        count_table = count_table.rename(columns=noise_columns)
        
        # Combine overall stats with count table (Estimation Counts tables must have has_result and total_runs)
        final_count_table = software_overall_stats.join(count_table, rsuffix='_noise')
        
        # Save and print
        filename = f"software_{run}_estimation_counts.csv"
        final_count_table.to_csv(filename)
        print(f"\nEstimation Counts for {run} (Rows: Systems, Columns: Noise Levels):")
        print("="*70)
        print(final_count_table.to_string())
        print()

    for statistic in statistics:
        value_column = statistic_to_column[statistic]

        has_result = df.groupby('run')['has_result'].sum()
        total_runs = df.groupby('run').size()
        
        overall_stats = pd.DataFrame({
            'has_result': has_result,
            'total_runs': total_runs,
        })
        
        if statistic == 'success_ratio':
            stats_by_noise = df.groupby(['run', 'noise'])[value_column].agg([
                lambda x: f"{int(round(x.sum() / len(x) * 100, DISPLAY_DIGITS))}%"  # success percentage
            ]).round(0)
            stats_by_noise.columns = ['success_pct']
            stats_by_noise = stats_by_noise['success_pct'].unstack(fill_value=0.0)
        else:
            # Choose aggregation method based on statistic type
            if statistic == 'max':
                agg_method = 'max'
            else:
                agg_method = 'median'
                
            stats_by_noise = df.groupby(['run', 'noise'])[value_column].agg(agg_method).round(DISPLAY_DIGITS)
            stats_by_noise = stats_by_noise.unstack(fill_value=np.nan)
        
        noise_columns = {col: f"{col:.0e}" for col in stats_by_noise.columns}
        stats_by_noise = stats_by_noise.rename(columns=noise_columns)
        
        software_summary = overall_stats.join(stats_by_noise, rsuffix='_noise')
        software_summary = software_summary.sort_values('has_result', ascending=False)
        
        comparison_filename = f"software_comparison_{statistic}.csv"
        software_summary.to_csv(comparison_filename)
        
        print(f"\nOverall Software Performance Summary ({statistic}):")
        print("="*90)
        print(software_summary.to_string())
        print()

    # Generate parameter comparison tables (ground-truth vs estimation)
    print("\n" + "="*90)
    print("PARAMETER COMPARISON TABLES (Ground-truth vs Estimation)")
    print("="*90)
    
    def create_parameter_comparison_tables(df, args):
        """Create tables comparing ground-truth vs estimation results per parameter"""
        
        # Get valid results only
        valid_df = df[df['params_valid'] == True].copy()
        
        if valid_df.empty:
            print("No valid estimation results found for parameter comparison.")
            return
        
        # Get unique combinations of model, software, and noise level
        groups = valid_df.groupby(['name', 'run', 'noise'])
        
        for (model_name, run, noise_level), group in groups:
            if len(group) == 0:
                continue
                
            # Get all parameter names from the first valid row
            first_valid_row = group.iloc[0]
            true_params = first_valid_row['true_params_parsed']
            estimated_params = first_valid_row['estimated_params_parsed']
            non_identifiable = first_valid_row['non_identifiable_parsed']
            
            # Get both identifiable and non-identifiable parameters
            identifiable_params = [p for p in true_params.keys() if p not in non_identifiable]
            non_identifiable_params = [p for p in true_params.keys() if p in non_identifiable]
            all_params = identifiable_params + non_identifiable_params
            
            if not all_params:
                print("   No parameters found.")
                continue
                
            print(f"\nModel: {model_name} | Software: {run} | Noise: {noise_level:.0e}")
            print("-" * 80)
            if identifiable_params and non_identifiable_params:
                print(f"   Identifiable parameters: {', '.join(sorted(identifiable_params))}")
                print(f"   Non-identifiable parameters: {', '.join(sorted(non_identifiable_params))}")
            elif non_identifiable_params:
                print(f"   All parameters are non-identifiable: {', '.join(sorted(non_identifiable_params))}")
            else:
                print(f"   All parameters are identifiable: {', '.join(sorted(identifiable_params))}")
            print()
            
            # Create comparison table
            comparison_data = []
            
            for idx, (_, row) in enumerate(group.iterrows()):
                row_data = {'Run': idx + 1}
                
                true_vals = row['true_params_parsed']
                est_vals = row['estimated_params_parsed']
                
                # Add true values (prefixed with 'True_')
                for param in all_params:
                    if param in true_vals:
                        row_data[f'True_{param}'] = true_vals[param]
                
                # Add estimated values (prefixed with 'Est_')
                for param in all_params:
                    if param in est_vals:
                        row_data[f'Est_{param}'] = est_vals[param]
                    else:
                        row_data[f'Est_{param}'] = np.nan
                
                # Add overall statistics for this run (using existing functions)
                filtered_true, filtered_est = filter_identifiable_parameters(true_vals, est_vals, non_identifiable)
                
                if filtered_true and filtered_est:
                    try:
                        tolerance = getattr(args, 'tolerance', 0.1)
                        row_data['MedianRelErr'] = calculate_relative_median_error(filtered_true, filtered_est)
                        row_data['MeanRelErr'] = calculate_mean_relative_error(filtered_true, filtered_est)
                        row_data['MaxRelErr'] = calculate_max_relative_error(filtered_true, filtered_est)
                        row_data['RMSE'] = calculate_rmse(filtered_true, filtered_est)
                        row_data['Success'] = calculate_success_ratio(filtered_true, filtered_est, tolerance)
                    except Exception as e:
                        row_data['MedianRelErr'] = np.nan
                        row_data['MeanRelErr'] = np.nan
                        row_data['MaxRelErr'] = np.nan
                        row_data['RMSE'] = np.nan
                        row_data['Success'] = False
                else:
                    row_data['MedianRelErr'] = np.nan
                    row_data['MeanRelErr'] = np.nan
                    row_data['MaxRelErr'] = np.nan
                    row_data['RMSE'] = np.nan
                    row_data['Success'] = False
                
                comparison_data.append(row_data)
            
            # Create DataFrame and format
            comparison_df = pd.DataFrame(comparison_data)
            
            # Set Run as index
            comparison_df.set_index('Run', inplace=True)
            
            # Group columns: identifiable parameters, non-identifiable parameters, statistics
            identifiable_true_columns = []
            identifiable_est_columns = []
            non_identifiable_true_columns = []
            non_identifiable_est_columns = []
            
            for param in sorted(identifiable_params):
                identifiable_true_columns.append(f'True_{param}')
                identifiable_est_columns.append(f'Est_{param}')
            
            for param in sorted(non_identifiable_params):
                non_identifiable_true_columns.append(f'True_{param}')
                non_identifiable_est_columns.append(f'Est_{param}')
            
            overall_columns = ['MedianRelErr', 'MeanRelErr', 'MaxRelErr', 'RMSE', 'Success']
            
            # Order: identifiable true, identifiable est, non-identifiable true, non-identifiable est, statistics
            ordered_columns = (identifiable_true_columns + identifiable_est_columns + 
                             non_identifiable_true_columns + non_identifiable_est_columns + 
                             overall_columns)
            comparison_df = comparison_df.reindex(columns=ordered_columns)
            
            # Sort by RMSE in descending order (worst performers first)
            comparison_df = comparison_df.sort_values('RMSE', ascending=False)
            
            # Print the table
            print(comparison_df.to_string())
            
            # Save to CSV
            safe_model_name = model_name.replace('/', '_').replace(' ', '_')
            filename = f"parameter_comparison_{safe_model_name}_{run}_noise_{noise_level:.0e}.csv"
            comparison_df.to_csv(filename)
            print(f"   Saved to: {filename}")
            print()
    
    create_parameter_comparison_tables(df, args)

    # Generate timing table
    print("\n" + "="*90)
    print("TIMING ANALYSIS")
    print("="*90)
    
    # Filter to only include finished runs with timing data
    timing_df = df[(df['finished'] == True) & (df['time'].notna()) & (df['time'] > 0)].copy()
    
    if not timing_df.empty:
        # Overall timing statistics by software
        timing_stats = timing_df.groupby('run')['time'].agg([
            'count',
            'mean', 
            'median',
            'std',
            'min',
            'max'
        ]).round(DISPLAY_DIGITS)
        
        timing_stats.columns = ['runs', 'mean_time', 'median_time', 'std_time', 'min_time', 'max_time']
        timing_stats = timing_stats.sort_values('median_time')
        
        # Save timing summary
        timing_stats.to_csv("software_timing_summary.csv")
        
        print(f"\nTiming Summary by Software (seconds):")
        print("="*70)
        print(timing_stats.to_string())
        print()
        
        # Timing by noise level and software
        timing_by_noise = timing_df.groupby(['run', 'noise'])['time'].median().round(DISPLAY_DIGITS)
        timing_by_noise = timing_by_noise.unstack(fill_value=np.nan)
        
        # Format noise level columns
        noise_columns = {col: f"{col:.0e}" for col in timing_by_noise.columns}
        timing_by_noise = timing_by_noise.rename(columns=noise_columns)
        
        # Save timing by noise
        timing_by_noise.to_csv("software_timing_by_noise.csv")
        
        print(f"\nMedian Timing by Software and Noise Level (seconds):")
        print("="*70)
        print(timing_by_noise.to_string())
        print()
        
        # Timing by system (top 10 slowest and fastest)
        timing_by_system = timing_df.groupby(['name', 'run'])['time'].median().round(DISPLAY_DIGITS)
        timing_by_system = timing_by_system.unstack(fill_value=np.nan)
        timing_by_system = timing_by_system.reindex(columns=run_list, fill_value=np.nan)
        
        # Calculate average time across all software for each system
        timing_by_system['avg_time'] = timing_by_system.mean(axis=1, skipna=True).round(DISPLAY_DIGITS)
        timing_by_system_sorted = timing_by_system.sort_values('avg_time', ascending=False)
        
        # Save full timing by system
        timing_by_system_sorted.to_csv("system_timing_by_software.csv")
        
        print(f"\nTiming by System and Software (median time in seconds, sorted by average):")
        print("="*80)
        print(timing_by_system_sorted.to_string())
        print()
        
    else:
        print("\nNo timing data available in the results.")
        print("Make sure the estimation runs completed successfully.")
        print()

def main(args):
  parent = Path(__file__).parent.parent.resolve()
  args.dir = parent / Path(args.dir)
  with open(args.dir / 'config' / 'config.json', 'r') as io:
    args.config = json.load(io)
  with open(args.dir / 'result.csv', 'r') as io:
    df = pd.read_csv(io)

  # Create analysis_results directory
  import os
  analysis_dir = args.dir / "analysis_results"
  analysis_dir.mkdir(exist_ok=True)
  
  original_dir = os.getcwd()
  os.chdir(analysis_dir)
  
  try:
    create_accuracy_tables(df, args)
  finally:
    os.chdir(original_dir)
  
if __name__ == "__main__":
  
    parser = argparse.ArgumentParser(
        description="Analyze benchmark results and compute various statistics",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Available statistics:
  median        Median relative error (default)
  mean          Mean relative error  
  rmse          Root Mean Square Error
  success_ratio Ratio of runs where estimation is close to true values (within 10% tolerance)

Examples:
  python summarize_results.py LATEST/                           # Default: median relative error
  python summarize_results.py LATEST/ --stats median mean       # Median and mean relative errors
  python summarize_results.py LATEST/ --stats all               # All available statistics
  python summarize_results.py LATEST/ --stats success_ratio     # Only success ratio
  python summarize_results.py LATEST/ --log-limit 0             # Show all invalid result details
  python summarize_results.py LATEST/ --log-limit 10            # Show first 10 invalid result details
  python summarize_results.py LATEST/ --log-software pe sciml # Only log errors from pe and sciml
        """)
    
    parser.add_argument("dir", help="The directory generated by generate_data.py.")
    parser.add_argument("run", help="The directory generated by generate_scripts.py.")
    parser.add_argument("--stats", "--statistics", dest="statistics", nargs='+', 
                      choices=['median', 'mean', 'rmse', 'success_ratio', 'max', 'all'],
                      default=['all'],
                      help="Statistics to compute (default: median)")
    parser.add_argument("--tolerance", type=float, default=0.1,
                      help="Tolerance for success ratio calculation (default: 0.1 = 10%%)")
    parser.add_argument("--log-limit", type=int, default=0,
                      help="Maximum number of detailed invalid result logs to show (default: 5, 0 for no limit)")
    parser.add_argument("--log-software", nargs='+', default=None,
                      choices=AVAILABLE_SOFTWARE,
                      help=f"Only log errors from specific software. Available options: {', '.join(AVAILABLE_SOFTWARE)}. If not specified, logs errors from all software.")
    
    args = parser.parse_args()
    args.run = args.run.split(",")

    # Handle 'all' option
    if 'all' in args.statistics:
        args.statistics = ['median', 'mean', 'rmse', 'success_ratio', 'max']
    
    main(args)

