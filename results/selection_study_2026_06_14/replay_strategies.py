#!/usr/bin/env python3
"""
Candidate-selection replay over the final_v2 POLISH pools.

For each cell's full candidate pool (pool.csv), this:
  - identifies the ORACLE candidate = min `max_rel_err` (truth-distance over identifiable
    vars; truth used for EVALUATION only, never for ranking),
  - replays each candidate-RANKING strategy (a sort over err + features) and records, per
    strategy: the rank the oracle lands at, the top-1 pick's truth-distance, and top-K
    capture of a truth-near candidate,
  - emits per-candidate features (err-top-50 ∪ oracle per cell) for the Q3 feature mining.

Strategies = the 5 production `rank_strategy` schemes (exact sort tuples from
analysis_utils.jl) + a few prototyped err-bucketed rerankers. Ranking NEVER sees truth.

Read-only over the benchmark; writes selection_per_cell.csv + candidate_features.csv here.
"""
import glob
import math
import os

import numpy as np
import pandas as pd
import warnings
warnings.filterwarnings("ignore")

HERE = os.path.dirname(os.path.abspath(__file__))
B = "/home/orebas/ParameterEstimationBenchmark-local/benchmark_final_v2_2026-06-12"
ARM = "odepe_v2_polish_run"
FILETREE = os.path.join(B, "filetree", ARM)
OUT_CELL = os.path.join(HERE, "selection_per_cell.csv")
OUT_FEAT = os.path.join(HERE, "candidate_features.csv")

NOISE_VAL = {"0": 0.0, "1em8": 1e-8, "1em6": 1e-6, "1em4": 1e-4, "1em2": 1e-2}
THRESH = {"1pct": 0.01, "10pct": 0.10}   # truth-near thresholds on max_rel_err
TOPKS = [1, 5, 10, 20]
ANSWER = 0.10                            # answer-bearing: pool has a <10% candidate

# strategy name -> list of columns to sort ascending (tuple sort key)
STRATEGIES = {
    # ---- the 5 production rank_strategy schemes ----
    "err_only":          ["err"],
    "sat_err":           ["saturation_count", "err"],
    "sat_neg1_err":      ["saturation_count", "is_untagged", "err"],          # = legacy S2
    "lognorm_err":       ["lognorm_score", "err"],
    "lognorm_neg1_err":  ["lognorm_score", "is_untagged", "err"],
    # ---- prototyped err-bucketed rerankers (err dominates; feature breaks near-ties) ----
    "errbucket_sat":         ["err_bucket", "saturation_count", "err"],
    "errbucket_branch_big":  ["err_bucket", "neg_branch", "err"],   # prefer LARGER cluster
    "errbucket_branch_small":["err_bucket", "branch_size", "err"],  # prefer SMALLER cluster
    "errbucket_single":      ["err_bucket", "not_single", "err"],   # prefer single_point
}


def split_noise(cell):
    parts = cell.rsplit("_", 2)
    return (parts[0], parts[1], parts[2]) if len(parts) == 3 else (cell, "", "")


