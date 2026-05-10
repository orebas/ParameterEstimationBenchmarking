# ODEPE Failure Analysis — Bilby Benchmark (2026-03-09)

## Summary

Analysis of ODEPE (ODEParameterEstimation.jl) failures in the bilby benchmark run,
compared against AMIGO2 and SciML solvers across 23 systems, 8 interpolator variants,
and 5 noise levels (0, 1e-8, 1e-6, 1e-4, 1e-2).

Overall success@1% rates:
- **odepe_polish**: 66.0%
- **odepe_nopolish**: 58.2%
- **amigo2_run**: 70.0%
- **sciml_run**: 37.6%

---

## Noise=0 Failures (ODEPE nopolish): 12 failures across 4 systems

### CSTR — "No Reaction" Spurious Branch (P0, 7/8 fail)

**Error signature:** On 6 of 7 failures, `dH_rhoCP ≈ 0`, `r_eff ≈ 0`, and often `C ≈ 0`,
while `tau`, `UA_VrhoCP`, and `Temp` are close to correct. The `max_rel_error = 1.0000`
is literal: the estimated value is ≈0 while the true value is nonzero.

**Cross-solver:** AMIGO2 7/8, SciML 6/8. Polishing does NOT help (still 1/8).

**Root cause (CONFIRMED):** The HC solver consistently finds a **"no reaction" equilibrium**
where the reaction-related variables (dH_rhoCP, r_eff, C) are zero. This is a valid
mathematical solution to the polynomial system because:

1. If `r_eff = 0`, then `dr_eff/dt = (12.5 * r_eff / Temp²) * (dTemp/dt) = 0` trivially.
2. If `dH_rhoCP = 0`, the reaction heat term `0.0286 * dH_rhoCP * r_eff * C` vanishes from dTemp/dt.
3. The Temp dynamics reduce to simple mixing/cooling: `(Tin - Temp)/(2τ) - 2*UA*Temp + ...`
4. The single observable `y1 = 700*Temp` cannot distinguish this from the true solution
   because Temp is still well-determined by the cooling/mixing terms.

**Evidence from candidate analysis:**
- Instance 1 (cstr_1_0): 101 HC candidates, 75 have r_eff ≈ 0, **zero** near true value (0.856)
- Instance 3 (cstr_3_0, the only SUCCESS): 175 candidates, 10 near true r_eff=0.110. This
  succeeds because r_eff=0.110 is *close to zero*, so the spurious and true branches nearly
  coincide. The oracle selector can distinguish them.
- On 6/8 instances, **no candidate at all** has the correct solution — HC completely misses it.

**Per-instance breakdown:**

| Instance | tau_err | dH_err | r_eff_err | C_err  | #cands | Correct exists? |
|----------|---------|--------|-----------|--------|--------|-----------------|
| cstr_0_0 | 0.03%   | 3.8%   | 4.2%      | 0.2%   |    252 | No (best=4.2%)  |
| cstr_1_0 | 0.00%   | 100%   | 100%      | 100%   |    101 | No              |
| cstr_2_0 | 0.3%    | 17.9%  | 100%      | 100%   |     82 | No              |
| cstr_3_0 | 0.00%   | 0.00%  | 0.00%     | 0.00%  |    175 | YES (3 cands)   |
| cstr_4_0 | 0.00%   | 100%   | 100%      | 100%   |     33 | No              |
| cstr_5_0 | 1.1%    | 100%   | 100%      | 4.2%   |     50 | No              |
| cstr_6_0 | 0.05%   | 97.4%  | 100%      | 4.4%   |     62 | No              |
| cstr_7_0 | 0.00%   | 100%   | 100%      | 51.8%  |     73 | No              |

**Why instance 3 succeeds:** Its true `r_eff = 0.110` is close to the spurious branch's
`r_eff ≈ 0`. The gap between branches is small enough that HC tracks both.

**Potential fixes:**
1. **ODE residual filter:** After HC, forward-simulate each candidate and reject those
   with high ODE residual. The zero-reaction branch will have wrong C dynamics.
2. **Observability enrichment:** If the benchmark supported `y2 = C` as a second observable,
   the spurious branch would be immediately distinguishable.
3. **Positivity constraints:** Enforce r_eff > 0, dH_rhoCP > 0 as physical bounds during
   candidate selection. This would filter most spurious candidates.

### forced_lotka_volterra — Convergence Gap (P2, 2/8 fail)

**Error signature:** errors 2-6%, within one order of magnitude of threshold.

**Cross-solver:** AMIGO2 8/8. **Polishing fixes both failures** (8/8 with polish).

**Root cause:** HC gets into the right basin but doesn't fully converge. This is the
polishing step working exactly as designed — a success story for the pipeline.

### Crauste — Outlier Parameters (P2, 2/8 fail)

**Error signature:** median ≈ 0, but max = 1-10%. One outlier parameter off in a 17-param system.

**Cross-solver:** AMIGO2 6/8, SciML 0/8. Polish fixes 1 of 2.

**Root cause:** Large parameter count (17 identifiable) means interpolation sensitivity
on one variable can pull a single parameter estimate off.

### Brusselator — Catastrophic Single Run (P3, 1/8 fail)

