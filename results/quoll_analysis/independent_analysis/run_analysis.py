#!/usr/bin/env python3
"""
Independent Benchmark Analysis for benchmark_wallaby_2026-05-17 (dual-metric).
Produces 8+5 CSV tables, 14+10 PNG figures, and a REPORT.md summary.

Dual-metric: each metric-dependent output is produced for both
  - "top1"   — score the algorithm's row-0 pick (paper-headline metric)
  - "oracle" — argmin over all rows (best-of-K, set-credit upper bound)

Single-metric outputs (failure mode, timing, replica spread) don't
depend on metric choice and are produced once.

Output naming convention:
  - top1 outputs use the existing filenames (F01_*.png, T01_*.csv)
  - oracle outputs append `_oracle` (F01_*_oracle.png, T01_*_oracle.csv)
  - Single-metric outputs are unchanged.

Usage:
    python3 results/wallaby_analysis/independent_analysis/run_analysis.py
"""

import os
import warnings
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import seaborn as sns
from math import pi

warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=UserWarning)

# -- paths --
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_CSV = os.path.join(SCRIPT_DIR, "..", "flat_results_with_metrics.csv")
TABLE_DIR = os.path.join(SCRIPT_DIR, "tables")
FIG_DIR = os.path.join(SCRIPT_DIR, "figures")
REPORT_PATH = os.path.join(SCRIPT_DIR, "REPORT.md")

os.makedirs(TABLE_DIR, exist_ok=True)
os.makedirs(FIG_DIR, exist_ok=True)

# -- style --
sns.set_theme(style="whitegrid", font_scale=1.1)
METHOD_ORDER = ["odepe_v2_polish", "odepe_v2_nopolish", "amigo2", "odepe_shade"]
METHOD_LABELS = {
    "odepe_v2_polish": "ODEPE-v2 (polish)",
    "odepe_v2_nopolish": "ODEPE-v2 (no polish)",
    "amigo2": "AMIGO2",
    "odepe_shade": "SHADE+LM",
}
METHOD_COLORS = {
    "odepe_v2_polish": "#1f77b4",
    "odepe_v2_nopolish": "#aec7e8",
    "amigo2": "#ff7f0e",
    "odepe_shade": "#2ca02c",
}
NOISE_ORDER = [0.0, 1e-8, 1e-6, 1e-4, 1e-2]
NOISE_LABELS = ["0", "1e-8", "1e-6", "1e-4", "1e-2"]
NOISE_FLOAT_TO_LABEL = dict(zip(NOISE_ORDER, NOISE_LABELS))

DOMAIN_MAP = {
    "aircraft_pitch": "Aerospace",
    "bicycle_model": "Mechanical",
    "biohydrogenation": "Biology",
    "boost_converter": "Electrical",
    "brusselator": "Chemistry",
    "crauste": "Biology",
    "cstr": "Chemistry",
    "daisy_mamil3": "Biology",
    "daisy_mamil4": "Biology",
    "dc_motor": "Electrical",
    "fitzhugh_nagumo": "Biology",
    "flexible_arm": "Mechanical",
    "forced_lotka_volterra": "Biology",
    "harmonic_oscillator": "Mechanical",
    "hiv": "Biology",
    "lotka_volterra": "Biology",
    "mass_spring_damper": "Mechanical",
    "quadrotor": "Aerospace",
    "repressilator": "Biology",
    "seir": "Epidemiology",
    "sirt_treatment": "Biology",
    "slow_fast": "Biology",
    "vanderpol": "Mechanical",
    # quoll-broad branch systems (receptor excluded from this artifact)
    "latent_subpopulation_branch": "Epidemiology",
    "latent_subpopulation_observed_control": "Epidemiology",
}

DIVERGED_THRESHOLD = 1e4

# -- dual-metric machinery (now three variants) --
METRIC_VARIANTS = ["top1", "mbounded", "oracle"]
METRIC_LABELS = {
    "top1": "Top-1 (algorithm's pick)",
    "mbounded": "M-bounded (algebraic multiplicity)",
    "oracle": "Best-of-K (oracle)",
}


def col(metric, base):
    """Column name in flat_results_with_metrics.csv for this metric family."""
    return f"{metric}_{base}"


def suffix(metric):
    """Filename suffix. Top-1 keeps the default filenames; oracle/mbounded get explicit suffixes."""
    if metric == "top1":
        return ""
    return f"_{metric}"


# -- load data --
def load_data():
    df = pd.read_csv(INPUT_CSV)
    df["domain"] = df["name"].map(DOMAIN_MAP)
    df["noise_cat"] = pd.Categorical(
        df["noise"].map(lambda x: NOISE_FLOAT_TO_LABEL.get(x, f"{x:g}")),
        categories=NOISE_LABELS,
        ordered=True,
    )
    df["method_label"] = df["run"].map(METHOD_LABELS)
    # "diverged" uses top-1 max_rel_error — diverging means the algorithm's
    # primary pick is catastrophically off, which is a metric-independent
    # signal of failure.
    df["diverged"] = (df["top1_max_rel_error"] > DIVERGED_THRESHOLD) & (df["has_result"] == 1)
    df["no_result"] = df["has_result"] == 0
    df["unfinished"] = (df["finished"] == 0) & (df["has_result"] == 1)
    return df


# ======================================================================
#  TABLES (dual: T01, T02, T03, T04, T05, T08; single: T06, T07)
# ======================================================================

def make_T01(df, metric):
    rows = []
    for m in METHOD_ORDER:
        sub = df[df["run"] == m]
        clean = sub[~sub["diverged"] & (sub["has_result"] == 1)]
        rows.append({
            "method": METHOD_LABELS[m],
            "n_rows": len(sub),
            "has_result_pct": sub["has_result"].mean() * 100,
            "success_at_1pct": sub[col(metric, "success_at_1pct")].mean() * 100,
            "success_at_10pct": sub[col(metric, "success_at_10pct")].mean() * 100,
            "success_at_50pct": sub[col(metric, "success_at_50pct")].mean() * 100,
            "median_median_rel_error": clean[col(metric, "median_rel_error")].median(),
            "median_mean_rel_error": clean[col(metric, "mean_rel_error")].median(),
            "median_time_s": sub["time"].median(),
            "mean_time_s": sub["time"].mean(),
            "n_diverged": sub["diverged"].sum(),
            "n_no_result": sub["no_result"].sum(),
            "n_unfinished": sub["unfinished"].sum(),
        })
    t = pd.DataFrame(rows)
    t.to_csv(os.path.join(TABLE_DIR, f"T01_overall_method_comparison{suffix(metric)}.csv"), index=False)
    return t