def process_cell(cell_dir):
    cell = os.path.basename(cell_dir)
    system, rep, noise = split_noise(cell)
    try:
        df = pd.read_csv(os.path.join(cell_dir, "pool.csv"))
    except Exception:
        return [], None
    for c in ["err", "max_rel_err", "mean_rel_err", "saturation_count", "branch_size",
              "polish_source_hc_idx", "source_shooting_index", "pre_polish_error",
              "post_polish_error", "n_id_vars"]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df[np.isfinite(df["err"]) & np.isfinite(df["max_rel_err"])].reset_index(drop=True)
    n = len(df)
    if n == 0:
        return [], None

    # ---- features (NO truth) ----
    df["is_untagged"] = (df["polish_source_hc_idx"].isna() | (df["polish_source_hc_idx"] == -1)).astype(int)
    pcols = [c for c in df.columns if c.startswith("p_")]
    Pp = df[pcols].to_numpy(dtype=float) if pcols else np.zeros((n, 0))
    pos = Pp > 0
    with np.errstate(divide="ignore", invalid="ignore"):
        sq = np.where(pos, np.log10(np.where(pos, Pp, 1.0)) ** 2, 0.0)
    cnt = pos.sum(axis=1)
    df["lognorm_score"] = np.where(cnt > 0, sq.sum(axis=1), np.inf)
    e = df["err"].to_numpy(dtype=float)
    df["err_bucket"] = np.where((e > 0) & np.isfinite(e),
                                np.floor(2 * np.log10(np.where(e > 0, e, 1.0))) / 2.0, 9.9e9)
    df["branch_size"] = df["branch_size"].fillna(1)
    df["neg_branch"] = -df["branch_size"]
    df["not_single"] = (df["source_type"] != "single_point").astype(int)
    df["err_rank"] = df["err"].rank(method="first").astype(int)

    mre = df["max_rel_err"]
    oracle_i = mre.idxmin()
    oracle_mre = float(mre.loc[oracle_i])
    df["is_oracle"] = (df.index == oracle_i).astype(int)
    answer = oracle_mre < ANSWER
    near = {t: (mre < tv) for t, tv in THRESH.items()}

    rows = []
    for name, keys in STRATEGIES.items():
        order = df.sort_values(keys, kind="mergesort").index.to_numpy()
        orank = int(np.where(order == oracle_i)[0][0]) + 1
        top1_i = order[0]
        top1_mre = float(mre.loc[top1_i])
        rec = {"cell": cell, "system": system, "noise": noise, "n_cand": n,
               "answer_bearing": int(answer), "oracle_max_rel": oracle_mre,
               "strategy": name, "top1_max_rel": top1_mre, "oracle_rank": orank,
               "top1_src": df.loc[top1_i, "source_type"]}
        for t in THRESH:
            rec[f"top1_near_{t}"] = int(top1_mre < THRESH[t])
            for K in TOPKS:
                rec[f"cap{K}_{t}"] = int(near[t].loc[order[:K]].any())
        rows.append(rec)

    keep = sorted(set(df.nsmallest(min(50, n), "err").index) | {oracle_i})
    fcols = ["err", "max_rel_err", "mean_rel_err", "is_oracle", "err_rank", "branch_size",
             "saturation_count", "source_type", "interpolator_source", "source_shooting_index",
             "n_id_vars", "pre_polish_error", "post_polish_error", "is_untagged", "lognorm_score"]
    fdf = df.loc[keep, [c for c in fcols if c in df.columns]].copy()
    fdf.insert(0, "cell", cell)
    fdf.insert(1, "system", system)
    fdf.insert(2, "noise", noise)
    return rows, fdf


def main():
    cells = sorted(c for c in glob.glob(os.path.join(FILETREE, "*")) if os.path.isdir(c))
    cell_rows, feat_frames, skipped = [], [], 0
    for i, cd in enumerate(cells):
        rows, fdf = process_cell(cd)
        if not rows:
            skipped += 1
            continue
        cell_rows.extend(rows)
        feat_frames.append(fdf)
        if (i + 1) % 200 == 0:
            print(f"  {i + 1}/{len(cells)} cells")
    cell_df = pd.DataFrame(cell_rows)
    cell_df["noise_val"] = cell_df["noise"].map(NOISE_VAL)
    cell_df.to_csv(OUT_CELL, index=False)
    feat = pd.concat(feat_frames, ignore_index=True)
    feat.to_csv(OUT_FEAT, index=False)
    print(f"wrote {OUT_CELL}  ({len(cell_df)} rows = {cell_df.cell.nunique()} cells x {cell_df.strategy.nunique()} strategies; {skipped} cells skipped)")
    print(f"wrote {OUT_FEAT}  ({len(feat)} candidate rows)")


if __name__ == "__main__":
    main()
