#!/usr/bin/env python3
"""
Oracle-ranking audit: how much does ODEPE's truth-based final sort
(`oracle_sort_key` in analysis_utils.jl:426) inflate the headline numbers?

For each sampled cell we:
  1. Read all N rows of result.csv (each row is an (states, params) candidate)
  2. Compute max_rel_err vs ground truth per row  -> "oracle metric"
  3. Re-integrate the ODE forward with that row's (states, params) and
     compare to the observed data.csv  -> "data residual" (legitimate)
  4. Sort rows by data residual, record where the truth-best row lands
  5. For K = 1, 5, 10, 20, 50, 100: did truth-best end up in top-K?

Output: results/numbat_analysis/oracle_ranking_audit.csv

Usage:
    python3 results/numbat_analysis/oracle_ranking_audit.py \\
        [--sample N]       # default 50 cells
        [--cells comma,sep,list]  # override sample with explicit cells
"""

import argparse
import json
import multiprocessing as mp
import os
import re
import signal
import sys
import time
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import sympy as sp
from scipy.integrate import solve_ivp

warnings.filterwarnings("ignore")


class _IntegrationTimeout(Exception):
    pass


def _alarm_handler(signum, frame):
    raise _IntegrationTimeout()

# Worker-local parsed ODE state (set by _worker_init)
_W = {}

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BENCH = REPO_ROOT / "benchmark_numbat_2026-05-06"
OUT_CSV = REPO_ROOT / "results/numbat_analysis/oracle_ranking_audit.csv"

ESTIMATORS = ["odepe_v2_polish", "odepe_v2_nopolish"]


def normalize(col: str) -> str:
    return col[:-3] if col.endswith("(t)") else col


def parse_ode(inst: dict):
    """Build a (rhs_fn, observation_fns, state_order, param_order) closure for the cell.

    rhs_fn(t, y, p_arr) -> dy/dt array
    observation_fns: list of (name, fn(y_state, p_arr, t) -> scalar) — IN data.csv COLUMN ORDER,
                     i.e. inst["measurement_variables"]. The `measurements` dict can be in
                     a different order (e.g. ['y3','y1','y2']); data.csv is always in
                     `measurement_variables` order.
    """
    state_vars = inst["state_variables"]
    param_vars = inst["parameter_variables"]
    ode_strs = inst["ode_system"]
    meas_strs = inst["measurements"]
    # CRITICAL: data.csv column order follows measurement_variables, NOT measurements dict order.
    meas_var_order = inst.get("measurement_variables") or list(meas_strs.keys())

    t_sym = sp.Symbol("t")
    state_syms = [sp.Symbol(s) for s in state_vars]
    param_syms = [sp.Symbol(p) for p in param_vars]
    syms = [t_sym] + state_syms + param_syms

    rhs_exprs = []
    for s in state_vars:
        e = sp.sympify(ode_strs[s])
        rhs_exprs.append(e)
    rhs_lambdas = [sp.lambdify(syms, e, modules=["numpy"]) for e in rhs_exprs]

    def rhs_fn(t, y, p_arr):
        return np.array([f(t, *y, *p_arr) for f in rhs_lambdas])

    obs_lambdas = []
    for name in meas_var_order:
        if name not in meas_strs:
            continue
        e = sp.sympify(meas_strs[name])
        f = sp.lambdify(syms, e, modules=["numpy"])
        obs_lambdas.append((name, f))

    return rhs_fn, obs_lambdas, state_vars, param_vars


