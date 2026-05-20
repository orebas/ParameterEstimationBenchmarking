# Algebraic multiplicity per benchmark system

> **Status (2026-05-19, end of day):** This file is the **first-pass**
> empirical + 16-system SI cross-check. A **complete catalog** covering
> all 23 systems (including the 7 sin(t)-forced systems that SI rejected
> here), per-system branch transformations, the algebraic-vs-physical
> bounds analysis, and a recipe-for-finding-all-branches lives in
> ODEPE's repro tree at
> `environments/ODEParameterEstimation/repro/multiplicity_complete_2026_05_19/MULTIPLICITY_COMPLETE.md`
> (ODEPE commit `b623e5e`). Treat that file as authoritative when it
> conflicts with what's written here.
>
> Highlights from the complete catalog:
> - **All 23 systems** now have SI verdicts (the sin(t) issue was worked
>   around: transcribe wallaby's actual `state_equations` and pass
>   `sin(omega*t)` as a free input variable, no oscillator-state ODE,
>   matching ODEPE's `transform_pep_for_estimation()` convention).
> - **biohydrogenation's algebraic second branch is exactly k9 → -k9,
>   k10 → -k10** (sign-flip preserving the ratio), with k8 and x6
>   compensating — so it's multiplicity 2 algebraically, not "≥ 2 in
>   some subspace."
> - **Physical multiplicity (within wallaby's opt_lb=1e-5, opt_ub=10
>   bounds) is only 2 of 23 systems**: daisy_mamil4 and seir. Both
>   slow_fast's xA<0 branch and biohydrogenation's k9,k10<0 branch are
>   out-of-bounds and the log-space PolishLSOBoundedLog correctly
>   rejects them.

## Definition

Given a locally identifiable ODE parameter estimation problem and the
canonical truth (params, IC) for a benchmark cell, the **algebraic
multiplicity** is the size of the finite set of OTHER (params, IC)
tuples that produce identical observations to within exact precision.
"Locally identifiable" rules out continuous symmetries (infinite
multiplicity). Multiplicity = 1 means globally identifiable; ≥ 2 means
there are genuine additional algebraic solution branches.

## Method (per agent run 2026-05-19)

For each of the 23 systems in `config/systems.json`, the agent ran
wallaby's existing per-cell `result.csv` files (20 polished candidates
per cell, K=20) through a distinct-row counting analysis at multiple
distance tolerances. The "true" multiplicity is read off the count at
the tightest tolerance (cd10 = `1e-10`) — at that tolerance, numerical
noise has been merged but algebraic branches are still separated.

A SIAN / `StructuralIdentifiability.assess_identifiability` cross-check
was then run on all systems with polynomial/rational RHS — see the
"SIAN cross-check" section below. All three empirical multiplicity-2
claims are confirmed; biohydrogenation was revised from `1` to
`≥ 2 in identifiable subspace`.

## Per-system multiplicity

| System | Multiplicity | Unidentifiable axes | Confidence |
|---|---|---|---|
| aircraft_pitch | 1 | theta(t) | high (cd10 = (1, 20) — 20/20 cells unanimous) |
| bicycle_model | 1 | — | high (cd10 = (1, 20)) |
| biohydrogenation | **2** (algebraic) / 1 (physical, in bounds) | x7(t) | k9→-k9, k10→-k10 sign-flip; alt branch OOB on wallaby — see MULTIPLICITY_COMPLETE.md |
| boost_converter | 1 | — | high |
| brusselator | 1 | — | high |
| crauste | 1 | — | high (cd10 = (1, 10) + (0, 9) — many failures, but single-basin) |
| cstr | 1 | — | high (cd10 = (0, 20) — many cells failed entirely; treat as 1 by default) |
| daisy_mamil3 | 1 | — | high |
| **daisy_mamil4** | **2** | — | **high** (cd10 = (2, 20) — 20/20 cells unanimous on 2 distinct branches) |
| dc_motor | 1 | — | high |
| fitzhugh_nagumo | 1 | — | high |
| flexible_arm | 1 | — | high (cd10 = (1, 14) + (0, 6)) |
| forced_lotka_volterra | 1 | — | high |
| harmonic_oscillator | 1 | — | high |
| hiv | 1 | — | high (cd10 = (1, 12) + (0, 8)) |
| lotka_volterra | 1 | — | high |
| mass_spring_damper | 1 | — | high |
| quadrotor | 1 | — | high |
| repressilator | 1 | — | high |
| **seir** | **2** | — | **high** (cd10 = (2, 17) + (0, 2) + (9, 1) — 17/20 cells unanimous on 2) |
| **slow_fast** | **2** (algebraic) / 1 (physical, in bounds) | — | k1↔k2 swap, but alt has xA<0 → OOB on wallaby — see MULTIPLICITY_COMPLETE.md |
| sirt_treatment | 1 | — | high |
| vanderpol | 1 | — | high |

