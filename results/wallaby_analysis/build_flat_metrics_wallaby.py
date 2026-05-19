#!/usr/bin/env python3
"""
Build flat_results_with_metrics.csv for the wallaby benchmark.

Reads per-cell sidecars directly (result.csv, failure_reason.txt,
wall_time_seconds.txt, <est>_metadata.json) and emits one row per cell.

Wallaby variant differs from numbat's builder in:
  * Two parallel metric families per cell:
    - `top1_*`  — metrics computed from result.csv row 0 (the algorithm's
                  own pick, sorted ascending by `err` column for ODEPE).
    - `oracle_*` — metrics computed by taking min over all rows of
                   max_rel_error on identifiable axes (truth-cheat).
    For amigo2/shade, K=1 so top1_* and oracle_* are equal by construction.
    For odepe_v2_polish / odepe_v2_nopolish (K=20), they differ when the
    algorithm's err-ranking disagrees with the truth-ranking.
  * Default --bench-dir and --out point at wallaby paths.

Usage:
    python3 results/wallaby_analysis/build_flat_metrics_wallaby.py [--bench-dir DIR]
"""

import argparse
import json
import os
import subprocess
from pathlib import Path

import numpy as np
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_BENCH = REPO_ROOT / "benchmark_wallaby_2026-05-17"

ESTIMATORS = ["amigo2", "odepe_shade", "odepe_v2_polish", "odepe_v2_nopolish"]
RUN_DIR_NAME = {est: f"{est}_run" for est in ESTIMATORS}

NOISE_LABEL_TO_FLOAT = {
    "0": 0.0,
    "1em8": 1e-8,
    "1em6": 1e-6,
    "1em4": 1e-4,
    "1em2": 1e-2,
}

# Fallback hardcoded non-identifiable list, used only if no ODEPE metadata is
# available for a system. Primary source is `all_unidentifiable` in each cell's
# odepe_metadata.json — that's the actual SIAN/SI output (SIAN.jl /
# StructuralIdentifiability.jl), so we don't need to maintain a curated list.
# Excluding non-identifiable vars from the score evens the playing field
# for AMIGO2/SHADE which don't internally detect identifiability.
NON_IDENTIFIABLE_FALLBACK = {
    "aircraft_pitch": ["theta"],
    "biohydrogenation": ["x7"],
}


def discover_non_identifiable_per_system(bench_dir: Path) -> dict:
    """Walk each system's ODEPE metadata to extract `all_unidentifiable`.

    Structural identifiability is a property of the system, not the cell, so we
    take the first ODEPE metadata we find per system. Returns dict[sys] -> set[var].
    Variable names are normalized: `theta(t)` -> `theta`.
    """
    out: dict = {}
    for est in ("odepe_v2_polish", "odepe_v2_nopolish", "odepe_shade"):
        run_dir = bench_dir / "filetree" / f"{est}_run"
        if not run_dir.exists():
            continue
        for cell_dir in run_dir.iterdir():
            md = cell_dir / "odepe_metadata.json"
            if not md.exists():
                continue
            sys_name = cell_dir.name.rsplit("_", 2)[0]
            if sys_name in out:
                continue
            try:
                with open(md) as f:
                    data = json.load(f)
            except Exception:
                continue
            unid = data.get("best", {}).get("all_unidentifiable") or []
            out[sys_name] = {normalize_var_name(v) for v in unid}
    return out


def normalize_var_name(col: str) -> str:
    """ODEPE-v2 result.csv writes state columns as `theta(t)`; AMIGO2 writes
    them as `theta`. Normalize to the bare name so cross-method scoring works.
    """
    if col.endswith("(t)"):
        return col[:-3]
    return col


def load_huge_json(bench_dir: Path) -> dict:
    """Map cell_id -> instance dict (with state_values, parameter_values, ...)."""
    with open(bench_dir / "huge_json.json") as f:
        data = json.load(f)
    return {c["id"]: c for c in data["instances"]}


