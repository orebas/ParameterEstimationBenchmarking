#!/usr/bin/env python3
"""Plot kernel comparison results for lotka_volterra derivative quality."""

import csv
import os
import numpy as np

# Must set backend before importing pyplot
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.ticker import LogLocator

OUTDIR = "/scratch/oren-qc-13/ParameterEstimationBenchmarking/kernel_comparison_results"
PLOTDIR = os.path.join(OUTDIR, "plots")
os.makedirs(PLOTDIR, exist_ok=True)

# Kernels to plot (skip Periodic — it's terrible)
KERNELS = ["SE", "Matern52", "Matern72", "Matern92", "SExPeriodic"]
KERNEL_LABELS = {
    "SE": "SE (RBF)",
    "Matern52": "Matérn 5/2",
    "Matern72": "Matérn 7/2",
    "Matern92": "Matérn 9/2",
    "SExPeriodic": "SE × Periodic",
}
KERNEL_COLORS = {
    "SE": "#1f77b4",
    "Matern52": "#ff7f0e",
    "Matern72": "#2ca02c",
    "Matern92": "#d62728",
    "SExPeriodic": "#9467bd",
}


def read_csv(path):
    """Read CSV into dict of numpy arrays."""
    with open(path) as f:
        reader = csv.DictReader(f)
        cols = {k: [] for k in reader.fieldnames}
        for row in reader:
            for k, v in row.items():
                cols[k].append(float(v))
    return {k: np.array(v) for k, v in cols.items()}


def read_summary(path):
    """Read summary CSV."""
    with open(path) as f:
        reader = csv.DictReader(f)
        data = {}
        for row in reader:
            name = row["kernel"]
            data[name] = {k: float(v) for k, v in row.items() if k != "kernel"}
    return data


# ── Figure 1: Bar chart of derivative errors by kernel ────────────────
for noise_tag in ["0", "1em8"]:
    summary = read_summary(os.path.join(OUTDIR, f"summary_{noise_tag}.csv"))
    noise_label = "noise=0" if noise_tag == "0" else "noise=1e-8"

    fig, ax = plt.subplots(figsize=(10, 5))
    deriv_orders = [0, 1, 2, 3]
    x = np.arange(len(deriv_orders))
    width = 0.15
    n_kernels = len(KERNELS)

    for i, kname in enumerate(KERNELS):
        if kname not in summary:
            continue
        vals = [summary[kname].get(f"d{d}", np.nan) for d in deriv_orders]
        offset = (i - n_kernels / 2 + 0.5) * width
        bars = ax.bar(x + offset, vals, width, label=KERNEL_LABELS[kname],
                      color=KERNEL_COLORS[kname], alpha=0.85)

    ax.set_yscale("log")
    ax.set_xlabel("Derivative order", fontsize=12)
    ax.set_ylabel("Relative RMSE (at 8 shooting pts)", fontsize=12)
    ax.set_title(f"Lotka-Volterra: Kernel Comparison ({noise_label}, n=1001)", fontsize=13)
    ax.set_xticks(x)
    ax.set_xticklabels([f"d{d}" for d in deriv_orders])
    ax.legend(fontsize=9, loc="upper left")
    ax.grid(axis="y", alpha=0.3)
    ax.set_ylim(1e-7, 1e2)

    fig.tight_layout()
    fig.savefig(os.path.join(PLOTDIR, f"deriv_errors_bar_{noise_tag}.png"), dpi=150)
    plt.close(fig)
    print(f"Saved deriv_errors_bar_{noise_tag}.png")


