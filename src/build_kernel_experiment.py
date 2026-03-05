#!/usr/bin/env python3
"""
Build the kernel experiment data from the wombat benchmark.

Extracts 60 instances (10 systems x 3 runs x 2 noise levels) from
benchmark_wombat_2026_02_26, re-indexes them 0-59, copies data directories,
and writes a merged huge_json.json + config.json.

Re-indexed layout (alphabetical by system, noise=0 first):
  Indices 0-29:  noise=0
  Indices 30-59: noise=1em8
  Within each noise group: alphabetical by system, 3 runs each.
"""

import json
import os
import shutil
import sys
from pathlib import Path

# Source benchmark
WOMBAT_DIR = Path(os.path.expanduser(
    "~/ParameterEstimationBenchmarking/benchmark_wombat_2026_02_26"))

# Output directory
OUTPUT_DIR = Path(os.path.expanduser(
    "~/ParameterEstimationBenchmark-local/results/kernel_experiment"))

# Target systems (alphabetical)
TARGET_SYSTEMS = [
    "aircraft_pitch",
    "bicycle_model",
    "biohydrogenation",
    "crauste",
    "daisy_mamil3",
    "daisy_mamil4",
    "dc_motor",
    "fitzhugh_nagumo",
    "hiv",
    "vanderpol",
]

NUM_RUNS = 3
NOISE_LEVELS = ["0", "1em8"]


def main():
    # Load wombat huge_json
    wombat_json_path = WOMBAT_DIR / "huge_json.json"
    if not wombat_json_path.exists():
        print(f"ERROR: {wombat_json_path} not found")
        sys.exit(1)

    with open(wombat_json_path) as f:
        wombat_data = json.load(f)

    # Index instances by id for fast lookup
    instances_by_id = {inst["id"]: inst for inst in wombat_data["instances"]}

    # Build the ordered list of instance IDs we want
    # noise=0 first (indices 0-29), then noise=1em8 (indices 30-59)
    ordered_ids = []
    for noise in NOISE_LEVELS:
        for system in TARGET_SYSTEMS:
            for run in range(NUM_RUNS):
                instance_id = f"{system}_{run}_{noise}"
                ordered_ids.append(instance_id)

    assert len(ordered_ids) == 60, f"Expected 60 instances, got {len(ordered_ids)}"

    # Verify all exist
    missing = [iid for iid in ordered_ids if iid not in instances_by_id]
    if missing:
        print(f"ERROR: Missing instances in wombat data: {missing}")
        sys.exit(1)

    # Build re-indexed instances
    new_instances = []
    for new_idx, iid in enumerate(ordered_ids):
        inst = json.loads(json.dumps(instances_by_id[iid]))  # deep copy
        inst["index"] = new_idx
        new_instances.append(inst)

    # Write huge_json.json
    output_json = {"instances": new_instances}
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(OUTPUT_DIR / "huge_json.json", "w") as f:
        json.dump(output_json, f, indent=None)
    print(f"Wrote {OUTPUT_DIR / 'huge_json.json'} ({len(new_instances)} instances)")

    # Copy data directories
    src_data = WOMBAT_DIR / "filetree" / "data_noisy"
    dst_data = OUTPUT_DIR / "filetree" / "data_noisy"
    os.makedirs(dst_data, exist_ok=True)

    copied = 0
    for iid in ordered_ids:
        src_dir = src_data / iid
        dst_dir = dst_data / iid
        if dst_dir.exists():
            continue  # already copied
        shutil.copytree(src_dir, dst_dir)
        copied += 1
    print(f"Copied {copied} data directories to {dst_data}")

    # Write config.json
    config = {
        "NUM_TESTS": 3,
        "TIME_INTERVAL": [-1.0, 1.0],
        "PARAM_INTERVAL": [0.1, 0.9],
        "NUM_PTS": 1001,
        "ODEPE_POLISH": "false",
        "NOISE_LEVEL": {"0": 0, "1em8": 1e-8},
        "SEARCH_BOUNDS": [1e-5, 10.0],
        "POLISH_MAXTIME": 1200.0,
        "POLISH_DIVERGENCE_FACTOR": 10.0,
        "POLISH_STAGNATION_WINDOW": 50,
        "POLISH_ODE_MAXITERS": 20000,
        "NOISE_TYPE": "MULTIPLICATIVE",
        "DATA_DIR_NOISY": "data_noisy",
        "FILETREE": "filetree",
        "PATH_TO_AMIGO2": ""
    }
    config_dir = OUTPUT_DIR / "config"
    os.makedirs(config_dir, exist_ok=True)
    with open(config_dir / "config.json", "w") as f:
        json.dump(config, f, indent=4)
    print(f"Wrote {config_dir / 'config.json'}")

    print("\nDone! Next steps:")
    print("  cd ~/ParameterEstimationBenchmark-local")
    print("  for kernel in se rq se_plus_rq se_times_rq; do")
    print("    python3 src/generate_scripts.py results/kernel_experiment \\")
    print("      -s odepe_kernel_${kernel} -r odepe_kernel_${kernel} \\")
    print("      -c config/config.json")
    print("  done")


if __name__ == "__main__":
    main()
