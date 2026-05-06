#!/usr/bin/env python3
"""
Generate flat_results_with_metrics.csv from the preprocessed result CSV.
Computes per-row error metrics on identifiable variables (parameters + states).

Usage:
    cd ~/ParameterEstimationBenchmarking/benchmark_wombat_2026_02_26
    python3 generate_flat_metrics.py
"""

import ast
import json
import os
import numpy as np
import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_CSV = os.path.join(SCRIPT_DIR, "result_odepe_best.csv")
SYSTEMS_JSON = os.path.join(SCRIPT_DIR, "config", "systems.json")
NONID_JSON = os.path.join(os.path.expanduser("~"), "tmp", "no-matlab-no-worry", "config", "non_identifiable.json")
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "analysis_results")
OUTPUT_CSV = os.path.join(OUTPUT_DIR, "flat_results_with_metrics.csv")

os.makedirs(OUTPUT_DIR, exist_ok=True)


def parse_result(result_str):
    """Parse the result column string into a dict of {name: value}."""
    if pd.isna(result_str) or result_str in ('', '[]', 'None'):
        return None
    try:
        data = ast.literal_eval(result_str)
        if not data:
            return None
        # data is a list of [name, value] or [name, value1, value2, ...]
        # After preprocessing, ODEPE should have single values
        result = {}
        for item in data:
            name = item[0]
            if len(item) >= 2:
                try:
                    result[name] = float(item[1])
                except (ValueError, TypeError):
                    result[name] = None
        return result
    except Exception:
        return None


def parse_true_params(params_str):
    """Parse the true_parameters column string into a dict of {name: value}."""
    if pd.isna(params_str) or params_str in ('', 'None'):
        return None
    try:
        return ast.literal_eval(params_str)
    except Exception:
        return None


def parse_non_identifiable(ni_str):
    """Parse the non_identifiable column into a list of parameter names."""
    if pd.isna(ni_str) or ni_str in ('', '[]', 'None'):
        return []
    try:
        return ast.literal_eval(ni_str)
    except Exception:
        return []


def main():
    print("Loading data...")
    df = pd.read_csv(INPUT_CSV)
    print(f"  {len(df)} rows loaded")

    # Load system definitions for parameter info
    with open(SYSTEMS_JSON) as f:
        systems_data = json.load(f)
    sys_info = {s['name']: s for s in systems_data['systems']}

    # Load authoritative non-identifiable parameter list
    non_id_override = {}
    if os.path.exists(NONID_JSON):
        with open(NONID_JSON) as f:
            non_id_override = json.load(f)
        print(f"  Loaded non-identifiable overrides for: {list(non_id_override.keys())}")

    rows = []
    n_has_result = 0
    n_no_result = 0

    for idx, row in df.iterrows():
        name = row['name']
        run = row['run']
        noise = row['noise']
        instance_id = row['id']
        has_result = bool(row['has_result'])
        finished = bool(row['finished'])
        time_val = float(row['time']) if pd.notna(row['time']) else 0.0

        # Get system info
        si = sys_info.get(name, {})
        param_vars = si.get('parameter_variables', [])
        state_vars = si.get('state_variables', [])
        all_vars = param_vars + state_vars

        # Non-identifiable: use override file (authoritative), fall back to row data
        if name in non_id_override and non_id_override[name]:
            non_id_vars = non_id_override[name]
        else:
            non_id_vars = parse_non_identifiable(row.get('non_identifiable', '[]'))

        # Score on ALL variables (params + states), excluding non-identifiable
        id_vars = [v for v in all_vars if v not in non_id_vars]
        non_id_count = len([v for v in all_vars if v in non_id_vars])
        n_id = len(id_vars)
        n_nonid = non_id_count

        # Default metrics
        metrics = {
            'name': name,
            'run': run,
            'noise': noise,
            'id': instance_id,
            'has_result': int(has_result),
            'finished': int(finished),
            'time': time_val,
            'n_id_params': n_id,
            'n_nonid_params': n_nonid,
            'median_rel_error': np.nan,
            'mean_rel_error': np.nan,
            'max_rel_error': np.nan,
            'rmse': np.nan,
            'success_at_1pct': 0,
            'success_at_10pct': 0,
            'success_at_50pct': 0,
        }

        if has_result:
            result = parse_result(row['result'])
            # Merge true_parameters and true_states into one dict
            true_params = parse_true_params(row['true_parameters']) or {}
            true_states = parse_true_params(row.get('true_states', '')) or {}
            true_all = {**true_states, **true_params}

            if not id_vars:
                # All variables are non-identifiable: vacuously successful
                metrics['median_rel_error'] = 0.0
                metrics['mean_rel_error'] = 0.0
                metrics['max_rel_error'] = 0.0
                metrics['rmse'] = 0.0
                metrics['success_at_1pct'] = 1
                metrics['success_at_10pct'] = 1
                metrics['success_at_50pct'] = 1
                n_has_result += 1
            elif result and true_all:
                rel_errors = []
                for p in id_vars:
                    true_val = true_all.get(p)
                    est_val = result.get(p)
                    if true_val is not None and est_val is not None:
                        tv = float(true_val)
                        ev = float(est_val)
                        if abs(tv) > 1e-15:
                            rel_err = abs(ev - tv) / abs(tv)
                        else:
                            rel_err = abs(ev - tv)
                        rel_errors.append(rel_err)

                if rel_errors:
                    arr = np.array(rel_errors)
                    metrics['median_rel_error'] = float(np.median(arr))
                    metrics['mean_rel_error'] = float(np.mean(arr))
                    metrics['max_rel_error'] = float(np.max(arr))
                    metrics['rmse'] = float(np.sqrt(np.mean(arr**2)))
                    metrics['success_at_1pct'] = int(np.all(arr <= 0.01))
                    metrics['success_at_10pct'] = int(np.all(arr <= 0.10))
                    metrics['success_at_50pct'] = int(np.all(arr <= 0.50))
                    n_has_result += 1
                else:
                    n_no_result += 1
            else:
                n_no_result += 1
        else:
            n_no_result += 1

        rows.append(metrics)

    out_df = pd.DataFrame(rows)
    out_df.to_csv(OUTPUT_CSV, index=False)
    print(f"\nOutput: {OUTPUT_CSV}")
    print(f"  {len(out_df)} rows")
    print(f"  {n_has_result} with computed metrics, {n_no_result} without")
    print(f"  Columns: {list(out_df.columns)}")

    # Quick sanity check
    print("\nSanity check — odepe_polish success@10% by noise:")
    for noise in sorted(out_df['noise'].unique()):
        sub = out_df[(out_df['run'] == 'odepe_polish') & (out_df['noise'] == noise)]
        rate = sub['success_at_10pct'].mean() * 100
        print(f"  noise={noise}: {rate:.1f}%")


if __name__ == "__main__":
    main()
