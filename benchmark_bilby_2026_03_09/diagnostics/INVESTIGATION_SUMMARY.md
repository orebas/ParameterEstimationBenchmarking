# Multipoint Benchmark Investigation Summary

**Date:** 2026-03-29
**Benchmark:** benchmark_bilby_2026_03_09 (Bilby)
**Context:** Ran new "odepe_multipoint" variant (7 interpolators + multipoint mode, nopolish) against same Bilby data, compared to old "odepe_nopolish" (12 interpolators, no multipoint) and AMIGO2.

---

## 1. Benchmark Results Overview

920 jobs completed, 0 failures. Overall success rates:

| Run | Noise 0 | 1e-8 | 1e-6 | 1e-4 | 1e-2 |
|-----|---------|------|------|------|------|
| **AMIGO2** | 82% | 83% | 79% | 71% | 48% |
| **ODEPE nopolish (old, 12 interps)** | 87% | 76% | 70% | 57% | 26% |
| **ODEPE multipoint (new, 7 interps)** | 78% | 76% | 69% | 61% | 30% |

Multipoint is slightly better at high noise (1e-4, 1e-2) but regressed at noise=0.

Results files: `benchmark_bilby_2026_03_09/analysis_results/software_comparison_*.csv`

---

## 2. Regressions Identified (noise=0)

| System | Multipoint | Old Nopolish | AMIGO2 | Severity |
|--------|-----------|--------------|--------|----------|
| **crauste** | 12.5% (1/8) | 87.5% (7/8) | 75% (6/8) | Severe |
| **cstr** | 0% (0/8) | 25% (2/8) | 100% (8/8) | Moderate (was already mostly broken) |
| **hiv** | 25% (2/8) | 100% (8/8) | 100% (8/8) | Severe |
| **brusselator** | 50% (4/8) | 87.5% (7/8) | 50% (4/8) | Moderate |

---

## 3. Root Cause: Interpolator Selection, NOT Multipoint Algorithm

### Key finding
The multipoint code runs single-point estimation first, then adds multipoint solutions to the pool. Single-point always runs. Therefore multipoint can only ADD solutions, never remove them. The regression is caused entirely by the change from 12 to 7 interpolators.

### A/B test results (crauste instance 0)

| Variant | Interpolators | Multipoint | Result | Solutions |
|---------|--------------|------------|--------|-----------|
| A (control) | Old 12 | off | **PASS** (0.0000) | 27 |
| B | Old 12 | on | **PASS** (0.0000) | 40 |
| C | New 7 | off | **FAIL** (0.6230) | 7 |
| D | New 7 | on | **FAIL** (0.5953) | 10 |

**Verdict:** Old 12 interpolators pass regardless of multipoint. New 7 fail regardless. The regression is 100% interpolator selection.

A/B test script: `benchmark_bilby_2026_03_09/diagnostics/ab_test_crauste.jl`
SLURM output: `output/ab_crauste_50338.out`

### Interpolator change between old and new

**Kept (3):** InterpolatorAAADGPR, InterpolatorAGPRobust, InterpolatorAGPRobustSExRQ
**Dropped (9):** InterpolatorAAAD, InterpolatorS2AAAMLE, InterpolatorAGPRobustRQ, InterpolatorAGPRobustSEpRQ, InterpolatorS3SE, InterpolatorS3RQ, InterpolatorS3SEpRQ, InterpolatorS3SExRQ, InterpolatorFHD
**Added (4):** InterpolatorS3AdaptSE, InterpolatorChebyshevBIC, InterpolatorS3AdaptSExRQ, InterpolatorChebyshevAICc

---

## 4. The Hero Interpolators (crauste)

Individual interpolator testing on crauste instance 0 identified exactly which interpolators find good solutions:

| Interpolator | Type | Sols | MaxRelErr | Pass? |
|---|---|---|---|---|
| **InterpolatorAAAD** | AAA rational | 6 | 0.0014 | **PASS** |
| **InterpolatorS2AAAMLE** | AAA→MLE | 6 | 0.00003 | **PASS** |
| InterpolatorAGPRobustRQ | GP (RQ) | 1 | 10.22 | FAIL |
| InterpolatorAGPRobustSEpRQ | GP (SE+RQ) | 2 | 0.73 | FAIL |
| InterpolatorS3SE | GP→AAA→MLE | 1 | 0.62 | FAIL |
| InterpolatorS3RQ | GP→AAA→MLE | 1 | 4.03 | FAIL |
| InterpolatorS3SEpRQ | GP→AAA→MLE | 2 | 0.37 | FAIL |
| InterpolatorS3SExRQ | GP→AAA→MLE | 2 | 3.73 | FAIL |
| InterpolatorFHD | Floater-Hormann | 2 | 0.60 | FAIL |

