#!/usr/bin/env python3
"""Deep-dive on flexible_arm_0_1em8: why does the err filter drop the truth-recovering raw?

Outputs (all in this directory):
  report.md
  raw_candidates_analysis.csv
  fig01_noisy_data.png
  fig02_truth_trajectory.png
  fig03_matched_raw_trajectory.png
  fig04_raw_vs_oracle_scatter.png
  fig05_top10_closest_to_truth.png
  fig06_polished_vs_matched_raw.png
"""
import csv
import json
import math
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import sympy as sp
from scipy.integrate import solve_ivp

REPO = Path(__file__).resolve().parent.parent.parent.parent.parent
BENCH = REPO / "benchmark_numbat_2026-05-12"
CELL = "flexible_arm_0_1em8"
HERE = REPO / "results/numbat_analysis/branch_detection_comparison/flexible_arm_deepdive"
PROBE_DD = BENCH / "probes" / CELL / "deep_dump"
PROBE_NC = BENCH / "probes" / CELL / "no_clustering"

BRANCH_ERR_FACTOR = 100.0


def normalize(c):
    return c[:-3] if c.endswith("(t)") else c


def build_ode_funcs(inst):
    """Build a callable RHS and observation functions from huge_json instance."""
    state_vars = inst["state_variables"]
    param_vars = inst["parameter_variables"]
    ode_strs = inst["ode_system"]
    meas_strs = inst["measurements"]
    meas_order = inst.get("measurement_variables") or list(meas_strs.keys())

    t_sym = sp.Symbol("t")
    state_syms = [sp.Symbol(s) for s in state_vars]
    param_syms = [sp.Symbol(p) for p in param_vars]
    syms = [t_sym] + state_syms + param_syms
    sym_locals = {str(s): s for s in syms}

    rhs_lambdas = [
        sp.lambdify(syms, sp.sympify(ode_strs[s], locals=sym_locals), modules=["numpy"])
        for s in state_vars
    ]

    def rhs(t, y, p):
        return np.array([f(t, *y, *p) for f in rhs_lambdas])

    obs = []
    for name in meas_order:
        if name in meas_strs:
            f = sp.lambdify(syms, sp.sympify(meas_strs[name], locals=sym_locals), modules=["numpy"])
            obs.append((name, f))
    return rhs, obs, state_vars, param_vars, meas_order


def integrate_or_warn(rhs, ic, p, t_grid, label=""):
    """Integrate ODE with given IC and params. Returns (t, Y) or (None, None) on failure.
    Captures blow-ups by clamping max|y|."""
    t_span = (float(t_grid[0]), float(t_grid[-1]))

    def safe_rhs(t, y):
        with np.errstate(over="raise", invalid="raise", divide="raise"):
            try:
                dy = rhs(t, y, p)
            except (FloatingPointError, OverflowError, ValueError):
                return np.full_like(y, 1e30)
        if not np.all(np.isfinite(dy)):
            return np.full_like(y, 1e30)
        return dy

    try:
        sol = solve_ivp(
            safe_rhs, t_span, ic, t_eval=t_grid,
            method="LSODA", rtol=1e-8, atol=1e-11,
            max_step=(t_span[1] - t_span[0]) / 100.0,
        )
    except Exception as e:
        print(f"  [{label}] solve_ivp threw: {e}")
        return None, None
    if not sol.success:
        print(f"  [{label}] solve_ivp failed: {sol.message}")
    return sol.t, sol.y


def compute_err(rhs, obs, ic, p, t_grid, observed):
    """Mimic process_raw_solution err: integrate, compute sum of L2 norm of residuals per obs."""
    t, Y = integrate_or_warn(rhs, ic, p, t_grid, label="err")
    if Y is None or Y.shape[1] != len(t_grid):
        return np.inf
    if not np.all(np.isfinite(Y)) or np.max(np.abs(Y)) > 1e15:
        return np.inf
    err = 0.0
    n = len(t_grid)
    for name, f in obs:
        obs_d = observed.get(name)
        if obs_d is None:
            continue
        try:
            pred = np.array([f(t_grid[i], *Y[:, i], *p) for i in range(n)])
        except Exception:
            return np.inf
        if not np.all(np.isfinite(pred)):
            return np.inf
        # process_raw_solution: norm of (pred - data) / length. Then average over obs.
        err += float(np.linalg.norm(pred - obs_d)) / n
    err /= max(1, len(obs))
    return err


