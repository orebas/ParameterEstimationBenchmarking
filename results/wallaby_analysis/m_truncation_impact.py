#!/usr/bin/env python3
"""Impact estimate: what happens to benchmark stats if ODEPE truncates
result.csv from K=20 to M rows?

We already have the per-cell K=20 result.csv data and computed both
oracle (best of all K=20 rows) and mbounded (best of rows[:M]) metrics
in `flat_results_with_metrics.csv`. The new ODEPE behavior would emit
only rows[:M]; so "the new oracle" ≡ today's mbounded. Top-1 is
unaffected (row 0 doesn't change).

This script quantifies the *visible* impact on:
  - Per-estimator headline @1%, @10%, @50%
  - Per-system: which systems lose how much accuracy under truncation
  - Per-noise: where in the noise spectrum the truncation costs accuracy
  - Per-cell: top-15 cells where rows beyond M contained a truth-near
    candidate (= the cost of truncating)

If the per-cell distribution is concentrated on the multiplicity-2
systems, truncation is benign — those rows are noise spread inside an
algebraic branch, not extra branches.

If there are mult-1 cells where rows[2:20] of K=20 contain truth-near
candidates not at row 0, that's a *real* loss from truncation we'd
want to flag before deciding to ship the M-truncation feature.

Outputs:
  - m_truncation_impact.csv (per-cell deltas)
  - m_truncation_impact.md  (paper-ready summary)
"""
import csv
import math
from collections import defaultdict
from pathlib import Path

import pandas as pd

REPO = Path(__file__).resolve().parent.parent.parent
FLAT = REPO / "results/wallaby_analysis/flat_results_with_metrics.csv"
OUT_DIR = REPO / "results/wallaby_analysis"

THRESHOLDS = [("@1%", 0.01), ("@10%", 0.10), ("@50%", 0.50)]
ESTIMATORS = ["odepe_v2_polish", "odepe_v2_nopolish", "amigo2", "odepe_shade"]
METHOD_LABELS = {
    "odepe_v2_polish": "ODEPE-v2 (polish)",
    "odepe_v2_nopolish": "ODEPE-v2 (no polish)",
    "amigo2": "AMIGO2",
    "odepe_shade": "SHADE+LM",
}


def fmt_pct(v):
    if v is None or (isinstance(v, float) and (math.isnan(v) or math.isinf(v))):
        return "-"
    return f"{v*100:.1f}%"


def succ_rate(series, threshold):
    finite = series.dropna()
    if len(finite) == 0:
        return None
    return (finite < threshold).mean()


