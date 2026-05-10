#!/usr/bin/env python3
"""
Step 0: Load bilby result.csv (all instances, all systems).

Usage:
    python3 results/bilby_analysis/collect_and_filter.py
"""

import os
import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_CSV = os.path.expanduser(
    "~/ParameterEstimationBenchmarking/benchmark_bilby_2026_03_09/result.csv"
)
OUTPUT_CSV = os.path.join(SCRIPT_DIR, "result_filtered.csv")


def extract_instance_number(row):
    """Extract instance number from id by stripping the system name prefix."""
    name = row["name"]
    suffix = row["id"][len(name) + 1:]  # strip "{name}_"
    parts = suffix.split("_")
    return int(parts[0])


def main():
    print("Loading data...")
    df = pd.read_csv(INPUT_CSV)
    print(f"  {len(df)} rows loaded")

    df.to_csv(OUTPUT_CSV, index=False)
    print(f"\nOutput: {OUTPUT_CSV}")
    print(f"  {len(df)} rows")
    print(f"  Systems: {sorted(df['name'].unique())}")
    print(f"  Runs: {sorted(df['run'].unique())}")

    # Verify expected count
    n_systems = df["name"].nunique()
    n_noises = df["noise"].nunique()
    n_instances = 8
    n_runs = df["run"].nunique()
    expected = n_systems * n_noises * n_instances * n_runs
    print(f"\n  Expected: {n_systems} systems x {n_noises} noises x {n_instances} instances x {n_runs} runs = {expected}")
    print(f"  Actual: {len(df)}")


if __name__ == "__main__":
    main()
