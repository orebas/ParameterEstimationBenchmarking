#!/usr/bin/env python3
"""Offline eps-ladder on the 3 nopolish probes.

For each nopolish probe (which has the full ~1000-row polish-survivor list since
clustering was disabled), re-apply L∞-MAD clustering in Python at multiple eps
values. For each eps, pick the lowest-err member of each cluster as the cluster
rep (matching ODEPE's `first(cluster)` after err-sort) and find the oracle-best
across the reps.

No SLURM needed; everything offline on the existing probe output.
"""
import csv
import json
import multiprocessing as mp
import numpy as np
import os
import signal
import sys
import time
import warnings
from pathlib import Path
import sympy as sp
from scipy.integrate import solve_ivp

warnings.filterwarnings("ignore")

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH = REPO / "benchmark_numbat_2026-05-12"
HERE = REPO / "results/numbat_analysis/branch_detection_comparison"

PROBES = [
    "hiv_8_0",
    "biohydrogenation_2_0",
    "dc_motor_4_1em4",
]

EPS_LADDER = [0.0001, 0.001, 0.005, 0.01, 0.02, 0.05]  # 0.05 is the current default

# ---- ODE integration utilities (subset of oracle_ranking_audit.py) -----

class _IntegrationTimeout(Exception):
    pass


def _alarm(s, f):
    raise _IntegrationTimeout()


def normalize(c):
    return c[:-3] if c.endswith("(t)") else c


def parse_ode(inst):
    state_vars = inst["state_variables"]
    param_vars = inst["parameter_variables"]
    ode_strs = inst["ode_system"]
    meas_strs = inst["measurements"]
    meas_var_order = inst.get("measurement_variables") or list(meas_strs.keys())

    t_sym = sp.Symbol("t")
    syms = [t_sym] + [sp.Symbol(s) for s in state_vars] + [sp.Symbol(p) for p in param_vars]
    # Pass explicit locals so names like 'beta', 'gamma' don't collide with sympy functions
    sym_locals = {str(s): s for s in syms}

    rhs_lambdas = [sp.lambdify(syms, sp.sympify(ode_strs[s], locals=sym_locals), modules=["numpy"]) for s in state_vars]
    def rhs_fn(t, y, p_arr):
        return np.array([f(t, *y, *p_arr) for f in rhs_lambdas])

    obs_lambdas = []
    for name in meas_var_order:
        if name in meas_strs:
            f = sp.lambdify(syms, sp.sympify(meas_strs[name], locals=sym_locals), modules=["numpy"])
            obs_lambdas.append((name, f))
    return rhs_fn, obs_lambdas, state_vars, param_vars


def integrate_residual(rhs_fn, obs_lambdas, t_grid, observed, ic_arr, p_arr, timeout_s=3):
    """Sum-of-squares data residual. Inf on failure."""
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

    old = signal.signal(signal.SIGALRM, _alarm)
    signal.alarm(int(timeout_s))
    try:
        try:
            sol = solve_ivp(safe_rhs, t_span, ic_arr, t_eval=t_grid,
                            method="LSODA", rtol=1e-7, atol=1e-10, max_step=max_step)
        except _IntegrationTimeout:
            return np.inf
        except Exception:
            return np.inf
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)
    if not sol.success or sol.y.shape[1] != len(t_grid):
        return np.inf
    if not np.all(np.isfinite(sol.y)) or np.max(np.abs(sol.y)) > 1e15:
        return np.inf
    Y = sol.y
    total = 0.0
    with np.errstate(all="ignore"):
        for name, f in obs_lambdas:
            obs_d = observed.get(name)
            if obs_d is None:
                continue
            try:
                pred = np.array([f(t_grid[i], *Y[:, i], *p_arr) for i in range(len(t_grid))])
            except Exception:
                return np.inf
            if not np.all(np.isfinite(pred)) or np.max(np.abs(pred)) > 1e15:
                return np.inf
            d = pred - obs_d
            total += float(np.sum(d * d))
            if not np.isfinite(total):
                return np.inf
    return total


# ---- Worker pool ----
_W = {}


def _worker_init(inst_payload, t_grid, observed):
    rhs_fn, obs_lambdas, sv, pv = parse_ode(inst_payload)
    _W["rhs"] = rhs_fn
    _W["obs"] = obs_lambdas
    _W["sv"] = sv
    _W["pv"] = pv
    _W["t"] = t_grid
    _W["o"] = observed