def main():
    df = pd.read_csv(FLAT)
    print(f"Loaded {len(df)} rows from {FLAT.name}")
    print()

    # === Part 1: per-estimator headline shift ===
    print("=== Per-estimator headline @ thresholds (current → after M-truncation) ===")
    print(f"{'metric':<35s} {'top-1':>10s} {'oracle(K=20)':>14s} {'mbounded≡new':>14s} {'delta':>10s}")
    print("-" * 90)
    perEst_rows = []
    for est in ESTIMATORS:
        sub = df[df["run"] == est]
        for label, thr in THRESHOLDS:
            t = succ_rate(sub["top1_max_rel_error"], thr) or 0
            o = succ_rate(sub["oracle_max_rel_error"], thr) or 0
            m = succ_rate(sub["mbounded_max_rel_error"], thr) or 0
            print(f"  {est:<18s} {label:<14s} {fmt_pct(t):>10s} {fmt_pct(o):>14s} "
                  f"{fmt_pct(m):>14s} {(m-o)*100:+10.2f}pp")
            perEst_rows.append({
                "method": METHOD_LABELS[est], "threshold": label,
                "top1": t, "oracle_K20": o, "mbounded_eq_new": m, "delta_pp": (m-o)*100,
            })

    # === Part 2: per-system at @10% (paper headline) ===
    print()
    print("=== Per-system delta @ 10% (ODEPE polish, after M-truncation) ===")
    print("Negative delta = some K=20 cells had truth in rows beyond M.")
    print()
    sys_deltas = []
    for sys_name in sorted(df["name"].unique()):
        for est in ("odepe_v2_polish", "odepe_v2_nopolish"):
            sub = df[(df["name"] == sys_name) & (df["run"] == est)]
            o = succ_rate(sub["oracle_max_rel_error"], 0.10) or 0
            m = succ_rate(sub["mbounded_max_rel_error"], 0.10) or 0
            M = int(sub["algebraic_multiplicity"].iloc[0])
            if abs(o - m) > 1e-9:
                sys_deltas.append({
                    "system": sys_name, "estimator": est, "M": M,
                    "oracle_K20": o, "mbounded": m, "delta_pp": (m-o)*100,
                })
    sys_deltas.sort(key=lambda r: r["delta_pp"])
    print(f"{'system':<22s} {'M':>3s} {'estimator':<22s} {'K=20 oracle':>12s} {'new (mbnd)':>12s} {'delta':>10s}")
    print("-" * 88)
    for r in sys_deltas:
        print(f"{r['system']:<22s} {r['M']:>3d} {r['estimator']:<22s} "
              f"{fmt_pct(r['oracle_K20']):>12s} {fmt_pct(r['mbounded']):>12s} "
              f"{r['delta_pp']:+10.2f}pp")
    if not sys_deltas:
        print("(no system shows any delta — truncation is fully benign at @10%)")

    # === Part 3: per-noise at @10% ===
    print()
    print("=== Per-noise delta @ 10% (polish + nopolish combined) ===")
    odepe = df[df["run"].isin(["odepe_v2_polish", "odepe_v2_nopolish"])]
    print(f"{'noise':>8s} {'K=20 oracle':>14s} {'new (mbnd)':>14s} {'delta':>10s}")
    print("-" * 50)
    for noise_lbl in ("0", "1em8", "1em6", "1em4", "1em2"):
        sub = odepe[odepe["noise_label"] == noise_lbl]
        o = succ_rate(sub["oracle_max_rel_error"], 0.10) or 0
        m = succ_rate(sub["mbounded_max_rel_error"], 0.10) or 0
        print(f"{noise_lbl:>8s} {fmt_pct(o):>14s} {fmt_pct(m):>14s} "
              f"{(m-o)*100:+10.2f}pp")

    # === Part 4: per-cell — where rows beyond M held truth ===
    odepe = df[df["run"].isin(["odepe_v2_polish", "odepe_v2_nopolish"])].copy()
    odepe["cost_pp"] = odepe["mbounded_max_rel_error"] - odepe["oracle_max_rel_error"]
    # Cells where new (mbounded) is WORSE than old (oracle) by at least
    # an order of magnitude, AND new fails at some coarse threshold:
    significant_loss = odepe[
        (odepe["oracle_max_rel_error"] < 0.01)
        & (odepe["mbounded_max_rel_error"] >= 0.10)
    ]
    print()
    print(f"=== Cells where truncation costs (mbounded > 10% while oracle < 1%) ===")
    print(f"Count: {len(significant_loss)} / {len(odepe)} ODEPE cells")
    print()
    print(f"{'cell':<26s} {'estimator':<22s} {'M':>3s} {'top1':>10s} {'oracle':>10s} {'mbnd':>10s}")
    print("-" * 90)
    for _, r in significant_loss.sort_values("mbounded_max_rel_error", ascending=False).head(15).iterrows():
        print(f"{r['id']:<26s} {r['run']:<22s} {int(r['algebraic_multiplicity']):>3d} "
              f"{r['top1_max_rel_error']:>10.2e} {r['oracle_max_rel_error']:>10.2e} "
              f"{r['mbounded_max_rel_error']:>10.2e}")

    # Write the per-cell detail CSV
    out_csv = OUT_DIR / "m_truncation_impact.csv"
    impact_rows = []
    for _, r in odepe.iterrows():
        impact_rows.append({
            "cell_id": r["id"],
            "system": r["name"],
            "estimator": r["run"],
            "noise_label": r["noise_label"],
            "M": int(r["algebraic_multiplicity"]),
            "top1_err": r["top1_max_rel_error"],
            "oracle_K20_err": r["oracle_max_rel_error"],
            "mbounded_err": r["mbounded_max_rel_error"],
            "loss_pp_under_truncation": r["mbounded_max_rel_error"] - r["oracle_max_rel_error"],
        })
    pd.DataFrame(impact_rows).to_csv(out_csv, index=False)
    print()
    print(f"wrote {out_csv}")

    # Write markdown summary
    md = []
    md.append("# M-truncation impact estimate")
    md.append("")
    md.append("**Question.** If ODEPE truncates `result.csv` from K=20 rows to M rows ")
    md.append("(where M is the algebraic multiplicity from `config/systems.json`), what's ")
    md.append("the visible impact on benchmark stats?")
    md.append("")
    md.append("**Method.** The new ODEPE would output `rows[0:M]` of what it currently ")
    md.append("outputs as K=20. So:")
    md.append("- top-1 is **unchanged** (row 0 doesn't move)")
    md.append("- new \"oracle\" = best-of-M = today's `mbounded_*` columns")
    md.append("")
    md.append("All numbers below come from `flat_results_with_metrics.csv`. No new ")
    md.append("benchmark run is needed.")
    md.append("")
    md.append("## 1. Per-estimator headline (top-1 / K=20 oracle / new oracle = mbounded)")
    md.append("")
    md.append("| Method | Threshold | Top-1 | Oracle (K=20) | New (≡ mbounded) | Δ |")
    md.append("|---|---|---:|---:|---:|---:|")
    for r in perEst_rows:
        md.append(f"| {r['method']} | {r['threshold']} | {fmt_pct(r['top1'])} | "
                  f"{fmt_pct(r['oracle_K20'])} | {fmt_pct(r['mbounded_eq_new'])} | "
                  f"{r['delta_pp']:+.2f}pp |")
    md.append("")
    md.append("**Reading:** AMIGO2 and SHADE are K=1 and unaffected. ODEPE polish loses ")
    md.append(f"~{abs(sum(r['delta_pp'] for r in perEst_rows if r['method']=='ODEPE-v2 (polish)' and r['threshold']=='@10%')):.1f}pp of K=20-oracle credit at @10%; top-1 unchanged. ")
    md.append("**Paper-headline M-bounded metric is unaffected** by definition.")
    md.append("")
    md.append("## 2. Per-system (ODEPE @10%) where truncation costs accuracy")
    md.append("")
    if sys_deltas:
        md.append("| System | M | Estimator | K=20 oracle | New (mbnd) | Δ |")
        md.append("|---|---:|---|---:|---:|---:|")
        for r in sys_deltas:
            md.append(f"| `{r['system']}` | {r['M']} | {r['estimator']} | "
                      f"{fmt_pct(r['oracle_K20'])} | {fmt_pct(r['mbounded'])} | "
                      f"{r['delta_pp']:+.2f}pp |")
    else:
        md.append("(no system shows any delta at @10%)")
    md.append("")
    md.append("## 3. Cells where truncation costs (oracle <1% but new ≥10%)")
    md.append("")
    md.append(f"**{len(significant_loss)} cells / {len(odepe)} ODEPE cells** where the K=20 ")
    md.append("oracle found a truth-near row beyond `rows[0:M]`.")
    md.append("")
    if len(significant_loss) > 0:
        md.append("Top 15 by post-truncation error:")
        md.append("")
        md.append("| Cell | Estimator | M | top-1 err | oracle err | new err |")
        md.append("|---|---|---:|---:|---:|---:|")
        for _, r in significant_loss.sort_values("mbounded_max_rel_error", ascending=False).head(15).iterrows():
            md.append(f"| `{r['id']}` | {r['run']} | {int(r['algebraic_multiplicity'])} | "
                      f"{r['top1_max_rel_error']:.2e} | {r['oracle_max_rel_error']:.2e} | "
                      f"{r['mbounded_max_rel_error']:.2e} |")
    md.append("")
    md.append("## 4. Implication")
    md.append("")
    if len(significant_loss) == 0:
        md.append("**Truncation is fully benign at the paper-headline thresholds.** No ")
        md.append("cell loses its truth-near row by going from K=20 to M.")
    elif len(significant_loss) < 20:
        md.append(f"**Truncation is essentially benign.** Only {len(significant_loss)} ")
        md.append(f"cells out of {len(odepe)} lose accuracy, and the M-bounded paper-headline ")
        md.append("metric is unaffected.")
    else:
        md.append(f"**{len(significant_loss)} cells regress under truncation.** Worth ")
        md.append("inspecting the table above before shipping the M-truncation feature.")
    md.append("")
    md.append("Detailed per-cell data in `m_truncation_impact.csv`.")

    out_md = OUT_DIR / "m_truncation_impact.md"
    out_md.write_text("\n".join(md))
    print(f"wrote {out_md}")


if __name__ == "__main__":
    main()
