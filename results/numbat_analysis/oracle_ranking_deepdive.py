#!/usr/bin/env python3
"""Deep-dive on the cells where residual ranking fails worst.

For each cell, we compute residual + oracle err per row, then ask:
  - How does residual distribute? (cliff? plateau? long tail?)
  - Do the top-by-residual rows cluster on parameters?
  - Are some params freely varying among low-residual candidates? (= effectively unidentifiable on this data)
  - Where does truth-best sit among the residual-low rows?
  - If we cluster low-residual rows by params, does the "right" cluster contain truth-best?

Usage:
    python3 results/numbat_analysis/oracle_ranking_deepdive.py
"""
from __future__ import annotations
import json
import os
import multiprocessing as mp
import sys
import time
import warnings
from pathlib import Path

import numpy as np
import pandas as pd

# Reuse machinery from oracle_ranking_audit
sys.path.insert(0, str(Path(__file__).resolve().parent))
from oracle_ranking_audit import (
    parse_ode, integrate_and_score, build_observed_data, normalize,
    max_rel_err, discover_non_id, _worker_init, _score_one_row, _W,
)

warnings.filterwarnings("ignore")

REPO = Path(__file__).resolve().parent.parent.parent
BENCH = REPO / "benchmark_numbat_2026-05-06"

# Cells to audit. Picked because audit shows truth-best deeply buried + a
# range of conditions (noise-free vs noisy, different systems).
TARGET_CELLS = [
    "biohydrogenation_0_1em2",# rank 786 — high noise, ODEPE didn't find truth either
    "cstr_5_1em8",            # rank 427 — cstr at low noise
    "cstr_3_1em2",            # rank 352 — cstr at high noise
    "fitzhugh_nagumo_4_1em6", # rank 53 — moderate
    "biohydrogenation_4_1em8",# rank 9 (was 542 pre-fix) — confirms x7 non-id manifold
]

EST = "odepe_v2_polish"


def deep_audit(cell_id: str, instances: dict, nonid: dict, n_workers: int = 16):
    inst = instances[cell_id]
    sys_name = inst["name"]
    cell_dir = BENCH / "filetree" / f"{EST}_run" / cell_id
    rdf = pd.read_csv(cell_dir / "result.csv")
    rdf.columns = [normalize(c) for c in rdf.columns]
    state_vars = inst["state_variables"]
    param_vars = inst["parameter_variables"]
    obs_names = inst.get("measurement_variables") or list(inst["measurements"].keys())
    non_id = nonid.get(sys_name, set())
    id_vars = [v for v in (param_vars + state_vars) if v not in non_id]

    truth_p = {**(inst.get("state_values") or {}), **(inst.get("parameter_values") or {})}
    t_grid, observed = build_observed_data(cell_dir / "data.csv", obs_names, subsample=50)

    # Per-row oracle err
    oracle = np.zeros(len(rdf))
    for i in range(len(rdf)):
        d = {c: float(rdf.iloc[i][c]) for c in rdf.columns if pd.notna(rdf.iloc[i][c])}
        oracle[i] = max_rel_err(truth_p, d, id_vars)

    # Per-row residual (parallel)
    inst_payload = {
        "state_variables": state_vars,
        "parameter_variables": param_vars,
        "ode_system": inst["ode_system"],
        "measurements": inst["measurements"],
    }
    job_args = []
    for i in range(len(rdf)):
        d = {c: float(rdf.iloc[i][c]) for c in rdf.columns if pd.notna(rdf.iloc[i][c])}
        ic_arr = np.array([d.get(s, np.nan) for s in state_vars], dtype=float)
        p_arr = np.array([d.get(p, np.nan) for p in param_vars], dtype=float)
        job_args.append((i, ic_arr, p_arr))

    residual = np.full(len(rdf), np.inf)
    ctx = mp.get_context("fork")
    with ctx.Pool(n_workers, initializer=_worker_init,
                  initargs=(inst_payload, t_grid, observed)) as pool:
        for (i, r) in pool.imap_unordered(_score_one_row, job_args, chunksize=8):
            residual[i] = r

    rdf["residual"] = residual
    rdf["oracle"] = oracle

    return {
        "cell_id": cell_id, "system": sys_name,
        "noise": cell_id.rsplit("_", 1)[1],
        "rdf": rdf,
        "id_vars": id_vars,
        "non_id": list(non_id),
        "truth": truth_p,
        "state_vars": state_vars, "param_vars": param_vars,
    }