## Summary

Revised after the all-23 SI cross-check (`MULTIPLICITY_COMPLETE.md`,
ODEPE commit `b623e5e`):

- **19 systems are globally identifiable** in their identifiable subspace.
- **4 systems have algebraic multiplicity 2**: daisy_mamil4, seir,
  slow_fast, biohydrogenation. Branch transformations explicitly
  characterized (channel swap; (a,nu) hyperbola; k1↔k2 swap; k9,k10
  sign-flip respectively).
- **2 of those 4 are physical multiplicity 2 in wallaby's opt_lb=1e-5,
  opt_ub=10.0 bounds**: daisy_mamil4 and seir. The slow_fast and
  biohydrogenation alt branches require negative state/parameter values
  and are correctly rejected by `PolishLSOBoundedLog` (log-space polish
  can't handle negatives). Those alt branches still appear in
  result.csv as unpolished raw HC candidates — explaining the cd10
  empirical signal that originally triggered this investigation.
- 2 systems have a continuous unidentifiable axis (aircraft_pitch's
  theta, biohydrogenation's x7) — these are excluded from oracle
  scoring throughout the benchmark. ODEPE plugs them silently via
  `representative_completion_value` (1.0 for params, 0.0 for states),
  see `src/core/parameter_estimation_helpers.jl:380`.

## Caveats

1. **cd6/cd8 noise.** At looser tolerances (cd6 = 1e-6, cd8 = 1e-8),
   distinct-row counts diverge — numerical errors create spurious
   "branches." daisy_mamil4 cd6 shows 8 distinct rows for 5/20 cells.
   Treat anything above cd10 as numerical artifacts, not multiplicity.

2. **"Multiplicity 1" with many cd10 = 0 cells.** A cd10 = 0 means the
   cell's HC/polish pipeline failed to converge on the truth basin at
   all. For crauste, cstr, flexible_arm, hiv these counts run 6-20
   cells with 0 distinct converged solutions — those are *cell failures*,
   not multiplicity evidence. The agent's "best=1" inference is robust
   to this (it picks the dominant non-zero count).

3. ~~**SIAN cross-check incomplete.**~~ **Completed 2026-05-19** — see
   the "SIAN cross-check" section below. The 3 multiplicity-2 claims
   (daisy_mamil4, seir, slow_fast) are confirmed; biohydrogenation
   updated from `1` to `≥ 2 in identifiable subspace` based on the
   SI verdict.

4. ~~**slow_fast was a surprise.**~~ **Confirmed 2026-05-19**: SI
   marks `k1, k2, xA, xB, eB` as `:locally` identifiable, consistent
   with the conjectured fast/slow exchange symmetry.

5. ~~**biohydrogenation top-2 branch capture not yet measured.**~~
   **Done 2026-05-19** — see `top2_branch_capture_all4.py` and
   `biohydrogenation_top2.txt` in
   `environments/ODEParameterEstimation/repro/multiplicity_complete_2026_05_19/`.
   Biohydrogenation's alt branch is rank-9 (not rank-1) on the cell
   examined, because the sign-flipped k9, k10 branch is OOB and the
   polish demotes it.

## Implication for the paper

Two layers to the K-bound justification:

**Algebraic (structural) catalog:** 4 of 23 systems have multiplicity 2 —
daisy_mamil4, seir, slow_fast, biohydrogenation — confirmed by SI on
all 23. The other 19 are globally identifiable (after plugging
continuous-unidentifiable axes for aircraft_pitch and biohydrogenation).

**Physical catalog (within wallaby's `opt_lb=1e-5, opt_ub=10`):** only 2
of 23 give multiple bound-satisfying solutions — daisy_mamil4 and seir.
slow_fast's alt branch has xA<0; biohydrogenation's has k9,k10<0. Both
get rejected by `PolishLSOBoundedLog` (log-space, no negatives), but
their unpolished raw HC candidate rows still appear in result.csv,
which is what generated the empirical cd10 ≥ 2 signal originally.

For the paper claim "we return up to k candidates where k is the
algebraic multiplicity":

- **Strong form** (algebraic): 4/23 systems justify K ≥ 2; 19/23 should
  collapse to K=1 after multiplicity-aware dedup.
- **Operational form** (in bounds): 2/23 (daisy_mamil4, seir) reliably
  produce 2 physical rows ranked at the top; the other 2 multiplicity-2
  systems show their second branch only as OOB raw HC candidates that
  a bound-aware ranker would correctly demote.

The K=20 default is a numerical-safety bound, not the multiplicity
bound. Either framing is defensible in the paper; the stronger
algebraic claim is more general (independent of user-chosen bounds),
while the operational claim better matches what wallaby's
`result.csv` actually contains row-by-row.

## SIAN cross-check (2026-05-19)

`StructuralIdentifiability.assess_identifiability` was run on the 16
polynomial / rational systems (script:
`run_sian_polynomial_only.jl`, log: `sian_poly_output.log`,
total runtime ~46 s across all 16). The other 7 systems use `sin(t)`
forcing, which SI cannot handle directly without manual variable
transformation (`@ODEmodel` rejects non-arithmetic RHS at parse time);
they remain on empirical evidence only.

### Reconciliation table

| System | Empirical (cd10) | SI verdict | Match? |
|---|---|---|---|
| biohydrogenation | 1 | **5 globally / 4 locally / 1 nonidentifiable** | MISMATCH (SI ≥ 2 in identifiable subspace) |
| brusselator | 1 | 4 globally | ✓ |
| crauste | 1 | 17 globally | ✓ |
| daisy_mamil3 | 1 | 8 globally | ✓ |
| **daisy_mamil4** | **2** | **5 globally / 6 locally** | **✓ confirmed multiplicity ≥ 2** |
| fitzhugh_nagumo | 1 | 5 globally | ✓ |
| flexible_arm | 1 | 9 globally | ✓ |
| harmonic_oscillator | 1 | 4 globally | ✓ |
| hiv | 1 | 15 globally | ✓ |
| lotka_volterra | 1 | 5 globally | ✓ |
| mass_spring_damper | 1 | 5 globally | ✓ |
| repressilator | 1 | 9 globally | ✓ |
| **seir** | **2** | **3 globally / 4 locally** | **✓ confirmed multiplicity ≥ 2** |
| sirt_treatment | 1 | 9 globally | ✓ |
| **slow_fast** | **2** | **3 globally / 5 locally** | **✓ confirmed multiplicity ≥ 2** |
| vanderpol | 1 | 4 globally | ✓ |

### Detailed per-var status for the multiplicity-2 systems

**daisy_mamil4** (5 globally + 6 locally):
- globally: `k01, k12, k21, x1(t), x2(t)`
- locally:  `k13, k14, k31, k41, x3(t), x4(t)`

The branch symmetry exchanges the (k13, k31, x3) chain with the
(k14, k41, x4) chain — the model has two equivalent "channels" feeding
out of x1 and the y3 output `1.2*x3 + 1.6*x4` doesn't distinguish them.
This matches the empirical 20/20 cd10 = 2 finding.

**seir** (3 globally + 4 locally):
- globally: `In(t), Npop(t), b`
- locally:  `E(t), S(t), a, nu`

Latent compartment + transition rate (E, nu) trade with susceptible
+ infection rate (S, a) in a way that preserves the observed In(t)
and Npop(t). Matches the empirical 17/20 cd10 = 2 finding.

**slow_fast** (3 globally + 5 locally):
- globally: `eA(t), eC(t), xC(t)`
- locally:  `eB(t), k1, k2, xA(t), xB(t)`

The fast/slow rate constants (k1, k2) can swap with simultaneous
rescaling of (xA, xB, eB) — confirming the "fast/slow exchange
symmetry" caveat speculated earlier. Matches empirical 20/20 cd10 = 2.

### Biohydrogenation — empirical=1 vs SI = locally identifiable

SI flags `k8, k9, k10, x6(t)` as `:locally` (≥ 2 discrete branches)
plus `x7(t)` as `:nonidentifiable` (continuous axis). The empirical
cd10 histogram was `(1, 10) + (2, 6) + (3, 4)` — i.e. 50% of cells
landed on 1 row, 30% on 2 rows, 20% on 3+ rows. We earlier read
"dominant 1" as the answer; SI says the answer in the identifiable
subspace is ≥ 2, and the pipeline finds the second branch in roughly
half the cells.

Likely cause of the empirical under-call: when x7 is unidentifiable,
the K=20 candidates spread x7 along a continuous axis, which the
distinct-row counter (operating on all columns including x7) merges
under cd10 tolerance for some cells and not others. The "1 row" cells
are cases where the spread happened to be tight; the "2+" cells are
cases where two branches each had their own x7-spread cluster.

A cleaner empirical analysis would **project out the unidentifiable
columns before counting distinct rows** — that's a cheap re-run if
desired. As-is, biohydrogenation should be treated as having algebraic
multiplicity ≥ 2 in the identifiable subspace, not 1.

### Status of the 7 sin(t) systems — RESOLVED via `MULTIPLICITY_COMPLETE.md`

`aircraft_pitch, bicycle_model, boost_converter, cstr, dc_motor,
forced_lotka_volterra, quadrotor` all use `sin(t)` forcing. SI's
`@ODEmodel` macro rejects this at parse time as written here.

**Resolution (per ODEPE commit `b623e5e`):** instead of polynomializing
sin via auxiliary oscillator states (an approach that triggers a
Groebner-internal BoundsError on bicycle_model), transcribe each
wallaby cell's actual `state_equations` and pass `sin(omega*t)` as a
free input variable `u_sin(t)` — no derivative line, SI auto-infers
it as input. This matches ODEPE's runtime convention at
`src/core/si_equation_builder.jl:172`. All 7 systems then run cleanly
under SI; all are confirmed multiplicity 1 (with `aircraft_pitch`'s
theta(t) the only continuous unidentifiable axis among them).

See `run_sian_all_23.jl` and `run_sian_all_23.txt` in
`environments/ODEParameterEstimation/repro/multiplicity_complete_2026_05_19/`.

## Artifacts

- `multiplicity_final.pkl` — per-system summary dict, key `best`
- `multiplicity_pass1.pkl` — per-cell distinct-row counts (machine precision)
- `multiplicity_pass2.pkl` — per-cell counts at tolerances 0.001, 0.01, 0.1
- `run_sian_check.jl` — original seir-only SIAN smoke script
- `run_sian_all_systems.jl` — first attempt at all-23 cross-check (crashed at parse time on aircraft_pitch's sin(t))
- `run_sian_polynomial_only.jl` — successful cross-check on the 16 polynomial systems
- `sian_poly_output.log` — full SI output (per-var :globally / :locally / :nonidentifiable for each of the 16 systems)

## Reading the pickles

```python
import pickle
d = pickle.load(open('multiplicity_final.pkl','rb'))
for sys, info in d.items():
    print(sys, info['best'])
```

`cd10`, `cd8`, `cd6` fields in the final dict are histograms of
`(distinct_count, cells_with_that_count)` pairs.
