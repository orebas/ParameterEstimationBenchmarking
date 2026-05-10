# CSTR Interpolator Sweep — Full Analysis
**Date:** 2026-03-10
**Runtime:** ~30 minutes (dominated by GP kernel fitting on 1501-point data)

## Executive Summary

**1 out of 39 test cases found the true CSTR root.** Only PerfectInterpolant (exact Taylor polynomial) at t=0 succeeded. Zero real interpolators find the root at any shooting point. The CSTR failure is a two-layer problem: structural (r_eff decay) + interpolation (boundary derivative accuracy).

---

## Setup

- **Model:** CSTR with 3 states (C, Temp, r_eff), 4 params, 1 observable (y1 = 700*Temp)
- **Data:** 1501 points on [0, 20], noise-free, ODE solved at abstol=1e-14
- **Transform:** sin(0.5t) polynomialized via _trfn_ oscillator (adds 2 states, 2 observables)
- **Transformed system:** 5 states, 4 params, 3 measured quantities
- **SIAN results:** `good_deriv_level = Dict(1 => 6, 3 => 1)` (y1 needs order-6 derivatives)
- **Polynomial system:** 26 equations, 26 variables (after _trfn_ substitution)

## Test Points

| Point | Index | Time   | r_eff    | Coupling (r_eff/Temp^2) | Notes |
|-------|-------|--------|----------|-------------------------|-------|
| pt1   | 1     | 0.0000 | 3.84e-1  | ~0.51                   | Domain boundary, only viable point |
| pt2   | 26    | 0.3333 | 2.66e-5  | ~1e-4                   | r_eff nearly gone |
| pt3   | 58    | 0.7600 | 5.57e-7  | ~1e-6                   | r_eff effectively zero |

---

## Full Results Table

### HC Solve Outcomes

| #  | Interpolator            | pt1 t=0.00          | pt2 t=0.33           | pt3 t=0.76           |
|----|-------------------------|---------------------|----------------------|----------------------|
| 1  | **PerfectInterpolant**  | **FOUND** 3sol 2.6e-5 | MISSED 2sol 2.7e+8  | MISSED 1sol 7.5e+5  |
| 2  | aaad                    | MISSED 3sol 2.6e+7  | MISSED 3sol 1.1e+6  | MISSED 1sol 7.5e+5  |
| 3  | aaad_gpr                | NO_SOLS             | MISSED 3sol 2.7e+8  | MISSED 1sol 1.2e+8  |
| 4  | s2_aaa_mle              | MISSED 3sol 5.4e+8  | MISSED 3sol 8.4e+6  | MISSED 1sol 7.5e+5  |
| 5  | agp_robust              | MISSED 5sol 1.5e+8  | MISSED 4sol 2.7e+8  | MISSED 2sol 3.9e+6  |
| 6  | agp_robust_rq           | MISSED 5sol 1.6e+8  | MISSED 4sol 2.2e+8  | MISSED 2sol 4.1e+6  |
| 7  | agp_robust_se+rq        | NO_SOLS             | MISSED 4sol 2.8e+8  | MISSED 2sol 3.9e+6  |
| 8  | agp_robust_se*rq        | MISSED 5sol 1.5e+8  | MISSED 3sol 2.3e+8  | MISSED 2sol 4.1e+6  |
| 9  | s3_se                   | MISSED 4sol 3.0e+9  | MISSED 6sol 2.7e+8  | NO_SOLS              |
| 10 | s3_rq                   | MISSED 4sol 1.6e+9  | MISSED 1sol 5.9e+10 | MISSED 4sol 1.8e+6  |
| 11 | s3_se+rq                | MISSED 4sol 2.0e+9  | MISSED 2sol 2.5e+10 | MISSED 2sol 6.9e+5  |
| 12 | s3_se*rq                | MISSED 4sol 2.1e+9  | MISSED 2sol 4.8e+10 | NO_SOLS              |
| 13 | fhd                     | BUILD FAILED        | BUILD FAILED         | BUILD FAILED         |

### Derivative Accuracy (Max Relative Error)

| #  | Interpolator            | pt1 t=0.00 | pt2 t=0.33 | pt3 t=0.76 |
|----|-------------------------|------------|------------|------------|
| 1  | **PerfectInterpolant**  | **0**      | **0**      | **0**      |
| 2  | aaad                    | 2.62e-3    | 1.73e-6    | 1.27e-9    |
| 3  | aaad_gpr                | 3.40       | 5.22e-2    | 1.01e-1    |
| 4  | s2_aaa_mle              | 6.60e-2    | 2.52e-6    | 6.32e-7    |
| 5  | agp_robust              | 1.32       | 3.55e-1    | 4.85e-1    |
| 6  | agp_robust_rq           | 1.36       | 3.55e-1    | 6.59e-1    |
| 7  | agp_robust_se+rq        | 1.31       | 3.54e-1    | 4.62e-1    |
| 8  | agp_robust_se*rq        | 1.36       | 3.54e-1    | 5.94e-1    |
| 9  | s3_se                   | 8.75e-1    | 3.90e+1    | 3.45e+3    |
| 10 | s3_rq                   | 7.11e-1    | 3.58e+1    | 6.86       |
| 11 | s3_se+rq                | 7.87e-1    | 1.97e+1    | 5.68e-3    |
| 12 | s3_se*rq                | 8.34e-1    | 1.16e+1    | 1.62e+6    |
| 13 | fhd                     | FAIL       | FAIL       | FAIL       |

---

## Key Findings

### Finding 1: Only PerfectInterpolant at t=0 succeeds (1/39)

