#!/usr/bin/env python3
"""
Step 6a: Export result_odepe_best.csv into the paper pipeline format.

Copies the preprocessed results to ~/tex/ParameterEstimationGPR/dataset_package/combined_results.csv

Usage:
    python3 results/bilby_analysis/export_for_paper.py
"""

import os
import shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_CSV = os.path.join(SCRIPT_DIR, "result_odepe_best.csv")
PAPER_DIR = os.path.expanduser("~/tex/ParameterEstimationGPR/dataset_package")
OUTPUT_CSV = os.path.join(PAPER_DIR, "combined_results.csv")


def main():
    if not os.path.exists(PAPER_DIR):
        print(f"Error: Paper directory not found: {PAPER_DIR}")
        return

    if not os.path.exists(INPUT_CSV):
        print(f"Error: Input CSV not found: {INPUT_CSV}")
        return

    # Backup existing file if present
    if os.path.exists(OUTPUT_CSV):
        backup = OUTPUT_CSV + ".bak"
        shutil.copy2(OUTPUT_CSV, backup)
        print(f"  Backed up existing file to {backup}")

    shutil.copy2(INPUT_CSV, OUTPUT_CSV)
    print(f"Exported to: {OUTPUT_CSV}")

    # Verify
    import pandas as pd
    df = pd.read_csv(OUTPUT_CSV)
    print(f"  {len(df)} rows, {df['name'].nunique()} systems, {df['run'].nunique()} methods")


if __name__ == "__main__":
    main()