**Error signature:** median = 3%, max = 946x (!). One parameter wildly wrong.

**Cross-solver:** AMIGO2 4/8, SciML 0/8. ODEPE actually *best* on this system.
Polish doesn't fix the one failure.

**Root cause:** HC lands on wrong branch for one run. Given ODEPE outperforms other
solvers here, this is acceptable.

---

## Noise=1e-8 Cliff Analysis (ODEPE nopolish)

44 total failures. The key question: which systems show a "cliff" (sharp drop from noise=0)?

| System              | n=0 | 1e-8 | Drop | AMIGO2 | SciML | #params | Category |
|---------------------|-----|------|------|--------|-------|---------|----------|
| hiv                 | 8/8 | 0/8  |   -8 |    4/8 |   0/8 |      15 | Total collapse |
| crauste             | 6/8 | 0/8  |   -6 |    4/8 |   0/8 |      17 | Total collapse |
| cstr                | 1/8 | 0/8  |   -1 |    7/8 |   4/8 |       7 | Already broken |
| seir                | 8/8 | 3/8  |   -5 |    4/8 |   4/8 |       7 | Significant |
| biohydrogenation    | 8/8 | 4/8  |   -4 |    6/8 |   1/8 |       9 | Significant |
| daisy_mamil4        | 8/8 | 5/8  |   -3 |    5/8 |   0/8 |      11 | Significant |
| brusselator         | 7/8 | 4/8  |   -3 |    4/8 |   0/8 |       4 | Moderate |
| flexible_arm        | 8/8 | 6/8  |   -2 |    8/8 |   5/8 |       9 | Mild |
| forced_lotka_volt.  | 6/8 | 6/8  |    0 |    8/8 |   2/8 |       6 | No change |

### Two Distinct Failure Modes

**1. Polishing-fixable failures:** HC gets near the right answer but not within 1%.
The ODE-residual polishing step converges these. Examples: forced_lotka_volterra (nopol 6→pol 8),
seir (nopol 3→pol 5). These are pipeline wins.

**2. Polishing-unfixable failures:** HC lands on a wrong branch entirely. No amount of
local polishing can fix a spurious solution. Examples: CSTR (1/8 both), HIV (0/8 both at 1e-8).
These need better candidate selection or branch pruning upstream.

### Observations

- **High param count correlates with cliff severity:** HIV (15), crauste (17) both collapse
  completely. The HC polynomial conditioning deteriorates with parameter count.
- **AMIGO2 degrades gracefully** because local optimization (Nelder-Mead / gradient) doesn't
  depend on polynomial root conditioning — it just needs a decent starting point.
- **SciML is generally worse** than ODEPE at noise=1e-8 (0/8 on HIV, crauste, brusselator,
  daisy_mamil4). ODEPE's approach is competitive except on CSTR.

---

## Nopolish vs Polish Comparison (all systems with any failure)

| System              | nopol n=0 | pol n=0 | nopol 1e-8 | pol 1e-8 | #id |
|---------------------|-----------|---------|------------|----------|-----|
| biohydrogenation    |       8/8 |     8/8 |        4/8 |      4/8 |   9 |
| brusselator         |       7/8 |     7/8 |        4/8 |      4/8 |   4 |
| crauste             |       6/8 |     7/8 |        0/8 |      0/8 |  17 |
| cstr                |       1/8 |     1/8 |        0/8 |      0/8 |   7 |
| daisy_mamil4        |       8/8 |     8/8 |        5/8 |      5/8 |  11 |
| flexible_arm        |       8/8 |     8/8 |        6/8 |      6/8 |   9 |
| forced_lotka_volt.  |       6/8 |     8/8 |        6/8 |      8/8 |   6 |
| hiv                 |       8/8 |     8/8 |        0/8 |      0/8 |  15 |
| seir                |       8/8 |     8/8 |        3/8 |      5/8 |   7 |

Polish helps most on forced_lotka_volterra (+2 at both noise levels) and seir (+2 at 1e-8).
No impact on systems where HC lands on wrong branch (CSTR, HIV, crauste at noise).

---

## NaN Parsing Bug — 5 Instances Mis-scored (P3, FIXED)

**Affected instances (all noise=0):**
- `bicycle_model` (run 6), `hiv` (run 3), `mass_spring_damper` (run 5),
  `sirt_treatment` (run 3), `vanderpol` (run 7)

**Root cause:** Multi-candidate ODEPE results containing bare `nan` literals
caused `ast.literal_eval` to fail. Fixed with `_sanitize_for_literal_eval()`.

---

## Actionable Next Steps

1. **CSTR (P0):** Investigate HC branch symmetry. Add ODE-residual-based candidate
   filtering before best-candidate selection. 7/8 fail at noise=0 — biggest single
   system improvement opportunity.

2. **Noise robustness (P1):** For HIV/crauste cliff, explore polynomial preconditioning
   or multi-precision arithmetic in HC. Long-term research direction.

3. **Polish refinement (P2):** Polish already helps on 2 systems. Consider increasing
   polishing iterations or switching to a more robust local optimizer for near-miss cases.

---

*Updated 2026-03-10. Based on bilby benchmark run 2026-03-09 with 8 interpolator variants.*