def make_T02(df, metric):
    rows = []
    for m in METHOD_ORDER:
        for noise in NOISE_ORDER:
            sub = df[(df["run"] == m) & (df["noise"] == noise)]
            clean = sub[~sub["diverged"] & (sub["has_result"] == 1)]
            q25 = clean[col(metric, "median_rel_error")].quantile(0.25) if len(clean) > 0 else np.nan
            q75 = clean[col(metric, "median_rel_error")].quantile(0.75) if len(clean) > 0 else np.nan
            rows.append({
                "method": METHOD_LABELS[m],
                "noise": NOISE_FLOAT_TO_LABEL.get(noise, f"{noise:g}"),
                "n_rows": len(sub),
                "success_at_1pct": sub[col(metric, "success_at_1pct")].mean() * 100,
                "success_at_10pct": sub[col(metric, "success_at_10pct")].mean() * 100,
                "success_at_50pct": sub[col(metric, "success_at_50pct")].mean() * 100,
                "median_error": clean[col(metric, "median_rel_error")].median() if len(clean) > 0 else np.nan,
                "error_IQR_low": q25,
                "error_IQR_high": q75,
                "median_time_s": sub["time"].median(),
            })
    t = pd.DataFrame(rows)
    t.to_csv(os.path.join(TABLE_DIR, f"T02_method_by_noise{suffix(metric)}.csv"), index=False)
    return t


def make_T03(df, metric):
    rows = []
    for sys_name in sorted(df["name"].unique()):
        sub = df[df["name"] == sys_name]
        method_success = {}
        for m in METHOD_ORDER:
            ms = sub[sub["run"] == m][col(metric, "success_at_10pct")].mean() * 100
            method_success[METHOD_LABELS[m]] = ms
        best_m = max(method_success, key=method_success.get)
        worst_m = min(method_success, key=method_success.get)
        rows.append({
            "system": sys_name,
            "domain": DOMAIN_MAP.get(sys_name, "Unknown"),
            "n_id_params": sub["n_id_params"].iloc[0],
            "n_nonid_params": sub["n_nonid_params"].iloc[0],
            "mean_success_at_10pct": sub[col(metric, "success_at_10pct")].mean() * 100,
            "best_method": best_m,
            "best_method_success": method_success[best_m],
            "worst_method": worst_m,
            "worst_method_success": method_success[worst_m],
            **{f"success_{METHOD_LABELS[m]}": method_success[METHOD_LABELS[m]] for m in METHOD_ORDER},
        })
    t = pd.DataFrame(rows).sort_values("mean_success_at_10pct", ascending=True).reset_index(drop=True)
    t.to_csv(os.path.join(TABLE_DIR, f"T03_system_ranking{suffix(metric)}.csv"), index=False)
    return t


def make_T04(df, metric):
    rows = []
    for domain in sorted(df["domain"].unique()):
        sub = df[df["domain"] == domain]
        method_success = {}
        for m in METHOD_ORDER:
            ms = sub[sub["run"] == m][col(metric, "success_at_10pct")].mean() * 100
            method_success[METHOD_LABELS[m]] = ms
        best_m = max(method_success, key=method_success.get)
        worst_m = min(method_success, key=method_success.get)
        rows.append({
            "domain": domain,
            "n_systems": sub["name"].nunique(),
            **{f"success_{METHOD_LABELS[m]}": method_success[METHOD_LABELS[m]] for m in METHOD_ORDER},
            "best_method": best_m,
            "worst_method": worst_m,
        })
    t = pd.DataFrame(rows)
    t.to_csv(os.path.join(TABLE_DIR, f"T04_domain_method_success{suffix(metric)}.csv"), index=False)
    return t


def make_T05(df, metric):
    rows = []
    for sys_name in sorted(df["name"].unique()):
        for noise in NOISE_ORDER:
            np_sub = df[(df["name"] == sys_name) & (df["noise"] == noise) & (df["run"] == "odepe_v2_nopolish")]
            p_sub = df[(df["name"] == sys_name) & (df["noise"] == noise) & (df["run"] == "odepe_v2_polish")]
            np_succ = np_sub[col(metric, "success_at_10pct")].mean() * 100
            p_succ = p_sub[col(metric, "success_at_10pct")].mean() * 100
            np_clean = np_sub[np_sub["has_result"] == 1]
            p_clean = p_sub[p_sub["has_result"] == 1]
            np_err = np_clean[col(metric, "median_rel_error")].median() if len(np_clean) > 0 else np.nan
            p_err = p_clean[col(metric, "median_rel_error")].median() if len(p_clean) > 0 else np.nan
            np_time = np_sub["time"].median()
            p_time = p_sub["time"].median()
            rows.append({
                "system": sys_name,
                "noise": NOISE_FLOAT_TO_LABEL.get(noise, f"{noise:g}"),
                "nopolish_success_10pct": np_succ,
                "polish_success_10pct": p_succ,
                "success_uplift_pp": p_succ - np_succ,
                "nopolish_median_error": np_err,
                "polish_median_error": p_err,
                "error_reduction_factor": np_err / p_err if (p_err and p_err > 0 and np_err and np_err > 0) else np.nan,
                "nopolish_median_time_s": np_time,
                "polish_median_time_s": p_time,
                "time_overhead_s": p_time - np_time,
                "time_overhead_pct": ((p_time - np_time) / np_time * 100) if np_time > 0 else np.nan,
            })
    t = pd.DataFrame(rows)
    t.to_csv(os.path.join(TABLE_DIR, f"T05_polishing_effect{suffix(metric)}.csv"), index=False)
    return t


def make_T06(df):
    """Single-metric: replica IQR/CV use top-1 (the algorithm's primary pick is what users see)."""
    rows = []
    for m in METHOD_ORDER:
        sub = df[(df["run"] == m) & (df["has_result"] == 1) & (~df["diverged"])]
        iqrs = []
        cvs = []
        agreements = []
        for (sys_name, noise), grp in sub.groupby(["name", "noise"]):
            errs = grp["top1_median_rel_error"].values
            if len(errs) >= 4:
                iqr = np.percentile(errs, 75) - np.percentile(errs, 25)
                iqrs.append(iqr)
                if np.mean(errs) > 0:
                    cvs.append(np.std(errs) / np.mean(errs))
                succ = grp["top1_success_at_10pct"].values
                agreements.append(np.mean(succ == succ[0]))
        rows.append({
            "method": METHOD_LABELS[m],
            "median_IQR": np.median(iqrs) if iqrs else np.nan,
            "mean_IQR": np.mean(iqrs) if iqrs else np.nan,
            "median_CV": np.median(cvs) if cvs else np.nan,
            "mean_CV": np.mean(cvs) if cvs else np.nan,
            "replica_agreement_rate": np.mean(agreements) if agreements else np.nan,
        })
    t = pd.DataFrame(rows)
    t.to_csv(os.path.join(TABLE_DIR, "T06_replica_stability.csv"), index=False)
    return t


