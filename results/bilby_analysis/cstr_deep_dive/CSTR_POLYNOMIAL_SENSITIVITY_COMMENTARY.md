# CSTR Polynomial Sensitivity Analysis — Detailed Commentary

## Executive Summary

This analysis investigates **why a 0.26% interpolation error causes 8 orders of magnitude
degradation** in the CSTR benchmark's parameter estimation quality. The CSTR (Continuously
Stirred Tank Reactor) model uses a single observable (`y1 = 700 * Temp`) to reconstruct
4 ODE parameters, 5 state variables, and auxiliary transcendental function states — producing
a 26-equation polynomial system that is solved via homotopy continuation (HC.jl).

**Bottom line**: The polynomial system's roots lie on a near-singular stratum (Jacobian
condition number = 3.79×10¹⁹, effective rank 18/26). AAAD interpolation errors in
high-order derivatives (up to order 6) produce coefficient perturbations of magnitude
|Δ| ≈ 10⁴–10⁵. The root displacement scales linearly with the perturbation:
‖δx‖ ≈ 2.6×10⁷ × α, where α is the perturbation fraction.

This is **not** a solver failure. HC.jl correctly finds the roots of each system it is given.
The problem is that the perturbed system has roots that are genuinely far from the true
ODE parameters.

---

## Table of Contents

