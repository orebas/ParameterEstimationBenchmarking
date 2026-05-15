#!/usr/bin/env python3
"""Offline 2D (pre_eps, post_eps) sweep for polish-pipeline branch clustering.

Reads a `deep_dump` probe's outputs:
  - raw_candidates.csv: every raw HC candidate (input to _polish_cluster_metadata)
                        with state/param values + err + all_unidentifiable
  - result.csv:         polished outputs, with a polish_source_hc_idx column
                        pointing back to a row in raw_candidates.csv

For each cell, for each (pre_eps, post_eps) pair:
  1. Apply branch_err_factor (=100) filter on raw HC candidates
  2. L∞-MAD cluster surviving raw candidates at pre_eps → reps
  3. Look up the polished version of each rep via polish_source_hc_idx
  4. L∞-MAD cluster polished reps at post_eps → final survivors
  5. Compute oracle-best max_rel_err vs truth across final survivors

Outputs:
  eps_grid.csv  — flat per-(cell, pre_eps, post_eps)
  eps_grid.md   — per-cell 6×6 heatmaps
"""
import csv
import json
import math
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH = REPO / "benchmark_numbat_2026-05-12"
HERE = REPO / "results/numbat_analysis/branch_detection_comparison"

EPS_LADDER = [1e-4, 1e-3, 5e-3, 1e-2, 2e-2, 5e-2]
BRANCH_ERR_FACTOR = 100.0   # match ODEPE default
BRANCH_RESID_FACTOR = 100.0  # match ODEPE default

POLISH_PROBES = [
    "flexible_arm_0_1em8",
    "daisy_mamil4_8_1em8",
    "seir_3_0",
    "vanderpol_6_1em2",
    "quadrotor_9_1em4",
    "fitzhugh_nagumo_4_1em6",
    "fitzhugh_nagumo_0_1em4",
]


def normalize(c):
    return c[:-3] if c.endswith("(t)") else c


def parse_state_param_columns(header):
    """Given raw_candidates.csv header (with s::x1, p::a, etc.), return
    (state_names_normalized, param_names_normalized, state_cols, param_cols)."""
    state_cols, param_cols = [], []
    state_names, param_names = [], []
    for h in header:
        if h.startswith("s::"):
            state_cols.append(h)
            state_names.append(normalize(h[3:]))
        elif h.startswith("p::"):
            param_cols.append(h)
            param_names.append(normalize(h[3:]))
    return state_names, param_names, state_cols, param_cols


def read_raw_candidates(path):
    """Returns:
      hc_idx (n,) int
      X (n, d) float identifiable state+param matrix (id columns only)
      err (n,) float (np.inf for blank/non-finite)
      id_var_names list[str]
      truth_full_var_names list[str] (state+param normalized, in order)
    Identifiability: derived per-row from `all_unidentifiable` (uses *intersection* — keep var as
    identifiable only if it's never listed as unidentifiable). Robust to empty all_unid rows.
    """
    with open(path) as f:
        rdr = csv.DictReader(f)
        rows = list(rdr)
        header = rdr.fieldnames or []
    state_names, param_names, state_cols, param_cols = parse_state_param_columns(header)
    all_var_names = state_names + param_names
    all_var_cols = state_cols + param_cols
    n = len(rows)

    hc_idx = np.array([int(r["hc_idx"]) for r in rows])

    err = np.full(n, np.inf)
    for i, r in enumerate(rows):
        v = r.get("err", "").strip()
        if v:
            try:
                fv = float(v)
                if math.isfinite(fv):
                    err[i] = fv
            except ValueError:
                pass

    # Identifiability: union of "ever-unidentifiable" across rows. A var is identifiable
    # only if no row ever lists it as unidentifiable.
    ever_unid = set()
    for r in rows:
        u = r.get("all_unidentifiable", "")
        if u:
            for nm in u.split(";"):
                nm = nm.strip()
                if nm:
                    ever_unid.add(normalize(nm))
    id_mask = [vn not in ever_unid for vn in all_var_names]
    id_var_names = [vn for vn, m in zip(all_var_names, id_mask) if m]
    id_var_cols = [vc for vc, m in zip(all_var_cols, id_mask) if m]

    if not id_var_names:
        return hc_idx, np.zeros((n, 0)), err, [], all_var_names, header

    X = np.zeros((n, len(id_var_names)))
    for i, r in enumerate(rows):
        for j, c in enumerate(id_var_cols):
            try:
                X[i, j] = float(r[c])
            except (ValueError, TypeError, KeyError):
                X[i, j] = np.nan
    return hc_idx, X, err, id_var_names, all_var_names, header