def integrate_and_score(rhs_fn, obs_lambdas, state_vars, param_vars,
                        t_grid, observed_data, ic_arr, p_arr,
                        rtol=1e-7, atol=1e-10, timeout_s=2):
    """Integrate ODE from t_grid[0] with given ICs+params, compute residual to data.

    observed_data: dict {obs_name: np.array shape (n_t,)}
    Returns: scalar residual = sum_obs sum_t (predicted - observed)**2 (sum-of-squares)
             OR np.inf on integration failure / overflow / timeout.
    """
    t_span = (t_grid[0], t_grid[-1])
    max_step = (t_span[1] - t_span[0]) / 50.0

    def safe_rhs(t, y):
        with np.errstate(over="raise", invalid="raise", divide="raise"):
            try:
                dy = rhs_fn(t, y, p_arr)
            except (FloatingPointError, OverflowError, ValueError):
                return np.full_like(y, 1e30)
        if not np.all(np.isfinite(dy)):
            return np.full_like(y, 1e30)
        return dy

    # Hard per-row wallclock cutoff via SIGALRM
    old_handler = signal.signal(signal.SIGALRM, _alarm_handler)
    signal.alarm(int(timeout_s) if timeout_s >= 1 else 1)
    try:
        try:
            # LSODA handles both stiff and non-stiff; RK45 fails on stiff systems like crauste
            sol = solve_ivp(
                safe_rhs, t_span, ic_arr,
                t_eval=t_grid, method="LSODA",
                rtol=rtol, atol=atol, max_step=max_step,
            )
        except _IntegrationTimeout:
            return np.inf
        except Exception:
            return np.inf
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)

    if not sol.success or sol.y.shape[1] != len(t_grid):
        return np.inf
    if not np.all(np.isfinite(sol.y)):
        return np.inf
    # Cap state magnitudes to prevent overflow downstream
    if np.max(np.abs(sol.y)) > 1e15:
        return np.inf
    Y = sol.y  # shape (n_states, n_t)
    total = 0.0
    with np.errstate(all="ignore"):
        for name, f in obs_lambdas:
            observed = observed_data.get(name)
            if observed is None:
                continue
            n_t = len(t_grid)
            try:
                predicted = np.array([f(t_grid[i], *Y[:, i], *p_arr) for i in range(n_t)])
            except Exception:
                return np.inf
            if not np.all(np.isfinite(predicted)):
                return np.inf
            if np.max(np.abs(predicted)) > 1e15:
                return np.inf
            d = predicted - observed
            total += float(np.sum(d * d))
            if not np.isfinite(total):
                return np.inf
    return total


def max_rel_err(true_dict: dict, est_dict: dict, id_vars: list) -> float:
    errs = []
    for v in id_vars:
        tv = true_dict.get(v)
        ev = est_dict.get(v)
        if tv is None or ev is None:
            continue
        if abs(tv) > 1e-15:
            errs.append(abs(ev - tv) / abs(tv))
        else:
            errs.append(abs(ev - tv))
    return max(errs) if errs else float("inf")


def build_observed_data(data_csv: Path, obs_names: list, subsample: int = 50):
    """data.csv has columns [t, y1, y2, ...]. Return (t_grid, {name: array}).
    Subsamples to ~`subsample` evenly spaced points to keep per-row integration fast.
    """
    df = pd.read_csv(data_csv, header=None)
    t_full = df.iloc[:, 0].to_numpy()
    if len(t_full) > subsample:
        idx = np.linspace(0, len(t_full) - 1, subsample).astype(int)
    else:
        idx = np.arange(len(t_full))
    t_grid = t_full[idx]
    obs = {}
    for i, name in enumerate(obs_names):
        if i + 1 < df.shape[1]:
            obs[name] = df.iloc[:, i + 1].to_numpy()[idx]
    return t_grid, obs


def discover_non_id(bench: Path) -> dict:
    """Same logic as build_flat_metrics — pull from any odepe_metadata.json."""
    out = {}
    for est in ("odepe_v2_polish", "odepe_v2_nopolish", "odepe_shade"):
        rd = bench / "filetree" / f"{est}_run"
        if not rd.exists(): continue
        for cell in rd.iterdir():
            md = cell / "odepe_metadata.json"
            if not md.exists(): continue
            sn = cell.name.rsplit("_", 2)[0]
            if sn in out: continue
            try:
                d = json.load(open(md))
            except Exception:
                continue
            unid = d.get("best", {}).get("all_unidentifiable") or []
            out[sn] = {normalize(v) for v in unid}
    return out


