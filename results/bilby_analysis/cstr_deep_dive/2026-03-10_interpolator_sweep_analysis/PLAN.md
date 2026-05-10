# Plan: CSTR Interpolator Sweep — Real Interpolator x Shooting Point Matrix

## Context

The `cstr_hc_isolation.jl` script (now complete) proved that:
- **r_eff decays catastrophically fast**: 0.384 at t=0 -> 2.66e-5 at t=0.33 -> ~3.5e-7 at t>=0.76
- **Only t=0 works with perfect data**: HC.jl finds the true root at 1/12 shooting points
- **The production pipeline selects t~10** via `point_hint=0.5`, guaranteeing failure
- The coupling term `r_eff/Temp^2` drops from 0.511 (t=0) to 1e-4 (t=0.33) to 1e-6 (t>=0.76)

**Open question:** Even if we fix point selection to target t=0, will *real* interpolators (AGPRobust, AAAD, FHD, S3, etc.) provide accurate enough derivatives at the boundary for HC.jl to succeed? The bilby benchmark uses 12 interpolators — we need to test each.

## Action: Create `cstr_interpolator_sweep.jl`

### Test Matrix: 13 interpolators x 3 shooting points = 39 test cases

**Interpolators (12 from bilby + PerfectInterpolant baseline):**
1. PerfectInterpolant (exact Taylor -- ceiling/control)
2. InterpolatorAAAD
3. InterpolatorAAADGPR
4. InterpolatorS2AAAMLE
5. InterpolatorAGPRobust
6. InterpolatorAGPRobustRQ
7. InterpolatorAGPRobustSEpRQ
8. InterpolatorAGPRobustSExRQ
9. InterpolatorS3SE
10. InterpolatorS3RQ
11. InterpolatorS3SEpRQ
12. InterpolatorS3SExRQ
13. InterpolatorFHD

**Shooting points (first 3 from warped grid):**
| Point | Index | Time | r_eff | Notes |
|-------|-------|------|-------|-------|
| 1 | 1 | 0.00 | 3.84e-1 | boundary -- only point where perfect data works |
| 2 | 26 | 0.33 | 2.66e-5 | near-boundary -- r_eff already very small |
| 3 | 58 | 0.76 | 5.57e-7 | r_eff ~ 0 -- expected to fail regardless |

### Structure

**STEP 1: Setup (done once)**
- Define CSTR model, generate data_sample (1501 pts, [0,20]), solve ODE (abstol=1e-14)
- Transform PEP for transcendentals (sin(0.5t) -> _trfn_ oscillator)
- Run `setup_identifiability(pep)` -> SIAN analysis (good_deriv_level, varlist, DD)
- Cache SI template via `get_si_equation_system(...)` -- shared across all test cases
- Compute Taylor coefficients at 3 test points via `compute_taylor_coefficients()`
- Compute ground-truth derivatives for comparison baseline

**STEP 2: Interpolator Loop (13 x 3 = 39 test cases)**

For each interpolator:
1. Build interpolants (once per interpolator for real; per-point for PerfectInterpolant)
2. For each of the 3 shooting points:
   a. Derivative accuracy check (max relative error across all observables and orders)
   b. Build polynomial system via `construct_equation_system_from_si_template`
   c. Solve with HC.jl
   d. Compare to truth (L2 distance, found? threshold: 1e-3)

**STEP 3: Summary Tables**
- Table 1: Derivative accuracy (max rel error per interpolator x point)
- Table 2: HC solve results (#solutions, closest L2, FOUND/MISSED)
- Table 3: Threshold analysis (derivative error vs HC success)

**STEP 4: Conclusions**
- How many of 39 test cases find the true root?
- Which interpolators (if any) work at t=0 with real data?
- Is the failure at t>=0.33 universal (structural HC limitation) or interpolation-dependent?
- Does derivative accuracy predict HC success?

### Key Implementation Details

**Interpolant keying:** `create_interpolants` keys by `mq.rhs`. `construct_equation_system_from_si_template` reads via `diff2term(obs.rhs)`. For the CSTR these should match (rhs is a bare state variable). Verify at runtime.

**PerfectInterpolant per-point:** Unlike real interpolators (built once from data), PerfectInterpolants must be rebuilt for each shooting point since they're Taylor polynomials centered at t_eval.

**Error handling:** Wrap each interpolator creation and each (interp, point) test in try/catch.

**Derivative orders needed:** From SIAN analysis: `good_deriv_level = Dict(1 => 6, 3 => 1)`. Observable 1 (y1~700*Temp) needs up to order 6. Observable 3 needs up to order 1.

## Key Functions Used

| Function | Source | Purpose |
|----------|--------|---------|
| `compute_taylor_coefficients(sol, t_eval, p_vals, max_order)` | cstr_hc_isolation.jl | Ground-truth Taylor coefficients |
| `build_true_substitution(vars, p_vals, tc, t_eval)` | cstr_hc_isolation.jl | Map variables to true values |
| `build_perfect_interpolants(tc, t_eval, mq_list, max_order)` | cstr_hc_isolation.jl | Baseline perfect data |
| `get_interpolator_function(method)` | ODEPE estimation_options.jl | Enum -> interpolation function |
| `create_interpolants(mq, data, t_vec, func)` | ODEPE parameter_estimation.jl | Build interpolant dict |
| `interpolator_method_to_symbol(method)` | ODEPE estimation_options.jl | Clean name for tables |
| `construct_equation_system_from_si_template(...)` | ODEPE si_template_integration.jl | Build polynomial system |
| `solve_with_hc(eqs, vars)` | ODEPE homotopy_continuation.jl | Solve with HC.jl |
| `nth_deriv(f, k, t)` | ODEPE derivatives.jl | k-th derivative via TaylorDiff |

## Verification

```bash
julia results/bilby_analysis/cstr_deep_dive/cstr_interpolator_sweep.jl
```

Expected runtime: ~30 minutes (GP methods with 1501 data points dominate)