1. [Background: The CSTR Model](#1-background)
2. [The Polynomial System](#2-polynomial-system)
3. [Step-by-Step Analysis](#3-step-by-step)
4. [Key Findings](#4-key-findings)
5. [Parameter Homotopy Failure](#5-parameter-homotopy)
6. [Scaling Experiments](#6-scaling)
7. [Root Cause Diagnosis](#7-root-cause)
8. [Implications for ODEPE](#8-implications)
9. [Possible Mitigations](#9-mitigations)
10. [Reproducing Results](#10-reproducing)

---

## 1. Background: The CSTR Model <a name="1-background"></a>

The CSTR model describes a continuously stirred tank reactor with Arrhenius kinetics:

```
dC/dt    = (1/τ)(1 - C) - r_eff
dTemp/dt = (1/τ)(Tin - Temp) + dH_rhoCP * r_eff - UA_VrhoCP * (Temp - Tin) * sin(0.5t)
```

where `r_eff = C * exp(25 * (1 - 1/Temp))` is the reaction rate (Arrhenius).

**Key features making this model difficult:**
- **Single observable**: `y1 = 700 * Temp` — all information comes from one measurement
- **Transcendental forcing**: `sin(0.5t)` must be polynomialized via auxiliary state variables
  (`_trfn_sin_0_5`, `_trfn_cos_0_5`) satisfying their own ODEs
- **Arrhenius kinetics**: The exponential is polynomialized through the SIAN analysis,
  introducing `r_eff` as an auxiliary algebraic variable at each derivative order
- **4 unknown parameters**: `τ, Tin, dH_rhoCP, UA_VrhoCP`

The SIAN (Structural Identifiability ANalyzer) analysis determines that derivative orders
0 through 7 of the observable are needed to construct a square polynomial system, leading
to auxiliary variables at orders 0–7 for some quantities.

## 2. The Polynomial System <a name="2-polynomial-system"></a>

After SIAN analysis and polynomial system construction, we get:

| Property | Value |
|----------|-------|
| Equations | 26 |
| Variables | 26 |
| Maximum degree | 5 |
| Bézout bound | 1.87 × 10¹¹ |
| Mixed volume | ~7–8 (the actual number of paths tracked) |

The 26 variables include:
- 4 parameters: `τ_0, Tin_0, dH_rhoCP_0, UA_VrhoCP_0`
- State values: `C_0, ..., C_6` and `Temp_0, ..., Temp_7`
- Transcendental auxiliaries: `_trfn_sin_0_5_0, ..., _trfn_sin_0_5_6` and `_trfn_cos_0_5_0, ..., _trfn_cos_0_5_5`
- Reaction rate auxiliaries: `r_eff_0, ..., r_eff_6`

**The enormous gap between Bézout bound (10¹¹) and mixed volume (~8)** means the system
is extremely sparse — most variable combinations never appear together. The polyhedral
homotopy exploits this sparsity to track only ~8 paths instead of 10¹¹.

### Variable magnitude range

The true solution spans a huge dynamic range:

| Variable | Magnitude | Example |
|----------|-----------|---------|
| `C_0` | 0.127 | Concentration (dimensionless) |
| `Temp_0` | 0.878 | Temperature (dimensionless) |
| `r_eff_0` | 0.0216 | Reaction rate |
| `r_eff_6` | 5.91 × 10⁸ | 6th derivative of reaction rate |

The ratio of largest to smallest variable magnitude is **4.66 × 10⁹** — this is one
of the root causes of the conditioning problems.

## 3. Step-by-Step Analysis <a name="3-step-by-step"></a>

### Step 1: Setup

The script builds the CSTR model using ModelingToolkit, solves the ODE with known parameters,
creates a `ParameterEstimationProblem`, and runs SIAN identifiability analysis. This step
caches the SI (Structural Identifiability) template, which defines the polynomial structure
that is reused for all interpolators and time points.

### Step 2: Building 4 Polynomial Systems

Four systems are constructed by combining two interpolation methods with two time points:

| Label | Interpolator | Time Point | Purpose |
|-------|-------------|------------|---------|
| SYS1 | PerfectInterpolant | t=0 | Baseline (exact derivatives from Taylor series) |
| SYS2 | PerfectInterpolant | t=0.33 | Time-point sensitivity check |
| SYS3 | AAAD | t=0 | Real-world interpolation (the one that fails) |
| SYS4 | AAAD | t=0.33 | Real-world at different time point |

**PerfectInterpolant** uses recursive Taylor coefficient computation from the ODE itself
to produce exact polynomial representations of all derivatives. It introduces zero
interpolation error — the only error source is floating-point arithmetic.

**AAAD** (Adaptive AAA with Degree-based selection) is the real-world rational interpolant
used in the ODEPE pipeline. It fits rational functions to the ODE solution data, then
evaluates derivatives of those rational functions.

### Step 3: System Structure

All four systems have identical structure (26 eqs, degree 5, Bézout 1.87×10¹¹) because
the polynomial template comes from SIAN — only the constant coefficients differ between
interpolators.

The sparsity analysis reveals that most equations involve only 2–5 of the 26 variables,
except for the highest-derivative equations (involving `r_eff_5, r_eff_6, Temp_7`) which
touch 7+ variables due to the recursive derivative chain.

### Step 4: Coefficient Comparison

Comparing SYS1 (Perfect) vs SYS3 (AAAD) equation by equation:

| Metric | Value |
|--------|-------|
| Max |Δ| across all equations | 4.37 × 10⁴ – 1.46 × 10⁵ (varies by run/seed) |
| Mean |Δ| | 1.69 × 10³ – 5.63 × 10³ |
| Equations with |Δ| > 10⁻⁶ | 5 of 26 |

**Only 5 equations differ** — the ones involving high-order derivative evaluations.
The other 21 equations are structural (ODE relationships, trigonometric identities)
and are identical between Perfect and AAAD.

The perturbation grows geometrically with derivative order:
- Order 0–2: |Δ| < 10⁻⁸ (effectively zero)
- Order 3–4: |Δ| ~ 10⁻³ to 10⁰
- Order 5–6: |Δ| ~ 10² to 10⁵

This geometric growth (~100–300× per order) is inherent to numerical differentiation:
errors in the k-th derivative of a rational interpolant scale roughly as k! × (error in
function values) / (step size)^k.

### Step 5: Jacobian Conditioning

The Jacobian of the polynomial system, evaluated at the true solution:

| Metric | SYS1 (Perfect) | SYS3 (AAAD) |
|--------|----------------|--------------|
| cond(J) | 3.79 × 10¹⁹ | 3.79 × 10¹⁹ |
| Effective rank (σᵢ > 10⁻¹⁰ σ₁) | 18 / 26 | 18 / 26 |
| σ_max | ~10¹⁵ | ~10¹⁵ |
| σ_min | ~10⁻⁵ | ~10⁻⁵ |

**Both systems have identical conditioning at the true point** because the Jacobian depends
on the polynomial structure (shared from the SI template) and the point of evaluation
(the true parameter values), not on the constant coefficients.

The 8 near-zero singular values (rank deficiency of 8) indicate that the true solution
sits on or very near a singular stratum of the polynomial system. This is a property
of the mathematical structure, not a numerical artifact.

**Amplification bound**: cond(J) × max|Δ| = 3.79×10¹⁹ × 1.46×10⁵ = 5.53×10²⁴.
This is a loose upper bound; the observed error (2.6×10⁷) is much smaller, which
is expected since the condition number gives the worst-case amplification.

### Step 6: Linear Variable Elimination

Of the 26 variables, 17 can be eliminated by solving linear equations (degree 1 in that
variable). After iterative Gaussian-style elimination:

| Pass | Variables eliminated |
|------|---------------------|
| 1 | Tin_0, C_0, C_1, dH_rhoCP_0, _trfn_sin_0_5_0, _trfn_cos_0_5_0, Temp_1, Temp_2, r_eff_1, tau_0, Temp_3, C_3, Temp_4, Temp_5, Temp_6 |
| 2 | C_2, r_eff_2, r_eff_4 |
| 3 | UA_VrhoCP_0, r_eff_3, C_4 |
| 4 | r_eff_5 |
| 5+ | C_5, C_6, r_eff_6, Temp_7 |

Final: **9 equations in ~3-9 variables** (the deeply substituted expressions reference
additional variables in their expression trees).

However, solving this reduced system with HC.jl fails because:
1. `Symbolics.expand()` on the substituted expressions is astronomically expensive
   (the expressions have degree ~17 with nested substitution chains)
2. The string-based `convert_to_hc_format` encounters "phantom" variables (`Tin_0`)
   that were eliminated symbolically but still appear in expression subterms

### Step 6b: Diagonal Scaling (Row + Column Equilibration)

Column scaling (substitute xᵢ → |x_true_i| × x̃ᵢ) normalizes all variables to O(1).
Row scaling (divide each equation by its Jacobian row norm) equalizes equation magnitudes.

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| cond(J) | 3.79 × 10¹⁹ | 5.50 × 10⁸ | 69 billion × |
| Effective rank | 18 / 26 | **26 / 26** | Full rank restored |
| Variable range | [0.127, 5.91×10⁸] | [1.0, 1.0] | Uniform |

**HC.jl on scaled SYS1 (Perfect): FOUND** — all 5 seeds find the root.
**HC.jl on scaled SYS3 (AAAD): MISSED** — all 5 seeds miss.

The scaling dramatically improves local conditioning but does not help the AAAD case
because the coefficient perturbation has already moved the roots far from truth.

### Step 7: HC.jl Diagnostics

Detailed path-tracking analysis for SYS1 and SYS3:

**SYS1 (Perfect)**: 7 total paths tracked (polyhedral homotopy), 3 real solutions.
The closest real solution is within 2.62×10⁻⁵ of truth [FOUND]. Multiple seeds
consistently find the root.

**SYS3 (AAAD)**: 6–7 total paths tracked, 3–4 real solutions. The closest is
2.61×10⁷ from truth [MISSED]. This is the **same solution** across all seeds —
HC.jl reliably finds the (wrong) root of the perturbed system.

### Step 8: α-Sweep (Unscaled)

Interpolating between systems: `F_α = (1-α)·F_perfect + α·F_aaad`:

| α | Max Residual | #Real | Closest L2 | Found? |
|---|-------------|-------|-----------|--------|
| 0.0 | 1.33×10⁻⁸ | 3 | 2.62×10⁻⁵ | YES |
| 10⁻⁵ | 1.46×10⁰ | 3 | 2.61×10² | no |
| 10⁻⁴ | 1.46×10¹ | 3 | 2.61×10³ | no |
| 10⁻³ | 1.46×10² | 3 | 2.61×10⁴ | no |
| 0.01 | 1.46×10³ | 3 | 2.61×10⁵ | no |
| 0.1 | 1.46×10⁴ | 3 | 2.61×10⁶ | no |
| 1.0 | 1.46×10⁵ | 3 | 2.61×10⁷ | no |

**Critical α**: between 0 and 10⁻⁵ (the root is lost with even 0.001% perturbation).

**Key observation**: Closest L2 is perfectly linear in α. The ratio L2/α ≈ 2.6×10⁷
is constant across 5 orders of magnitude. This is the signature of a smooth,
continuous root displacement — NOT a topological bifurcation.

### Step 8b: α-Sweep (Scaled)

Same sweep but with row+column equilibration applied:

| α | Max Residual | #Real | Closest L2 | Found? |
|---|-------------|-------|-----------|--------|
| 0.0 | 2.58×10⁻¹² | 4 | 1.22×10⁻⁴ | YES |
| 10⁻⁶ | 2.08×10⁻⁴ | 4 | 2.61×10¹ | no |
| 10⁻⁵ | 2.08×10⁻³ | 4 | 2.61×10² | no |
| 10⁻³ | 2.08×10⁻¹ | 4 | 2.61×10⁴ | no |
| 1.0 | 2.08×10² | 4 | 2.61×10⁷ | no |

**Scaling does not shift the critical α**. The L2 displacement is identical (within
rounding) to the unscaled case. This definitively proves that the failure is not
a conditioning artifact — the polynomial roots genuinely move with the coefficients.

### Step 9: Parameter Homotopy

Attempted to track the true solution continuously from α=0 to α=1 using HC.jl's
parameter homotopy feature. Result:

**All 7 paths: `terminated_invalid_startvalue_singular_jacobian`**

HC.jl's parameter homotopy tracker requires non-singular start solutions. With
cond(J) = 3.79×10¹⁹ and effective rank 18/26, the start solutions (at α=0) have
numerically singular Jacobians, and the tracker refuses to start.

This is why polyhedral homotopy works (it starts from a generic system where ALL
Jacobians are well-conditioned) while parameter homotopy fails (it must start from
the actual, near-singular solutions).

Even raising `terminate_cond` to 10³⁰ and enabling `extended_precision` did not
help — the tracker's `invalid_startvalue` check is fundamental, not a threshold issue.

## 4. Key Findings <a name="4-key-findings"></a>

### Finding 1: The failure is pure coefficient sensitivity, not a solver bug

HC.jl correctly solves every system it is given. The AAAD system has roots that are
genuinely 2.6×10⁷ L2 distance from the true parameters. This is the correct answer
to the wrong question.

### Finding 2: Root displacement is linear in perturbation magnitude

‖δx‖ ≈ 2.6×10⁷ × α across 5 orders of magnitude. No bifurcation, no path crossing,
no topological change. The root slides smoothly and continuously.

### Finding 3: The system is near-singular at its roots

The Jacobian has condition number 3.79×10¹⁹ and effective rank 18/26 — regardless
of which interpolator produced the coefficients. This is a structural property of
the CSTR's polynomial system.

### Finding 4: Scaling improves conditioning but not accuracy

Row+column equilibration reduces cond(J) by 69 billion× and restores full rank.
But it doesn't change where the roots are — the perturbed system's roots are still
far from truth.

### Finding 5: Parameter homotopy cannot work on this system

The near-singular Jacobian at the solutions prevents HC.jl's parameter tracker
from even starting. This means "track from a known good solution" is not viable
without first regularizing the system.

## 5. Parameter Homotopy Failure <a name="5-parameter-homotopy"></a>

The parameter homotopy experiment is particularly instructive. The idea was:
1. Start from the known true solution at α=0 (Perfect system)
2. Continuously deform the coefficients to α=1 (AAAD system)
3. Watch the root move, confirming the linear displacement hypothesis

But HC.jl rejected all 7 start solutions with `terminated_invalid_startvalue_singular_jacobian`.

**Why polyhedral homotopy succeeds where parameter homotopy fails:**

In polyhedral homotopy, paths start from a randomly-constructed "start system" whose
solutions are generically non-singular. The paths are tracked through complex space
where the Jacobian is well-conditioned along most of the path. Only at the endpoint
(t→0) does the path approach the near-singular target system. HC.jl's endgame
algorithm handles this transition using Cauchy integration and extended precision.

In parameter homotopy, we START at the near-singular point (which is the endpoint of
the polyhedral homotopy). The tracker needs a reliable tangent direction to begin
stepping, but the singular Jacobian provides no reliable direction.

This explains why the ODEPE pipeline cannot use parameter homotopy to "warm-start"
from one time point's solution to another — the solutions are too close to singular.

## 6. Scaling Experiments <a name="6-scaling"></a>

### Why scaling doesn't help (even though it should)

The scaling experiment reveals a subtle but important distinction:

**Scaling helps the SOLVER** (HC.jl finds the Perfect root more reliably after scaling)
but **does not help the PROBLEM** (the AAAD root is still far from truth).

This is because scaling is a change of variables: x̃ᵢ = xᵢ/sᵢ. It transforms the
system `F(x) = 0` into `F̃(x̃) = 0` where the Jacobian J̃ = D_r J D_c is better
conditioned. But the ROOTS are related by x = D_c x̃ — they're the SAME roots in
different coordinates.

The perturbation Δ from AAAD affects the polynomial COEFFICIENTS, not the variables.
Scaling changes variable representation but not coefficient values. Therefore scaling
cannot reduce the coefficient perturbation, and the root displacement remains the same.

### What would scaling help?

If the failure were due to the solver (HC.jl) losing a path during tracking because
of poor conditioning along the path, then scaling could help by improving the Jacobian
condition along the path. Indeed, for SYS1 (Perfect), scaled solving is more robust
(4 real solutions found vs 3 unscaled, and ALL seeds succeed).

But for AAAD, the root that HC.jl needs to find simply isn't there — the perturbed
system doesn't have a root near the truth.

## 7. Root Cause Diagnosis <a name="7-root-cause"></a>

### The sensitivity chain

```
AAAD interpolation error in function values
    ↓  (×k! / hᵏ amplification per derivative order)
Error in k-th derivative, growing geometrically ~100-300× per order
    ↓  (k=0 to 6 needed)
Coefficient perturbation |Δ| ≈ 10⁴ – 10⁵ in 5 of 26 equations
    ↓  (inverse Jacobian amplification)
Root displacement ‖δx‖ ≈ ‖J⁻¹‖ × ‖Δ‖ ≈ 10⁴ × 10⁵ ≈ 10⁷ – 10⁹
    ↓  (observed)
L2 error ≈ 2.6 × 10⁷
```

The effective sensitivity ‖δx/δα‖ ≈ 2.6×10⁷ is consistent with:
- ‖J⁻¹‖ ≈ 1/σ_min ≈ 10⁵ (from σ_min ≈ 10⁻⁵)
- ‖Δ‖ at α=1 ≈ 10⁵

So the actual amplification is ||J⁻¹|| × ||Δ||, which is much tighter than the
loose bound cond(J) × ||Δ|| ≈ 10²⁴.

### Why the CSTR is uniquely bad

Other benchmark models (Lotka-Volterra, SEIR, etc.) also have interpolation errors,
but they don't exhibit this catastrophic sensitivity because:

1. **Multiple observables** — more measurements → lower derivative orders needed →
   smaller interpolation errors
2. **Lower maximum derivative order** — CSTR needs up to order 7 (for Temp) and
   order 6 (for auxiliary variables), while simpler models need order 2-3
3. **Better-conditioned Jacobians** — systems with multiple observables tend to have
   more balanced equation structures
4. **No transcendental forcing** — the sin(0.5t) polynomialization adds 12 extra
   variables and equations, inflating the system from ~14×14 to 26×26

## 8. Implications for ODEPE <a name="8-implications"></a>

### What this means for the pipeline

1. **CSTR failures are expected and unavoidable with current interpolation accuracy.**
   The AAAD interpolant's derivative errors at order 6+ are inherently too large
   for this system's sensitivity.

2. **The solver (HC.jl) is working correctly.** No bug, no missed path, no numerical
   failure. It finds the right roots of the wrong system.

3. **Preconditioning cannot help.** Scaling, equilibration, variable transformation —
   none of these change the polynomial's roots. The problem is in the coefficients.

4. **Parameter homotopy warm-starting won't work** for systems with near-singular
   Jacobians at the solutions. The tracker can't start from these points.

5. **The 7/8 failure rate at noise=0** (from bilby benchmarks) is consistent with
   this analysis: different time points (different shooting points) produce slightly
   different polynomial systems, and most of them have the same sensitivity issue.

### What works

- **PerfectInterpolant**: Works because it computes exact Taylor coefficients from
  the ODE, introducing only floating-point errors (~10⁻⁸ vs ~10⁵ for AAAD)
- **Low derivative orders**: If the SIAN analysis could use fewer derivative orders,
  the interpolation error would be much smaller

## 9. Possible Mitigations <a name="9-mitigations"></a>

### A. Improve interpolation accuracy at high derivative orders

The most direct fix. Options:
- Use higher-degree rational interpolants in AAAD
- Use more data points in the interpolation window
- Use specialized high-derivative interpolation methods (Hermite interpolation with
  known lower-order derivatives)
- Use the ODE itself to constrain derivative consistency (e.g., compute d⁶y/dt⁶
  from lower derivatives using the ODE structure)

### B. Reduce the required derivative order

If the SIAN analysis could produce identifiability equations using derivatives only
up to order 3-4 instead of 6-7, the interpolation error would drop by factors of
10⁴–10⁶ (enough to cross the critical threshold).

Options:
- Add a second observable (if physically available)
- Use multi-experiment data (different initial conditions)
- Use a modified SIAN strategy that trades equation count for derivative order

### C. Parameter homotopy with regularization

Since standard parameter homotopy fails (singular start values), one could:
- Add a small regularization term εI to the Jacobian during tracking
- Use a "nearby" non-singular start solution from a slightly perturbed system
- Use monodromy-based methods that avoid the singular stratum

### D. Hybrid approach

1. Solve the Perfect system (which works) at each time point
2. Use those solutions as initial guesses for Newton's method on the AAAD system
3. Newton's method may converge if the basin of attraction is large enough

This bypasses HC.jl entirely for the AAAD case, using it only for the tractable
Perfect case.

### E. Accept and characterize the limitation

For benchmark purposes, document that single-observable systems with high-order
derivative requirements (like CSTR with Arrhenius kinetics) represent a fundamental
difficulty for polynomial-system-based parameter estimation, not an ODEPE bug.

## 10. Reproducing Results <a name="10-reproducing"></a>

### Running the analysis

```bash
# From the ParameterEstimationBenchmark-local directory:
julia results/bilby_analysis/cstr_deep_dive/cstr_polynomial_sensitivity.jl \
    2>&1 | tee results/bilby_analysis/cstr_deep_dive/cstr_polynomial_sensitivity_output.log
```

**Runtime**: ~10–15 minutes (dominated by package loading, SIAN analysis, and HC.jl solves)

**Dependencies**: Uses the global Julia environment with MTK 11, Symbolics 7, HC.jl, SIAN 1.8.0

### Key files

| File | Description |
|------|-------------|
| `cstr_polynomial_sensitivity.jl` | Main analysis script (10 steps) |
| `cstr_polynomial_sensitivity_output.log` | Saved output from script run |
| `CSTR_POLYNOMIAL_SENSITIVITY_COMMENTARY.md` | This file |
| `cstr_hc_isolation.jl` | Reference: PerfectInterpolant, Taylor coefficients |
| `cstr_interpolator_sweep.jl` | Reference: AAAD interpolant building |

### Verifying key numbers

To verify the critical finding (linear L2 vs α), look for the Step 8 output table:
```
  alpha      MaxResid   #Real    Closest_L2  Found?
```

The ratio `Closest_L2 / alpha` should be approximately constant (~2.6×10⁷) for all
α values from 10⁻⁵ to 1.0.

To verify the singular Jacobian finding, look for Step 9:
```
  return_code terminated_invalid_startvalue_singular_jacobian: 7 paths
```

---

## Appendix: Glossary

| Term | Definition |
|------|-----------|
| **SIAN** | Structural Identifiability ANalyzer — determines which parameters can be identified from observed outputs |
| **SI template** | The polynomial structure produced by SIAN, with "slots" for interpolated coefficient values |
| **PerfectInterpolant** | Interpolant built from exact Taylor coefficients of the ODE solution |
| **AAAD** | Adaptive AAA rational interpolation with Degree-based selection |
| **Mixed volume** | The number of solutions of a generic polynomial system with the given monomial support structure |
| **Bézout bound** | Product of equation degrees — upper bound on solution count, often very loose for sparse systems |
| **Polyhedral homotopy** | HC.jl algorithm that exploits sparsity via Newton polytopes to track only mixed-volume-many paths |
| **Parameter homotopy** | Technique to track solutions as polynomial coefficients change continuously |
| **Endgame** | Algorithm for handling near-singular endpoints during path tracking (Cauchy integration) |
| **cond(J)** | Condition number of the Jacobian: σ_max / σ_min. Measures sensitivity of the solution to perturbations |
| **Effective rank** | Number of singular values above 10⁻¹⁰ × σ_max — the "useful" rank of the Jacobian |

---

*Generated from analysis run on 2026-03-11. Script: `cstr_polynomial_sensitivity.jl`.*