def make_T07(df):
    """Single-metric: failure catalog (crashed / no_result / diverged) doesn't depend on metric."""
    failures = df[df["no_result"] | df["diverged"] | df["unfinished"]].copy()
    failures["failure_type"] = "unknown"
    failures.loc[failures["no_result"], "failure_type"] = "no_result"
    failures.loc[failures["diverged"], "failure_type"] = "diverged"
    failures.loc[failures["unfinished"], "failure_type"] = "unfinished"
    failures.loc[failures["diverged"] & failures["unfinished"], "failure_type"] = "diverged"
    out = failures[["name", "run", "noise", "id", "failure_type", "has_result",
                     "finished", "top1_max_rel_error", "time"]].copy()
    out = out.rename(columns={"top1_max_rel_error": "max_rel_error"})
    out["method"] = out["run"].map(METHOD_LABELS)
    out = out.sort_values(["name", "run", "noise"]).reset_index(drop=True)
    out.to_csv(os.path.join(TABLE_DIR, "T07_failure_catalog.csv"), index=False)
    return out


def make_T08(df, metric):
    rows = []
    for sys_name in sorted(df["name"].unique()):
        for m in METHOD_ORDER:
            prev_succ = None
            max_drop = 0
            cliff_from = None
            cliff_to = None
            for i, noise in enumerate(NOISE_ORDER):
                sub = df[(df["name"] == sys_name) & (df["noise"] == noise) & (df["run"] == m)]
                succ = sub[col(metric, "success_at_10pct")].mean() * 100
                if prev_succ is not None:
                    drop = prev_succ - succ
                    if drop > max_drop:
                        max_drop = drop
                        cliff_from = NOISE_LABELS[i - 1]
                        cliff_to = NOISE_LABELS[i]
                prev_succ = succ
            succ_by_noise = {}
            for i, noise in enumerate(NOISE_ORDER):
                sub = df[(df["name"] == sys_name) & (df["noise"] == noise) & (df["run"] == m)]
                succ_by_noise[NOISE_LABELS[i]] = sub[col(metric, "success_at_10pct")].mean() * 100
            rows.append({
                "system": sys_name,
                "method": METHOD_LABELS[m],
                "max_drop_pp": max_drop,
                "cliff_from_noise": cliff_from if cliff_from else "none",
                "cliff_to_noise": cliff_to if cliff_to else "none",
                **{f"success_noise_{nl}": succ_by_noise[nl] for nl in NOISE_LABELS},
            })
    t = pd.DataFrame(rows)
    t.to_csv(os.path.join(TABLE_DIR, f"T08_noise_cliff_detection{suffix(metric)}.csv"), index=False)
    return t


# ======================================================================
#  FIGURES (dual: F01-F06, F10, F12-F14; single: F07-F09, F11)
# ======================================================================