**Only the two pure AAA rational interpolators pass.** Everything GP-based (including S3 composites that use GP internally) fails. Both dropped AAA interpolators were critical for crauste.

Script: `benchmark_bilby_2026_03_09/diagnostics/interpolator_hunt_crauste.jl`
SLURM output: `output/hunt_crauste_50349.out`

---

## 5. Why: Sensitivity Analysis (from ODEPE diagnostics)

### Diagnostics ran on crauste instance 0, noise=0

**Difficulty classification:** moderate
**Bottleneck:** Jacobian conditioning (κ = 9.43×10⁹)
**Polynomial system:** 39 equations × 39 variables, 2 solutions (mixed volume = 2)

Key diagnostic files:
- `benchmark_bilby_2026_03_09/diagnostics/artifacts/diagnostics/crauste_0/report.html`
- `benchmark_bilby_2026_03_09/diagnostics/artifacts/diagnostics/crauste_0/summary.txt`

### The failing parameter: L (latent immune cell population)

Every single failing solution across all interpolators has **L** as the worst parameter. The UQ prediction from the diagnostics:

- **L₀**: true value = 0.275, predicted ±1σ = ±25.5, **CV = 92.5%** → essentially unresolvable
- **mu_LE**: true value = 0.581, predicted ±1σ = ±1.56, **CV = 269%** → also unresolvable
- **mu_PE**: true value = 0.188, predicted ±1σ = ±2.66, **CV = 1410%** → worst absolute sensitivity

### Sensitivity flows through y4 (= 2·P)

All high-sensitivity variables trace to **y4″** (second derivative of the P observable):

| Unknown | Max |S| | Most sensitive to |
|---------|---------|------------------|
| mu_PE | 221,000 | y4″ |
| L₀ | 7,780 | y4″ |
| M₀ | 7,780 | y4″ |
| rho_P | 5,610 | y4″ |
| mu_LE | 1,890 | y4″ |

L appears in the P equation with coefficient `0.00036*mu_PL*L` — an extremely weak coupling. The polynomial system needs high-order derivatives of y4 to extract L, amplifying any interpolation error by ~7,780×.

### Why AAA works and GP doesn't

- **Derivative accuracy is NOT the differentiator** — all interpolators achieve < 1.3e-8 relative error on derivatives up to order 4 (the diagnostic-tested range).
- The single-point SI template requires derivatives up to **order 6**.
- At κ = 9.43×10⁹, a ~10⁻⁸ coefficient difference in the polynomial system shifts the L solution by ~10⁻⁸ × 10¹⁰ ≈ 100.
- AAA rational interpolators produce enough numerical variation across the 12 shooting points that some HC solutions land near the true L. GP interpolators produce "smoother" coefficients that consistently push L to the wrong basin.
- The old nopolish run found **21 solutions** from 12 interpolators (11 with L within 10%). The multipoint run found only **7 solutions** from 7 interpolators (0 with L within 10%).

### CSTR diagnostics

Also ran diagnostics on CSTR (0% multipoint vs 25% old nopolish):

- **Difficulty:** hard
- **Jacobian κ = 8.44×10¹⁷** (catastrophically ill-conditioned)
- **Effective rank:** 24/26 (rank deficient)
- Even with **perfect data**, closest HC solution is 746,000 units from truth
- This system is structurally broken for the polynomial approach — not an interpolator issue

Diagnostic files: `benchmark_bilby_2026_03_09/diagnostics/artifacts/diagnostics/cstr_0_polynomialized/`

---

## 6. Immediate Fix

Add `InterpolatorAAAD` and `InterpolatorS2AAAMLE` back to the multipoint interpolator list in `templates/julia_template_for_estimation_odepe_multipoint.jl`. These are also the two fastest interpolators (~3 min vs 8-15 min for GP-based), so it's essentially free runtime cost.

Current 7 → proposed 9:
```julia
interpolators = [
    InterpolatorAGPRobust,        # AGP-Robust-SE
    InterpolatorS3AdaptSE,        # S3-Adapt-SE (new)
    InterpolatorChebyshevBIC,     # Chebyshev-BIC (new spectral)
    InterpolatorS3AdaptSExRQ,     # S3-Adapt-SExRQ (new)
    InterpolatorAGPRobustSExRQ,   # AGP-Robust-SExRQ
    InterpolatorChebyshevAICc,    # Chebyshev-AICc (new spectral)
    InterpolatorAAADGPR,          # AAAD-GPR-Pivot
    InterpolatorAAAD,             # AAA rational (restored)
    InterpolatorS2AAAMLE,         # AAA→MLE (restored)
]
```

---

## 7. Open Questions / Follow-up Work

### 7a. Multipoint derivative order reduction (HIGH PRIORITY)