def read_polished_dump(path, id_var_names, all_var_names):
    """Read polished_results.csv (one row per polished cluster rep, BEFORE
    downstream clustering). Schema:
      polish_idx,polish_source_hc_idx,s::x1(t),...,p::a,...,err,post_polish_error

    Returns:
      polish_src_idx (m,) int (1-based hc_idx in raw_candidates.csv)
      X_p (m, d_id) float (identifiable values)
      values_full (m,) dict[name -> float] for oracle calculation
      err_arr (m,) float (data residual, NaN if missing)
      ppe_arr (m,) float (post_polish_error, NaN if missing)
    """
    with open(path) as f:
        rdr = csv.DictReader(f)
        rows = list(rdr)
        header = rdr.fieldnames or []

    # Build state/param name lookup (cols are "s::x1(t)", "p::a")
    state_cols, param_cols = [], []
    state_names, param_names = [], []
    for h in header:
        if h.startswith("s::"):
            state_cols.append(h)
            state_names.append(normalize(h[3:]))
        elif h.startswith("p::"):
            param_cols.append(h)
            param_names.append(normalize(h[3:]))
    full_name_to_col = {n: c for n, c in zip(state_names, state_cols)}
    full_name_to_col.update({n: c for n, c in zip(param_names, param_cols)})

    m = len(rows)
    polish_src = np.zeros(m, dtype=int)
    X_p = np.zeros((m, len(id_var_names)))
    values_full = []
    err_arr = np.full(m, np.nan)
    ppe_arr = np.full(m, np.nan)
    for i, r in enumerate(rows):
        try:
            psh = r.get("polish_source_hc_idx", "")
            polish_src[i] = int(float(psh)) if psh.strip() else -1
        except (ValueError, TypeError):
            polish_src[i] = -1
        for s in ("err", "post_polish_error"):
            v = r.get(s, "").strip()
            if v:
                try:
                    fv = float(v)
                    if s == "err":
                        err_arr[i] = fv
                    else:
                        ppe_arr[i] = fv
                except ValueError:
                    pass
        for j, vn in enumerate(id_var_names):
            col = full_name_to_col.get(vn)
            try:
                X_p[i, j] = float(r[col]) if col else np.nan
            except (ValueError, TypeError, KeyError):
                X_p[i, j] = np.nan
        d = {}
        for vn in all_var_names:
            col = full_name_to_col.get(vn)
            if col is None:
                continue
            try:
                d[vn] = float(r[col])
            except (ValueError, TypeError, KeyError):
                pass
        values_full.append(d)
    return polish_src, X_p, values_full, err_arr, ppe_arr


def oracle_max_rel(values_dict, truth_id_vars):
    vals = []
    for v, tv in truth_id_vars.items():
        ev = values_dict.get(v)
        if ev is None:
            continue
        if abs(tv) > 1e-15:
            vals.append(abs(ev - tv) / abs(tv))
        else:
            vals.append(abs(ev - tv))
    return max(vals) if vals else np.inf