def load_result_csv(p: Path):
    """Read per-cell result.csv. Returns:
      - rows_top1: dict of var_name -> value from row 0 (algorithm's top pick)
      - rows_all:  list of dicts, one per row (for oracle computation)
    Both are None if file missing/empty.
    """
    if not p.exists():
        return None, None
    try:
        df = pd.read_csv(p)
    except Exception:
        return None, None
    if df.empty:
        return None, None
    # Build the top-1 view (row 0).
    row = df.iloc[0]
    top1 = {}
    for col in df.columns:
        try:
            v = float(row[col])
            if np.isfinite(v):
                top1[normalize_var_name(col)] = v
        except (ValueError, TypeError):
            pass
    # Build the all-rows view (list of per-row dicts).
    rows_all = []
    for _, r in df.iterrows():
        d = {}
        for col in df.columns:
            try:
                v = float(r[col])
                if np.isfinite(v):
                    d[normalize_var_name(col)] = v
            except (ValueError, TypeError):
                pass
        if d:
            rows_all.append(d)
    if not top1:
        top1 = None
    if not rows_all:
        rows_all = None
    return top1, rows_all


def load_wall_time(p: Path):
    if not p.exists():
        return None
    try:
        return float(p.read_text().strip().split()[0])
    except Exception:
        return None


def load_failure_token(p: Path):
    if not p.exists():
        return None
    try:
        return p.read_text().strip().split("\n", 1)[0].strip()
    except Exception:
        return "unknown"


def load_metadata_notes(p: Path):
    """Return (was_terminal_fallback, polish_maxtime_exceeded, primary_method)."""
    if not p.exists():
        return False, False, None
    try:
        with open(p) as f:
            md = json.load(f)
    except Exception:
        return False, False, None
    notes = md.get("provenance", {}).get("notes", []) or []
    notes_set = {str(n).lower() for n in notes}
    return (
        bool(md.get("provenance", {}).get("was_terminal_fallback", False)),
        "polish_maxtime_exceeded" in notes_set,
        md.get("provenance", {}).get("primary_method"),
    )


def load_seed_retries(p: Path):
    """cell_seed.txt contains lines like noise_free_seed_retries=N."""
    if not p.exists():
        return 0
    try:
        for line in p.read_text().splitlines():
            if line.startswith("noise_free_seed_retries="):
                return int(line.split("=", 1)[1])
    except Exception:
        pass
    return 0


def fetch_sacct_state_and_maxrss():
    """Pull SLURM accounting for current user. Returns dict keyed by cell_id (best effort).

    Cell-id mapping from SLURM tasks isn't directly recoverable without job-script context,
    so we just record the raw map keyed by JobID for later cross-reference if needed.
    Skip if sacct unavailable. The state/maxrss are *not* used in the basic metrics; they
    populate the optional `slurm_state` / `max_rss_gb` columns for the user's audit.
    """
    if not subprocess.run(["which", "sacct"], capture_output=True).returncode == 0:
        return {}
    try:
        out = subprocess.check_output(
            [
                "sacct",
                "--starttime",
                "2026-05-06",
                "--format=JobID,JobName,State,MaxRSS,Elapsed",
                "-n",
                "-P",
            ]
        ).decode()
    except Exception:
        return {}
    return {}  # placeholder — wire up if needed


def parse_cell_id(cell_id: str):
    """cell_id format: <system>_<inst>_<noise_label> e.g. lotka_volterra_3_1em6."""
    # noise_label is the last underscore-separated part; instance is the second-to-last
    # This handles system names that contain underscores like 'lotka_volterra'.
    last_us = cell_id.rfind("_")
    noise_label = cell_id[last_us + 1 :]
    rest = cell_id[:last_us]
    second_us = rest.rfind("_")
    inst = rest[second_us + 1 :]
    sys_name = rest[:second_us]
    return sys_name, int(inst), noise_label