With exact Taylor polynomial derivatives (zero error), HC.jl finds the true root at t=0 with L2 distance = 2.62e-5. This matches the isolation script result. At t>=0.33, even perfect data fails — the r_eff decay makes the true solution indistinguishable from the spurious r_eff=0 branch.

### Finding 2: Zero real interpolators succeed at any point (0/36)

No production interpolator achieves the derivative accuracy needed for HC.jl to find the true root. The best real interpolator at t=0 is AAAD with derivative error 2.62e-3 — and even that 0.26% error causes the closest HC solution to jump from L2=2.6e-5 (perfect) to L2=2.6e7 (AAAD). This is an **8 orders of magnitude degradation** from a 0.26% perturbation.

### Finding 3: The failure at t>=0.33 is structural and universal

Even PerfectInterpolant with zero derivative error fails at t>=0.33. This confirms the r_eff decay hypothesis from the isolation script. The structural failure is independent of interpolation quality.

### Finding 4: Derivative accuracy tiers at t=0

The interpolators naturally cluster by derivative accuracy at the boundary:

| Tier | Interpolators | Deriv Error at t=0 | HC Outcome |
|------|--------------|-------------------|------------|
| Perfect | PerfectInterpolant | 0 | FOUND |
| Best real | AAAD | 2.6e-3 | MISSED (L2=2.6e7) |
| Medium | S2_AAA_MLE | 6.6e-2 | MISSED (L2=5.4e8) |
| Poor | S3 composites | 0.7-0.9 | MISSED (L2=1.6-3.0e9) |
| Terrible | GP methods | 1.3-3.4 | MISSED/NO_SOLS |

### Finding 5: GP methods are catastrophically bad at boundaries

All AGP_Robust variants have derivative errors >1.0 at t=0, meaning the interpolated 6th derivative of 700*Temp differs from truth by more than 100%. GP regression with SE/RQ/Matern kernels fundamentally cannot extrapolate — and at t=0 (the left boundary of [0, 20]), the interpolant must extrapolate for high-order derivatives.

The AAAD_GPR variant is even worse (error 3.4) because the GPR pivot selection fails with the 1501x1501 covariance matrix (hundreds of PosDefExceptions during fitting).

### Finding 6: S3 composites degrade catastrophically at interior points

S3 methods (GP -> AAA -> MLE pipeline) show relatively moderate errors at t=0 (~0.7-0.9) but explode at interior points:
- s3_se at t=0.76: error = 3,450
- s3_se*rq at t=0.76: error = 1,620,000

The multi-step pipeline amplifies errors through the GP -> AAA -> MLE chain.

### Finding 7: AAAD is the most accurate real interpolator

AAAD (rational AAA interpolation) achieves by far the best derivative accuracy:
- t=0.00: 2.62e-3
- t=0.33: 1.73e-6
- t=0.76: 1.27e-9

The error decreases toward the interior (away from boundary) as expected for rational interpolation. S2_AAA_MLE is second-best with similar interior accuracy but 25x worse at the boundary.

### Finding 8: FHD (Floater-Hormann) fails to build

`InterpolatorFHD` triggers `UndefVarError(:fhd5)` — the `fhd5` function is not available in the current ODEPE build. This is an ODEPE packaging issue, not a script issue.

---

## Sensitivity Analysis: How Accurate Must Derivatives Be?

The only successful case has error = 0. The best failing case has error = 2.62e-3. This gives us:

- **Upper bound on tolerable error:** < 2.62e-3 (and likely much less)
- **The system is exquisitely sensitive** to derivative perturbations because the polynomial system is 26x26 with coefficients spanning many orders of magnitude
- The r_eff variable appears in the system at value ~0.384 (at t=0), and even tiny perturbations push HC.jl toward the spurious r_eff=0 branch which has L2 distance ~1e7 from truth

This suggests that for CSTR-like systems with Arrhenius kinetics, the ODEPE pipeline requires derivative accuracy better than ~1e-4 at the shooting point — a threshold no tested interpolation method achieves at domain boundaries.

---

## Implications for ODEPE

### Why CSTR fails 7/8 at noise=0 in bilby

1. Production pipeline selects shooting point at t~10 (via point_hint=0.5) where r_eff ~ 1e-30
2. Even at t=0 (the only structurally viable point), all real interpolators fail
3. The combination makes CSTR essentially unsolvable by the current pipeline

### Potential Mitigations (from most to least feasible)

1. **Detect and warn about Arrhenius-decay systems** — if r_eff/Temp^2 appears in the ODE and r_eff decays exponentially, flag the system as challenging
2. **Boundary-biased shooting point selection** — for systems with rapid decay, prefer points near t=0
3. **Higher-accuracy boundary derivatives** — develop interpolation methods specifically designed for accurate high-order derivatives at domain boundaries (e.g., one-sided finite differences, boundary-aware GP with derivative observations)
4. **System reformulation** — eliminate r_eff as a separate state by substituting the Arrhenius expression directly, potentially removing the spurious r_eff=0 branch
5. **Regularized HC** — add a penalty term to the polynomial system that biases solutions away from r_eff=0

### Systems likely affected by similar issues

Any ODE system with:
- Arrhenius kinetics (exp(-E/T) terms)
- Variables that decay exponentially to zero
- Stiff dynamics where state variables span many orders of magnitude
- Rational terms (state/state^2) that create spurious zero-denominator branches

---

## Files in This Directory

| File | Description |
|------|-------------|
| `PLAN.md` | Original implementation plan for the sweep |
| `ANALYSIS.md` | This document — full analysis of results |
| `cstr_interpolator_sweep.jl` | The sweep script (814 lines, fixed scoping bug) |
| `cstr_hc_isolation.jl` | Reference: the isolation script that motivated this work |
| `raw_output.log` | Complete stdout/stderr from the sweep run |
