# Independent Benchmark Analysis Report
## benchmark_wallaby_2026-05-17

**Generated:** 2026-05-21
**Data:** 4600 rows = 23 systems x 4 methods x 5 noise levels x 10 replicas
**Noise type:** Additive

---

## Metric definitions

This report tracks **three parallel accuracy metrics** per cell:

- **Top-1 (algorithm's pick)** — the algorithm's row-0 answer in
  `result.csv` (sorted by `err` for ODEPE, single answer for AMIGO2 /
  SHADE) is scored on `max_rel_error` over identifiable axes only.
  What a user sees if they take only the algorithm's primary
  recommendation.
- **M-bounded (algebraic multiplicity)** — argmin over the top `M`
  rows of `result.csv`, where `M` is the algebraic multiplicity of
  the system (1 for 19 of 23 systems; 2 for daisy_mamil4, seir,
  slow_fast, biohydrogenation). This is the **paper-headline** metric:
  it gives the algorithm credit for returning *all* algebraic
  branches without punishing it for the K=20 numerical safety cap.
  For M=1 systems it equals top-1 exactly.
- **Best-of-K (oracle)** — argmin over **all** K=20 rows. The
  set-credit upper bound — what the algorithm could have done if the
  rank-1 sort were perfect. The mbounded → oracle gap measures
  in-cluster sort headroom (within an algebraic branch).

For K=1 methods (AMIGO2, SHADE) all three collapse to the same value.
For ODEPE (K=20): `top1 ≤ mbounded ≤ oracle` per cell.

---

## 1. Executive Summary

This analysis evaluates four parameter estimation methods across 23 ODE systems at five noise levels (0, 1e-8, 1e-6, 1e-4, 1e-2) with 10 replicas each. Key findings:

- **Top-1 best**: AMIGO2 at **76.1%** success@10%.
- **M-bounded best**: ODEPE-v2 (polish) at **78.8%** success@10%.
- **Oracle best**: ODEPE-v2 (polish) at **78.8%** success@10%.
- Polishing uplift: **+13.5 pp** (top-1) / **+12.5 pp** (M-bounded) / **+12.5 pp** (oracle) over unpolished ODEPE.
- ODEPE-v2 polish: top-1 = 75.3%, M-bounded = 78.8% (**+3.5pp** from counting both algebraic branches), oracle = 78.8%.
- Success degrades from **87.2%** at noise=0 to **41.3%** at noise=1e-2 (top-1, across methods).
- **3** rows produced no result; **28** rows diverged (top-1 max_rel_error > 10^4).

---

## 2A. Top-1 method comparison (paper convention)

![Success by Noise — Top-1](figures/F01_overall_success_by_noise.png)

| Method | Success@1% | Success@10% | Success@50% | Median Time (s) | No Result | Diverged |
|--------|-----------|------------|------------|-----------------|-----------|----------|
| ODEPE-v2 (polish) | 64.8% | 75.3% | 80.1% | 712 | 1 | 5 |
| ODEPE-v2 (no polish) | 53.0% | 61.8% | 70.5% | 762 | 2 | 23 |
| AMIGO2 | 67.2% | 76.1% | 80.8% | 633 | 0 | 0 |
| SHADE+LM | 62.3% | 69.8% | 74.0% | 372 | 0 | 0 |

### Method Rankings (Top-1)

![Rank Distribution — Top-1](figures/F14_method_rank_distribution.png)

---

## 2B. M-bounded method comparison (paper headline)

The M-bounded metric scores the best of the top `M` rows per cell,
where `M = algebraic_multiplicity` from `config/systems.json`.
For multiplicity-1 systems this is identical to top-1; for the
4 multiplicity-2 systems, the algorithm gets credit for finding
both branches as long as either one is near truth.

![Success by Noise — M-bounded](figures/F01_overall_success_by_noise_mbounded.png)

| Method | Success@1% | Success@10% | Success@50% | Median Time (s) | No Result | Diverged |
|--------|-----------|------------|------------|-----------------|-----------|----------|
| ODEPE-v2 (polish) | 67.7% | 78.8% | 83.3% | 712 | 1 | 5 |
| ODEPE-v2 (no polish) | 56.7% | 66.3% | 75.2% | 762 | 2 | 23 |
| AMIGO2 | 67.2% | 76.1% | 80.8% | 633 | 0 | 0 |
| SHADE+LM | 62.3% | 69.8% | 74.0% | 372 | 0 | 0 |

### Method Rankings (M-bounded)

![Rank Distribution — M-bounded](figures/F14_method_rank_distribution_mbounded.png)

---

## 2C. Best-of-K (oracle) method comparison — set-credit ceiling

For ODEPE (K=20) this reports the lower-bound oracle: what the
algorithm could have done with a perfect rank-1 picker. For AMIGO2 and
SHADE (K=1) it equals the top-1 row.

![Success by Noise — Oracle](figures/F01_overall_success_by_noise_oracle.png)

| Method | Success@1% | Success@10% | Success@50% | Median Time (s) | No Result | Diverged |
|--------|-----------|------------|------------|-----------------|-----------|----------|
| ODEPE-v2 (polish) | 67.7% | 78.8% | 83.3% | 712 | 1 | 5 |
| ODEPE-v2 (no polish) | 56.7% | 66.3% | 75.2% | 762 | 2 | 23 |
| AMIGO2 | 67.2% | 76.1% | 80.8% | 633 | 0 | 0 |
| SHADE+LM | 62.3% | 69.8% | 74.0% | 372 | 0 | 0 |

### Method Rankings (Oracle)

![Rank Distribution — Oracle](figures/F14_method_rank_distribution_oracle.png)

---

## 3. Noise Degradation Analysis

Top-1, M-bounded, and oracle heatmaps:

![Heatmap — Top-1](figures/F02_method_comparison_heatmap.png)

![Heatmap — M-bounded](figures/F02_method_comparison_heatmap_mbounded.png)

![Heatmap — Oracle](figures/F02_method_comparison_heatmap_oracle.png)

### Noise Cliffs

![Noise Cliff — Top-1](figures/F10_noise_cliff_heatmap.png)

![Noise Cliff — M-bounded](figures/F10_noise_cliff_heatmap_mbounded.png)

![Noise Cliff — Oracle](figures/F10_noise_cliff_heatmap_oracle.png)

---

## 4. Polishing Effect

The metric choice matters here. Under top-1, polish helps
**+13.5pp**. Under M-bounded, polish helps
**+12.5pp**. Under oracle, polish helps
**+12.5pp**. The interpretation:

- Top-1 → M-bounded gap is **rank-1 sort within the K=20 list,
  *across* algebraic branches** — small for polish (row 0 is usually
  truth or near-truth) but large for nopolish (row 0 is often the
  wrong branch).
- M-bounded → oracle gap is **within-branch sort headroom** — when
  it's nonzero, the algorithm has a near-truth row deeper than row M.
  Smaller than the top-1 → M-bounded gap.

![Polishing — Top-1](figures/F04_polishing_effect_by_noise.png)

![Polishing — M-bounded](figures/F04_polishing_effect_by_noise_mbounded.png)

![Polishing — Oracle](figures/F04_polishing_effect_by_noise_oracle.png)

![Polishing Heatmap — Top-1](figures/F05_polishing_heatmap.png)

![Polishing Heatmap — M-bounded](figures/F05_polishing_heatmap_mbounded.png)

![Polishing Heatmap — Oracle](figures/F05_polishing_heatmap_oracle.png)

- Of 115 (system, noise) pairs (top-1): polishing **helped** in 43, **hurt** in 6, **neutral** in 66.
- Under M-bounded: polishing **helped** in 41.
- Under oracle: polishing **helped** in 41.

---

## 5. System Difficulty

![System Ranking — Top-1](figures/F03_system_difficulty_ranking.png)

![System Ranking — M-bounded](figures/F03_system_difficulty_ranking_mbounded.png)

![System Ranking — Oracle](figures/F03_system_difficulty_ranking_oracle.png)

- **Hardest system (top-1):** `cstr` (22.0% mean success)
- **Easiest system (top-1):** `harmonic_oscillator` (100.0% mean success)

![Param Count vs Difficulty — Top-1](figures/F13_param_count_vs_difficulty.png)

---

## 6. Domain Analysis

![Domain Radar — Top-1](figures/F06_domain_radar.png)

![Domain Radar — M-bounded](figures/F06_domain_radar_mbounded.png)

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

![Speed-Accuracy — M-bounded](figures/F12_accuracy_vs_time_scatter_mbounded.png)

![Speed-Accuracy — Oracle](figures/F12_accuracy_vs_time_scatter_oracle.png)

---

## 10. Conclusions

### Method Rankings (Top-1, what users see by default)
1. **AMIGO2** -- 76.1% success@10%, median 633s
2. **ODEPE-v2 (polish)** -- 75.3% success@10%, median 712s
3. **SHADE+LM** -- 69.8% success@10%, median 372s
4. **ODEPE-v2 (no polish)** -- 61.8% success@10%, median 762s

### Method Rankings (M-bounded, paper-headline)
1. **ODEPE-v2 (polish)** -- 78.8% success@10%, median 712s
2. **AMIGO2** -- 76.1% success@10%, median 633s
3. **SHADE+LM** -- 69.8% success@10%, median 372s
4. **ODEPE-v2 (no polish)** -- 66.3% success@10%, median 762s

### Method Rankings (Oracle, set-credit ceiling)
1. **ODEPE-v2 (polish)** -- 78.8% success@10%, median 712s
2. **AMIGO2** -- 76.1% success@10%, median 633s
3. **SHADE+LM** -- 69.8% success@10%, median 372s
4. **ODEPE-v2 (no polish)** -- 66.3% success@10%, median 762s

### Key Takeaways
- **Noise is the primary difficulty driver** — top-1 success drops by ~46pp from noise=0 to noise=1e-2.
- **Polishing helps** under all three metrics: top-1 +13.5pp, M-bounded +12.5pp, oracle +12.5pp.
- **The top-1 → M-bounded gap on ODEPE polish** is +3.5pp at @10%. That's how much paper-headline success comes from giving the algorithm credit for finding all M algebraic branches instead of just row 0.
- **The M-bounded → oracle gap on ODEPE polish** is +0.0pp at @10%. Within-branch sort headroom — smaller than the cross-branch gap.
- **Best paper-headline method**: ODEPE-v2 (polish) at 78.8%.
