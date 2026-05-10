#!/usr/bin/env python3
"""
Step 2: Reduce ODEPE multi-candidate results to single best candidate.

For ODEPE rows, selects the candidate minimizing mean relative error
on identifiable variables only. SciML/AMIGO2 rows pass through unchanged.

Usage:
    python3 results/bilby_analysis/select_odepe_best.py
"""

import ast
import json
import os
import re
import numpy as np
import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_CSV = os.path.join(SCRIPT_DIR, "result_filtered.csv")
SYSTEMS_JSON = os.path.expanduser(
    "~/ParameterEstimationBenchmarking/benchmark_bilby_2026_03_09/config/systems.json"
)
OUTPUT_CSV = os.path.join(SCRIPT_DIR, "result_odepe_best.csv")

NON_IDENTIFIABLE = {
    "aircraft_pitch": ["theta"],
    "biohydrogenation": ["x7"],
}


def load_system_vars(systems_json):
    with open(systems_json) as f:
        data = json.load(f)
    info = {}
    for s in data["systems"]:
        name = s["name"]
        all_vars = s["parameter_variables"] + s["state_variables"]
        non_id = NON_IDENTIFIABLE.get(name, [])
        id_vars = [v for v in all_vars if v not in non_id]
        info[name] = {"all_vars": all_vars, "id_vars": id_vars}
    return info


def _sanitize_for_literal_eval(s):
    """Replace bare nan/inf/-inf with None so ast.literal_eval can parse."""
    s = re.sub(r'\bnan\b', 'None', s)
    s = re.sub(r'\binf\b', 'None', s)
    s = re.sub(r'-None', 'None', s)  # fix -inf that became -None
    return s


def parse_result_raw(result_str):
    if pd.isna(result_str) or result_str in ("", "[]", "None"):
        return None
    try:
        data = ast.literal_eval(_sanitize_for_literal_eval(result_str))
        return data if data else None
    except Exception:
        return None


def parse_true_values(params_str):
    if pd.isna(params_str) or params_str in ("", "None"):
        return {}
    try:
        d = ast.literal_eval(_sanitize_for_literal_eval(params_str))
        if isinstance(d, dict):
            return {k: v for k, v in d.items() if v is not None}
        return d if d else {}
    except Exception:
        return {}


def select_best_candidate(result_data, true_all, id_vars):
    if not result_data or not true_all or not id_vars:
        return result_data

    n_candidates = 1
    for item in result_data:
        if len(item) > 2:
            n_candidates = len(item) - 1
            break

    if n_candidates <= 1:
        return result_data

    best_idx = 0
    best_error = float("inf")

    for ci in range(n_candidates):
        rel_errors = []
        for item in result_data:
            name = item[0]
            if name not in id_vars:
                continue
            true_val = true_all.get(name)
            if true_val is None:
                continue
            tv = float(true_val)
            val_idx = min(ci + 1, len(item) - 1)
            try:
                if item[val_idx] is None:
                    rel_errors.append(float("inf"))
                    continue
                ev = float(item[val_idx])
                if not np.isfinite(ev):
                    rel_errors.append(float("inf"))
                    continue
            except (ValueError, TypeError):
                rel_errors.append(float("inf"))
                continue
            if abs(tv) > 1e-15:
                rel_errors.append(abs(ev - tv) / abs(tv))
            else:
                rel_errors.append(abs(ev - tv))

        mean_err = np.mean(rel_errors) if rel_errors else float("inf")
        if mean_err < best_error:
            best_error = mean_err
            best_idx = ci

    selected = []
    for item in result_data:
        name = item[0]
        val_idx = min(best_idx + 1, len(item) - 1)
        selected.append([name, item[val_idx]])

    return selected


def main():
    print("Loading data...")
    df = pd.read_csv(INPUT_CSV)
    print(f"  {len(df)} rows loaded")

    sys_info = load_system_vars(SYSTEMS_JSON)

    n_selected = 0
    n_passthrough = 0

    for idx, row in df.iterrows():
        software = row.get("software", "")
        if software != "odepe":
            n_passthrough += 1
            continue

        if not row.get("has_result", False):
            n_passthrough += 1
            continue

        result_data = parse_result_raw(row["result"])
        if result_data is None:
            n_passthrough += 1
            continue

        name = row["name"]
        si = sys_info.get(name, {"id_vars": [], "all_vars": []})
        true_params = parse_true_values(row.get("true_parameters", ""))
        true_states = parse_true_values(row.get("true_states", ""))
        true_all = {**true_states, **true_params}

        selected = select_best_candidate(result_data, true_all, si["id_vars"])
        df.at[idx, "result"] = str(selected)
        n_selected += 1

    df.to_csv(OUTPUT_CSV, index=False)
    print(f"\nOutput: {OUTPUT_CSV}")
    print(f"  {len(df)} rows total")
    print(f"  {n_selected} ODEPE rows reduced to best candidate")
    print(f"  {n_passthrough} rows passed through unchanged")

    n_multi = 0
    for _, row in df[df["software"] == "odepe"].iterrows():
        result_data = parse_result_raw(row["result"])
        if result_data:
            for item in result_data:
                if len(item) > 2:
                    n_multi += 1
                    break
    print(f"  Remaining multi-valued ODEPE rows: {n_multi}")


if __name__ == "__main__":
    main()