def linfmad_cluster_greedy(X, err_sorted_idx_into_X, eps):
    """Same algorithm as in nopolish_eps_ladder.py. X is the (n, d) matrix of
    *all* candidates; err_sorted_idx_into_X selects rows of X in order. The
    returned reps are indices into X (rows of err_sorted_idx_into_X)."""
    if X.shape[0] == 0:
        return []
    med = np.median(X, axis=0)
    mad = np.median(np.abs(X - med), axis=0)
    scale = np.maximum.reduce([np.abs(med), mad, np.full_like(med, 1e-10)])
    Xn = (X - med) / scale
    clusters = []
    reps = []
    for orig_idx in err_sorted_idx_into_X:
        pt = Xn[orig_idx]
        if not np.all(np.isfinite(pt)):
            # Treat NaN candidate as its own cluster
            clusters.append([orig_idx])
            reps.append(orig_idx)
            continue
        joined = False
        for members in clusters:
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


def get_truth_id_vars(inst, non_id_set):
    truth = {**(inst.get("state_values") or {}), **(inst.get("parameter_values") or {})}
    return {v: val for v, val in truth.items() if v not in non_id_set}


def read_non_id(bench):
    out = {}
    for est in ("odepe_v2_polish", "odepe_v2_nopolish"):
        rd = bench / "filetree" / f"{est}_run"
        if not rd.exists():
            continue
        for cell in rd.iterdir():
            md = cell / "odepe_metadata.json"
            if not md.exists():
                continue
            sn = cell.name.rsplit("_", 2)[0]
            if sn in out:
                continue
            try:
                d = json.load(open(md))
                out[sn] = {normalize(v) for v in (d.get("best", {}).get("all_unidentifiable") or [])}
            except Exception:
                pass
    return out