def _score(args):
    i, ic, pa = args
    if not (np.all(np.isfinite(ic)) and np.all(np.isfinite(pa))):
        return (i, np.inf)
    r = integrate_residual(_W["rhs"], _W["obs"], _W["t"], _W["o"], ic, pa)
    return (i, r)


# ---- Main analysis ----
def linfmad_cluster_greedy(X, err_sorted_idx, eps):
    """Greedy first-fit clustering by L∞ distance on MAD-normalized identifiable axes.

    X: (n_rows, n_id_axes) array of identifiable variable values.
    err_sorted_idx: row indices in order of increasing err.
    eps: clustering threshold.

    Returns: list of cluster representatives (first-encountered, lowest-err per cluster).
    """
    if X.shape[0] == 0:
        return []
    # MAD-normalize per column
    med = np.median(X, axis=0)
    mad = np.median(np.abs(X - med), axis=0)
    scale = np.maximum.reduce([np.abs(med), mad, np.full_like(med, 1e-10)])
    Xn = (X - med) / scale

    # Greedy single-link: a candidate joins a cluster if its L∞ distance to ANY
    # existing cluster member ≤ eps. (Matches the Julia _branch_cluster_linf
    # algorithm structure closely enough for offline use.)
    clusters = []  # list of list-of-row-indices, in order
    reps = []      # rep = first (lowest-err) member of each cluster

    for orig_idx in err_sorted_idx:
        pt = Xn[orig_idx]
        joined = False
        for c_idx, members in enumerate(clusters):
            # check distance to each member; break on first match (single-link)
            for m in members:
                if np.max(np.abs(pt - Xn[m])) <= eps:
                    members.append(orig_idx)
                    joined = True
                    break
            if joined:
                break
        if not joined:
            clusters.append([orig_idx])
            reps.append(orig_idx)
    return reps


def max_rel_err(truth_id_vars, est_dict):
    vals = []
    for v, tv in truth_id_vars.items():
        ev = est_dict.get(v)
        if ev is None:
            continue
        if abs(tv) > 1e-15:
            vals.append(abs(ev - tv) / abs(tv))
        else:
            vals.append(abs(ev - tv))
    return max(vals) if vals else float("inf")