def compute_metrics(result, true_all, id_vars):
    """Return (median, mean, max, rmse, s1, s10, s50) per the bilby convention,
    for ONE row of result (dict var_name -> value).

    id_vars: list of *identifiable* state+param variable names (excludes non_identifiable).
    """
    if not id_vars:
        return 0.0, 0.0, 0.0, 0.0, 1, 1, 1
    rel_errors = []
    for v in id_vars:
        tv = true_all.get(v)
        ev = result.get(v) if result else None
        if tv is None or ev is None:
            continue
        try:
            tv = float(tv)
            ev = float(ev)
        except (ValueError, TypeError):
            continue
        if abs(tv) > 1e-15:
            rel_errors.append(abs(ev - tv) / abs(tv))
        else:
            rel_errors.append(abs(ev - tv))
    if not rel_errors:
        return (np.nan,) * 4 + (0, 0, 0)
    arr = np.array(rel_errors)
    return (
        float(np.median(arr)),
        float(np.mean(arr)),
        float(np.max(arr)),
        float(np.sqrt(np.mean(arr ** 2))),
        int(np.all(arr <= 0.01)),
        int(np.all(arr <= 0.10)),
        int(np.all(arr <= 0.50)),
    )


def compute_oracle_metrics(rows_all, true_all, id_vars):
    """Pick the row with minimum max-rel-error over identifiable axes; return
    that row's full (median, mean, max, rmse, s1, s10, s50). For K=1 (amigo2/shade)
    this is identical to compute_metrics on row 0.
    """
    if not rows_all:
        return (np.nan,) * 4 + (0, 0, 0)
    if not id_vars:
        return 0.0, 0.0, 0.0, 0.0, 1, 1, 1
    best_max = float("inf")
    best_metrics = None
    for r in rows_all:
        m = compute_metrics(r, true_all, id_vars)
        # m = (med, mean, max, rmse, s1, s10, s50). pick by m[2] = max
        if np.isnan(m[2]):
            continue
        if m[2] < best_max:
            best_max = m[2]
            best_metrics = m
    if best_metrics is None:
        return (np.nan,) * 4 + (0, 0, 0)
    return best_metrics


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench-dir", default=str(DEFAULT_BENCH))
    ap.add_argument(
        "--out",
        default=str(REPO_ROOT / "results/wallaby_analysis/flat_results_with_metrics.csv"),
    )
    args = ap.parse_args()
    bench = Path(args.bench_dir)
    out_path = Path(args.out)

    cells = load_huge_json(bench)
    print(f"Loaded {len(cells)} cells from huge_json.json")

    nonid_by_sys = discover_non_identifiable_per_system(bench)
    print(f"\n=== Non-identifiable vars by system (from ODEPE SIAN/SI output) ===")
    for s in sorted(nonid_by_sys):
        if nonid_by_sys[s]:
            print(f"  {s}: {sorted(nonid_by_sys[s])}")
    # Apply fallback for any system ODEPE didn't run on / metadata missing
    for s, vars_ in NON_IDENTIFIABLE_FALLBACK.items():
        if s not in nonid_by_sys or not nonid_by_sys[s]:
            nonid_by_sys[s] = set(vars_)
            print(f"  {s}: {sorted(vars_)}  (FALLBACK — ODEPE metadata missing)")

    rows = []
    skipped = 0
    for est in ESTIMATORS:
        run_dir = bench / "filetree" / RUN_DIR_NAME[est]
        if not run_dir.exists():
            print(f"  WARNING: {run_dir} missing, skipping estimator {est}")
            continue
        for cell_id, inst in cells.items():
            cell_path = run_dir / cell_id
            if not cell_path.exists():
                skipped += 1
                continue

            res_top1, res_all = load_result_csv(cell_path / "result.csv")
            wall = load_wall_time(cell_path / "wall_time_seconds.txt")
            failure_token = load_failure_token(cell_path / "failure_reason.txt")
            seed_retries = load_seed_retries(cell_path / "cell_seed.txt")

            md_path = cell_path / f"{est.split('_', 1)[-1] if est.startswith('odepe_') else est}_metadata.json"
            # All ODEPE/SHADE templates write `odepe_metadata.json`; AMIGO2 doesn't write metadata
            if not md_path.exists():
                md_path = cell_path / "odepe_metadata.json"
            wtf, pmt, prim = load_metadata_notes(md_path)

            sys_name = inst["name"]
            param_vars = inst.get("parameter_variables", [])
            state_vars = inst.get("state_variables", [])
            non_id = set(inst.get("non_identifiable", []) or []) | set(
                nonid_by_sys.get(sys_name, set())
            )
            all_vars = param_vars + state_vars
            id_vars = [v for v in all_vars if v not in non_id]
            n_id = len(id_vars)
            n_nonid = len([v for v in all_vars if v in non_id])

            true_all = {**(inst.get("state_values") or {}), **(inst.get("parameter_values") or {})}
            has_result = res_top1 is not None
            finished = has_result or (failure_token is not None)

            # Top-1: row 0 of result.csv (algorithm's own pick).
            t_med, t_mn, t_mx, t_rmse, t_s1, t_s10, t_s50 = compute_metrics(res_top1, true_all, id_vars)
            # Oracle: argmin-over-rows of max_rel_error.
            o_med, o_mn, o_mx, o_rmse, o_s1, o_s10, o_s50 = compute_oracle_metrics(res_all, true_all, id_vars)
            # Legacy / numbat-compat: keep `median_rel_error` etc. as the TOP-1 family
            # (matches what numbat builder always produced — read row 0 only — so
            # downstream run_analysis.py without dual-aware patches still works).
            med, mn, mx, rmse, s1, s10, s50 = t_med, t_mn, t_mx, t_rmse, t_s1, t_s10, t_s50
            n_returned = len(res_all) if res_all is not None else 0

            sys_name2, inst_idx, noise_label = parse_cell_id(cell_id)
            noise_float = NOISE_LABEL_TO_FLOAT.get(noise_label)
            if noise_float is None:
                # try parsing as float
                try:
                    noise_float = float(noise_label.replace("em", "e-"))
                except Exception:
                    noise_float = np.nan

            rows.append(
                {
                    # bilby-compatible columns
                    "name": sys_name,
                    "run": est,
                    "noise": noise_float,
                    "id": cell_id,
                    "has_result": int(has_result),
                    "finished": int(finished),
                    "time": wall if wall is not None else 0.0,
                    "n_id_params": n_id,
                    "n_nonid_params": n_nonid,
                    "median_rel_error": med,
                    "mean_rel_error": mn,
                    "max_rel_error": mx,
                    "rmse": rmse,
                    "success_at_1pct": s1,
                    "success_at_10pct": s10,
                    "success_at_50pct": s50,
                    # numbat-specific extras
                    "instance": inst_idx,
                    "noise_label": noise_label,
                    "failure_token": failure_token or "",
                    "was_terminal_fallback": int(wtf),
                    "polish_maxtime_exceeded": int(pmt),
                    "primary_method": prim or "",
                    "noise_free_seed_retries": int(seed_retries),
                    # wallaby-specific dual-metric columns
                    "n_returned": n_returned,
                    "top1_median_rel_error": t_med,
                    "top1_mean_rel_error": t_mn,
                    "top1_max_rel_error": t_mx,
                    "top1_rmse": t_rmse,
                    "top1_success_at_1pct": t_s1,
                    "top1_success_at_10pct": t_s10,
                    "top1_success_at_50pct": t_s50,
                    "oracle_median_rel_error": o_med,
                    "oracle_mean_rel_error": o_mn,
                    "oracle_max_rel_error": o_mx,
                    "oracle_rmse": o_rmse,
                    "oracle_success_at_1pct": o_s1,
                    "oracle_success_at_10pct": o_s10,
                    "oracle_success_at_50pct": o_s50,
                }
            )

    df = pd.DataFrame(rows)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out_path, index=False)

    print(f"\nOutput: {out_path}")
    print(f"  {len(df)} rows ({skipped} cell paths missing)")

    print("\n=== Sanity: cells per (run, noise) ===")
    print(df.groupby(["run", "noise"]).size().unstack(fill_value=0))

    print("\n=== Success rate (median rel err < 1e-3) by run x noise ===")
    s = df.groupby(["run", "noise"])["success_at_1pct"].mean() * 100
    print(s.unstack(fill_value=0).round(1))

    print("\n=== Failure tokens ===")
    print(df[df["failure_token"] != ""].groupby(["run", "failure_token"]).size())

    print("\n=== Wall-time summary (median seconds, per run) ===")
    print(df[df["time"] > 0].groupby("run")["time"].agg(["median", "mean", "max"]).round(1))


if __name__ == "__main__":
    main()