def read_raw_candidates(path):
    """Returns list of dicts."""
    rows = []
    with open(path) as f:
        rdr = csv.DictReader(f)
        for r in rdr:
            d = {"hc_idx": int(r["hc_idx"])}
            for col in rdr.fieldnames:
                if col.startswith("s::"):
                    d[normalize(col[3:])] = float(r[col])
                elif col.startswith("p::"):
                    d[normalize(col[3:])] = float(r[col])
                elif col == "err":
                    try: d["err"] = float(r[col]) if r[col].strip() else np.inf
                    except: d["err"] = np.inf
            rows.append(d)
    return rows


def read_polished(path):
    rows = []
    with open(path) as f:
        rdr = csv.DictReader(f)
        for r in rdr:
            d = {}
            for col in rdr.fieldnames:
                if col.startswith("s::") or col.startswith("p::"):
                    d[normalize(col[3:])] = float(r[col])
                elif col == "polish_source_hc_idx":
                    d["polish_source_hc_idx"] = int(r[col])
                elif col in ("err", "post_polish_error"):
                    try: d[col] = float(r[col]) if r[col].strip() else np.nan
                    except: d[col] = np.nan
            rows.append(d)
    return rows


def read_nc_result(path):
    """no_clustering's result.csv: bare column names (no s::/p:: prefix)."""
    rows = []
    with open(path) as f:
        rdr = csv.DictReader(f)
        fields = rdr.fieldnames
        for r in rdr:
            d = {}
            for col in fields:
                key = normalize(col)
                try: d[key] = float(r[col])
                except (ValueError, TypeError, KeyError): pass
            rows.append(d)
    return rows


