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
#from julia.api import Julia
#import csv
import pandas as pd
pd.set_option("display.precision",16)
import argparse
from datetime import datetime
from pathlib import Path
from termcolor import colored
from shared import warn, info, get_settings, AVAILABLE_SOFTWARE
import ast
import math

def parse_dict_string(s):
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
    max_estimations = 0
    
    for item in result:
        if len(item) >= 2:  # At least parameter name and one value
            param = item[0]
            if param:  # Non-empty parameter name
                values = [float(v) for v in item[1:] if v]  # Convert all values to float
                if values:
                    param_values[param] = values
                    max_estimations = max(max_estimations, len(values))
        elif len(item) == 1:
            # Just parameter name without values - estimation failed for this parameter
            continue
    
    if not param_values or max_estimations == 0:
        return []
    
    # Create estimation results where i-th result uses i-th value from each parameter
    estimation_results = []
    for i in range(max_estimations):
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
    if not true_params or not estimation_results:
        return {}
    
    best_result = {}
    best_score = float('inf')
    
    for result in estimation_results:
        if not result:
            continue
            
        # Calculate score based on relative error to true values
        score = 0.0
        valid_params = 0
        
        # Only consider parameters that exist in both dictionaries
        common_params = set(true_params.keys()) & set(result.keys())
        
        if not common_params:
            continue
            
        for param in common_params:
            try:
                true_val = float(true_params[param])
                est_val = float(result[param])
                
                if abs(true_val) > 1e-15:  # Avoid division by very small numbers
                    rel_error = abs(est_val - true_val) / abs(true_val)
                    score += rel_error
                    valid_params += 1
                else:
                    # For very small true values, use absolute error
                    score += abs(est_val - true_val)
                    valid_params += 1
            except (ValueError, TypeError):
                continue
        
        if valid_params > 0:
            avg_score = score / valid_params
            if avg_score < best_score:
                best_score = avg_score
                best_result = result
    
    return best_result

def log_invalid_estimation(row, reason, results_dir, counter=None, limit=5):
    """Log information about invalid estimation results with clickable path"""
    model_name = row.get('name', 'unknown')
    software = row.get('software', 'unknown')
    row_id = row.get('id', 'unknown')
    
    # Determine script extension based on software
    # Most software uses Julia (.jl), except for some that use MATLAB (.m)
    if software.lower() in ['amigo2', 'iqm']:  # Add other MATLAB-based software here if needed
        script_ext = '.m'
    else:
        script_ext = '.jl'  # Default to Julia for most software
    
    # Create the correct path: $RESULTS/filetree/$SOFTWARE/$ID/script.m (or .jl)
    script_path = f"{results_dir}/filetree/{software}/{row_id}/script{script_ext}"
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

def calculate_relative_median_error(true_params, estimated_params):
    """Calculate relative median error between true and estimated parameters"""
    if not true_params or not estimated_params:
        return np.nan
    
    # Only consider parameters that exist in both dictionaries
    common_params = set(true_params.keys()) & set(estimated_params.keys())
    
    if not common_params:
        return np.nan
    
    # Calculate relative errors for each parameter
    relative_errors = []
    for param in common_params:
        try:
            true_val = float(true_params[param])
            est_val = float(estimated_params[param])
            
            # Assert that true value is not zero (to avoid division by zero)
            assert abs(true_val) >= 1e-15, f"True parameter value for '{param}' is too small: {true_val}"
                
            relative_error = abs(est_val - true_val) / abs(true_val)
            relative_errors.append(relative_error)
        except (ValueError, TypeError):
            continue
    
    if not relative_errors:
        return np.nan
    
    # Return median relative error
    return np.median(relative_errors)

def calculate_mean_relative_error(true_params, estimated_params):
    """Calculate mean relative error between true and estimated parameters"""
    if not true_params or not estimated_params:
        return np.nan
    
    # Only consider parameters that exist in both dictionaries
    common_params = set(true_params.keys()) & set(estimated_params.keys())
    
    if not common_params:
        return np.nan
    
    relative_errors = []
    for param in common_params:
        try:
            true_val = float(true_params[param])
            est_val = float(estimated_params[param])
            assert abs(true_val) > 1e-10, f"True parameter value for '{param}' is too small: {true_val}"
            relative_error = abs(est_val - true_val) / abs(true_val)
            relative_errors.append(relative_error)
        except (ValueError, TypeError):
            continue
    
    if not relative_errors:
        return np.nan
    
    # Return mean relative error
    return np.mean(relative_errors)

def calculate_rmse(true_params, estimated_params):
    """Calculate Root Mean Square Error between true and estimated parameters"""
    if not true_params or not estimated_params:
        return np.nan
    
    # Only consider parameters that exist in both dictionaries
    common_params = set(true_params.keys()) & set(estimated_params.keys())
    
    if not common_params:
        return np.nan
    
    squared_errors = []
    for param in common_params:
        try:
            true_val = float(true_params[param])
            est_val = float(estimated_params[param])
            squared_errors.append((true_val - est_val) ** 2)
        except (ValueError, TypeError):
            continue
    
    if not squared_errors:
        return np.nan
    
    return math.sqrt(sum(squared_errors) / len(squared_errors))

