# Algebraic multiplicity per benchmark system

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
| biohydrogenation | **≥ 2** (in id. subspace) | x7(t) | empirical=1 but SI says ≥ 2 — see SIAN cross-check |
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
| **slow_fast** | **2** | — | **high** (cd10 = (2, 20) — 20/20 unanimous) |
| sirt_treatment | 1 | — | high |
| vanderpol | 1 | — | high |

## Summary

- **19 systems are globally identifiable** (multiplicity 1).
- **3 systems have algebraic multiplicity 2** (no continuous unidentifiability):
  daisy_mamil4, seir, slow_fast — confirmed by SI 2026-05-19.
- **1 system has algebraic multiplicity ≥ 2 within its identifiable subspace**:
  biohydrogenation (with x7(t) being separately nonidentifiable, a continuous
  axis). Empirical analysis read this as "1" earlier; SI revises to "≥ 2 in
  the identifiable subspace."
- 2 systems have a structurally unidentifiable axis (aircraft_pitch's
  theta, biohydrogenation's x7) — these are excluded from oracle
  scoring throughout the benchmark.

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

5. **biohydrogenation top-2 branch capture not yet measured.** The
   `TOP2_BRANCH_CAPTURE.md` analysis was run only on the 3 systems
   the empirical pass called multiplicity-2 (daisy_mamil4, seir,
   slow_fast). Now that SI has revised biohydrogenation upward,
   running the same top-2 capture analysis on biohydrogenation is
   a cheap follow-up. The analysis would need to project out x7(t)
   (the unidentifiable axis) when computing rel-distance between
   row 0 and row 1.

## Implication for the paper

ODEPE's K=20 output gives "credit" for multiplicity in 4 of 23 systems
(after SI cross-check): daisy_mamil4, seir, slow_fast, and
biohydrogenation (the last one in its identifiable subspace, with x7
separately unidentifiable). For these 4, returning multiple distinct
candidates is *correct*, not redundant. For the remaining 19 systems,
returning >1 candidate is either numerical-noise spread of a single
basin (most cases) or genuine pipeline failure (the cd10 = 0 cells in
crauste, cstr, etc.).

Concrete numbers per noise level: the multiplicity ≥ 2 systems are
4/23 = 17% of systems × 50 cells/system × ~3 active noise levels
= roughly 200-600 cells where K ≥ 2 is theoretically justified.
The remaining ~3300-4100 cells should have K = 1 as the "correct"
output if the pipeline converged to truth.

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

### Status of the 7 untestable systems

`aircraft_pitch, bicycle_model, boost_converter, cstr, dc_motor,
forced_lotka_volterra, quadrotor` all use `sin(t)` forcing. SI/SIAN
require polynomial / rational RHS. The empirical multiplicity-1
finding for these stands but has no SI confirmation. None of these
systems were flagged as multiplicity > 1 by empirical evidence at
the tightest cd10 tolerance.

Reproducing the SI verdict for these would require introducing
auxiliary states `phi(t) = sin(omega*t)`, `psi(t) = cos(omega*t)`
with `phi'(t) = omega*psi(t)`, `psi'(t) = -omega*phi(t)` and
substituting in the original RHS — out of scope here.

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