def describe_cell(out):
    rdf = out["rdf"]
    truth = out["truth"]
    id_vars = out["id_vars"]
    non_id = out["non_id"]
    sv = out["state_vars"]
    pv = out["param_vars"]

    print("=" * 80)
    print(f"CELL: {out['cell_id']}  (system={out['system']}, noise={out['noise']})")
    print(f"  states={sv}  params={pv}  non_id={non_id}")
    print(f"  N rows = {len(rdf)}; finite residual rows = {(rdf['residual'] < np.inf).sum()}")
    print("=" * 80)

    # Residual distribution
    fr = rdf[rdf["residual"] < np.inf].copy()
    if fr.empty:
        print("  All residuals infinite — abort"); return
    res = fr["residual"].to_numpy()
    print(f"\n  Residual quantiles (finite rows only, {len(res)} rows):")
    qs = [0.01, 0.10, 0.25, 0.50, 0.75, 0.90, 0.99]
    for q in qs:
        v = np.quantile(res, q)
        print(f"    p{int(q*100):>2d}: {v:.3e}")
    print(f"    min: {res.min():.3e}   max: {res.max():.3e}")

    # Truth-best row
    tb = int(np.argmin(rdf["oracle"].to_numpy()))
    tb_res = rdf.iloc[tb]["residual"]
    rank_tb = (rdf["residual"] < tb_res).sum() + 1
    print(f"\n  Truth-best row index: {tb}  (oracle={rdf.iloc[tb]['oracle']:.3e}, residual={tb_res:.3e})")
    print(f"    Its rank by residual: {rank_tb}/{len(rdf)}")

    # Where does the truth-best's residual sit relative to the residual-best?
    rb = int(np.argmin(rdf["residual"].to_numpy()))
    rb_res = rdf.iloc[rb]["residual"]
    rb_or = rdf.iloc[rb]["oracle"]
    print(f"  Residual-best row index: {rb}  (residual={rb_res:.3e}, oracle={rb_or:.3e})")
    if tb_res < np.inf and rb_res < np.inf:
        ratio = tb_res / rb_res
        print(f"    truth-best residual / resid-best residual = {ratio:.3e}x")

    # How many rows are within 2x of residual-best? Within 10x? Within 1.01x?
    print(f"\n  Rows clustered near residual-best (where the noise-floor plateau lives):")
    for mult in [1.001, 1.01, 1.1, 2.0, 10.0, 100.0]:
        cap = rb_res * mult
        if not np.isfinite(cap):
            continue
        n = (rdf["residual"] <= cap).sum()
        print(f"    residual <= {mult:>6.3f}x rb_res ({cap:.3e}): {n:>5d} rows ({n/len(rdf)*100:.1f}%)")

    # In the "noise-floor plateau" (e.g. residual within 2x of best), how do params spread?
    cap_for_plateau = rb_res * 2.0 if np.isfinite(rb_res) else np.inf
    plat = rdf[rdf["residual"] <= cap_for_plateau].copy()
    print(f"\n  Plateau (residual <= 2x rb_res): {len(plat)} rows")
    print(f"  Per-variable spread within plateau:")
    print(f"    {'var':12s} {'truth':>14s} {'plateau_min':>14s} {'plateau_max':>14s} {'plateau_med':>14s} {'identifiable':>14s}")
    for v in sv + pv:
        if v not in plat.columns:
            continue
        vals = plat[v].dropna().to_numpy()
        if len(vals) == 0:
            continue
        tv = truth.get(v, np.nan)
        tag = "id" if v in id_vars else "non-id (declared)"
        # Spread metric: max/min ratio (if all positive) or std/abs(mean)
        if np.all(vals > 0):
            spread = vals.max() / vals.min()
            spread_str = f"{spread:.2e}x"
        else:
            spread_str = f"std={np.std(vals):.2e}"
        print(f"    {v:12s} {tv:>14.4e} {vals.min():>14.4e} {vals.max():>14.4e} {np.median(vals):>14.4e}  spread={spread_str:>10s} {tag}")

    # How does truth's row appear in plateau? Did it land there?
    truth_in_plateau = (plat.index == tb).any()
    print(f"\n  Truth-best (row {tb}) sits in plateau? {truth_in_plateau}")
    if not truth_in_plateau:
        # By how much does its residual exceed plateau cap?
        tb_excess = tb_res / cap_for_plateau if np.isfinite(cap_for_plateau) else np.inf
        print(f"    Its residual is {tb_excess:.2f}x the plateau cap")

    # Compare oracle landscape: are there many rows with oracle close to truth's?
    or_arr = rdf["oracle"].to_numpy()
    near_truth = or_arr <= np.min(or_arr) * 10
    print(f"\n  Rows with oracle <= 10x truth-best oracle: {near_truth.sum()} rows")
    print(f"    Of these, how many in residual plateau?: {(rdf[near_truth & (rdf['residual'] <= cap_for_plateau)]).shape[0]}")

    # If we cluster parameters in plateau, what natural clusters appear?
    try:
        from sklearn.cluster import DBSCAN
        from sklearn.preprocessing import StandardScaler
        feature_cols = [v for v in sv + pv if v in plat.columns]
        X = plat[feature_cols].dropna().to_numpy()
        if X.shape[0] > 5:
            # Log-scale + standardize
            with np.errstate(invalid="ignore"):
                Xlog = np.log(np.abs(X) + 1e-30)
            Xs = StandardScaler().fit_transform(Xlog)
            db = DBSCAN(eps=0.5, min_samples=3).fit(Xs)
            labels = db.labels_
            uniq, cnt = np.unique(labels, return_counts=True)
            print(f"\n  Plateau parameter clustering (DBSCAN, log+std, eps=0.5):")
            for u, c in zip(uniq, cnt):
                if u == -1:
                    print(f"    noise:           {c} rows")
                else:
                    print(f"    cluster {u:>2d}:       {c} rows")
            # Did truth land in a real cluster?
            if tb in plat.index:
                tb_pos_in_plat = list(plat.index).index(tb)
                tb_label = labels[tb_pos_in_plat]
                print(f"    truth-best cluster: {tb_label}")
    except ImportError:
        print("\n  (sklearn missing; skipping cluster analysis)")


def main():
    print("Loading huge_json...")
    big = json.load(open(BENCH / "huge_json.json"))
    instances = {c["id"]: c for c in big["instances"]}
    nonid = discover_non_id(BENCH)
    print(f"  {len(instances)} cells; non-id systems: {[s for s,v in nonid.items() if v]}")

    for cid in TARGET_CELLS:
        if cid not in instances:
            print(f"\nSKIP {cid} (not in instances)"); continue
        t0 = time.time()
        out = deep_audit(cid, instances, nonid, n_workers=16)
        print(f"\n[deep_audit took {time.time()-t0:.1f}s]")
        describe_cell(out)
        # Save per-cell augmented CSV for reproducibility
        outpath = REPO / "results/numbat_analysis" / f"deepdive_{cid}.csv"
        out["rdf"].to_csv(outpath, index=False)
        print(f"  -> {outpath}")


if __name__ == "__main__":
    main()
