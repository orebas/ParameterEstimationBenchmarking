#!/usr/bin/env python3
"""
Create a new benchmark directory with a frozen config snapshot and a stamped
MANIFEST.toml. Subsequent steps (`generate_data.py`, `generate_scripts.py`)
operate against the frozen snapshot, never against the master config.

Typical usage:

    python3 src/init_benchmark.py \
        --name numbat \
        --date 2026-05-06 \
        --phase preflight \
        --software odepe_v2_polish odepe_v2_nopolish amigo2 odepe_shade

This creates `benchmark_numbat_2026_05_06/` with:
  - config/config.json   (copied from master)
  - config/systems.json  (copied from master)
  - filetree/            (empty)
  - MANIFEST.toml        (stamped via `manifest.write_manifest`)

The flag `--phase` is recorded in the manifest only (preflight vs full); the
actual cell selection (instance subset, noise subset) is the responsibility
of downstream tooling, not this script.
"""
import argparse
import json
import shutil
import sys
from pathlib import Path

# Allow running as a module or a script.
sys.path.insert(0, str(Path(__file__).parent.resolve()))
from manifest import write_manifest  # noqa: E402
from shared import AVAILABLE_SOFTWARE, info, warn  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True,
                        help="Benchmark short name (e.g. 'numbat'). Output dir is "
                             "'benchmark_<name>_<date>'.")
    parser.add_argument("--date", required=True,
                        help="Date string for the benchmark dir, e.g. '2026-05-06'.")
    parser.add_argument("--phase", default="preflight",
                        choices=("smoke", "preflight", "full"),
                        help="Run phase tag (recorded in manifest only).")
    parser.add_argument("--software", nargs="+", required=True,
                        help="Software keys this benchmark will run. Validated against "
                             "AVAILABLE_SOFTWARE in src/shared.py.")
    parser.add_argument("--config", default="config/config.json",
                        help="Master config to freeze into the benchmark dir.")
    parser.add_argument("--systems", default="config/systems.json",
                        help="Master systems file to freeze.")
    parser.add_argument("--expected-cells", type=int, default=-1,
                        help="Expected total cell count (recorded in manifest).")
    parser.add_argument("--force", action="store_true",
                        help="Overwrite existing benchmark dir if present.")
    args = parser.parse_args()

    repo_root = Path(__file__).parent.parent.resolve()
    benchmark_dir = repo_root / f"benchmark_{args.name}_{args.date}"

    # Validate software list against shared.AVAILABLE_SOFTWARE.
    bad = [s for s in args.software if s not in AVAILABLE_SOFTWARE]
    if bad:
        warn(f"Unknown software keys: {bad}. Known: {AVAILABLE_SOFTWARE}")
        sys.exit(2)

    if benchmark_dir.exists():
        if args.force:
            warn(f"--force: removing existing {benchmark_dir}")
            shutil.rmtree(benchmark_dir)
        else:
            warn(f"Refusing to overwrite existing dir: {benchmark_dir}. Use --force.")
            sys.exit(1)

    info(f"Initializing benchmark: {benchmark_dir}")
    benchmark_dir.mkdir(parents=True)
    (benchmark_dir / "config").mkdir()
    (benchmark_dir / "filetree").mkdir()

    # Freeze the config + systems snapshots. Subsequent calls to generate_data.py /
    # generate_scripts.py should pass these frozen paths, NOT the master.
    src_config = repo_root / args.config
    src_systems = repo_root / args.systems
    if not src_config.exists():
        warn(f"Master config not found: {src_config}")
        sys.exit(2)
    if not src_systems.exists():
        warn(f"Master systems not found: {src_systems}")
        sys.exit(2)

    shutil.copy2(src_config, benchmark_dir / "config" / "config.json")
    shutil.copy2(src_systems, benchmark_dir / "config" / "systems.json")
    info(f"Froze config snapshot: {benchmark_dir / 'config'}")

    # Load the frozen config so the manifest sees the same values the run will see.
    with open(benchmark_dir / "config" / "config.json") as io:
        config = json.load(io)

    manifest_path = write_manifest(
        benchmark_dir=benchmark_dir,
        config=config,
        software_list=args.software,
        phase="init",
        expected_cells=args.expected_cells,
    )

    info(f"Wrote manifest: {manifest_path}")
    info("Next steps:")
    info(f"  python3 src/generate_data.py "
         f"{benchmark_dir / 'config' / 'config.json'} "
         f"{benchmark_dir / 'config' / 'systems.json'} "
         f"-d {benchmark_dir.name}")
    for sw in args.software:
        info(f"  python3 src/generate_scripts.py {benchmark_dir} -s {sw} -r {sw}_run")


if __name__ == "__main__":
    main()
