#!/usr/bin/env python3
"""
Filter Non-Identifiable Parameters

Removes non-identifiable parameters/states from the combined dataset.
For biohydrogenation, removes x7 (non-identifiable state) from:
- result column
- true_states column

All other systems are unchanged.

Usage:
    python3 filter_nonidentifiable.py

Input:  combined_results.csv
Output: combined_results_filtered.csv
"""

import pandas as pd
import ast
import sys

# Non-identifiable quantities by system
NON_IDENTIFIABLE = {
    'biohydrogenation': ['x7']
}


def parse_and_filter_result(result_str, system_name):
    """Parse result column and remove non-identifiable entries."""
    if pd.isna(result_str) or result_str == '' or result_str == '[]':
        return result_str

    # Get non-identifiable list for this system
    non_id = NON_IDENTIFIABLE.get(system_name, [])
    if not non_id:
        return result_str  # No filtering needed

    try:
        result_list = ast.literal_eval(result_str)

        # Filter out non-identifiable parameters
        filtered_list = [
            item for item in result_list
            if not (isinstance(item, list) and len(item) >= 1 and item[0] in non_id)
        ]

        return str(filtered_list)
    except:
        # If parsing fails, return original
        return result_str


def parse_and_filter_dict(dict_str, system_name):
    """Parse dict column (true_states) and remove non-identifiable entries."""
    if pd.isna(dict_str) or dict_str == '' or dict_str == '{}':
        return dict_str

    # Get non-identifiable list for this system
    non_id = NON_IDENTIFIABLE.get(system_name, [])
    if not non_id:
        return dict_str  # No filtering needed

    try:
        data_dict = ast.literal_eval(dict_str)

        # Filter out non-identifiable keys
        filtered_dict = {k: v for k, v in data_dict.items() if k not in non_id}

        return str(filtered_dict)
    except:
        # If parsing fails, return original
        return dict_str


def filter_dataset(input_file, output_file):
    """Filter non-identifiable parameters from dataset."""

    print(f"Loading {input_file}...")
    df = pd.read_csv(input_file)

    print(f"Total rows: {len(df)}")

    # Count affected rows
    biohydro_count = (df['name'] == 'biohydrogenation').sum()
    print(f"Biohydrogenation rows to filter: {biohydro_count}")

    # Apply filtering
    print("Filtering result column...")
    df['result'] = df.apply(
        lambda row: parse_and_filter_result(row['result'], row['name']),
        axis=1
    )

    print("Filtering true_states column...")
    df['true_states'] = df.apply(
        lambda row: parse_and_filter_dict(row['true_states'], row['name']),
        axis=1
    )

    # Save
    print(f"Saving to {output_file}...")
    df.to_csv(output_file, index=False)

    print("Done!")
    print()
    print("=" * 70)
    print("FILTERING SUMMARY")
    print("=" * 70)
    print(f"Input:  {input_file}")
    print(f"Output: {output_file}")
    print()
    print("Non-identifiable parameters removed:")
    for system, params in NON_IDENTIFIABLE.items():
        print(f"  {system}: {params}")
    print()
    print(f"Rows affected: {biohydro_count} (biohydrogenation only)")
    print(f"Total rows written: {len(df)}")
    print("=" * 70)


if __name__ == '__main__':
    filter_dataset('combined_results.csv', 'combined_results_filtered.csv')
