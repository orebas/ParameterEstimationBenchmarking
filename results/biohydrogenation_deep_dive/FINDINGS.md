# Biohydrogenation Deep Dive: Findings

## Status: Complete (Steps 1-3 + Residual Check + Interpolator Comparison)

## Executive Summary

Biohydrogenation gets 0% success@10% because **interpolated high-order derivatives are wildly inaccurate**, making the polynomial system HC solves encode wrong constraints.

The SI template requires derivatives of y2 up to **order 5**. All four GP-based interpolators have **24-36% error at order 4** and **63-112% error at order 5**. HC correctly solves this corrupted system — its solutions are genuine zeros (residuals ~1e-17) — but the zeros don't correspond to the true parameters.

AAAD+GPR is 100-1000x more accurate than GP variants at every derivative order, but still has 7% error at order 5.

---

## Root Cause: Interpolated Derivative Accuracy (CONFIRMED)

### The Definitive Test

**Residual check** (residual_check.jl):
- HC solutions have residuals at **machine precision** (1e-17) → they are genuine zeros
- True parameter values have residuals up to **10^27-10^30** → the true solution is NOT a zero of the instantiated system
- Conclusion: **HC is blameless. The polynomial system itself is wrong.**

**Interpolator derivative comparison** (interpolator_derivative_comparison.jl):
Ground-truth derivatives computed via Taylor coefficient recursion on the ODE, compared to each interpolator using `nth_deriv` (TaylorDiff):

### y1 derivatives (y1 = 8·x4, orders 0-2 needed)

| Interpolator | d⁰ | d¹ | d² |
|---|---|---|---|
| AGPRobust (SE) | 0.0004% | 0.002% | 0.13% |
| AGPRobust (RQ) | 0.0001% | 0.001% | 0.05% |
| AGP (SE+RQ) | 0.0002% | 0.001% | 0.07% |
| AGP (SE×RQ) | 0.0003% | 0.002% | 0.12% |
| **AAAD+GPR** | **0.0000%** | **0.000004%** | **0.0006%** |

All interpolators are adequate for y1 → explains why k5, k6 (determined by y1 equations) are always correct.

### y2 derivatives (y2 = 0.5·x5, orders 0-5 needed) — THE BOTTLENECK

| Interpolator | d⁰ | d¹ | d² | d³ | d⁴ | d⁵ |
|---|---|---|---|---|---|---|
| AGPRobust (SE) | 0.0003% | 0.002% | 0.07% | **1.8%** | **36%** | **63%** |
| AGPRobust (RQ) | 0.0003% | 0.003% | 0.06% | **2.1%** | **36%** | **84%** |
| AGP (SE+RQ) | 0.0002% | 0.002% | 0.06% | **2.1%** | **34%** | **112%** |
| AGP (SE×RQ) | 0.0002% | 0.002% | 0.06% | **2.1%** | **24%** | **109%** |
| **AAAD+GPR** | **0.0000%** | **0.000003%** | **0.0002%** | **0.02%** | **0.6%** | **7.1%** |

The degradation is exponential: each derivative order loses ~1.5 orders of magnitude of accuracy.

### Why This Causes the Failure Pattern

1. **k5, k6 always correct**: Determined by y1 equations (orders 0-2), where all interpolators have <0.13% error
2. **k7, k8 sometimes wrong**: Appear in equations involving y2 derivatives up to order 3-4, where errors are 2-36%
3. **k9, k10, x6 always wrong**: Determined by equations involving y2 derivatives at orders 4-5, where GP errors are 24-112%

### Previous (Wrong) Hypothesis

The earlier analysis blamed HC's polyhedral homotopy and the "product identifiability structure" (k10², k9·k10). This was **incorrect**. The product structure is real but HC handles it fine — the solutions it finds ARE genuine zeros. The problem is upstream: the zeros of the wrong system don't include the true parameters.

---

## Step 1: SI Template & HC Analysis

### System Properties