def main():
    print("Loading huge_json...")
    instances = {c["id"]: c for c in json.load(open(BENCH / "huge_json.json"))["instances"]}

    # Discover non-id per system (same logic as elsewhere)
    non_id = {}
    for est in ("odepe_v2_polish", "odepe_v2_nopolish"):
        rd = BENCH / "filetree" / f"{est}_run"
        if not rd.exists(): continue
        for cell in rd.iterdir():
            md = cell / "odepe_metadata.json"
            if not md.exists(): continue
            sn = cell.name.rsplit("_", 2)[0]
            if sn in non_id: continue
            try:
                d = json.load(open(md))
                non_id[sn] = {normalize(v) for v in (d.get("best", {}).get("all_unidentifiable") or [])}
            except Exception:
                pass

    all_rows = []
    for cell_id in PROBES:
        print(f"\n=== {cell_id} ===")
        probe_dir = BENCH / "probes" / cell_id / "no_clustering"
        result_csv = probe_dir / "result.csv"
        if not result_csv.exists():
            print(f"  no result.csv, skipping")
            continue

        inst = instances[cell_id]
        sys_name = inst["name"]
        non_id_set = non_id.get(sys_name, set())
        state_vars = inst["state_variables"]
        param_vars = inst["parameter_variables"]
        id_vars = [v for v in (state_vars + param_vars) if v not in non_id_set]

        truth = {**(inst.get("state_values") or {}), **(inst.get("parameter_values") or {})}
        truth_id_vars = {v: truth[v] for v in id_vars if v in truth}

        # Read result.csv
        with open(result_csv) as f:
            reader = csv.DictReader(f)
            rows = list(reader)
            fields = reader.fieldnames or []
        norm_fields = {normalize(c): c for c in fields}
        n = len(rows)
        print(f"  {n} candidates in probe")

        # Build per-row IC, p, and est_dict for oracle
        ic_arr_list, p_arr_list, est_dicts = [], [], []
        for row in rows:
            ic = np.array([float(row[norm_fields[s]]) if s in norm_fields else np.nan for s in state_vars])
            pa = np.array([float(row[norm_fields[p]]) if p in norm_fields else np.nan for p in param_vars])
            d = {}
            for c in fields:
                try:
                    d[normalize(c)] = float(row[c])
                except (ValueError, KeyError):
                    pass
            ic_arr_list.append(ic)
            p_arr_list.append(pa)
            est_dicts.append(d)

        # Build data subsample (50 points uniform)
        data_csv = probe_dir / "data.csv"
        import pandas as pd
        df = pd.read_csv(data_csv, header=None)
        t_full = df.iloc[:, 0].to_numpy()
        sub_idx = np.linspace(0, len(t_full) - 1, 50).astype(int)
        t_grid = t_full[sub_idx]

        obs_names = inst.get("measurement_variables") or list(inst["measurements"].keys())
        observed = {}
        for i, name in enumerate(obs_names):
            if i + 1 < df.shape[1]:
                observed[name] = df.iloc[:, i + 1].to_numpy()[sub_idx]

        # Compute err per row (parallel)
        inst_payload = {
            "state_variables": state_vars,
            "parameter_variables": param_vars,
            "ode_system": inst["ode_system"],
            "measurements": inst["measurements"],
            "measurement_variables": obs_names,
        }
        jobs = [(i, ic_arr_list[i], p_arr_list[i]) for i in range(n)]
        errs = np.full(n, np.inf)
        t0 = time.time()
        ctx = mp.get_context("fork")
        with ctx.Pool(16, initializer=_worker_init, initargs=(inst_payload, t_grid, observed)) as pool:
            for (i, r) in pool.imap_unordered(_score, jobs, chunksize=16):
                errs[i] = r
        print(f"  computed err per row in {time.time()-t0:.1f}s; finite errs: {(errs < np.inf).sum()}")

        # Oracle err per row
        oracles = np.array([max_rel_err(truth_id_vars, est_dicts[i]) for i in range(n)])

        # X for clustering: per-row identifiable variable values
        X = np.zeros((n, len(id_vars)))
        for i in range(n):
            for j, v in enumerate(id_vars):
                X[i, j] = est_dicts[i].get(v, np.nan)

        # Sort by err
        err_sorted = np.argsort(errs, kind="stable")

        # Run eps ladder
        for eps in EPS_LADDER:
            reps = linfmad_cluster_greedy(X, err_sorted, eps)
            rep_oracles = [oracles[r] for r in reps]
            rep_errs = [errs[r] for r in reps]
            best_oracle = min(rep_oracles) if rep_oracles else float("inf")
            best_oracle_in_rep_idx = rep_oracles.index(best_oracle) if rep_oracles else -1

            all_rows.append({
                "cell": cell_id,
                "eps": eps,
                "n_clusters": len(reps),
                "best_oracle_over_reps": best_oracle,
                "best_oracle_idx_in_reps": best_oracle_in_rep_idx,
                "best_err_at_rep": rep_errs[best_oracle_in_rep_idx] if rep_errs else None,
            })
            print(f"  eps={eps:6.4f}: n_clusters={len(reps):4d}, best_oracle_over_reps={best_oracle:.3e}")

    # Write CSV
    keys = ["cell", "eps", "n_clusters", "best_oracle_over_reps", "best_oracle_idx_in_reps", "best_err_at_rep"]
    out_csv = HERE / "nopolish_eps_ladder.csv"
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(all_rows)
    print(f"\nWrote {out_csv}")

    # Summary
    md = ["# Nopolish offline eps ladder", "",
          "**Setup**: re-cluster the no_clustering probe outputs at varied L∞-MAD eps. Pick lowest-err member of each cluster as rep, find oracle-best across reps. Fully offline.", ""]
    for cell_id in PROBES:
        md.append(f"## {cell_id}")
        md.append("")
        md.append("| eps | n_clusters | oracle-best over reps |")
        md.append("|----:|-----------:|----------------------:|")
        for r in all_rows:
            if r["cell"] == cell_id:
                md.append(f"| {r['eps']:.4f} | {r['n_clusters']} | {r['best_oracle_over_reps']:.3e} |")
        md.append("")
    (HERE / "nopolish_eps_ladder.md").write_text("\n".join(md))
    print(f"Wrote {HERE / 'nopolish_eps_ladder.md'}")


if __name__ == "__main__":
    main()