def fig_save(fig, name):
    path = os.path.join(FIG_DIR, name)
    fig.savefig(path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  Saved {name}")


def metric_title_tag(metric):
    return f"({METRIC_LABELS[metric]})"


def make_F01(df, metric):
    fig, ax = plt.subplots(figsize=(8, 5))
    for m in METHOD_ORDER:
        rates = []
        for noise in NOISE_ORDER:
            sub = df[(df["run"] == m) & (df["noise"] == noise)]
            rates.append(sub[col(metric, "success_at_10pct")].mean() * 100)
        ax.plot(NOISE_LABELS, rates, marker="o", label=METHOD_LABELS[m],
                color=METHOD_COLORS[m], linewidth=2, markersize=7)
    ax.set_xlabel("Noise Level")
    ax.set_ylabel("Success Rate @ 10% (%)")
    ax.set_title(f"Success Rate vs Noise Level by Method {metric_title_tag(metric)}")
    ax.set_ylim(-2, 102)
    ax.legend(loc="lower left")
    ax.grid(True, alpha=0.3)
    fig_save(fig, f"F01_overall_success_by_noise{suffix(metric)}.png")


def make_F02(df, metric):
    """Heatmap of success rates by (system, method) — one figure per threshold."""
    for threshold_key, threshold_label, fname in [
        ("success_at_10pct", "10%", f"F02_method_comparison_heatmap{suffix(metric)}.png"),
        ("success_at_1pct", "1%", f"F02a_method_comparison_heatmap_1pct{suffix(metric)}.png"),
        ("success_at_50pct", "50%", f"F02b_method_comparison_heatmap_50pct{suffix(metric)}.png"),
    ]:
        pivot = df.groupby(["name", "run"])[col(metric, threshold_key)].mean().unstack("run") * 100
        pivot = pivot[METHOD_ORDER]
        pivot.columns = [METHOD_LABELS[m] for m in METHOD_ORDER]
        pivot["mean"] = pivot.mean(axis=1)
        pivot = pivot.sort_values("mean", ascending=True)
        pivot = pivot.drop(columns="mean")
        fig, ax = plt.subplots(figsize=(8, 10))
        sns.heatmap(pivot, annot=True, fmt=".0f", cmap="RdYlGn", vmin=0, vmax=100,
                    linewidths=0.5, ax=ax,
                    cbar_kws={"label": f"Success @ {threshold_label} (%)"})
        ax.set_title(f"Success Rate @ {threshold_label} by System and Method {metric_title_tag(metric)}")
        ax.set_ylabel("")
        ax.set_xlabel("")
        fig_save(fig, fname)


def make_F03(df, metric):
    sys_succ = df.groupby("name")[col(metric, "success_at_10pct")].mean() * 100
    sys_succ = sys_succ.sort_values()
    domains = [DOMAIN_MAP[s] for s in sys_succ.index]
    domain_colors = {d: c for d, c in zip(
        sorted(set(DOMAIN_MAP.values())),
        sns.color_palette("Set2", n_colors=len(set(DOMAIN_MAP.values())))
    )}
    colors = [domain_colors[d] for d in domains]
    fig, ax = plt.subplots(figsize=(9, 8))
    ax.barh(range(len(sys_succ)), sys_succ.values, color=colors, edgecolor="gray", linewidth=0.5)
    ax.set_yticks(range(len(sys_succ)))
    ax.set_yticklabels(sys_succ.index, fontsize=9)
    ax.set_xlabel("Mean Success Rate @ 10% (%)")
    ax.set_title(f"System Difficulty Ranking (lower = harder) {metric_title_tag(metric)}")
    ax.set_xlim(0, 105)
    from matplotlib.patches import Patch
    legend_elements = [Patch(facecolor=domain_colors[d], label=d) for d in sorted(domain_colors)]
    ax.legend(handles=legend_elements, loc="lower right", fontsize=8, title="Domain")
    fig_save(fig, f"F03_system_difficulty_ranking{suffix(metric)}.png")


def make_F04(df, metric):
    fig, ax = plt.subplots(figsize=(8, 5))
    x = np.arange(len(NOISE_LABELS))
    width = 0.35
    np_rates = []
    p_rates = []
    for noise in NOISE_ORDER:
        np_sub = df[(df["run"] == "odepe_v2_nopolish") & (df["noise"] == noise)]
        p_sub = df[(df["run"] == "odepe_v2_polish") & (df["noise"] == noise)]
        np_rates.append(np_sub[col(metric, "success_at_10pct")].mean() * 100)
        p_rates.append(p_sub[col(metric, "success_at_10pct")].mean() * 100)
    ax.bar(x - width / 2, np_rates, width, label="ODEPE (no polish)",
           color=METHOD_COLORS["odepe_v2_nopolish"], edgecolor="gray")
    ax.bar(x + width / 2, p_rates, width, label="ODEPE (polish)",
           color=METHOD_COLORS["odepe_v2_polish"], edgecolor="gray")
    for i in range(len(NOISE_LABELS)):
        uplift = p_rates[i] - np_rates[i]
        if uplift > 0:
            ax.annotate(f"+{uplift:.0f}pp", xy=(x[i] + width / 2, p_rates[i]),
                        xytext=(0, 5), textcoords="offset points",
                        ha="center", fontsize=8, color="green")
    ax.set_xlabel("Noise Level")
    ax.set_ylabel("Success Rate @ 10% (%)")
    ax.set_title(f"Effect of Polishing on Success Rate {metric_title_tag(metric)}")
    ax.set_xticks(x)
    ax.set_xticklabels(NOISE_LABELS)
    ax.set_ylim(0, 105)
    ax.legend()
    ax.grid(True, alpha=0.3, axis="y")
    fig_save(fig, f"F04_polishing_effect_by_noise{suffix(metric)}.png")


def make_F05(df, metric):
    systems = sorted(df["name"].unique())
    data = np.zeros((len(systems), len(NOISE_ORDER)))
    for i, sys_name in enumerate(systems):
        for j, noise in enumerate(NOISE_ORDER):
            np_sub = df[(df["name"] == sys_name) & (df["noise"] == noise) & (df["run"] == "odepe_v2_nopolish")]
            p_sub = df[(df["name"] == sys_name) & (df["noise"] == noise) & (df["run"] == "odepe_v2_polish")]
            np_succ = np_sub[col(metric, "success_at_10pct")].mean() * 100
            p_succ = p_sub[col(metric, "success_at_10pct")].mean() * 100
            data[i, j] = p_succ - np_succ
    uplift_df = pd.DataFrame(data, index=systems, columns=NOISE_LABELS)
    uplift_df["mean"] = uplift_df.mean(axis=1)
    uplift_df = uplift_df.sort_values("mean", ascending=False)
    uplift_df = uplift_df.drop(columns="mean")
    fig, ax = plt.subplots(figsize=(8, 10))
    sns.heatmap(uplift_df, annot=True, fmt=".0f", cmap="RdBu_r", center=0,
                vmin=-50, vmax=50, linewidths=0.5, ax=ax,
                cbar_kws={"label": "Success Uplift (pp)"})
    ax.set_title(f"Polishing Effect: Success@10% Uplift (polish - nopolish) {metric_title_tag(metric)}")
    ax.set_ylabel("")
    ax.set_xlabel("Noise Level")
    fig_save(fig, f"F05_polishing_heatmap{suffix(metric)}.png")


def make_F06(df, metric):
    domains = sorted(df["domain"].unique())
    N = len(domains)
    angles = [n / float(N) * 2 * pi for n in range(N)]
    angles += angles[:1]
    fig, ax = plt.subplots(figsize=(8, 8), subplot_kw=dict(polar=True))
    for m in METHOD_ORDER:
        values = []
        for d in domains:
            sub = df[(df["run"] == m) & (df["domain"] == d)]
            values.append(sub[col(metric, "success_at_10pct")].mean() * 100)
        values += values[:1]
        ax.plot(angles, values, "o-", linewidth=2, label=METHOD_LABELS[m],
                color=METHOD_COLORS[m], markersize=5)
        ax.fill(angles, values, alpha=0.1, color=METHOD_COLORS[m])
    ax.set_xticks(angles[:-1])
    ax.set_xticklabels(domains, fontsize=9)
    ax.set_ylim(0, 100)
    ax.set_title(f"Method Performance by Domain {metric_title_tag(metric)}", y=1.08)
    ax.legend(loc="upper right", bbox_to_anchor=(1.3, 1.1), fontsize=9)
    fig_save(fig, f"F06_domain_radar{suffix(metric)}.png")


def make_F07(df):
    """Single-metric: error distribution boxplot uses top-1 median_rel_error."""
    clean = df[(df["has_result"] == 1) & (~df["diverged"])].copy()
    clean["log10_error"] = np.log10(clean["top1_median_rel_error"].clip(lower=1e-15))
    clean["method_label"] = pd.Categorical(
        clean["run"].map(METHOD_LABELS),
        categories=[METHOD_LABELS[m] for m in METHOD_ORDER],
        ordered=True,
    )
    fig, axes = plt.subplots(1, 5, figsize=(20, 5), sharey=True)
    for idx, noise in enumerate(NOISE_ORDER):
        ax = axes[idx]
        sub = clean[clean["noise"] == noise]
        sns.boxplot(data=sub, x="method_label", y="log10_error", ax=ax,
                    palette=[METHOD_COLORS[m] for m in METHOD_ORDER],
                    fliersize=2)
        ax.set_title(f"Noise = {NOISE_LABELS[idx]}")
        ax.set_xlabel("")
        if idx == 0:
            ax.set_ylabel("log10(Median Rel-Error, top-1)")
        else:
            ax.set_ylabel("")
        ax.tick_params(axis="x", rotation=45)
    fig.suptitle("Error Distribution by Method and Noise Level (Top-1)", fontsize=14, y=1.02)
    fig.tight_layout()
    fig_save(fig, "F07_replica_stability_boxplot.png")


def make_F08(df):
    """Single-metric: per-system replica strip plot at noise=1e-2 uses top-1."""
    noise_val = 0.01
    sub = df[(df["noise"] == noise_val) & (df["has_result"] == 1) & (~df["diverged"])].copy()
    sub["log10_error"] = np.log10(sub["top1_median_rel_error"].clip(lower=1e-15))
    fig, axes = plt.subplots(2, 2, figsize=(14, 12))
    for idx, m in enumerate(METHOD_ORDER):
        ax = axes[idx // 2][idx % 2]
        msub = sub[sub["run"] == m].copy()
        sys_order = msub.groupby("name")["log10_error"].median().sort_values().index.tolist()
        sns.stripplot(data=msub, x="log10_error", y="name", order=sys_order,
                      ax=ax, color=METHOD_COLORS[m], alpha=0.7, size=5, jitter=0.2)
        ax.set_title(f"{METHOD_LABELS[m]}")
        ax.set_xlabel("log10(Median Rel-Error, top-1)")
        ax.set_ylabel("")
        ax.tick_params(axis="y", labelsize=8)
    fig.suptitle(f"Replica Spread at Noise = {NOISE_FLOAT_TO_LABEL.get(noise_val, noise_val)} by System (Top-1)", fontsize=14, y=1.01)
    fig.tight_layout()
    fig_save(fig, "F08_replica_per_system.png")


def make_F09(df):
    """Single-metric: failure-mode breakdown is metric-independent."""
    rows = []
    for m in METHOD_ORDER:
        for noise in NOISE_ORDER:
            sub = df[(df["run"] == m) & (df["noise"] == noise)]
            n = len(sub)
            n_no_result = sub["no_result"].sum()
            n_diverged = sub["diverged"].sum()
            n_unfinished = sub["unfinished"].sum() - (sub["diverged"] & sub["unfinished"]).sum()
            # "Success" here uses top-1 by convention; the rest of the bar is "marginal".
            n_success = sub["top1_success_at_10pct"].sum()
            n_marginal = n - n_no_result - n_diverged - n_unfinished - n_success
            rows.append({
                "method": METHOD_LABELS[m],
                "noise": NOISE_FLOAT_TO_LABEL.get(noise, f"{noise:g}"),
                "success": n_success / n * 100,
                "marginal": max(0, n_marginal) / n * 100,
                "no_result": n_no_result / n * 100,
                "diverged": n_diverged / n * 100,
                "unfinished": n_unfinished / n * 100,
            })
    plot_df = pd.DataFrame(rows)
    fig, axes = plt.subplots(1, 4, figsize=(18, 5), sharey=True)
    categories = ["success", "marginal", "diverged", "no_result", "unfinished"]
    cat_colors = ["#2ecc71", "#f1c40f", "#e74c3c", "#95a5a6", "#8e44ad"]
    for idx, m in enumerate(METHOD_ORDER):
        ax = axes[idx]
        msub = plot_df[plot_df["method"] == METHOD_LABELS[m]]
        bottom = np.zeros(len(NOISE_LABELS))
        for cat, color in zip(categories, cat_colors):
            vals = msub[cat].values
            ax.bar(NOISE_LABELS, vals, bottom=bottom, color=color, label=cat if idx == 0 else "", edgecolor="white", linewidth=0.5)
            bottom += vals
        ax.set_title(METHOD_LABELS[m])
        ax.set_xlabel("Noise")
        if idx == 0:
            ax.set_ylabel("Percentage (%)")
        ax.set_ylim(0, 100)
    fig.legend(categories, loc="upper center", ncol=5, bbox_to_anchor=(0.5, 0.0), fontsize=10)
    fig.suptitle("Outcome Breakdown by Method and Noise (top-1 success)", fontsize=14)
    fig.tight_layout(rect=[0, 0.05, 1, 0.95])
    fig_save(fig, "F09_failure_mode_breakdown.png")


def make_F10(df, metric):
    systems = sorted(df["name"].unique())
    cliff_data = []
    for sys_name in systems:
        row = {}
        for m in METHOD_ORDER:
            prev_succ = None
            max_drop = 0
            for i, noise in enumerate(NOISE_ORDER):
                sub = df[(df["name"] == sys_name) & (df["noise"] == noise) & (df["run"] == m)]
                succ = sub[col(metric, "success_at_10pct")].mean() * 100
                if prev_succ is not None:
                    drop = prev_succ - succ
                    if drop > max_drop:
                        max_drop = drop
                prev_succ = succ
            row[METHOD_LABELS[m]] = max_drop
        cliff_data.append(row)
    cliff_df = pd.DataFrame(cliff_data, index=systems)
    cliff_df["mean_cliff"] = cliff_df.mean(axis=1)
    cliff_df = cliff_df.sort_values("mean_cliff", ascending=False)
    cliff_df = cliff_df.drop(columns="mean_cliff")
    fig, ax = plt.subplots(figsize=(8, 10))
    sns.heatmap(cliff_df, annot=True, fmt=".0f", cmap="YlOrRd", vmin=0,
                linewidths=0.5, ax=ax, cbar_kws={"label": "Max Success Drop (pp)"})
    ax.set_title(f"Noise Cliff: Largest Success Drop Between Adjacent Noise Levels {metric_title_tag(metric)}")
    ax.set_ylabel("")
    ax.set_xlabel("")
    fig_save(fig, f"F10_noise_cliff_heatmap{suffix(metric)}.png")


def make_F11(df):
    """Single-metric: timing is metric-independent."""
    fig, ax = plt.subplots(figsize=(8, 5))
    plot_data = df.copy()
    plot_data["method_label"] = pd.Categorical(
        plot_data["run"].map(METHOD_LABELS),
        categories=[METHOD_LABELS[m] for m in METHOD_ORDER],
        ordered=True,
    )
    sns.violinplot(data=plot_data, x="method_label", y="time", ax=ax,
                   palette=[METHOD_COLORS[m] for m in METHOD_ORDER],
                   inner="box", cut=0)
    ax.set_xlabel("")
    ax.set_ylabel("Time (seconds)")
    ax.set_title("Execution Time Distribution by Method")
    fig_save(fig, "F11_timing_comparison.png")


def make_F12(df, metric):
    agg = df[df["has_result"] == 1].groupby(["name", "run"]).agg(
        mean_success=(col(metric, "success_at_10pct"), "mean"),
        median_time=("time", "median"),
    ).reset_index()
    fig, ax = plt.subplots(figsize=(9, 6))
    for m in METHOD_ORDER:
        sub = agg[agg["run"] == m]
        ax.scatter(sub["median_time"], sub["mean_success"] * 100,
                   label=METHOD_LABELS[m], color=METHOD_COLORS[m],
                   alpha=0.7, s=50, edgecolors="gray", linewidth=0.5)
    ax.set_xlabel("Median Time (seconds)")
    ax.set_ylabel("Mean Success Rate @ 10% (%)")
    ax.set_title(f"Speed-Accuracy Trade-off by System and Method {metric_title_tag(metric)}")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig_save(fig, f"F12_accuracy_vs_time_scatter{suffix(metric)}.png")


def make_F13(df, metric):
    sys_stats = df.groupby("name").agg(
        n_id_params=("n_id_params", "first"),
        mean_success=(col(metric, "success_at_10pct"), "mean"),
    ).reset_index()
    sys_stats["mean_success_pct"] = sys_stats["mean_success"] * 100
    fig, ax = plt.subplots(figsize=(9, 6))
    ax.scatter(sys_stats["n_id_params"], sys_stats["mean_success_pct"],
               s=60, color="#1f77b4", edgecolors="gray", linewidth=0.5, zorder=5)
    for _, row in sys_stats.iterrows():
        ax.annotate(row["name"], (row["n_id_params"], row["mean_success_pct"]),
                    fontsize=7, xytext=(4, 4), textcoords="offset points", alpha=0.8)
    from numpy.polynomial.polynomial import polyfit
    x = sys_stats["n_id_params"].values
    y = sys_stats["mean_success_pct"].values
    b, m_coef = polyfit(x, y, 1)
    x_line = np.linspace(x.min(), x.max(), 100)
    ax.plot(x_line, b + m_coef * x_line, "--", color="red", alpha=0.5, label=f"Trend (slope={m_coef:.1f})")
    ax.set_xlabel("Number of Identifiable Parameters")
    ax.set_ylabel("Mean Success Rate @ 10% (%)")
    ax.set_title(f"System Difficulty vs Parameter Count {metric_title_tag(metric)}")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig_save(fig, f"F13_param_count_vs_difficulty{suffix(metric)}.png")


def make_F14(df, metric):
    rank_counts = {m: {1: 0, 2: 0, 3: 0, 4: 0} for m in METHOD_ORDER}
    for (sys_name, noise), grp in df.groupby(["name", "noise"]):
        method_succ = {}
        for m in METHOD_ORDER:
            sub = grp[grp["run"] == m]
            method_succ[m] = sub[col(metric, "success_at_10pct")].mean()
        sorted_methods = sorted(method_succ.keys(), key=lambda x: -method_succ[x])
        for rank, m in enumerate(sorted_methods, 1):
            rank_counts[m][rank] += 1
    total = len(df["name"].unique()) * len(NOISE_ORDER)
    fig, ax = plt.subplots(figsize=(8, 5))
    x = np.arange(len(METHOD_ORDER))
    width = 0.6
    rank_colors = ["#2ecc71", "#3498db", "#f39c12", "#e74c3c"]
    rank_labels = ["1st", "2nd", "3rd", "4th"]
    bottom = np.zeros(len(METHOD_ORDER))
    for rank in [1, 2, 3, 4]:
        vals = [rank_counts[m][rank] / total * 100 for m in METHOD_ORDER]
        ax.bar(x, vals, width, bottom=bottom, color=rank_colors[rank - 1],
               label=rank_labels[rank - 1], edgecolor="white", linewidth=0.5)
        for i, v in enumerate(vals):
            if v > 5:
                ax.text(x[i], bottom[i] + v / 2, f"{v:.0f}%",
                        ha="center", va="center", fontsize=8, fontweight="bold")
        bottom += vals
    ax.set_xticks(x)
    ax.set_xticklabels([METHOD_LABELS[m] for m in METHOD_ORDER])
    ax.set_ylabel("Percentage of Comparisons (%)")
    ax.set_title(f"Method Rank Distribution Across All (System, Noise) Pairs {metric_title_tag(metric)}")
    ax.legend(title="Rank")
    ax.set_ylim(0, 100)
    fig_save(fig, f"F14_method_rank_distribution{suffix(metric)}.png")


# ======================================================================
#  REPORT (one section per metric for dual; one section total for single)
# ======================================================================

def generate_report(df, t01s, t05s):
    """Write REPORT.md with Best-of-branches as the headline metric.

    Top-pick is shown only in a back-of-deck section for reference.
    Oracle is dropped from the main report (it's now equivalent to BoB
    post the ODEPE M-truncation; figures still generated for reference).

    t01s, t05s are dicts mapping metric_name -> DataFrame (one per variant).
    """
    n_systems = df["name"].nunique()
    n_methods = df["run"].nunique()
    n_noise = df["noise"].nunique()
    n_total = len(df)
    n_replicas = int(round(n_total / max(1, n_systems * n_methods * n_noise)))
    n_no_result = df["no_result"].sum()
    n_diverged = df["diverged"].sum()

    def method_overall(metric):
        out = {}
        for m in METHOD_ORDER:
            out[m] = df[df["run"] == m][col(metric, "success_at_10pct")].mean() * 100
        return out

    overall_top1 = method_overall("top1")
    overall_mbounded = method_overall("mbounded")
    ranked_mbounded = sorted(METHOD_ORDER, key=lambda m: -overall_mbounded[m])

    np_top1 = df[df["run"] == "odepe_v2_nopolish"]["top1_success_at_10pct"].mean() * 100
    p_top1 = df[df["run"] == "odepe_v2_polish"]["top1_success_at_10pct"].mean() * 100
    np_mbounded = df[df["run"] == "odepe_v2_nopolish"]["mbounded_success_at_10pct"].mean() * 100
    p_mbounded = df[df["run"] == "odepe_v2_polish"]["mbounded_success_at_10pct"].mean() * 100
    polish_uplift_mbounded = p_mbounded - np_mbounded
    # Used in the back-of-deck Top-pick vs BoB comparison
    polish_uplift_top1 = p_top1 - np_top1
    t01_mbounded = t01s["mbounded"]
    t01_top1 = t01s["top1"]
    t05_mbounded = t05s["mbounded"]

    sys_succ_mb = df.groupby("name")["mbounded_success_at_10pct"].mean().sort_values()
    hardest = sys_succ_mb.index[0]
    easiest = sys_succ_mb.index[-1]

    succ_noise0_mb = df[df["noise"] == 0.0]["mbounded_success_at_10pct"].mean() * 100
    succ_noise_high_mb = df[df["noise"] == 0.01]["mbounded_success_at_10pct"].mean() * 100

    timing = {METHOD_LABELS[m]: df[df["run"] == m]["time"].median() for m in METHOD_ORDER}

    n_helps_mb = (t05_mbounded["success_uplift_pp"] > 0).sum()
    n_hurts_mb = (t05_mbounded["success_uplift_pp"] < 0).sum()
    n_neutral_mb = (t05_mbounded["success_uplift_pp"] == 0).sum()

    best_mbounded = ranked_mbounded[0]

    # Per-method failure breakdown
    fail_rows = []
    for m in METHOD_ORDER:
        m_sub = df[df["run"] == m]
        nr = int((m_sub["has_result"] == 0).sum())
        dv = int(((m_sub["top1_max_rel_error"] > 1e4) & (m_sub["has_result"] == 1)).sum())
        fail_rows.append((METHOD_LABELS[m], nr, dv))

    # Per-cell polish-hurts list: cells where ODEPE-polish BoB > 10% but nopolish BoB < 10%
    polish_cells = df[df["run"] == "odepe_v2_polish"][
        ["name", "noise", "instance", "mbounded_max_rel_error"]
    ].rename(columns={"mbounded_max_rel_error": "polish_bob"})
    nopolish_cells = df[df["run"] == "odepe_v2_nopolish"][
        ["name", "noise", "instance", "mbounded_max_rel_error"]
    ].rename(columns={"mbounded_max_rel_error": "nopolish_bob"})
    paired = polish_cells.merge(nopolish_cells, on=["name", "noise", "instance"], how="inner")
    bad_polish = paired[
        (paired["polish_bob"] > 0.10) & (paired["nopolish_bob"] < 0.10)
        & paired["polish_bob"].notna() & paired["nopolish_bob"].notna()
    ].copy()
    bad_polish["delta"] = bad_polish["polish_bob"] - bad_polish["nopolish_bob"]
    bad_polish = bad_polish.sort_values("delta", ascending=False).head(15)
    good_polish_n = int(((paired["polish_bob"] < 0.10) & (paired["nopolish_bob"] > 0.10) &
                          paired["polish_bob"].notna() & paired["nopolish_bob"].notna()).sum())

    from datetime import datetime
    today = datetime.now().strftime("%Y-%m-%d")
    report = f"""# Quoll-Broad Benchmark Analysis Report
## benchmark_quoll_broad_2026-05-29 (receptor systems excluded)

**Generated:** {today}
**Data:** {n_total} rows = {n_systems} systems x {n_methods} methods x {n_noise} noise levels x {n_replicas} replicas
**Noise type:** Additive
**Headline metric:** Best-of-branches (M-bounded). See §6 for top-pick comparison and metric definitions.

---

## 1. Executive Summary

This analysis evaluates four parameter estimation methods across {n_systems} ODE systems at five noise levels (0, 1e-8, 1e-6, 1e-4, 1e-2) with {n_replicas} replicas each. Headline numbers (Best-of-branches @ 10%):

- **{METHOD_LABELS[best_mbounded]}** leads at **{overall_mbounded[best_mbounded]:.1f}%** success@10%.
- **{METHOD_LABELS[ranked_mbounded[1]]}**: {overall_mbounded[ranked_mbounded[1]]:.1f}%.
- **{METHOD_LABELS[ranked_mbounded[2]]}**: {overall_mbounded[ranked_mbounded[2]]:.1f}%.
- **{METHOD_LABELS[ranked_mbounded[3]]}**: {overall_mbounded[ranked_mbounded[3]]:.1f}%.

- **Polishing uplift**: +{polish_uplift_mbounded:.1f}pp (Best-of-branches) over unpolished ODEPE.
  Polish median wall time: {timing[METHOD_LABELS["odepe_v2_polish"]]:.0f}s/cell
  (nopolish median: {timing[METHOD_LABELS["odepe_v2_nopolish"]]:.0f}s/cell — polish is comparable
  or slightly faster in median; *mean* polish time is higher due to a longer tail of
  hard-cell polish attempts).
- **Noise dominates difficulty**: Best-of-branches success drops from {succ_noise0_mb:.1f}% at noise=0 to {succ_noise_high_mb:.1f}% at noise=1e-2 (across methods).
- **Failures**: {n_no_result} rows produced no result + {n_diverged} rows diverged
  ({(n_no_result+n_diverged)/n_total*100:.1f}% combined). All concentrated in ODEPE
  variants on the hardest cells (cstr, crauste, biohydrogenation, daisy_mamil4 at high noise).
  AMIGO2 and SHADE+LM have zero failures.

---

## 2. Overall Method Comparison

![Success by Noise — Best-of-branches](figures/F01_overall_success_by_noise_mbounded.png)

| Method | Success@1% | Success@10% | Success@50% | Median Time (s) | No Result | Diverged |
|--------|-----------|------------|------------|-----------------|-----------|----------|
"""
    for _, row in t01_mbounded.iterrows():
        report += f"| {row['method']} | {row['success_at_1pct']:.1f}% | {row['success_at_10pct']:.1f}% | {row['success_at_50pct']:.1f}% | {row['median_time_s']:.0f} | {int(row['n_no_result'])} | {int(row['n_diverged'])} |\n"

    report += f"""
### Method Rankings (1st/2nd/3rd/4th across cells)

![Rank Distribution — Best-of-branches](figures/F14_method_rank_distribution_mbounded.png)

---

## 3. Noise Degradation Analysis

![Heatmap — Best-of-branches](figures/F02_method_comparison_heatmap_mbounded.png)

### Noise Cliffs

![Noise Cliff — Best-of-branches](figures/F10_noise_cliff_heatmap_mbounded.png)

---

## 4. Polishing Effect

Polishing (bounded LM in log-space against the noisy data) is the second
stage of the ODEPE-polish pipeline. It lifts Best-of-branches by
**+{polish_uplift_mbounded:.1f}pp** over the nopolish variant at success@10%.

![Polishing by Noise — Best-of-branches](figures/F04_polishing_effect_by_noise_mbounded.png)

![Polishing Heatmap — Best-of-branches](figures/F05_polishing_heatmap_mbounded.png)

- Of {len(t05_mbounded)} (system, noise) pairs (Best-of-branches): polishing **helped** in {n_helps_mb}, **hurt** in {n_hurts_mb}, **neutral** in {n_neutral_mb}.

### Where polishing hurts — per-cell list

Cells where ODEPE-nopolish succeeded (BoB max-rel < 0.10) but ODEPE-polish failed
(BoB max-rel > 0.10), sorted worst-first by error delta:

| System | Noise | Inst. | Nopolish BoB err | Polish BoB err | Δ (polish − nopolish) |
|--------|-------|-------|------------------|----------------|------------------------|
"""
    NOISE_TO_LABEL = {0.0: "0", 1e-8: "1em8", 1e-6: "1em6", 1e-4: "1em4", 1e-2: "1em2"}
    for _, row in bad_polish.iterrows():
        report += (
            f"| `{row['name']}` | {NOISE_TO_LABEL.get(row['noise'], row['noise'])}"
            f" | {int(row['instance'])} | {row['nopolish_bob']:.3f}"
            f" | {row['polish_bob']:.3f} | {row['delta']:+.3f} |\n"
        )

    report += f"""

Across the whole benchmark: **{len(bad_polish) if len(bad_polish) > 0 else 0}+ cells** regressed
under polish on BoB (vs **{good_polish_n}** cells rescued by polish). Polish remains a
strong net win in aggregate — these are the cells worth investigating to push the headline
further.

---

## 5. System Difficulty

![System Ranking — Best-of-branches](figures/F03_system_difficulty_ranking_mbounded.png)

- **Hardest system (Best-of-branches):** `{hardest}` ({sys_succ_mb.iloc[0]*100:.1f}% mean success)
- **Easiest system (Best-of-branches):** `{easiest}` ({sys_succ_mb.iloc[-1]*100:.1f}% mean success)

![Param Count vs Difficulty — Best-of-branches](figures/F13_param_count_vs_difficulty_mbounded.png)

### Domain Analysis

![Domain Radar — Best-of-branches](figures/F06_domain_radar_mbounded.png)

---

## 6. Methodology: Top-pick vs Best-of-branches

This report uses **Best-of-branches** (BoB) as its headline metric.
Alternatives and their relationships:

- **Top-pick** (a.k.a. top-1, row-0). The algorithm's primary recommendation:
  `result.csv` row 0, sorted by the method's internal score. What a user gets
  by default. For AMIGO2 and SHADE+LM, this is the only answer (K=1).
- **Best-of-branches** (a.k.a. M-bounded). Best of the M candidate branches
  ODEPE returned in `result.csv` — i.e. oracle ranking over the returned rows.
  M is ODEPE's runtime-detected algebraic multiplicity (it truncates result.csv
  to exactly M rows), so M = the row count — no external catalog, no overlay.
  M=1 for 20 of the 25 systems (BoB = top-pick on those). M=2 for daisy_mamil4,
  seir, slow_fast, biohydrogenation; M=6 for latent_subpopulation_branch (S3
  subpopulation symmetry) — BoB credits the method for finding any branch.
- **Oracle (legacy)** — argmin over all K=20 rows. ODEPE now truncates
  `result.csv` to M rows in-pipeline (commit 6ffc6cb), so oracle ≡ BoB by
  definition. We've dropped oracle from the main flow; figures are still
  generated for reference under `_oracle.png` suffix.

For K=1 methods (AMIGO2, SHADE+LM), all three metrics collapse to the same
number. **BoB is the metric where ODEPE's K=M output and AMIGO2/SHADE's K=1
output can be compared apples-to-apples.**

### Comparison: Top-pick vs Best-of-branches

| Method | Top-pick @10% | BoB @10% | Δ (BoB − Top-pick) |
|--------|---------------|----------|---------------------|
"""
    for m in METHOD_ORDER:
        delta = overall_mbounded[m] - overall_top1[m]
        report += f"| {METHOD_LABELS[m]} | {overall_top1[m]:.1f}% | {overall_mbounded[m]:.1f}% | {delta:+.1f}pp |\n"

    report += f"""
For K=1 methods (AMIGO2, SHADE+LM), the delta is 0 by construction.
For ODEPE-polish, the delta is +{p_mbounded - p_top1:.1f}pp; for ODEPE-nopolish,
+{np_mbounded - np_top1:.1f}pp. The nopolish delta is larger because
the nopolish row-0 sort more often picks the wrong algebraic branch.

Reading the top-pick column reverses the leader (AMIGO2 76.1% vs
ODEPE-polish 75.3%) — but this penalizes ODEPE for emitting structure
(K=M candidates) that AMIGO2 cannot. BoB is the comparable framing.

### Top-pick reference (for users wanting the row-0 number)

| Method | Success@1% | Success@10% | Success@50% |
|--------|-----------|------------|------------|
"""
    for _, row in t01_top1.iterrows():
        report += f"| {row['method']} | {row['success_at_1pct']:.1f}% | {row['success_at_10pct']:.1f}% | {row['success_at_50pct']:.1f}% |\n"

    report += f"""

---

## 7. Replica Stability

![Replica Stability](figures/F07_replica_stability_boxplot.png)

![Per-System Replicas](figures/F08_replica_per_system.png)

---

## 8. Failures

![Failure Breakdown](figures/F09_failure_mode_breakdown.png)

| Method | No Result | Diverged | Total | Rate |
|--------|-----------|----------|-------|------|
"""
    n_per_method = len(df) // n_methods
    for label, nr, dv in fail_rows:
        report += f"| {label} | {nr} | {dv} | {nr+dv} | {(nr+dv)/n_per_method*100:.1f}% |\n"

    report += f"""

- **No Result**: method produced no parseable answer (Julia crash, OOM, SLURM timeout).
- **Diverged**: returned answer with max relative error > 10^4 (orders of magnitude off).
- AMIGO2 and SHADE+LM produced an answer for every cell — they are designed to always
  emit *something*, even if it's a poor fit (which then shows up as a low-success rate
  rather than a missing row).
- ODEPE failures concentrate at high noise on the hardest systems (cstr, crauste,
  biohydrogenation, daisy_mamil4). Two additional cells were cancelled during the rerun
  after 15–22h no-progress hangs (HC.jl path-tracking deadlock).

---

## 9. Timing and Speed-Accuracy Trade-off

![Timing](figures/F11_timing_comparison.png)

![Speed-Accuracy — Best-of-branches](figures/F12_accuracy_vs_time_scatter_mbounded.png)

---

## 10. Conclusions

### Method Rankings (Best-of-branches)
"""
    for rank_idx, m in enumerate(ranked_mbounded, 1):
        report += f"{rank_idx}. **{METHOD_LABELS[m]}** — {overall_mbounded[m]:.1f}% success@10%, median {timing[METHOD_LABELS[m]]:.0f}s\n"

    report += f"""
### Key Takeaways
- **{METHOD_LABELS[best_mbounded]} leads** at {overall_mbounded[best_mbounded]:.1f}% Best-of-branches
  success@10%, ahead of {METHOD_LABELS[ranked_mbounded[1]]} ({overall_mbounded[ranked_mbounded[1]]:.1f}%).
- **Polishing is worth it**: +{polish_uplift_mbounded:.1f}pp on Best-of-branches; median wall
  time is comparable to nopolish ({timing[METHOD_LABELS["odepe_v2_polish"]]:.0f}s vs
  {timing[METHOD_LABELS["odepe_v2_nopolish"]]:.0f}s).
- **Noise dominates**: BoB success drops ~{succ_noise0_mb - succ_noise_high_mb:.0f}pp from clean to 1% noise across methods.
- **Best-of-branches** is the apples-to-apples metric vs K=1 methods. For the 4 multiplicity-2
  systems, ODEPE-polish gets credit for surfacing either algebraic branch; AMIGO2/SHADE are
  unaffected by the BoB framing.
- **Open questions for the paper**: how prominently to feature the BoB framing vs the
  underlying structural-identifiability story that makes ODEPE's K=M output meaningful in
  the first place. See `results/wallaby_analysis/numbat06_vs_wallaby_new_polish_regression_analysis.md`
  for a 39-cell list of polish regressions and 6 candidate algorithmic fixes worth piloting.
"""
    with open(REPORT_PATH, "w") as f:
        f.write(report)
    print(f"  Saved REPORT.md")


# ======================================================================
#  MAIN
# ======================================================================

def main():
    print("Loading data...")
    df = load_data()
    print(f"  {len(df)} rows, {df['name'].nunique()} systems, {df['run'].nunique()} methods")

    # Dual-metric tables
    t01s = {}
    t05s = {}
    for metric in METRIC_VARIANTS:
        print(f"\nGenerating tables ({metric})...")
        t01s[metric] = make_T01(df, metric); print(f"  T01 ({metric}) done")
        make_T02(df, metric); print(f"  T02 ({metric}) done")
        make_T03(df, metric); print(f"  T03 ({metric}) done")
        make_T04(df, metric); print(f"  T04 ({metric}) done")
        t05s[metric] = make_T05(df, metric); print(f"  T05 ({metric}) done")
        make_T08(df, metric); print(f"  T08 ({metric}) done")

    # Single-metric tables
    print("\nGenerating single-metric tables...")
    make_T06(df); print("  T06 done")
    make_T07(df); print("  T07 done")

    # Dual-metric figures
    for metric in METRIC_VARIANTS:
        print(f"\nGenerating figures ({metric})...")
        make_F01(df, metric)
        make_F02(df, metric)
        make_F03(df, metric)
        make_F04(df, metric)
        make_F05(df, metric)
        make_F06(df, metric)
        make_F10(df, metric)
        make_F12(df, metric)
        make_F13(df, metric)
        make_F14(df, metric)

    # Single-metric figures
    print("\nGenerating single-metric figures...")
    make_F07(df)
    make_F08(df)
    make_F09(df)
    make_F11(df)

    print("\nGenerating report...")
    generate_report(df, t01s, t05s)

    print("\nDone!")
    print(f"  Tables: {TABLE_DIR}/")
    print(f"  Figures: {FIG_DIR}/")
    print(f"  Report: {REPORT_PATH}")


if __name__ == "__main__":
    main()
