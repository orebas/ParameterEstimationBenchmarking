#!/usr/bin/env python3
"""Prep one probe dir per regression cell.

Reads regression_trajectory.csv. For every cell in
{new_regression_vs_12, persistent_regression, partial_recovery}:

  - Creates benchmark_numbat_2026-05-13/probes/<run>__<cell>/dump/
  - Symlinks data.csv from the main run
  - Copies script.jl, then patches it:
      * branch_top_k = 0          (disable cap)
      * branch_cluster_eps unchanged (0.001)
      * dump_polished_path     = "<probe_dir>/polished_dump.csv"
      * dump_raw_candidates_path = "<probe_dir>/raw_candidates.csv"

Writes probe_dirs.txt with one absolute path per line (for the SLURM array driver).
"""
import csv
import os
import re
import shutil
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent
TRAJ = REPO / "results/numbat_analysis/three_way/regression_trajectory.csv"
BENCH = REPO / "benchmark_numbat_2026-05-13"
PROBES = BENCH / "probes"
PROBES.mkdir(exist_ok=True)
LIST_PATH = REPO / "results/numbat_analysis/three_way/probe_dirs.txt"

CATEGORIES = {"new_regression_vs_12", "persistent_regression", "partial_recovery"}


def patch_script(text: str, probe_dir: Path) -> str:
    """Inject branch_top_k=0 + dump paths into a numbat v2 script.jl.

    The v2 template doesn't explicitly set branch_top_k / dump_* — they
    inherit from ODEPE defaults. We insert a block right after the
    polish_maxtime line, which is reliably present.
    """
    inject = (
        f'    branch_top_k = 0,\n'
        f'    dump_polished_path = "{probe_dir}/polished_dump.csv",\n'
        f'    dump_raw_candidates_path = "{probe_dir}/raw_candidates.csv",\n'
    )
    if "dump_polished_path" in text:
        return text  # already patched

    # Find polish_maxtime line and insert AFTER it
    new_text, n_subs = re.subn(
        r"(polish_maxtime\s*=\s*[^,]+,)\n",
        r"\1\n" + inject,
        text, count=1,
    )
    if n_subs == 0:
        raise RuntimeError(f"could not find polish_maxtime line to anchor injection in script for {probe_dir}")
    return new_text


def main():
    rows = list(csv.DictReader(open(TRAJ)))
    targets = [r for r in rows if r["category"] in CATEGORIES]
    print(f"Found {len(targets)} regression cells to probe.")

    probe_dirs = []
    created, skipped = 0, 0
    for r in targets:
        cell_id = r["id"]
        run = r["run"]
        src_dir = BENCH / "filetree" / f"{run}_run" / cell_id
        if not src_dir.exists():
            print(f"  SKIP (source missing): {run}/{cell_id}")
            continue

        probe_name = f"{run}__{cell_id}"
        probe_dir = PROBES / probe_name / "dump"
        probe_dir.mkdir(parents=True, exist_ok=True)

        # data.csv: symlink
        data_target = probe_dir / "data.csv"
        if not data_target.exists():
            os.symlink((src_dir / "data.csv").resolve(), data_target)

        # script.jl: copy + patch
        script_target = probe_dir / "script.jl"
        if script_target.exists():
            skipped += 1
        else:
            text = (src_dir / "script.jl").read_text()
            text = patch_script(text, probe_dir.resolve())
            script_target.write_text(text)
            created += 1

        probe_dirs.append(str(probe_dir.resolve()))

    LIST_PATH.write_text("\n".join(probe_dirs) + "\n")
    print(f"Created {created} new probe scripts, {skipped} pre-existing.")
    print(f"Wrote {LIST_PATH}: {len(probe_dirs)} probe dirs.")


if __name__ == "__main__":
    main()
