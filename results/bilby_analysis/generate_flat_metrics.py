#!/usr/bin/env python3
"""
Step 3: Compute per-row error metrics from preprocessed results.

Scores both parameters AND initial conditions (merged), excluding
non-identifiable variables.

Usage:
    python3 results/bilby_analysis/generate_flat_metrics.py
"""

import ast
import json
import os
import re
import numpy as np
import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_CSV = os.path.join(SCRIPT_DIR, "result_odepe_best.csv")
SYSTEMS_JSON = os.path.expanduser(
    "~/ParameterEstimationBenchmarking/benchmark_bilby_2026_03_09/config/systems.json"
)
OUTPUT_CSV = os.path.join(SCRIPT_DIR, "flat_results_with_metrics.csv")

NON_IDENTIFIABLE = {
    "aircraft_pitch": ["theta"],
    "biohydrogenation": ["x7"],
}


def _sanitize_for_literal_eval(s):
    """Replace bare nan/inf/-inf with None so ast.literal_eval can parse."""
    s = re.sub(r'\bnan\b', 'None', s)
    s = re.sub(r'\binf\b', 'None', s)
    s = re.sub(r'-None', 'None', s)  # fix -inf that became -None
    return s


def _first_finite(values):
    """Return the first finite float from a list of candidate values, or None."""
    for v in values:
        if v is None:
            continue
        try:
            fv = float(v)
            if np.isfinite(fv):
                return fv
        except (ValueError, TypeError):
            continue
    return None


def parse_result(result_str):
    if pd.isna(result_str) or result_str in ("", "[]", "None"):
        return None
    try:
        data = ast.literal_eval(_sanitize_for_literal_eval(result_str))
        if not data:
            return None
        result = {}
        for item in data:
            name = item[0]
            if len(item) > 2:
                result[name] = _first_finite(item[1:])
            elif len(item) == 2:
                try:
                    fv = float(item[1]) if item[1] is not None else None
                    result[name] = fv if (fv is not None and np.isfinite(fv)) else None
                except (ValueError, TypeError):
                    result[name] = None
        return result
    except Exception:
        return None


def parse_true_params(params_str):
    if pd.isna(params_str) or params_str in ("", "None"):
        return None
    try:
        d = ast.literal_eval(_sanitize_for_literal_eval(params_str))
        if isinstance(d, dict):
            return {k: v for k, v in d.items() if v is not None}
        return d
    except Exception:
        return None


def main():
    print("Loading data...")
    df = pd.read_csv(INPUT_CSV)
    print(f"  {len(df)} rows loaded")

    with open(SYSTEMS_JSON) as f:
        systems_data = json.load(f)
    sys_info = {s["name"]: s for s in systems_data["systems"]}

    rows = []
    n_has_result = 0
    n_no_result = 0

    for idx, row in df.iterrows():
        name = row["name"]
        run = row["run"]
        noise = row["noise"]
        instance_id = row["id"]
        has_result = bool(row["has_result"])
        finished = bool(row["finished"])
        time_val = float(row["time"]) if pd.notna(row["time"]) else 0.0

        si = sys_info.get(name, {})
        param_vars = si.get("parameter_variables", [])
        state_vars = si.get("state_variables", [])
        all_vars = param_vars + state_vars

        non_id_vars = NON_IDENTIFIABLE.get(name, [])
        id_vars = [v for v in all_vars if v not in non_id_vars]
        n_id = len(id_vars)
        n_nonid = len([v for v in all_vars if v in non_id_vars])

        metrics = {
            "name": name,
            "run": run,
            "noise": noise,
            "id": instance_id,
            "has_result": int(has_result),
            "finished": int(finished),
            "time": time_val,
            "n_id_params": n_id,
            "n_nonid_params": n_nonid,
            "median_rel_error": np.nan,
            "mean_rel_error": np.nan,
            "max_rel_error": np.nan,
            "rmse": np.nan,
            "success_at_1pct": 0,
            "success_at_10pct": 0,
            "success_at_50pct": 0,
        }

        if has_result:
            result = parse_result(row["result"])
            true_params = parse_true_params(row["true_parameters"]) or {}
            true_states = parse_true_params(row.get("true_states", "")) or {}
            true_all = {**true_states, **true_params}

            if not id_vars:
                metrics["median_rel_error"] = 0.0
                metrics["mean_rel_error"] = 0.0
                metrics["max_rel_error"] = 0.0
                metrics["rmse"] = 0.0
                metrics["success_at_1pct"] = 1
                metrics["success_at_10pct"] = 1
                metrics["success_at_50pct"] = 1
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
                    metrics["median_rel_error"] = float(np.median(arr))
                    metrics["mean_rel_error"] = float(np.mean(arr))
                    metrics["max_rel_error"] = float(np.max(arr))
                    metrics["rmse"] = float(np.sqrt(np.mean(arr ** 2)))
                    metrics["success_at_1pct"] = int(np.all(arr <= 0.01))
                    metrics["success_at_10pct"] = int(np.all(arr <= 0.10))
                    metrics["success_at_50pct"] = int(np.all(arr <= 0.50))
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

    print("\nSanity check — success@10% by method:")
    for run in sorted(out_df["run"].unique()):
        sub = out_df[out_df["run"] == run]
        rate = sub["success_at_10pct"].mean() * 100
        print(f"  {run}: {rate:.1f}%")

    for sys_name, ni_vars in NON_IDENTIFIABLE.items():
        sub = out_df[out_df["name"] == sys_name]
        if len(sub) > 0:
            row0 = sub.iloc[0]
            print(f"\n  {sys_name}: n_id={int(row0['n_id_params'])}, n_nonid={int(row0['n_nonid_params'])}")


if __name__ == "__main__":
    main()