def grid_for_cell(probe_dir, inst, truth_id_vars):
    raw_csv = probe_dir / "raw_candidates.csv"
    pol_csv = probe_dir / "polished_results.csv"
    if not raw_csv.exists() or not pol_csv.exists():
        return None, f"missing files in {probe_dir} (need raw_candidates.csv + polished_results.csv)"

    hc_idx, X_raw_full, err_raw_full, id_var_names, all_var_names, _ = read_raw_candidates(raw_csv)
    polish_src, X_p_full, values_full, err_polished_full, ppe_polished_full = read_polished_dump(
        pol_csv, id_var_names, all_var_names
    )

    if len(polish_src) == 0:
        return None, f"empty polished dump in {pol_csv}"

    # The polished_results dump contains one row per pre-polish cluster rep (the
    # 97 = err-filter-survivors-deduplicated-at-eps=1e-12 raws for vanderpol).
    # Because the in-package clustering keeps the lowest-err member as cluster rep,
    # and any wider pre_eps cluster is a union of eps=1e-12 micro-clusters, the
    # rep of any wider cluster is necessarily one of these polished rows. So:
    # use these polish_source_hc_idx values as the pre-polish candidate pool.
    # Map polished_idx → raw row index (0-based into raw_candidates).
    pool_raw_indices = []
    pool_polished_indices = []
    for ki, hc in enumerate(polish_src):
        ihc = int(hc)
        if ihc >= 1 and ihc <= len(hc_idx):
            pool_raw_indices.append(ihc - 1)  # raw_candidates.csv 1-based hc_idx
            pool_polished_indices.append(ki)
    pool_raw_indices = np.array(pool_raw_indices, dtype=int)
    pool_polished_indices = np.array(pool_polished_indices, dtype=int)

    # Sub-arrays for clustering
    X_raw_pool = X_raw_full[pool_raw_indices]       # (n_pool, d_id) raw id-values
    err_raw_pool = err_raw_full[pool_raw_indices]   # (n_pool,) raw err
    X_p_pool = X_p_full[pool_polished_indices]      # (n_pool, d_id) polished id-values
    oracle_pool = np.array([oracle_max_rel(values_full[ki], truth_id_vars)
                            for ki in pool_polished_indices])

    # Polished err for post-polish ranking: prefer `err`, fall back to `post_polish_error`,
    # fall back to raw err.
    err_p_pool = err_polished_full[pool_polished_indices].copy()
    nan = np.isnan(err_p_pool)
    err_p_pool = np.where(nan, ppe_polished_full[pool_polished_indices], err_p_pool)
    nan = np.isnan(err_p_pool)
    if np.any(nan):
        err_p_pool = np.where(nan, err_raw_pool, err_p_pool)
    err_p_pool = np.where(np.isfinite(err_p_pool), err_p_pool, np.inf)

    n_pool = len(pool_raw_indices)
    if n_pool == 0:
        return None, "empty pool after polish_source_hc_idx mapping"

    # Pre-polish err filter on the FULL raw set (matches in-package behavior).
    # MAD/clustering must be done on the full survivor set, not just the 22-pool —
    # otherwise the MAD scale differs and eps thresholds give different cluster boundaries.
    finite_raw = err_raw_full[np.isfinite(err_raw_full)]
    if len(finite_raw) == 0:
        return None, f"no finite-err raw candidates in {raw_csv}"
    err_cap_pre = BRANCH_ERR_FACTOR * max(np.min(finite_raw), np.finfo(float).eps)
    raw_survivor_mask = np.isfinite(err_raw_full) & (err_raw_full <= err_cap_pre)
    raw_survivor_idx = np.where(raw_survivor_mask)[0]  # 0-based into X_raw_full
    if len(raw_survivor_idx) == 0:
        return None, "no raw survivors after err filter"

    # Build hc_idx (1-based) → pool position lookup for polish lookup.
    hc_to_poolpos = {int(hc_idx[pool_raw_indices[p]]): p for p in range(n_pool)}

    out_rows = []
    for pre_eps in EPS_LADDER:
        # Cluster the FULL err-filter survivors at pre_eps using their RAW id values.
        # MAD computed over the full survivor pool — matches in-package behavior.
        X_survivors = X_raw_full[raw_survivor_idx]
        err_survivors = err_raw_full[raw_survivor_idx]
        order_loc = np.argsort(err_survivors, kind="stable")
        # linfmad_cluster_greedy operates on full X_survivors; returns 0-based indices into it.
        pre_reps_local = linfmad_cluster_greedy(X_survivors, order_loc, pre_eps)
        # Map back to (1-based) hc_idx via raw_survivor_idx
        pre_reps_hc = [int(hc_idx[raw_survivor_idx[i]]) for i in pre_reps_local]

        # For each rep, look up its polished version (should be in the 22-pool by
        # the lowest-err-rep property). If not, skip (rare — only if rep is a non-
        # micro-rep, which shouldn't happen at any eps ≥ 1e-12).
        pre_reps_poolpos = []
        for hc in pre_reps_hc:
            p = hc_to_poolpos.get(hc)
            if p is not None:
                pre_reps_poolpos.append(p)
        if not pre_reps_poolpos:
            for post_eps in EPS_LADDER:
                out_rows.append({
                    "cell": probe_dir.parent.name, "pre_eps": pre_eps, "post_eps": post_eps,
                    "n_pool": n_pool, "n_pre_reps": 0, "n_post_reps": 0,
                    "oracle_best": np.inf,
                })
            continue

        X_post = X_p_pool[pre_reps_poolpos]
        oracle_post = oracle_pool[pre_reps_poolpos]
        err_post = err_p_pool[pre_reps_poolpos]

        # Post-polish err filter (per the package _detect_branches pre-filter at
        # line 218-226: drop entries with err > branch_resid_factor * min).
        finite_post = err_post[np.isfinite(err_post)]
        if len(finite_post) > 0:
            post_cap = BRANCH_RESID_FACTOR * max(np.min(finite_post), np.finfo(float).eps)
            post_keep = np.isfinite(err_post) & (err_post <= post_cap)
        else:
            post_keep = np.ones(len(err_post), dtype=bool)

        for post_eps in EPS_LADDER:
            kept_idx_post = np.where(post_keep)[0]
            if len(kept_idx_post) == 0:
                out_rows.append({
                    "cell": probe_dir.parent.name, "pre_eps": pre_eps, "post_eps": post_eps,
                    "n_pool": n_pool, "n_pre_reps": len(pre_reps_pool), "n_post_reps": 0,
                    "oracle_best": np.inf,
                })
                continue
            kept_sorted_post = kept_idx_post[np.argsort(err_post[kept_idx_post], kind="stable")]
            post_reps = linfmad_cluster_greedy(X_post, kept_sorted_post, post_eps)
            oracle_best = float(np.min(oracle_post[post_reps])) if post_reps else float("inf")
            out_rows.append({
                "cell": probe_dir.parent.name,
                "pre_eps": pre_eps,
                "post_eps": post_eps,
                "n_pool": n_pool,
                "n_pre_reps": len(pre_reps_poolpos),
                "n_post_reps": len(post_reps),
                "oracle_best": oracle_best,
            })
    return out_rows, None