def is_estimation_successful(true_params, estimated_params, tolerance=0.1):
    """Check if estimation is successful (all parameters within tolerance)"""
    if not true_params or not estimated_params:
        return False
    
    # Only consider parameters that exist in both dictionaries
    common_params = set(true_params.keys()) & set(estimated_params.keys())
    
    if not common_params:
        return False
    
    for param in common_params:
        try:
            true_val = float(true_params[param])
            est_val = float(estimated_params[param])
            assert abs(true_val) > 1e-10, f"True parameter value for '{param}' is too small: {true_val}"
            rel_error = abs(est_val - true_val) / abs(true_val)
            if rel_error > tolerance:
                return False
        except (ValueError, TypeError):
            return False
    
    return True

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
    
    statistics = getattr(args, 'statistics', ['median'])
    tolerance = args.tolerance
    results_dir = str(args.dir)
    log_limit = args.log_limit
    
    df['true_states_parsed'] = df['true_states'].apply(parse_dict_string)
    df['true_parameters_parsed'] = df['true_parameters'].apply(parse_dict_string)
    
    df['true_params_parsed'] = df.apply(
        lambda row: {**row['true_states_parsed'], **row['true_parameters_parsed']}, axis=1
    )
    df['estimation_candidates'] = df['result'].apply(parse_result_string)
    
    invalid_results_counter = {'count': 0}
    
    def select_and_log_best_estimation(row):
        candidates = row['estimation_candidates']
        true_params = row['true_params_parsed']
        
        if not candidates:
            log_invalid_estimation(row, "No valid estimation candidates found - parsing failed", results_dir, invalid_results_counter, log_limit)
            return {}
        
        best_result = select_best_estimation(true_params, candidates)
        
        if not best_result:
            log_invalid_estimation(row, "No estimation candidate matched true parameters", results_dir, invalid_results_counter, log_limit)
        
        return best_result
    
    df['estimated_params_parsed'] = df.apply(select_and_log_best_estimation, axis=1)
    
    def validate_and_log_parameter_coverage(row):
        try:
            return validate_parameter_coverage(
                row['true_params_parsed'], 
                row['estimated_params_parsed']
            )
        except AssertionError as e:
            log_invalid_estimation(row, f"Parameter validation failed: {str(e)}", results_dir, invalid_results_counter, log_limit)
            return False
        except Exception as e:
            log_invalid_estimation(row, f"Unexpected error during validation: {str(e)}", results_dir, invalid_results_counter, log_limit)
            return False
    
    df['params_valid'] = df.apply(validate_and_log_parameter_coverage, axis=1)
    
    if invalid_results_counter['count'] > 0:
        print(f"📊 Summary: Found {invalid_results_counter['count']} invalid estimation results")
        print("   See detailed logs above for script paths to investigate")
        print()
    
    if 'median' in statistics:
        df['relative_median_error'] = df.apply(
            lambda row: calculate_relative_median_error(
                row['true_params_parsed'], 
                row['estimated_params_parsed']
            ), axis=1
        )
    
    if 'mean' in statistics:
        df['relative_mean_error'] = df.apply(
            lambda row: calculate_mean_relative_error(
                row['true_params_parsed'], 
                row['estimated_params_parsed']
            ), axis=1
        )
    
    if 'rmse' in statistics:
        df['rmse'] = df.apply(
            lambda row: calculate_rmse(
                row['true_params_parsed'], 
                row['estimated_params_parsed']
            ), axis=1
        )
    
    if 'success_ratio' in statistics:
        df['is_successful'] = df.apply(
            lambda row: is_estimation_successful(
                row['true_params_parsed'], 
                row['estimated_params_parsed'],
                tolerance=tolerance
            ), axis=1
        )
    
    software_list = sorted(df['software'].unique())
    noise_levels = sorted(df['noise'].unique())
    
    for statistic in statistics:
        for software in software_list:
            software_df = df[df['software'] == software].copy()
            
            if len(software_df) == 0:
                continue
            
            if statistic == 'success_ratio':
                success_table = software_df.groupby(['name', 'noise'])['is_successful'].agg([
                    lambda x: x.sum() / len(x) * 100,
                    'count'
                ]).round(2)
                
                success_table.columns = ['success_percentage', 'total_runs']
                success_table = success_table['success_percentage'].unstack(fill_value=np.nan)
                
                # Reorder columns by noise level
                success_table = success_table.reindex(columns=noise_levels, fill_value=np.nan)
                
                # Save the table
                filename = f"software_{software}_{statistic}.csv"
                success_table.to_csv(filename)
                
                print(f"\n{statistic.title()} Table for {software} (%):")
                print("="*80)
                print(success_table.to_string())
                
            else:
                # For other statistics, use the corresponding column
                if statistic == 'median':
                    value_column = 'relative_median_error'
                elif statistic == 'mean':
                    value_column = 'relative_mean_error'
                elif statistic == 'rmse':
                    value_column = 'rmse'
                else:
                    continue
                
                # Create pivot table: rows = models, columns = noise levels
                accuracy_table = software_df.groupby(['name', 'noise'])[value_column].agg([
                    'median', 'count'
                ]).round(6)
                
                accuracy_table = accuracy_table['median'].unstack(fill_value=np.nan)
                
                # Reorder columns by noise level
                accuracy_table = accuracy_table.reindex(columns=noise_levels, fill_value=np.nan)
                
                # Save the table
                filename = f"software_{software}_{statistic}_relative_errors.csv"
                accuracy_table.to_csv(filename)
                
                print(f"\n{statistic.title()} Relative Error Table for {software}:")
                print("="*80)
                print(accuracy_table.to_string())
                
                # Calculate best/worst performing models for this statistic
                if len(accuracy_table) > 0:
                    model_avg_performance = accuracy_table.mean(axis=1, skipna=True)
                    model_avg_performance = model_avg_performance.dropna()
                    
                    if len(model_avg_performance) > 0:
                        best_model = model_avg_performance.idxmin()
                        worst_model = model_avg_performance.idxmax()
                        print(f"\nBest performing model for {software} ({statistic}): {best_model} (avg error: {model_avg_performance[best_model]:.6f})")
                        print(f"Worst performing model for {software} ({statistic}): {worst_model} (avg error: {model_avg_performance[worst_model]:.6f})")
                print()
    
    for statistic in statistics:
        
        if statistic == 'success_ratio':
            overall_success = df.groupby('software')['is_successful'].agg([
                lambda x: x.sum(),
                'count'
            ]).round(2)
            overall_success.columns = ['finished_runs', 'total_runs']
            overall_success.finished_runs = df.groupby('software')['finished'].sum()
            
            # Success percentage by noise level
            success_by_noise = df.groupby(['software', 'noise'])['is_successful'].agg([
                lambda x: x.sum() / len(x) * 100  # success percentage
            ]).round(2)
            success_by_noise.columns = ['success_pct']
            success_by_noise = success_by_noise['success_pct'].unstack(fill_value=0.0)
            
            # Rename noise level columns for better readability
            noise_columns = {col: f"{col:.0e}" for col in success_by_noise.columns}
            success_by_noise = success_by_noise.rename(columns=noise_columns)
            
            # Combine overall stats with noise-level breakdown
            software_summary = overall_success.join(success_by_noise, rsuffix='_noise')
            software_summary = software_summary.sort_values('finished_runs', ascending=False)
            
        else:
            if statistic == 'median':
                value_column = 'relative_median_error'
            elif statistic == 'mean':
                value_column = 'relative_mean_error'
            elif statistic == 'rmse':
                value_column = 'rmse'
            else:
                continue
            
            finished_runs = df.groupby('software')['finished'].sum()
            total_runs = df.groupby('software').size()
            
            overall_stats = pd.DataFrame({
                'finished_runs': finished_runs,
                'total_runs': total_runs
            })
            
            stats_by_noise = df.groupby(['software', 'noise'])[value_column].median().round(6)
            stats_by_noise = stats_by_noise.unstack(fill_value=np.nan)
            
            noise_columns = {col: f"{col:.0e}" for col in stats_by_noise.columns}
            stats_by_noise = stats_by_noise.rename(columns=noise_columns)
            
            software_summary = overall_stats.join(stats_by_noise, rsuffix='_noise')
            software_summary = software_summary.sort_values('finished_runs', ascending=False)
        
        comparison_filename = f"software_comparison_{statistic}.csv"
        software_summary.to_csv(comparison_filename)
        
        print(f"\nOverall Software Performance Summary ({statistic}):")
        print("="*120)
        print(software_summary.to_string())
        
        if statistic != 'success_ratio':
            print(f"\nBest overall software (by median {statistic}): {software_summary.index[0]}")
            print(f"Worst overall software (by median {statistic}): {software_summary.index[-1]}")
        else:
            print(f"\nBest overall software (by {statistic}): {software_summary.index[0]}")
            print(f"Worst overall software (by {statistic}): {software_summary.index[-1]}")
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
        """)
    
    parser.add_argument("dir", help="The directory generated by generate_data.py.")
    parser.add_argument("--stats", "--statistics", dest="statistics", nargs='+', 
                      choices=['median', 'mean', 'rmse', 'success_ratio', 'all'],
                      default=['median'],
                      help="Statistics to compute (default: median)")
    parser.add_argument("--tolerance", type=float, default=0.1,
                      help="Tolerance for success ratio calculation (default: 0.1 = 10%%)")
    parser.add_argument("--log-limit", type=int, default=5,
                      help="Maximum number of detailed invalid result logs to show (default: 5, 0 for no limit)")
    
    args = parser.parse_args()
    
    # Handle 'all' option
    if 'all' in args.statistics:
        args.statistics = ['median', 'mean', 'rmse', 'success_ratio']
    
    main(args)

