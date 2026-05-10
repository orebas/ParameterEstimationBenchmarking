#!/usr/bin/env python3
"""
Quick cross-benchmark comparison: numbat vs bilby.

Caveats (changes between benchmarks):
- bilby: 8 replicas/cell, single-seed RNG; numbat: 10 replicas/cell, per-cell md5 seeds.
- numbat shortened cstr→[0,10], seir→[0,30], repressilator→[0,15], crauste→[0,16].
- bilby AMIGO2 results parsed from stdout regex; numbat reads from result.csv.
- bilby ODEPE was old multipoint; numbat is ODEPE-v2 with polish_method=PolishLSOBoundedLog +
  synthesize_aggregate_candidates + post-bilby package patches.
- bilby had SciML; numbat replaces with SHADE+LM (different algorithm class).
- Common in both: AMIGO2 (closest cross-bench comparison), 23 systems, 5 noise levels.

So this comparison is most informative for AMIGO2 (essentially the same algorithm,
small data-distribution differences) and tells you basically nothing for ODEPE
(different algorithm). For ODEPE, see the per-noise table for shape, not absolute.

Usage:
    python3 results/numbat_analysis/numbat_vs_bilby.py
"""

from pathlib import Path
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BILBY_CSV = REPO_ROOT / "results/bilby_analysis/flat_results_with_metrics.csv"
NUMBAT_CSV = REPO_ROOT / "results/numbat_analysis/flat_results_with_metrics.csv"
OUT_CSV = REPO_ROOT / "results/numbat_analysis/numbat_vs_bilby.csv"

# Estimator mapping: numbat_run -> (bilby_run or None)
EQUIV = {
    "amigo2": "amigo2_run",                # essentially same algorithm
    "odepe_v2_polish": "odepe_polish",      # ODEPE was rewritten between; track shape
    "odepe_v2_nopolish": "odepe_nopolish",  # same caveat
    "odepe_shade": None,                    # SciML→SHADE, no equivalent
}


def main():
    b = pd.read_csv(BILBY_CSV)
    n = pd.read_csv(NUMBAT_CSV)

    rows = []
    for n_run, b_run in EQUIV.items():
        for noise in sorted(n["noise"].unique()):
            n_sub = n[(n["run"] == n_run) & (n["noise"] == noise)]
            n_succ = n_sub["success_at_10pct"].mean() * 100 if len(n_sub) else float("nan")
            n_med = n_sub["median_rel_error"].median() if len(n_sub) else float("nan")
            n_time = n_sub["time"].median() if len(n_sub) else float("nan")

            if b_run is None:
                b_succ = b_med = b_time = float("nan")
            else:
                b_sub = b[(b["run"] == b_run) & (b["noise"] == noise)]
                b_succ = b_sub["success_at_10pct"].mean() * 100 if len(b_sub) else float("nan")
                b_med = b_sub["median_rel_error"].median() if len(b_sub) else float("nan")
                b_time = b_sub["time"].median() if len(b_sub) else float("nan")

            rows.append(
                {
                    "estimator": n_run,
                    "noise": noise,
                    "numbat_success_pct": round(n_succ, 1),
                    "bilby_success_pct": round(b_succ, 1) if pd.notna(b_succ) else None,
                    "delta_pp": round(n_succ - b_succ, 1) if pd.notna(b_succ) else None,
                    "numbat_median_rel_err": n_med,
                    "bilby_median_rel_err": b_med if pd.notna(b_med) else None,
                    "numbat_median_time_s": round(n_time, 1) if pd.notna(n_time) else None,
                    "bilby_median_time_s": round(b_time, 1) if pd.notna(b_time) else None,
                }
            )

    df = pd.DataFrame(rows)
    df.to_csv(OUT_CSV, index=False)
    print(f"Wrote {OUT_CSV}\n")

    print("=== Success@10% delta (numbat - bilby), per noise ===")
    pv = df.pivot(index="estimator", columns="noise", values="delta_pp")
    print(pv.fillna("—  ").to_string())

    print("\n=== Success@10% absolute (numbat / bilby) ===")
    for est in EQUIV:
        sub = df[df["estimator"] == est]
        line = f"  {est:22s} | "
        for _, r in sub.iterrows():
            n_str = f"{r['numbat_success_pct']:.0f}" if pd.notna(r["numbat_success_pct"]) else "—"
            b_str = f"{r['bilby_success_pct']:.0f}" if pd.notna(r["bilby_success_pct"]) else "—"
            noise_str = f"{r['noise']:g}" if r["noise"] > 0 else "0"
            line += f"{noise_str}: {n_str}/{b_str}  "
        print(line)

    print("\n=== Overall (across all noise) ===")
    for est, b_eq in EQUIV.items():
        n_succ = n[n["run"] == est]["success_at_10pct"].mean() * 100
        if b_eq is None:
            print(f"  {est:22s}: numbat {n_succ:5.1f}%   (no bilby equivalent)")
        else:
            b_succ = b[b["run"] == b_eq]["success_at_10pct"].mean() * 100
            print(f"  {est:22s}: numbat {n_succ:5.1f}%  bilby {b_succ:5.1f}%  delta {n_succ - b_succ:+5.1f}pp")


if __name__ == "__main__":
    main()