def pick_sample(bench: Path, instances: dict, n: int, exclude_systems=None):
    """Stratified sample across (system, noise) buckets. Restrict to cells with full result.csv."""
    rd = bench / "filetree" / "odepe_v2_polish_run"
    valid = []
    for cell_id, inst in instances.items():
        if exclude_systems and inst["name"] in exclude_systems:
            continue
        rc = rd / cell_id / "result.csv"
        if not rc.exists():
            continue
        try:
            with open(rc) as f:
                first = f.readline()
                second = f.readline()
            if not (first and second):
                continue
        except Exception:
            continue
        valid.append(cell_id)
    # Stratify by (system, noise): pick at most n//(n_buckets) per bucket
    by_bucket = {}
    for cid in valid:
        inst = instances[cid]
        nl = cid.rsplit("_", 1)[1]
        key = (inst["name"], nl)
        by_bucket.setdefault(key, []).append(cid)
    rng = np.random.default_rng(42)
    buckets = sorted(by_bucket.keys())
    per_bucket = max(1, n // len(buckets))
    picked = []
    for b in buckets:
        cands = by_bucket[b]
        rng.shuffle(cands)
        picked.extend(cands[:per_bucket])
        if len(picked) >= n:
            break
    return picked[:n]


def _worker_init(inst_payload, t_grid, observed):
    """Parse ODE once per worker process; store in worker-local state."""
    rhs_fn, obs_lambdas, state_vars, param_vars = parse_ode(inst_payload)
    _W["rhs_fn"] = rhs_fn
    _W["obs_lambdas"] = obs_lambdas
    _W["state_vars"] = state_vars
    _W["param_vars"] = param_vars
    _W["t_grid"] = t_grid
    _W["observed"] = observed


def _score_one_row(args):
    """Worker function: integrate one row using worker-local parsed ODE."""
    (i, ic_arr, p_arr) = args
    if not (np.all(np.isfinite(ic_arr)) and np.all(np.isfinite(p_arr))):
        return (i, np.inf)
    r = integrate_and_score(
        _W["rhs_fn"], _W["obs_lambdas"], _W["state_vars"], _W["param_vars"],
        _W["t_grid"], _W["observed"], ic_arr, p_arr,
    )
    return (i, r)


def audit_cell(cell_id: str, est: str, bench: Path, instances: dict, nonid_by_sys: dict,
               n_workers: int = 1):
    """Run the audit on one cell. Returns dict of stats."""
    inst = instances[cell_id]
    sys_name = inst["name"]
    cell_dir = bench / "filetree" / f"{est}_run" / cell_id
    rc = cell_dir / "result.csv"
    dc = cell_dir / "data.csv"
    if not rc.exists() or not dc.exists():
        return None

    # Load result.csv
    rdf = pd.read_csv(rc)
    if rdf.empty:
        return None
    # Normalize column names
    rdf.columns = [normalize(c) for c in rdf.columns]

    state_vars = inst["state_variables"]
    param_vars = inst["parameter_variables"]
    obs_names = inst.get("measurement_variables") or list(inst["measurements"].keys())
    non_id = nonid_by_sys.get(sys_name, set())
    id_vars = [v for v in (param_vars + state_vars) if v not in non_id]

    truth = {**(inst.get("state_values") or {}), **(inst.get("parameter_values") or {})}

    # Parse ODE once per cell (in this process; worker procs reparse from inst payload)
    try:
        rhs_fn, obs_lambdas, _state_vars, _param_vars = parse_ode(inst)
    except Exception as e:
        return {"cell_id": cell_id, "est": est, "system": sys_name, "error": f"parse_ode: {e}"}

    t_grid, observed = build_observed_data(dc, obs_names)

    # Compute oracle metric (max_rel_err) for every row
    oracle_per_row = np.zeros(len(rdf))
    for i in range(len(rdf)):
        est_dict = {c: float(rdf.iloc[i][c]) for c in rdf.columns if pd.notna(rdf.iloc[i][c])}
        oracle_per_row[i] = max_rel_err(truth, est_dict, id_vars)

    # Build per-row IC/param arrays
    n = len(rdf)
    job_args = []
    for i in range(n):
        est_dict = {c: float(rdf.iloc[i][c]) for c in rdf.columns if pd.notna(rdf.iloc[i][c])}
        ic_arr = np.array([est_dict.get(s, np.nan) for s in state_vars], dtype=float)
        p_arr = np.array([est_dict.get(p, np.nan) for p in param_vars], dtype=float)
        job_args.append((i, ic_arr, p_arr))

    residual_per_row = np.full(n, np.inf)
    integration_errors = 0

    if n_workers > 1:
        # Parallelize across rows. Workers parse ODE once at init.
        inst_payload = {
            "state_variables": state_vars,
            "parameter_variables": param_vars,
            "ode_system": inst["ode_system"],
            "measurements": inst["measurements"],
        }
        ctx = mp.get_context("fork")
        with ctx.Pool(processes=n_workers,
                      initializer=_worker_init,
                      initargs=(inst_payload, t_grid, observed)) as pool:
            for (i, r) in pool.imap_unordered(_score_one_row, job_args, chunksize=8):
                residual_per_row[i] = r
                if not np.isfinite(r):
                    integration_errors += 1
    else:
        for (i, ic_arr, p_arr) in job_args:
            if not (np.all(np.isfinite(ic_arr)) and np.all(np.isfinite(p_arr))):
                integration_errors += 1
                continue
            r = integrate_and_score(rhs_fn, obs_lambdas, state_vars, param_vars,
                                    t_grid, observed, ic_arr, p_arr)
            if not np.isfinite(r):
                integration_errors += 1
            residual_per_row[i] = r

    # Truth-best = argmin oracle
    truth_best_idx = int(np.argmin(oracle_per_row))
    truth_best_oracle = float(oracle_per_row[truth_best_idx])

    # Sort by residual (ascending)
    sorted_by_residual = np.argsort(residual_per_row, kind="stable")
    # Where does truth-best land in the residual-sorted order?
    pos = int(np.where(sorted_by_residual == truth_best_idx)[0][0])
    rank_truth_best_by_residual = pos + 1  # 1-based

    # Top-K capture
    top_K = {}
    for K in (1, 5, 10, 20, 50, 100):
        top_K[K] = int(rank_truth_best_by_residual <= K)

    residual_best_idx = int(sorted_by_residual[0])
    residual_best_oracle = float(oracle_per_row[residual_best_idx])

    return {
        "cell_id": cell_id,
        "est": est,
        "system": sys_name,
        "noise_label": cell_id.rsplit("_", 1)[1],
        "n_rows": n,
        "n_integration_errors": integration_errors,
        "rank_truth_best_by_residual": rank_truth_best_by_residual,
        "truth_best_oracle_max_rel_err": truth_best_oracle,
        "residual_best_oracle_max_rel_err": residual_best_oracle,
        "row1_oracle_max_rel_err": float(oracle_per_row[0]),  # ODEPE's actual returned row 1
        **{f"top_K_{K}": v for K, v in top_K.items()},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=50)
    ap.add_argument("--cells", default=None, help="Comma-separated cell IDs to override sample")
    ap.add_argument("--est", default="odepe_v2_polish",
                    choices=ESTIMATORS,
                    help="Which estimator's result.csv to audit")
    ap.add_argument("--out", default=str(OUT_CSV))
    ap.add_argument("--workers", type=int, default=8,
                    help="Per-cell parallel row integrations (1 = serial)")
    args = ap.parse_args()

    print(f"Loading huge_json...")
    instances = {c["id"]: c for c in json.load(open(BENCH / "huge_json.json"))["instances"]}
    nonid = discover_non_id(BENCH)
    print(f"  {len(instances)} cells; non-id systems: {[s for s,v in nonid.items() if v]}")

    if args.cells:
        cell_list = [c.strip() for c in args.cells.split(",") if c.strip()]
    else:
        cell_list = pick_sample(BENCH, instances, args.sample)
    print(f"\nAuditing {len(cell_list)} cells (estimator={args.est})...")

    rows = []
    t0 = time.time()
    for i, cid in enumerate(cell_list):
        t1 = time.time()
        try:
            r = audit_cell(cid, args.est, BENCH, instances, nonid, n_workers=args.workers)
        except Exception as e:
            print(f"  [{i+1}/{len(cell_list)}] ERR  {cid}: {type(e).__name__}: {e}")
            continue
        dt = time.time() - t1
        if r is None:
            print(f"  [{i+1}/{len(cell_list)}] SKIP {cid}")
            continue
        if "error" in r:
            print(f"  [{i+1}/{len(cell_list)}] ERR  {cid}: {r['error']}")
            continue
        rows.append(r)
        print(
            f"  [{i+1}/{len(cell_list)}] {cid:30s} "
            f"n={r['n_rows']:>4d} rank={r['rank_truth_best_by_residual']:>4d}/{r['n_rows']:<4d} "
            f"row1_err={r['row1_oracle_max_rel_err']:.2e} "
            f"resid_best_err={r['residual_best_oracle_max_rel_err']:.2e} "
            f"{dt:.1f}s"
        )

    df = pd.DataFrame(rows)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(args.out, index=False)
    print(f"\nWrote {args.out}")
    print(f"Total audit time: {time.time() - t0:.1f}s")

    if df.empty:
        print("No successful audits"); return

    print("\n=== rank distribution (rank_truth_best_by_residual) ===")
    print(df["rank_truth_best_by_residual"].describe().round(1))

    print("\n=== top-K capture rates ===")
    for K in (1, 5, 10, 20, 50, 100):
        rate = df[f"top_K_{K}"].mean() * 100
        print(f"  top-{K:>3d}: {rate:5.1f}%")

    print("\n=== rank by noise level ===")
    print(df.groupby("noise_label")["rank_truth_best_by_residual"].agg(["median","mean","max"]).round(1))

    print("\n=== rank by system (worst-case max) ===")
    bys = df.groupby("system")["rank_truth_best_by_residual"].agg(["median","max","count"]).sort_values("median", ascending=False)
    print(bys.head(10).round(1))


if __name__ == "__main__":
    main()