# ── Figure 2: Prediction vs truth for d0 and d3 ──────────────────────
for noise_tag in ["0", "1em8"]:
    noise_label = "noise=0" if noise_tag == "0" else "noise=1e-8"

    fig, axes = plt.subplots(2, 2, figsize=(14, 8))
    fig.suptitle(f"Lotka-Volterra ({noise_label}, n=1001)", fontsize=14)

    for col, d in enumerate([0, 3]):
        # Top row: predictions overlaid on truth
        ax_top = axes[0, col]
        # Bottom row: absolute errors
        ax_bot = axes[1, col]

        # Plot truth
        gt = read_csv(os.path.join(OUTDIR, "ground_truth.csv"))
        t = gt["t"]
        truth = gt[f"d{d}"]
        ax_top.plot(t, truth, "k-", linewidth=1.5, label="Truth", zorder=10)
        ax_top.set_title(f"d{d} — predictions", fontsize=11)

        for kname in ["SE", "Matern72", "SExPeriodic"]:
            pred_file = os.path.join(OUTDIR, f"pred_{kname}_{noise_tag}.csv")
            if not os.path.exists(pred_file):
                continue
            data = read_csv(pred_file)
            pred = data[f"pred_d{d}"]
            err = data[f"abserr_d{d}"]

            ax_top.plot(t, pred, "-", color=KERNEL_COLORS[kname],
                        linewidth=0.8, alpha=0.8, label=KERNEL_LABELS[kname])
            ax_bot.plot(t, err, "-", color=KERNEL_COLORS[kname],
                        linewidth=0.8, alpha=0.8, label=KERNEL_LABELS[kname])

        ax_top.set_ylabel(f"d{d}(y₁)")
        ax_top.legend(fontsize=8)
        ax_top.grid(alpha=0.3)

        ax_bot.set_yscale("log")
        ax_bot.set_xlabel("t")
        ax_bot.set_ylabel(f"|error| in d{d}")
        ax_bot.legend(fontsize=8)
        ax_bot.grid(alpha=0.3)

    fig.tight_layout()
    fig.savefig(os.path.join(PLOTDIR, f"pred_vs_truth_{noise_tag}.png"), dpi=150)
    plt.close(fig)
    print(f"Saved pred_vs_truth_{noise_tag}.png")


# ── Figure 3: All kernels — d3 error across time ─────────────────────
for noise_tag in ["0", "1em8"]:
    noise_label = "noise=0" if noise_tag == "0" else "noise=1e-8"

    fig, ax = plt.subplots(figsize=(12, 5))
    for kname in KERNELS:
        pred_file = os.path.join(OUTDIR, f"pred_{kname}_{noise_tag}.csv")
        if not os.path.exists(pred_file):
            continue
        data = read_csv(pred_file)
        t = data["t"]
        err = data["abserr_d3"]
        ax.plot(t, err, "-", color=KERNEL_COLORS[kname],
                linewidth=1.0, alpha=0.8, label=KERNEL_LABELS[kname])

    ax.set_yscale("log")
    ax.set_xlabel("t", fontsize=12)
    ax.set_ylabel("|error| in d³y₁/dt³", fontsize=12)
    ax.set_title(f"d3 derivative error across time ({noise_label}, n=1001)", fontsize=13)
    ax.legend(fontsize=9)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(PLOTDIR, f"d3_error_vs_time_{noise_tag}.png"), dpi=150)
    plt.close(fig)
    print(f"Saved d3_error_vs_time_{noise_tag}.png")


# ── Figure 4: Summary heatmap — all kernels × all derivatives ────────
for noise_tag in ["0", "1em8"]:
    summary = read_summary(os.path.join(OUTDIR, f"summary_{noise_tag}.csv"))
    noise_label = "noise=0" if noise_tag == "0" else "noise=1e-8"

    kernels_show = [k for k in KERNELS if k in summary]
    deriv_orders = list(range(6))  # d0-d5
    matrix = np.zeros((len(kernels_show), len(deriv_orders)))
    for i, kname in enumerate(kernels_show):
        for j, d in enumerate(deriv_orders):
            matrix[i, j] = np.log10(max(summary[kname].get(f"d{d}", 1e-20), 1e-20))

    fig, ax = plt.subplots(figsize=(8, 4))
    im = ax.imshow(matrix, cmap="RdYlGn_r", aspect="auto", vmin=-7, vmax=2)
    ax.set_xticks(range(len(deriv_orders)))
    ax.set_xticklabels([f"d{d}" for d in deriv_orders])
    ax.set_yticks(range(len(kernels_show)))
    ax.set_yticklabels([KERNEL_LABELS[k] for k in kernels_show])
    ax.set_xlabel("Derivative order")
    ax.set_title(f"log₁₀(rel_rmse) — {noise_label}", fontsize=13)

    # Annotate cells
    for i in range(len(kernels_show)):
        for j in range(len(deriv_orders)):
            val = matrix[i, j]
            color = "white" if val > 0 else "black"
            ax.text(j, i, f"{10**val:.1e}", ha="center", va="center",
                    fontsize=7, color=color)

    fig.colorbar(im, ax=ax, label="log₁₀(rel_rmse)")
    fig.tight_layout()
    fig.savefig(os.path.join(PLOTDIR, f"heatmap_{noise_tag}.png"), dpi=150)
    plt.close(fig)
    print(f"Saved heatmap_{noise_tag}.png")


print(f"\nAll plots saved to {PLOTDIR}")