def main():
    instances = {c["id"]: c for c in json.load(open(BENCH / "huge_json.json"))["instances"]}
    non_id = read_non_id(BENCH)

    all_rows = []
    for cell_id in POLISH_PROBES:
        probe_dir = BENCH / "probes" / cell_id / "deep_dump"
        if not probe_dir.exists():
            print(f"[skip] {cell_id}: probe dir missing")
            continue
        inst = instances[cell_id]
        sys_name = inst["name"]
        non_id_set = non_id.get(sys_name, set())
        truth_id_vars = get_truth_id_vars(inst, non_id_set)

        rows, err = grid_for_cell(probe_dir, inst, truth_id_vars)
        if err:
            print(f"[skip] {cell_id}: {err}")
            continue
        all_rows.extend(rows)
        print(f"[ok] {cell_id}: {len(rows)} grid cells")

    # Write CSV
    keys = ["cell", "pre_eps", "post_eps", "n_pool", "n_pre_reps", "n_post_reps", "oracle_best"]
    out_csv = HERE / "eps_grid.csv"
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(all_rows)
    print(f"\nWrote {out_csv} ({len(all_rows)} rows)")

    # Markdown
    md = ["# 2D eps grid — polish-pipeline branch clustering", "",
          f"**Setup**: 7 polish probes, branch_detection=true, eps=1e-12. Raw HC candidates dumped.",
          f"For each (pre_eps, post_eps) pair the package's full pipeline is simulated offline:",
          f"err-filter → pre-cluster → polish lookup → err-filter → post-cluster → oracle-best.", ""]
    for cell_id in POLISH_PROBES:
        cell_rows = [r for r in all_rows if r["cell"] == cell_id]
        if not cell_rows:
            continue
        md.append(f"## {cell_id}")
        md.append("")
        n_pool = cell_rows[0]["n_pool"]
        md.append(f"n_pool (polished raw HC reps from eps=1e-12 probe) = {n_pool}")
        md.append("")
        md.append("### oracle-best (rows: pre_eps, cols: post_eps)")
        md.append("")
        header = "| pre\\\\post |" + "|".join(f" {e:.0e} " for e in EPS_LADDER) + "|"
        md.append(header)
        md.append("|" + "---|" * (len(EPS_LADDER) + 1))
        for pre_eps in EPS_LADDER:
            line = f"| **{pre_eps:.0e}** |"
            for post_eps in EPS_LADDER:
                r = next((x for x in cell_rows if x["pre_eps"] == pre_eps and x["post_eps"] == post_eps), None)
                if r is None:
                    line += " - |"
                else:
                    line += f" {r['oracle_best']:.2e} |"
            md.append(line)
        md.append("")
        md.append("### n_post_reps (final survivors)")
        md.append("")
        md.append(header)
        md.append("|" + "---|" * (len(EPS_LADDER) + 1))
        for pre_eps in EPS_LADDER:
            line = f"| **{pre_eps:.0e}** |"
            for post_eps in EPS_LADDER:
                r = next((x for x in cell_rows if x["pre_eps"] == pre_eps and x["post_eps"] == post_eps), None)
                line += f" {r['n_post_reps']} |" if r else " - |"
            md.append(line)
        md.append("")

    out_md = HERE / "eps_grid.md"
    out_md.write_text("\n".join(md))
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