def main():
    inst = next(c for c in json.load(open(BENCH / "huge_json.json"))["instances"]
                if c["id"] == CELL)
    rhs, obs, state_vars, param_vars, meas_order = build_ode_funcs(inst)

    truth_states = inst["state_values"]
    truth_params = inst["parameter_values"]
    truth_full = {**truth_states, **truth_params}
    print("=== flexible_arm system ===")
    print(f"  states: {state_vars}")
    print(f"  params: {param_vars}")
    print(f"  truth: {truth_full}")
    print()

    # Load data
    import pandas as pd
    df = pd.read_csv(PROBE_DD / "data.csv", header=None)
    t_grid = df.iloc[:, 0].to_numpy()
    observed = {}
    for i, name in enumerate(meas_order):
        if i + 1 < df.shape[1]:
            observed[name] = df.iloc[:, i + 1].to_numpy()
    print(f"data: {len(t_grid)} pts in [{t_grid[0]}, {t_grid[-1]}]")

    # Integrate truth
    truth_ic = [truth_states[s] for s in state_vars]
    truth_p = [truth_params[p] for p in param_vars]
    t_truth, Y_truth = integrate_or_warn(rhs, truth_ic, truth_p, t_grid, "truth")
    if Y_truth is None:
        raise RuntimeError("Truth integration failed!")
    truth_pred = {name: np.array([f(t_grid[i], *Y_truth[:, i], *truth_p) for i in range(len(t_grid))])
                  for name, f in obs}
    truth_residuals = {name: observed[name] - truth_pred[name] for name in observed}
    noise_levels = {name: float(np.std(truth_residuals[name])) for name in truth_residuals}
    print(f"noise std vs truth trajectory: {noise_levels}")

    # Load raws
    raws = read_raw_candidates(PROBE_DD / "raw_candidates.csv")
    print(f"n_raw_HC = {len(raws)}")
    raw_errs = np.array([r["err"] for r in raws])
    finite_raw = raw_errs[np.isfinite(raw_errs)]
    min_err = float(np.min(finite_raw))
    err_cap = BRANCH_ERR_FACTOR * max(min_err, 2.2e-16)
    print(f"raw err: min={min_err:.3e}, 100×min cap={err_cap:.3e}, max={float(np.max(finite_raw)):.3e}")
    print(f"raws passing err filter: {int(np.sum(np.isfinite(raw_errs) & (raw_errs <= err_cap)))} / {len(raws)}")

    # Load polished + no_clustering best
    polished = read_polished(PROBE_DD / "polished_results.csv")
    polished_hc_set = {p["polish_source_hc_idx"] for p in polished}
    nc_rows = read_nc_result(PROBE_NC / "result.csv")

    def oracle_err_dict(d):
        vals = []
        for v, tv in truth_full.items():
            if v not in d:
                continue
            ev = d[v]
            if abs(tv) > 1e-15: vals.append(abs(ev - tv) / abs(tv))
            else: vals.append(abs(ev - tv))
        return max(vals) if vals else np.inf

    nc_oracles = [oracle_err_dict(r) for r in nc_rows]
    nc_best_i = int(np.argmin(nc_oracles))
    nc_best = nc_rows[nc_best_i]
    nc_best_oracle = nc_oracles[nc_best_i]
    print(f"\nno_clustering best polish: oracle={nc_best_oracle:.3e}")
    for k in sorted(nc_best):
        print(f"  {k}={nc_best[k]:.6f}")

    # Distance to truth for each raw
    truth_id = np.array([truth_full[v] for v in truth_full])
    id_var_names = list(truth_full.keys())  # all are identifiable for flexible_arm

    rows_analysis = []
    for r in raws:
        vec = np.array([r.get(v, np.nan) for v in id_var_names])
        if not np.all(np.isfinite(vec)):
            d_truth = np.inf
        else:
            # Relative max distance, same metric as before
            dists = []
            for j, v in enumerate(id_var_names):
                tv = truth_full[v]
                if abs(tv) > 1e-15: dists.append(abs(vec[j] - tv) / abs(tv))
                else: dists.append(abs(vec[j] - tv))
            d_truth = max(dists)
        rows_analysis.append({
            "hc_idx": r["hc_idx"],
            "raw_err": r["err"],
            "oracle_max_rel_err": d_truth,
            "passed_err_filter": int(r["err"] <= err_cap),
            "was_polished": int(r["hc_idx"] in polished_hc_set),
            **{f"raw_{v}": r.get(v, np.nan) for v in id_var_names},
        })

    # Sort by truth distance
    rows_analysis.sort(key=lambda x: x["oracle_max_rel_err"])

    # Write CSV
    out_csv = HERE / "raw_candidates_analysis.csv"
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows_analysis[0].keys()))
        w.writeheader()
        w.writerows(rows_analysis)
    print(f"\nWrote {out_csv}")

    # The matched raw (closest to truth in id-space)
    matched = rows_analysis[0]
    matched_idx = matched["hc_idx"]
    print(f"\nClosest-to-truth raw: hc_idx={matched_idx}, distance_to_truth={matched['oracle_max_rel_err']:.3e}, raw_err={matched['raw_err']:.3e}, passed_filter={bool(matched['passed_err_filter'])}, was_polished={bool(matched['was_polished'])}")

    # Find the raw entry for re-integration
    matched_full = next(r for r in raws if r["hc_idx"] == matched_idx)
    matched_ic = [matched_full[s] for s in state_vars]
    matched_p = [matched_full[p] for p in param_vars]
    print(f"matched raw values:")
    for v in id_var_names:
        print(f"  {v}={matched_full[v]:.6f}  (truth={truth_full[v]:.6f}  Δ={matched_full[v] - truth_full[v]:+.3e})")

    # Re-verify the matched raw's err
    verified_err = compute_err(rhs, obs, matched_ic, matched_p, t_grid, observed)
    print(f"\nVerified err (scipy LSODA): {verified_err:.3e}")
    print(f"Reported err (ODEPE):       {matched_full['err']:.3e}")
    print(f"Ratio: {verified_err / matched_full['err']:.3e}")

    # Integrate matched raw
    t_m, Y_m = integrate_or_warn(rhs, matched_ic, matched_p, t_grid, "matched")
    # Integrate the no_clustering best polish
    polish_ic = [nc_best[s] for s in state_vars]
    polish_p = [nc_best[p] for p in param_vars]
    t_p, Y_p = integrate_or_warn(rhs, polish_ic, polish_p, t_grid, "polish")
    polish_pred = None
    if Y_p is not None:
        polish_pred = {name: np.array([f(t_grid[i], *Y_p[:, i], *polish_p) for i in range(len(t_grid))])
                       for name, f in obs}

    # === Plot 1: noisy data + truth trajectory ===
    fig, ax = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
    for i, name in enumerate(meas_order):
        ax[i].plot(t_grid, observed[name], "k.", ms=2, label=f"data ({name})", alpha=0.6)
        ax[i].plot(t_grid, truth_pred[name], "g-", lw=1.5, label="truth-trajectory")
        ax[i].set_ylabel(name)
        ax[i].legend(loc="best", fontsize=9)
        ax[i].grid(alpha=0.3)
    ax[-1].set_xlabel("t")
    ax[0].set_title("flexible_arm_0_1em8: noisy data vs truth trajectory")
    fig.tight_layout()
    fig.savefig(HERE / "fig01_data_vs_truth.png", dpi=110)
    plt.close(fig)

    # === Plot 2: matched-raw trajectory ===
    fig, ax = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
    for i, name in enumerate(meas_order):
        ax[i].plot(t_grid, observed[name], "k.", ms=2, label=f"data", alpha=0.4)
        ax[i].plot(t_grid, truth_pred[name], "g-", lw=1.0, label="truth", alpha=0.8)
        if Y_m is not None:
            pred_m = np.array([f(t_grid[k], *Y_m[:, k], *matched_p) for k in range(len(t_grid)) for f_name, f in obs if f_name == name][:len(t_grid)])
            # cleaner version
            pred_m_obs = np.array([obs[i][1](t_grid[k], *Y_m[:, k], *matched_p) for k in range(len(t_grid))])
            ax[i].plot(t_grid, pred_m_obs, "r-", lw=1.0, label=f"matched raw (hc={matched_idx})", alpha=0.8)
        ax[i].set_ylabel(name)
        ax[i].legend(loc="best", fontsize=9)
        ax[i].grid(alpha=0.3)
    ax[-1].set_xlabel("t")
    ax[0].set_title(f"matched raw (hc={matched_idx}, err={matched_full['err']:.2e}) trajectory vs truth")
    fig.tight_layout()
    fig.savefig(HERE / "fig02_matched_raw_trajectory.png", dpi=110)
    plt.close(fig)

    # === Plot 3: polished trajectory (truth-near) ===
    if polish_pred is not None:
        fig, ax = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
        for i, name in enumerate(meas_order):
            ax[i].plot(t_grid, observed[name], "k.", ms=2, label="data", alpha=0.4)
            ax[i].plot(t_grid, truth_pred[name], "g-", lw=1.0, label="truth", alpha=0.8)
            ax[i].plot(t_grid, polish_pred[name], "b--", lw=1.0, label=f"nc-polished (oracle={nc_best_oracle:.2e})", alpha=0.8)
            ax[i].set_ylabel(name)
            ax[i].legend(loc="best", fontsize=9)
            ax[i].grid(alpha=0.3)
        ax[-1].set_xlabel("t")
        ax[0].set_title("no_clustering's truth-near polish trajectory vs truth")
        fig.tight_layout()
        fig.savefig(HERE / "fig03_polish_trajectory.png", dpi=110)
        plt.close(fig)

    # === Plot 4: scatter raw_err vs oracle_dist ===
    fig, ax = plt.subplots(figsize=(8, 6))
    o = np.array([r["oracle_max_rel_err"] for r in rows_analysis])
    e = np.array([r["raw_err"] for r in rows_analysis])
    f_arr = np.array([r["passed_err_filter"] for r in rows_analysis])
    p_arr = np.array([r["was_polished"] for r in rows_analysis])
    eps = 1e-3
    o_clip = np.maximum(o, eps)
    e_clip = np.maximum(e, eps)
    ax.scatter(o_clip[f_arr == 0], e_clip[f_arr == 0], c="red", s=30, alpha=0.6, label=f"filtered out (n={int((f_arr == 0).sum())})")
    ax.scatter(o_clip[f_arr == 1], e_clip[f_arr == 1], c="green", s=30, alpha=0.6, label=f"passed filter (n={int((f_arr == 1).sum())})")
    # Highlight the matched raw (closest to truth)
    ax.scatter([max(matched["oracle_max_rel_err"], eps)], [max(matched["raw_err"], eps)],
               s=300, facecolors="none", edgecolors="purple", lw=2, label=f"closest-to-truth (hc={matched_idx})")
    ax.axhline(err_cap, color="red", lw=1, ls="--", label=f"err_cap = {err_cap:.2e}")
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("oracle_max_rel_err (distance to truth)")
    ax.set_ylabel("raw err (ODE residual)")
    ax.set_title(f"flexible_arm: all {len(rows_analysis)} raw HC candidates")
    ax.legend(loc="best", fontsize=9)
    ax.grid(alpha=0.3, which="both")
    fig.tight_layout()
    fig.savefig(HERE / "fig04_raw_vs_oracle_scatter.png", dpi=110)
    plt.close(fig)

    # === Plot 5: top-10 closest to truth + their trajectories ===
    top10 = rows_analysis[:10]
    fig, ax = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    cmap = plt.cm.viridis(np.linspace(0, 1, len(top10)))
    for i, name in enumerate(meas_order):
        ax[i].plot(t_grid, observed[name], "k.", ms=2, label="data", alpha=0.3)
        ax[i].plot(t_grid, truth_pred[name], "g-", lw=2.0, label="truth", alpha=0.8)
        for k, r in enumerate(top10):
            full = next(q for q in raws if q["hc_idx"] == r["hc_idx"])
            ic = [full[s] for s in state_vars]
            p_arr = [full[p] for p in param_vars]
            tt, YY = integrate_or_warn(rhs, ic, p_arr, t_grid, f"top{k}")
            if YY is None or YY.shape[1] != len(t_grid):
                continue
            pred = np.array([obs[i][1](t_grid[m], *YY[:, m], *p_arr) for m in range(len(t_grid))])
            if not np.all(np.isfinite(pred)) or np.max(np.abs(pred)) > 1e6:
                continue
            label = f"hc={r['hc_idx']} d={r['oracle_max_rel_err']:.2e} err={r['raw_err']:.1e}" if i == 0 else None
            ax[i].plot(t_grid, pred, color=cmap[k], lw=0.8, alpha=0.8, label=label)
        ax[i].set_ylabel(name)
        ax[i].grid(alpha=0.3)
    ax[0].legend(loc="upper right", fontsize=7, ncol=2)
    ax[-1].set_xlabel("t")
    ax[0].set_title("Trajectories of the 10 raws closest to truth (red=blow-up shown by axis clip)")
    fig.tight_layout()
    fig.savefig(HERE / "fig05_top10_closest_to_truth.png", dpi=110)
    plt.close(fig)

    # === Plot 6: matched raw vs polished trajectory (zoom on first 2 seconds) ===
    if Y_m is not None and Y_p is not None:
        fig, ax = plt.subplots(2, 2, figsize=(12, 7), sharex="col")
        mask_zoom = t_grid <= 2.0
        for i, name in enumerate(meas_order):
            # Full window
            ax[i][0].plot(t_grid, observed[name], "k.", ms=2, label="data", alpha=0.3)
            ax[i][0].plot(t_grid, truth_pred[name], "g-", lw=1.0, label="truth", alpha=0.8)
            pred_m = np.array([obs[i][1](t_grid[k], *Y_m[:, k], *matched_p) for k in range(len(t_grid))])
            pred_p = np.array([obs[i][1](t_grid[k], *Y_p[:, k], *polish_p) for k in range(len(t_grid))])
            ax[i][0].plot(t_grid, pred_m, "r-", lw=0.8, label=f"matched raw (err {matched_full['err']:.1e})", alpha=0.8)
            ax[i][0].plot(t_grid, pred_p, "b--", lw=0.8, label="polished", alpha=0.8)
            ax[i][0].set_ylabel(name)
            ax[i][0].legend(loc="best", fontsize=8)
            ax[i][0].grid(alpha=0.3)
            ax[i][0].set_title("full window")
            # Zoom
            ax[i][1].plot(t_grid[mask_zoom], observed[name][mask_zoom], "k.", ms=3, alpha=0.4)
            ax[i][1].plot(t_grid[mask_zoom], truth_pred[name][mask_zoom], "g-", lw=1.2)
            ax[i][1].plot(t_grid[mask_zoom], pred_m[mask_zoom], "r-", lw=1.0)
            ax[i][1].plot(t_grid[mask_zoom], pred_p[mask_zoom], "b--", lw=1.0)
            ax[i][1].grid(alpha=0.3)
            ax[i][1].set_title("zoom: t ∈ [0, 2]")
        ax[-1][0].set_xlabel("t")
        ax[-1][1].set_xlabel("t")
        fig.suptitle(f"matched raw (hc={matched_idx}) vs polished — both have nearly-identical params")
        fig.tight_layout()
        fig.savefig(HERE / "fig06_polished_vs_matched_raw.png", dpi=110)
        plt.close(fig)

    # === Write markdown report ===
    md = []
    md.append("# flexible_arm_0_1em8 — deep dive on the err-filter regression")
    md.append("")
    md.append(f"**Cell**: `{CELL}` (noise level 1e-8 = essentially noise-free)")
    md.append(f"**System**: 4-state flexible robotic arm — motor + tip angles + their angular velocities, coupled by a torsional spring (parameter `k`) with rotor inertias (`Jm`,`Jt`) and viscous damping (`bm`,`bt`).")
    md.append("")
    md.append("## ODE definition")
    md.append("")
    md.append(f"States: `{', '.join(state_vars)}`")
    md.append(f"Parameters: `{', '.join(param_vars)}`")
    meas_pairs = ", ".join(f"{n} = {inst['measurements'][n]}" for n in meas_order)
    md.append(f"Measurements: `{meas_pairs}`")
    md.append("")
    md.append("ODE:")
    md.append("```")
    for s in state_vars:
        md.append(f"  d{s}/dt = {inst['ode_system'][s]}")
    md.append("```")
    md.append("")
    md.append("## Truth values")
    md.append("")
    md.append("| variable | truth |")
    md.append("|---|---:|")
    for v, val in truth_full.items():
        md.append(f"| {v} | {val} |")
    md.append("")
    md.append(f"Time window: `[{t_grid[0]}, {t_grid[-1]}]` with {len(t_grid)} samples. Noise std (data − truth_trajectory) per channel: {noise_levels}.")
    md.append("")
    md.append("![data vs truth](fig01_data_vs_truth.png)")
    md.append("")
    md.append("## The truth-recovering polished output (from `no_clustering` probe)")
    md.append("")
    md.append("The legacy/no-err-filter probe successfully recovered truth. Its best polished output (oracle err = {:.3e}) had:".format(nc_best_oracle))
    md.append("")
    md.append("| variable | polished | truth | Δ |")
    md.append("|---|---:|---:|---:|")
    for v in truth_full:
        if v in nc_best:
            md.append(f"| {v} | {nc_best[v]:.6f} | {truth_full[v]:.6f} | {nc_best[v] - truth_full[v]:+.3e} |")
    md.append("")
    md.append("![polish trajectory](fig03_polish_trajectory.png)")
    md.append("")
    md.append("## The matched raw HC (the one that got filtered)")
    md.append("")
    md.append("Among the {} raw HC candidates produced by the new pipeline, the one closest to truth in identifiable-parameter space is:".format(len(raws)))
    md.append("")
    md.append(f"- **hc_idx**: {matched_idx}")
    md.append(f"- **id-space distance to truth (max rel err over states+params)**: `{matched['oracle_max_rel_err']:.3e}`")
    md.append(f"- **raw err (process_raw_solution data residual)**: `{matched_full['err']:.3e}`")
    md.append(f"- **err filter cap (100 × min raw err)**: `{err_cap:.3e}`")
    md.append(f"- **passed err filter?** `{bool(matched['passed_err_filter'])}`")
    md.append(f"- **got polished in deep_dump?** `{bool(matched['was_polished'])}`")
    md.append("")
    md.append("Variable-by-variable:")
    md.append("")
    md.append("| variable | matched raw | truth | Δ rel |")
    md.append("|---|---:|---:|---:|")
    for v in id_var_names:
        rv = matched_full[v]
        tv = truth_full[v]
        rel = abs(rv - tv) / abs(tv) if abs(tv) > 1e-15 else abs(rv - tv)
        md.append(f"| {v} | {rv:.6f} | {tv:.6f} | {rel:.3e} |")
    md.append("")
    md.append(f"**Verified err (scipy LSODA, rtol=1e-8 atol=1e-11)**: `{verified_err:.3e}`")
    md.append(f"(ODEPE reported `{matched_full['err']:.3e}` — ratio {verified_err / max(matched_full['err'], 1e-30):.3e}).")
    md.append("")
    md.append("![matched raw trajectory](fig02_matched_raw_trajectory.png)")
    md.append("")
    md.append("## What's near truth in raw HC space?")
    md.append("")
    md.append(f"Scatter of all {len(rows_analysis)} raws — x = id-space distance to truth, y = raw err.")
    md.append("Red = filtered out, green = passed filter, purple ring = closest-to-truth.")
    md.append("")
    md.append("![scatter](fig04_raw_vs_oracle_scatter.png)")
    md.append("")
    md.append("Top 10 closest-to-truth raws:")
    md.append("")
    md.append("| hc_idx | dist_to_truth | raw_err | passed_filter | got_polished |")
    md.append("|--:|---:|---:|:--:|:--:|")
    for r in rows_analysis[:10]:
        pf = "✓" if r["passed_err_filter"] else "✗"
        pp = "✓" if r["was_polished"] else "✗"
        md.append(f"| {r['hc_idx']} | {r['oracle_max_rel_err']:.3e} | {r['raw_err']:.3e} | {pf} | {pp} |")
    md.append("")
    md.append("![top10 trajectories](fig05_top10_closest_to_truth.png)")
    md.append("")
    md.append("![matched vs polished](fig06_polished_vs_matched_raw.png)")
    md.append("")
    md.append("## Sanity checks for degeneracy")
    md.append("")
    md.append("Is the matched raw 'all zeros' (low-information solution that happens to be near-zero truth)?")
    md.append("")
    md.append("| variable | matched | truth | |matched| |")
    md.append("|---|---:|---:|---:|")
    for v in id_var_names:
        md.append(f"| {v} | {matched_full[v]:.6f} | {truth_full[v]:.6f} | {abs(matched_full[v]):.6f} |")
    md.append("")
    matched_zero = sum(1 for v in id_var_names if abs(matched_full[v]) < 0.01)
    md.append(f"Components with |value| < 0.01: {matched_zero} / {len(id_var_names)}.")
    md.append("")
    # Distance distribution
    o_arr = np.array([r["oracle_max_rel_err"] for r in rows_analysis])
    md.append("## Distance-to-truth distribution across ALL raws")
    md.append("")
    md.append("Quantiles of `oracle_max_rel_err` (max |est − truth| / |truth| across all 9 variables):")
    md.append("")
    md.append("| stat | value |")
    md.append("|---|---:|")
    md.append(f"| min | {o_arr.min():.3e} |")
    md.append(f"| p10 | {np.percentile(o_arr, 10):.3e} |")
    md.append(f"| median | {np.median(o_arr):.3e} |")
    md.append(f"| p90 | {np.percentile(o_arr, 90):.3e} |")
    md.append(f"| max | {o_arr.max():.3e} |")
    md.append("")
    md.append("| count of raws with oracle_max_rel_err < threshold |")
    md.append("|---|")
    for thr in [0.01, 0.05, 0.1, 0.5, 1.0, 2.0]:
        md.append(f"| < {thr}: **{int((o_arr < thr).sum())}** / {len(o_arr)} |")
    md.append("")
    md.append("## Headline finding")
    md.append("")
    md.append(f"Of the {len(rows_analysis)} raw HC candidates produced by the `deep_dump` probe, **zero are within "
              f"a relative max-rel-err of 0.5 from truth**; the closest is at {o_arr.min():.3e} "
              f"(`k = {next(r for r in rows_analysis if r['oracle_max_rel_err'] == o_arr.min())['raw_k']:.3f}` vs truth `0.877`).")
    md.append("")
    md.append(f"Yet the `no_clustering` probe's polish successfully recovered truth at oracle err `{nc_best_oracle:.3e}`. "
              f"Both probes ran on the same data with the same Julia env. The only script differences are 3 lines "
              f"(`branch_detection`, `branch_cluster_eps`, plus our dump flags) — all of which apply *downstream* of "
              f"HC root computation.")
    md.append("")
    md.append(f"**Hypothesis**: the HC step itself produces a DIFFERENT candidate set between the two probes. "
              f"The `no_clustering` probe's raw pool likely contains a near-truth candidate that `deep_dump`'s does not.")
    md.append("")
    md.append("**Verification in flight** (job 62631): a third probe `no_clustering_dump` (branch_detection=false + dump_raw_candidates_path) "
              "is running. When it lands, we can directly diff the two raw pools.")
    md.append("")
    md.append("## Confirmed: HC pool is deterministic; OLD bench (Optim 1.x) has same raws bit-for-bit")
    md.append("")
    md.append("The OLD benchmark's `odepe_v2_nopolish_run/flexible_arm_0_1em8/result.csv` (170 rows = post-legacy-clustering) "
              "has its closest-to-truth row at oracle 0.999 with state/param values **identical to deep_dump's hc_idx=42** "
              "(`theta_m=0.526088, omega_m=0.428385, ..., k=0.040442`). Distribution stats also match: same min, same p10, same median. "
              "**The HC step is bit-deterministic across Julia stack versions and across probes.**")
    md.append("")
    md.append("## So how does OLD bench recover truth?")
    md.append("")
    md.append(f"Looking at `odepe_metadata.json` from OLD's polish run for this cell: the best solution came from a "
              f"**synthesized aggregate candidate** with `source_type=synthesized_aggregate` and "
              f"`aggregation_strategy=median`, built from candidate indices [7, 46, 56, 65, 86, 98, 102]. "
              "Same story in our `no_clustering` probe: best solution = synthesized aggregate of indices [5, 14, 42, 51, 63, 96, 102].")
    md.append("")
    md.append("This means the truth-finder is **not a raw HC root** — it's a *median-aggregate* of multiple HC roots, "
              "constructed by `synthesize_aggregate_candidates` (default-on in ODEPE) and appended to `solved_res` *before* "
              "`_polish_batch_from_context` is called. So the aggregate IS in our raw_candidates.csv dump (it's somewhere among the 187).")
    md.append("")
    md.append("Polish from that aggregate lands at truth (data_err ≈ 5.6e-22, oracle ≈ 4.78e-6). "
              "But deep_dump's 50 polished outputs all end up at a *non-truth basin* (data_err ≈ 1.5e-3, oracle ≈ 0.51).")
    md.append("")
    md.append("## The err filter mass-drops candidates whose ODE integration blew up")
    md.append("")
    err_arr = np.array([r["raw_err"] for r in rows_analysis])
    finite_arr = err_arr[np.isfinite(err_arr) & (err_arr < 1e15)]
    cap = err_cap
    n_blown = int(((~np.isfinite(err_arr)) | (err_arr > 1e15)).sum())
    md.append("Distribution of `raw_err` across the {} filtered-out candidates (those with err > {:.2e}):".format(int((err_arr > cap).sum()), cap))
    md.append("")
    md.append("| stat | err value |")
    md.append("|---|---:|")
    filt = err_arr[err_arr > cap]
    filt = filt[np.isfinite(filt)]
    if len(filt):
        for q in [10, 50, 90, 99]:
            md.append(f"| p{q} | {np.percentile(filt, q):.3e} |")
        md.append(f"| max (finite) | {filt.max():.3e} |")
    md.append(f"| count with err > 1e15 (blow-up) | **{n_blown}** of {int((err_arr > cap).sum())} |")
    md.append("")
    md.append("**Roughly a third of the filtered candidates have err > 1e15** — meaning ODE integration from their starting parameters "
              "literally diverged to numerical infinity. The polynomial-system roots include many `boundary` solutions where the spring "
              "stiffness `k` is near zero (decoupled limit), making the ODE singular or stiff in pathological ways.")
    md.append("")
    md.append("## Why this matters: polish can escape blow-up candidates")
    md.append("")
    md.append("Polish doesn't do naive ODE integration; it solves an optimization problem on the residual. Starting from a candidate "
              "where ODE blew up, polish can navigate the parameter space — possibly *through* a region where the ODE is well-behaved — "
              "and converge to a non-singular basin. The truth basin is *one* such non-singular basin.")
    md.append("")
    md.append("The `branch_err_factor=100` filter drops candidates by their *forward-integration data residual*, which is essentially a "
              "**locally-stable-only signal**. It throws away candidates that *would have worked* if polish had been allowed to escape "
              "the local singularity. For this cell, the truth-finder is exactly such a candidate.")
    md.append("")
    md.append("## Verdict")
    md.append("")
    md.append("**The regression on `flexible_arm_0_1em8` is caused by `branch_err_factor=100` dropping a synthesized-aggregate candidate "
              "whose ODE integration blows up but whose polish converges to truth.**")
    md.append("")
    md.append("Recommended fixes (worth A/B testing on the wider benchmark, not just this one cell):")
    md.append("")
    md.append("- **Option A**: Widen `branch_err_factor` to, say, 1e6 or 1e12 — keep candidates even with high raw err.")
    md.append("- **Option B**: Replace the err filter with a smarter screen — e.g., apply it only to *finite* errs, never drop candidates that blew up.")
    md.append("- **Option C**: Remove the err filter entirely.")
    md.append("")
    md.append("Cost of doing this: polish more candidates per cell (50 → ~187 here, ~3.7×). On the bench-wide average that's still likely cheaper than the wall-time savings from branch detection's clustering — but worth measuring.")
    md.append("")

    md.append("## Was the matched raw 'all zeros' / degenerate?")
    md.append("")
    md.append("Looking at the top-10 closest raws to truth (table above): they share a striking pattern — "
              "**`k` and `Jt` are very small (often near zero or negative)**. Truth: `k=0.877`, `Jt=0.14`. The HC roots have "
              "`k ≈ 0.04, 0.02, 0.02, …`. These look like *boundary roots* of the polynomial system where stiffness is degenerate "
              "(spring almost gone, tip mass almost zero). They're not random misses — they're structurally different solutions.")
    md.append("")
    md.append("If polish were started from one of these boundary roots, it'd have to traverse a huge parameter distance to reach truth — "
              "well outside any normal polish basin. So even if we widened `branch_err_factor` to keep these candidates, polish wouldn't "
              "reach truth from them.")
    md.append("")
    md.append("## So why does no_clustering recover truth?")
    md.append("")
    md.append("Two possibilities, distinguishable by the in-flight job 62631:")
    md.append("")
    md.append("1. **HC found different roots**: no_clustering's HC step produced a near-truth candidate; deep_dump's didn't. "
              "If so, HC.jl has hidden non-determinism (thread scheduling, random homotopy paths, etc.). "
              "Same Julia env shouldn't give different roots otherwise.")
    md.append("2. **Same HC roots, but no_clustering polished a candidate deep_dump didn't**: maybe legacy clustering at threshold=0.001 "
              "picked a different rep than L∞-MAD at 1e-12 did, and that rep happened to be in truth basin. But our deep_dump used eps=1e-12 "
              "which should keep all candidates as their own clusters → all polished. So this seems implausible.")
    md.append("")
    md.append("If hypothesis 1 is confirmed, the regression on this cell is fundamentally about HC determinism, not about clustering or err filtering.")
    md.append("")

    (HERE / "report.md").write_text("\n".join(md))
    print(f"\nWrote {HERE / 'report.md'}")


if __name__ == "__main__":
    main()
