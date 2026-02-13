# Software Performance Analysis

**Dataset**: `../results/september_16_2025_search_bound_100/result.csv`

**Analysis Date**: 2025-11-11

---

## Dataset Overview

- Total experiments: 2750
- Successful results: 1060 (38.5%)
- Software variants: 5
- Systems: 11
- Noise levels: 5

## Key Findings

### 1. Best Overall Performance: **amigo2**

   - Mean error: 1.813059
   - Success count: 536

### 3. ODEPE Multiple Solutions Analysis

   - **odepe**: 0.0% success, nan mean error

### 4. System Difficulty Ranking (by mean error across all software)

   1. **biohydrogenation**: 62.482409
   2. **crauste**: 38.028558
   3. **lotka_volterra**: 34.887112
   4. **vanderpol**: 32.625224
   5. **fitzhugh_nagumo**: 23.357502
   6. **seir**: 13.741199
   7. **daisy_mamil4**: 9.437998
   8. **hiv**: 8.507678
   9. **slowfast**: 2.804154
   10. **harmonic**: 0.234961
   11. **daisy_mamil3**: 0.210373

## Software Performance Comparison

### Overall Statistics by Software

| Software | Total | Success | Success Rate | Mean Error | Median Error | Mean Time (s) |
|----------|-------|---------|--------------|------------|--------------|---------------|
| amigo2          |   550 |     536 |        97.5% |   1.813059 |     0.002736 |        737.38 |
| sciml           |   550 |     524 |        95.3% |  39.071474 |     0.877242 |        280.68 |
| iqm             |   550 |       0 |         0.0% |        nan |          nan |           nan |
| odepe           |   550 |       0 |         0.0% |        nan |          nan |           nan |
| pe              |   550 |       0 |         0.0% |        nan |          nan |           nan |

### Performance by System

**Mean Error by System and Software:**

| System | amigo2 | iqm | odepe | pe | sciml |
|--------|--------|-----|-------|----|-------|
| biohydrogenation | 11.094748 | N/A | N/A | N/A | 112.821342 |
| crauste | 1.828489 | N/A | N/A | N/A | 97.155337 |
| daisy_mamil3 | 0.227360 | N/A | N/A | N/A | 0.193385 |
| daisy_mamil4 | 3.445550 | N/A | N/A | N/A | 14.831201 |
| fitzhugh_nagumo | 0.030036 | N/A | N/A | N/A | 47.161038 |
| harmonic | 0.000234 | N/A | N/A | N/A | 0.469687 |
| hiv | 1.780236 | N/A | N/A | N/A | 14.548646 |
| lotka_volterra | 0.804315 | N/A | N/A | N/A | 69.665476 |
| seir | 0.809760 | N/A | N/A | N/A | 26.672637 |
| slowfast | 0.452875 | N/A | N/A | N/A | 5.203419 |
| vanderpol | 0.000927 | N/A | N/A | N/A | 65.915323 |

### Performance by Noise Level

**Mean Error by Noise Level and Software:**

| Noise | amigo2 | iqm | odepe | pe | sciml |
|-------|--------|-----|-------|----|-------|
| 0.0 | 0.598864 | N/A | N/A | N/A | 37.143826 |
| 1e-08 | 0.755199 | N/A | N/A | N/A | 37.072448 |
| 1e-06 | 3.107790 | N/A | N/A | N/A | 38.987199 |
| 0.0001 | 0.817778 | N/A | N/A | N/A | 39.663135 |
| 0.01 | 3.684989 | N/A | N/A | N/A | 42.551414 |