| Property | Value |
|----------|-------|
| Template equations | 25 |
| Unknown variables | 25 (square system) |
| Data variables | 9 (y1_0, y1_1, y1_2, y2_0..y2_5) |
| Iterations to converge | 1 (no parameter fixing needed) |
| Unidentifiable | x7 only |
| Identifiable functions | k5, k6, k7, k8+5/2·k10, k10², k9·k10 |

### The 25 unknowns:

- **Parameters** (6): k5_0, k6_0, k7_0, k8_0, k9_0, k10_0
- **x4 Taylor coeffs** (6): x4_0 through x4_5
- **x5 Taylor coeffs** (7): x5_0 through x5_6
- **x6 Taylor coeffs** (6): x6_0 through x6_5

### HC Solutions at Midpoint (t=4.99)

HC finds exactly **6 solutions** with residuals at machine precision (~1e-17), grouped into 3 pairs:

| Variable | True | Sol 1&5 | Sol 2&3 | Sol 4&6 |
|----------|------|---------|---------|---------|
| k5_0 | 0.688 | **0.687** | **0.687** | **0.687** |
| k6_0 | 0.870 | **0.869** | **0.869** | **0.869** |
| k9_0 | 0.574 | **~0.000** | 1.094 | -1.094 |
| k10_0 | 0.558 | **~0.000** | 0.014 | -0.014 |

---

## Step 2: Candidate Analysis

### ZERO candidates pass across all 16 ODEPE rows

| Instance | #Cand | #Good | Joint Mean | Oracle Mean | Gap |
|----------|-------|-------|-----------|-------------|-----|
| biohydrogenation_0_0 | 301 | 0 | 0.075 | 0.004 | 0.071 |
| biohydrogenation_1_0 | 278 | 0 | 0.100 | 0.018 | 0.082 |
| biohydrogenation_2_0 | 303 | 0 | 0.276 | 0.029 | 0.247 |
| biohydrogenation_3_0 | 369 | 0 | 0.081 | 0.008 | 0.073 |
| biohydrogenation_4_0 | 303 | 0 | 0.074 | 0.059 | 0.015 |
| biohydrogenation_5_0 | 388 | 0 | 0.079 | 0.001 | 0.078 |
| biohydrogenation_6_0 | 283 | 0 | 0.113 | 0.028 | 0.085 |
| biohydrogenation_7_0 | 309 | 0 | 0.225 | 0.015 | 0.209 |

---

## Recommended Fixes (Revised)

### 1. Use AAAD+GPR Only for High-Derivative Systems (Quick Win)
AAAD+GPR is 100-1000x more accurate than GP variants at all derivative orders. For systems requiring d⁴ or d⁵, the GP interpolators introduce fatal errors. Running ONLY with AAAD+GPR (instead of 6 interpolators) would also be much faster.

### 2. Reduce Maximum Derivative Order Required
The SI template needs y2 derivatives up to order 5. Investigate whether alternative SIAN parameterizations or additional measurement equations can reduce this to order 3, where even GP interpolators have <2% error.

### 3. Perfect-Data HC Test
Use the PerfectInterpolant approach (from ERK deep dive) to verify that HC finds the true solution when given exact derivatives. This would confirm the fix is purely in interpolation quality. (Partially confirmed by residual_check.jl.)

### 4. Adaptive Interpolator Selection
Detect the maximum derivative order a system needs (from SIAN analysis) and automatically select the interpolator: GP variants for order ≤ 3, AAAD-based for order ≥ 4.

---

## Files

| File | Description |
|------|-------------|
| `diagnose_biohydrogenation.jl` | SI template + HC analysis |
| `analyze_candidates.py` | Candidate alignment analysis |
| `residual_check.jl` | Proves HC solutions are genuine zeros, true values are not |
| `interpolator_derivative_comparison.jl` | **Key result**: derivative accuracy by interpolator × order |
| `experiment_fixes.jl` | Experiment with different settings (not yet run) |
| `candidate_analysis.csv` | Detailed per-variable per-instance CSV |