The core thesis of multipoint is that by using N time points, the system needs **lower-order derivatives** per point, which should be estimated more accurately. We have NOT yet verified:

1. **What derivative orders does single-point actually use?** The SI template says max order 6 for crauste. We need the exact list of which derivatives of which observables appear as data variables in the 39-variable polynomial system.

2. **What derivative orders does multipoint (n_points=2) use?** In theory it should roughly halve the max order needed. The multipoint template takes the single-point equations, duplicates them at 2 time points, then rank-strips from the top (removing highest-order equations first). We need to know what the stripped system actually looks like.

3. **Derivative estimation error at orders 5-6.** The diagnostics only tested through order 4 (where all errors are < 1.3e-8). But the polynomial system needs order 6. If errors grow rapidly at orders 5-6, that's where the sensitivity amplification really bites. Need to extend `diagnose_derivative_accuracy()` to test through the actual max required order.

4. **Does multipoint actually reduce max derivative order for crauste?** If the rank-stripping removes the order-6 equations when 2 points are used, then multipoint's polynomial system might only need order 3-4, which could reduce L's sensitivity. But this needs verification.

**Suggested diagnostics enhancement:** Add a function that, given a PEP and estimation options, reports:
- The list of data variables in the polynomial system (observable name, derivative order) for both single-point and multipoint
- The derivative estimation error at each of those specific orders for a given interpolator
- The predicted parameter displacement = S[i,j] × derivative_error[j] for each (parameter, data variable) pair

### 7b. Per-interpolator sensitivity analysis

Currently the diagnostics compute sensitivity for one (interpolator, time point) combination. For the regression analysis, we'd want to see:
- The actual polynomial coefficient values for AAAD vs AGPRobust at the same shooting point
- Which specific coefficient difference drives L to the wrong basin
- Whether this is deterministic or stochastic (GP kernel optimization has randomness)

### 7c. Broader interpolator diversity strategy

The finding that "more different interpolators = more chances to find good solutions" suggests that the interpolator list should maximize **diversity** of numerical behavior, not just accuracy. Possible strategies:
- Always include at least one pure rational (AAAD/S2AAAMLE) and at least one GP-based
- Use the sensitivity matrix to predict which systems need interpolator diversity
- For systems with κ > 10⁸, automatically expand the interpolator list

### 7d. HIV and brusselator investigation

We haven't done the deep dive on hiv (25% → 100% regression) or brusselator (50% → 87.5%). The same interpolator-selection mechanism likely applies but needs confirmation. HIV has 10 parameters and κ is likely very high.

---

## 8. Files and Artifacts

### Scripts created
- `benchmark_bilby_2026_03_09/diagnostics/ab_test_crauste.jl` — A/B test (4 variants × 3 instances)
- `benchmark_bilby_2026_03_09/diagnostics/interpolator_hunt_crauste.jl` — Individual interpolator identification
- `benchmark_bilby_2026_03_09/diagnostics/diagnose_crauste.jl` — Diagnostics framework run
- `benchmark_bilby_2026_03_09/diagnostics/diagnose_cstr.jl` — CSTR diagnostics

### SLURM jobs
- 49285: Main multipoint benchmark (920 jobs, all COMPLETED)
- 50338: A/B test (COMPLETED at 6h wall limit, got through instance 0 fully + instance 1 partial)
- 50349: Interpolator hunt (COMPLETED, all 9 individual tests done)
- 50336: Crauste diagnostics (reports generated, display code crashed — artifacts saved)
- 50337: CSTR diagnostics (same — artifacts saved)

### Diagnostic artifacts
- `benchmark_bilby_2026_03_09/diagnostics/artifacts/diagnostics/crauste_0/report.html` — Full HTML diagnostic report
- `benchmark_bilby_2026_03_09/diagnostics/artifacts/diagnostics/crauste_0/summary.txt` — Text summary
- `benchmark_bilby_2026_03_09/diagnostics/artifacts/diagnostics/cstr_0_polynomialized/report.html`
- `benchmark_bilby_2026_03_09/diagnostics/artifacts/diagnostics/cstr_0_polynomialized/summary.txt`

### Pipeline changes made
- `environments/ODEParameterEstimation/` — Updated to commit ecfa4df (17 new commits)
- `templates/julia_template_for_estimation_odepe_multipoint.jl` — New template (7 interpolators + multipoint)
- `src/shared.py` — Added 'odepe_multipoint' to AVAILABLE_SOFTWARE + JULIA_ENVIRONMENTS
- `src/generate_scripts.py` — Added 'odepe_multipoint' to all dispatch tables
- `hpc/array_job_odepe.s` — Fixed path from `no-matlab-no-worry/` to `ParameterEstimationBenchmarking/`
