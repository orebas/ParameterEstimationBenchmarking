# Summary Statistics

**Generated from**: `combined_results_filtered.csv`

This document provides high-level summary statistics for the benchmark results.

---

### Overall Performance by Software

| software | success_count | total_experiments | success_rate_% | mean_error | median_error | mean_time_sec |
|----------|---------------|-------------------|----------------|------------|--------------|---------------|
| amigo2_0_10 | 547 | 550 | 99.5 | 0.5007 | 0.0014 | 706.4 |
| amigo2_0_100 | 536 | 550 | 97.5 | 1.8131 | 0.0027 | 737.4 |
| odepe | 548 | 550 | 99.6 | 0.409 | 0.0025 | 527.6 |
| odepe_polish | 545 | 550 | 99.1 | 0.3968 | 0.0011 | 1571.9 |
| sciml | 548 | 550 | 99.6 | 0.1482 | 0.0038 | 222.1 |

**Interpretation**:
- `success_rate_%`: Percentage of experiments that completed successfully
- `mean_error`: Mean relative error (lower is better)
- `median_error`: Median relative error (lower is better, less sensitive to outliers)
- `mean_time_sec`: Average computation time in seconds

---

### Mean Error by System

| name | amigo2_0_10 | amigo2_0_100 | odepe | odepe_polish | sciml |
|------|-------------|--------------|-------|--------------|-------|
| biohydrogenation | 1.7885 | 11.0947 | 0.3805 | 0.3768 | 0.5905 |
| daisy_mamil4 | 0.7204 | 3.4455 | 1.3202 | 1.2384 | 0.2379 |
| crauste | 0.5537 | 1.8285 | 0.9329 | 0.9735 | 0.1663 |
| seir | 0.8596 | 0.8098 | 0.5053 | 0.4968 | 0.1989 |
| hiv | 0.5724 | 1.7802 | 0.204 | 0.2003 | 0.09 |
| lotka_volterra | 0.3502 | 0.8043 | 0.5513 | 0.5478 | 0.1277 |
| daisy_mamil3 | 0.1999 | 0.2274 | 0.4713 | 0.4624 | 0.1073 |
| slowfast | 0.4438 | 0.4529 | 0.0295 | 0.0336 | 0.0359 |
| fitzhugh_nagumo | 0.0458 | 0.03 | 0.0875 | 0.0766 | 0.0701 |
| harmonic | 2.00e-04 | 2.00e-04 | 2.00e-04 | 2.00e-04 | 0.0123 |
| vanderpol | 9.00e-04 | 9.00e-04 | 7.00e-04 | 7.00e-04 | 9.00e-04 |

**Interpretation**:
- Each cell shows mean relative error for that system-software combination
- Systems sorted by difficulty (hardest systems first)
- Lower values indicate better performance

---

### Mean Error by Noise Level

| noise | amigo2_0_10 | amigo2_0_100 | odepe | odepe_polish | sciml |
|-------|-------------|--------------|-------|--------------|-------|
| 0 | 0.2711 | 0.5989 | 1.00e-04 | 1.00e-04 | 0.0785 |
| 1.00e-08 | 0.224 | 0.7552 | 0.0457 | 0.0484 | 0.076 |
| 1.00e-06 | 0.3097 | 3.1078 | 0.3022 | 0.2924 | 0.1064 |
| 1.00e-04 | 0.4005 | 0.8178 | 0.3444 | 0.2926 | 0.1426 |
| 0.01 | 1.3012 | 3.685 | 1.3458 | 1.3577 | 0.3373 |

**Interpretation**:
- Each cell shows mean relative error for that noise level-software combination
- Noise levels: 0.0 (no noise) to 1e-2 (high noise)
- Shows how robust each software is to measurement noise

---

**Files**:
- `overall_performance.csv` - Overall statistics by software
- `performance_by_system.csv` - Mean error by system
- `performance_by_noise.csv` - Mean error by noise level
- `SUMMARY.md` - This document (human-readable version)