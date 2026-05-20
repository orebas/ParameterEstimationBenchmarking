# Independent Benchmark Analysis Report
## benchmark_wallaby_2026-05-17

**Generated:** 2026-05-19
**Data:** 4600 rows = 23 systems x 4 methods x 5 noise levels x 10 replicas
**Noise type:** Additive

---

## Metric definitions

This report tracks two parallel accuracy metrics per cell:

- **Top-1 (algorithm's pick)** — the algorithm's row-0 answer in
  `result.csv` (sorted by `err` for ODEPE, single answer for AMIGO2 /
  SHADE) is scored on `max_rel_error` over identifiable axes only.
  This is the **paper-headline** metric: what the user actually sees.
- **Best-of-K (oracle)** — argmin over all rows of `result.csv` on the
  same identifiable axes. This is the **set-credit ceiling**: the best
  the algorithm could have done if its row-0 sort were perfect. For
  K=1 methods (AMIGO2, SHADE) the two are identical. For ODEPE
  (K=20), they can differ — the gap measures rank-1 sort headroom.

Section 2A reports top-1; section 2B reports oracle. Sections 3+
(metric-independent: noise cliffs, polishing, replica spread, failure
analysis, timing) reference both as relevant.

---

## 1. Executive Summary

This analysis evaluates four parameter estimation methods across 23 ODE systems at five noise levels (0, 1e-8, 1e-6, 1e-4, 1e-2) with 10 replicas each. Key findings:

- **Top-1 best**: AMIGO2 at **76.1%** success@10%.
- **Oracle best**: ODEPE-v2 (polish) at **81.1%** success@10%.
- Polishing uplift: **+13.8 pp** (top-1) / **+11.4 pp** (oracle) over unpolished ODEPE.
- Success degrades from **87.3%** at noise=0 to **41.3%** at noise=1e-2 (top-1, across methods).
- **6** rows produced no result; **30** rows diverged (top-1 max_rel_error > 10^4).

---

## 2A. Top-1 method comparison (paper convention)

![Success by Noise — Top-1](figures/F01_overall_success_by_noise.png)

| Method | Success@1% | Success@10% | Success@50% | Median Time (s) | No Result | Diverged |
|--------|-----------|------------|------------|-----------------|-----------|----------|
| ODEPE-v2 (polish) | 64.7% | 75.4% | 80.4% | 694 | 3 | 5 |
| ODEPE-v2 (no polish) | 52.8% | 61.6% | 69.9% | 743 | 3 | 25 |
| AMIGO2 | 67.2% | 76.1% | 80.8% | 633 | 0 | 0 |
| SHADE+LM | 62.3% | 69.8% | 74.0% | 372 | 0 | 0 |

### Method Rankings (Top-1)

![Rank Distribution — Top-1](figures/F14_method_rank_distribution.png)

---

## 2B. Best-of-K (oracle) method comparison — set-credit ceiling

For ODEPE (K=20) this reports the lower-bound oracle: what the
algorithm could have done with a perfect rank-1 picker. For AMIGO2 and
SHADE (K=1) it equals the top-1 row.

![Success by Noise — Oracle](figures/F01_overall_success_by_noise_oracle.png)

| Method | Success@1% | Success@10% | Success@50% | Median Time (s) | No Result | Diverged |
|--------|-----------|------------|------------|-----------------|-----------|----------|
| ODEPE-v2 (polish) | 68.9% | 81.1% | 85.7% | 694 | 3 | 5 |
| ODEPE-v2 (no polish) | 57.7% | 69.7% | 79.0% | 743 | 3 | 25 |
| AMIGO2 | 67.2% | 76.1% | 80.8% | 633 | 0 | 0 |
| SHADE+LM | 62.3% | 69.8% | 74.0% | 372 | 0 | 0 |

### Method Rankings (Oracle)

![Rank Distribution — Oracle](figures/F14_method_rank_distribution_oracle.png)

---

## 3. Noise Degradation Analysis

Top-1 vs oracle heatmaps side-by-side:

![Heatmap — Top-1](figures/F02_method_comparison_heatmap.png)

![Heatmap — Oracle](figures/F02_method_comparison_heatmap_oracle.png)

### Noise Cliffs

![Noise Cliff — Top-1](figures/F10_noise_cliff_heatmap.png)

![Noise Cliff — Oracle](figures/F10_noise_cliff_heatmap_oracle.png)

---

## 4. Polishing Effect

The polishing slide is where the top-1 vs oracle distinction matters
most. Under top-1, polish helps **+13.8pp**. Under
oracle, polish helps **+11.4pp** — the larger
gap reflects that polish often **finds** the right basin (improving
oracle), but the row-0 sort doesn't always **surface** the truth-near
row at rank 1 (reducing top-1 uplift).

![Polishing — Top-1](figures/F04_polishing_effect_by_noise.png)

![Polishing — Oracle](figures/F04_polishing_effect_by_noise_oracle.png)

![Polishing Heatmap — Top-1](figures/F05_polishing_heatmap.png)

![Polishing Heatmap — Oracle](figures/F05_polishing_heatmap_oracle.png)

- Of 115 (system, noise) pairs (top-1): polishing **helped** in 44, **hurt** in 7, **neutral** in 64.
- Same count under oracle: polishing **helped** in 42.

---

## 5. System Difficulty

![System Ranking — Top-1](figures/F03_system_difficulty_ranking.png)

![System Ranking — Oracle](figures/F03_system_difficulty_ranking_oracle.png)

- **Hardest system (top-1):** `cstr` (22.0% mean success)
- **Easiest system (top-1):** `harmonic_oscillator` (100.0% mean success)

![Param Count vs Difficulty — Top-1](figures/F13_param_count_vs_difficulty.png)

---

## 6. Domain Analysis

![Domain Radar — Top-1](figures/F06_domain_radar.png)

![Domain Radar — Oracle](figures/F06_domain_radar_oracle.png)

---

## 7. Replica Stability (single-metric — top-1)

![Replica Stability](figures/F07_replica_stability_boxplot.png)

![Per-System Replicas](figures/F08_replica_per_system.png)

---

## 8. Failure Analysis (single-metric)

![Failure Breakdown](figures/F09_failure_mode_breakdown.png)

---

## 9. Timing and Speed-Accuracy Trade-off

![Timing (single-metric)](figures/F11_timing_comparison.png)

![Speed-Accuracy — Top-1](figures/F12_accuracy_vs_time_scatter.png)

![Speed-Accuracy — Oracle](figures/F12_accuracy_vs_time_scatter_oracle.png)

---

## 10. Conclusions

### Method Rankings (Top-1, paper convention)
1. **AMIGO2** -- 76.1% success@10%, median 633s
2. **ODEPE-v2 (polish)** -- 75.4% success@10%, median 694s
3. **SHADE+LM** -- 69.8% success@10%, median 372s
4. **ODEPE-v2 (no polish)** -- 61.6% success@10%, median 743s

### Method Rankings (Oracle, set-credit ceiling)
1. **ODEPE-v2 (polish)** -- 81.1% success@10%, median 694s
2. **AMIGO2** -- 76.1% success@10%, median 633s
3. **SHADE+LM** -- 69.8% success@10%, median 372s
4. **ODEPE-v2 (no polish)** -- 69.7% success@10%, median 743s

### Key Takeaways
- **Noise is the primary difficulty driver** — top-1 success drops by ~46pp from noise=0 to noise=1e-2.
- **Polishing helps** — top-1 uplift +13.8pp, oracle uplift +11.4pp.
- **The top-1 → oracle gap on ODEPE polish** is +5.7pp at @10% — that's the room available if the rank-1 sort were perfect.
- **No method dominates everywhere** — best top-1 is AMIGO2, best oracle is ODEPE-v2 (polish).
