# Polish Oracle Regression Analysis: numbat-06 → wallaby NEW

**Generated:** 2026-05-21 14:15 EDT (rerun ~99% complete; 11 cells still running, mostly polish on crauste/biohydrogenation/cstr at high noise)

**Author:** Claude (Opus 4.7, 1M context) — off-cluster experiment seed for orebas

## TL;DR

Comparing oracle@50% (= min over all rows in result.csv of the max relative
error across identifiable variables) for ODEPE v2 polish, cell-by-cell,
between two benchmarks running on bit-equivalent synthetic data:

- **numbat-06** (2026-05-06): old ODEPE, branch_top_k=100, very large result.csv
  files (median 384 rows, max 2849). Row-0 ≈ oracle (suspected: row 0 was
  truth-aware ordered).
- **wallaby NEW** (2026-05-17 + 2026-05-21 in-place rerun): current ODEPE
  (commit 6ffc6cb) with M-truncation, Groebner pin PR #218,
  branch_top_k=20, S2 rank strategy, identifiable-subspace clustering.

| variant | n | oracle@1% | oracle@10% | oracle@50% |
|---|---|---|---|---|
| numbat-06 polish | 1144 | 72.4% | **81.7%** | 86.7% |
| wallaby NEW polish | 1128 | 68.9% | 80.1% | 84.8% |
| Δ | | -3.5pp | -1.6pp | -1.9pp |

Cell-level set diff at @50%:
- **numbat-06_only = 39 cells lost** in wallaby
- **wallaby_NEW_only = 4 cells gained**
- net = **-35 cells** (~3.1pp)

The 4 cells wallaby gains are not enumerated here (they're at the noise tail
where small randomness wins).

This document enumerates and diagnoses the 39 lost cells so we can run
targeted off-cluster experiments to recover them.

## Why this is happening (suspects, in order)

1. **wallaby init knob changes from numbat-06**: branch_top_k 100→20,
   `cluster_method=:identifiable_subspace`, `rank_strategy=:sat_neg1_err` (S2),
   `soft-wall λ=1e-2, ε=0.10`. These were a deliberate quality/speed trade,
   never specifically validated against numbat-06.
2. **Data subtle drift**: per MANIFEST, "data.csv differs in last-digit
   precision because OrdinaryDiffEq jumped from 6.x to 7.0.0". Most of the
   regressions are unlikely to be data-driven (errors are macroscopic), but a
   few might be.
3. **NOT M-truncation**: comparison of wallaby OLD (K=20) vs wallaby NEW
   (M-truncated) shows the new oracle is within ~1pp of the OLD K=20 oracle.
   The bulk of the regression vs numbat-06 was already present in wallaby OLD.

## Methodology notes

- `non_identifiable` is read from per-cell
  `odepe_metadata.json[best][all_unidentifiable]` (per project memory:
  `huge_json[non_identifiable]` is parameter-only and incomplete). Variables
  in `all_unidentifiable` are **excluded** from the max-rel-error calculation.
- "Best row" = row of result.csv minimizing max-rel-error over identifiable
  variables.
- "Regression cell" = `numbat-06 oracle ≤ 0.50 AND wallaby NEW oracle > 0.50
  (or no result)`.
- Truth = `huge_json.json[instances][*][state_values ∪ parameter_values]`.

## Noise distribution of the 39 regressions

| noise | n | comment |
|---|---|---|
| 0 (noise-free) | 1 | cstr_0_0 — catastrophic-style (-3 orders), pure algorithmic |
| 1e-8 | 4 | cstr_0/6, biohydrogenation_4_1em8 (in flight), crauste_9_1em8 (in flight) |
| 1e-6 | 5 | cstr_1, cstr_6_1em6, biohydrogenation_2, daisy_mamil4_8, seir_1 |
| 1e-4 | 13 | bulk of cstr+seir+slow_fast+sirt regressions |
| 1e-2 | 16 | high-noise cells, hardest |

75% (29/39) are at 1e-4 or 1e-2. **But** the 10 at low noise (0, 1e-8, 1e-6)
are the most diagnostic — at near-noiseless data, regression is algorithmic,
not statistical.

## Closeness of the wallaby NEW oracle (how badly did we miss?)

| wallaby oracle range | n | comment |
|---|---|---|
| NO_RESULT (still in flight or empty) | 3 | biohydrogenation_4_1em8, crauste_7_1em4, crauste_9_1em8 |
| 0.5 – 1.0 | 15 | **just over** — small algorithm-tuning could rescue |
| 1.0 – 10.0 | 12 | factor 2-10× off |
| 10 – 100 | 7 | factor 10-100× off |
| > 100 | 2 | **catastrophic**: cstr_1_1em6 (3419×), cstr_0_1em8 (154×) |

## Per-system breakdown

| system | n | dominant variable(s) | notes |
|---|---|---|---|
| **cstr** | **7** | `dH_rhoCP`, `r_eff`, `C` | The biggest single source. Includes the catastrophic >100× misses. Multiple distinct trouble params. |
| **biohydrogenation** | **3** | (varies; x7 is unid and excluded) | 2 NO_RESULT (4_1em8 still running) + 2_1em6 |
| **seir** | **5** | `E`, `S` (states/ICs) | Mult-2 system. Often returns two near-identical (wrong) rows; sometimes two distinct (wrong) branches. |
| **slow_fast** | **5** | `xA`, `xB`, `k1` | Mult-2 system. Similar pattern to seir; high-noise data, hard problem. |
| **brusselator** | **3** | `a`, `Yc` | param + IC |
| **fitzhugh_nagumo** | **3** | `b` | single trouble parameter dominates |
| **sirt_treatment** | **3** | `a` | single trouble parameter (sensitivity?) |
| **crauste** | **2** | NO_RESULT (still running) | both 1em4/1em8 in flight as of writing |
| **daisy_mamil3** | **2** | `a31` | single param |
| **daisy_mamil4** | **2** | `x3`, `k41` | Mult-2 system. |
| **forced_lotka_volterra** | **2** | `yv` (IC) | initial condition |
| **vanderpol** | **2** | `b`, `x2` | param + IC |
| **lotka_volterra** | **1** | `w` | high-noise (1em2) only |

## Mult-2 failure modes (12 of 39 regressions)

These cells are from the 4 mult-2 systems (seir, slow_fast, daisy_mamil4,
biohydrogenation). ODEPE auto-detected M=2 and produced 2 rows. The two
modes:

### Mode A — duplicate wrong-branch (clustering too aggressive)

The 2 rows are nearly identical. ODEPE returned the same wrong solution twice;
the second algebraic branch was lost.

| cell | row 0 max | row 1 max | dominant |
|---|---|---|---|
| seir_7_1em2 | 0.742 (E) | 0.743 (E) | identical wrong-branch |
| seir_7_1em4 | 0.615 (S) | 0.605 (S) | identical |
| slow_fast_8_1em2 | 0.846 (xA) | 0.870 (xA) | identical |

### Mode B — distinct rows, both wrong

ODEPE found two distinct candidates, but neither is the true branch.

| cell | row 0 max | row 1 max | comment |
|---|---|---|---|
| seir_1_1em6 | 20.2 (S) | 3.09 (E) | both far off; weird at low noise |
| seir_5_1em4 | 13.7 (E) | 73.6 (E) | both catastrophic |
| seir_8_1em4 | 1.23 (nu) | 0.816 (E) | both >50% |
| daisy_mamil4_4_1em2 | 1.37 (k41) | 1.13 (x3) | both >100% |
| daisy_mamil4_8_1em6 | 3.46 (x3) | 0.849 (x3) | row 1 is "almost" |
| slow_fast_1_1em4 | 1.36 (xA) | 2.31 (eB) | both wrong |
| slow_fast_5_1em2 | 0.938 (xA) | 6.67 (k1) | both wrong |
| slow_fast_6_1em4 | 47.4 (k1) | 28.3 (xB) | catastrophic at 1e-4 |
| slow_fast_9_1em4 | 8.34 (k1) | 6.42 (k1) | catastrophic |
| biohydrogenation_2_1em6 | k10=5.8, x7 excluded | (1 row good?) | k10 dominates |

## Trouble parameters by system (low-sensitivity hypothesis)

When the same parameter dominates the error across multiple cells of one
system, this points to a low-sensitivity direction in the inverse problem
that the wallaby ranking happens to filter out:

| system | param | n cells | hypothesis |
|---|---|---|---|
| cstr | `dH_rhoCP` | 3 | Thermodynamic constant; low identifiability at low noise |
| cstr | `r_eff` | 3 | Reaction-rate effective constant |
| cstr | `C` | 1 | (concentration?) |
| sirt_treatment | `a` | 3 | Single low-sensitivity param |
| fitzhugh_nagumo | `b` | 3 | Single low-sensitivity param |
| daisy_mamil3 | `a31` | 2 | Single low-sensitivity param |
| brusselator | `a` | 2 | |
| forced_lotka_volterra | `yv` | 2 | Initial condition (low identifiability) |

The "single trouble parameter per system" pattern is very strong for cstr,
sirt_treatment, fitzhugh_nagumo, daisy_mamil3 — these may have a known
low-sensitivity axis where the wallaby pipeline polishes into a flat valley
and lands on a wrong fixed point.

## Algorithmic improvements (ranked by expected impact)

### Tier 1 — high impact

**1. Column scaling of the polynomial system** *(ODEPE TODO already, hardest to implement)*

- Targets: cstr catastrophic misses at low noise (cstr_1_1em6 → 3419×,
  cstr_0_1em8 → 154×). These can't be statistical at noise=1e-8/1e-6.
- Per ODEPE's `docs/2026-05-01_variable_scaling_investigation.md`,
  cstr/biohydrogenation/daisy_mamil4 show Jacobian condition numbers of 1e6–1e10.
  HC.jl does row scaling but not column.
- Implementing column scaling at the polynomial-system level should
  directly address the low-noise catastrophic tier (~5-7 cells).

**2. Forward-simulation re-ranking before truncation** *(low effort, broad upside)*

- For top K=20 candidates, integrate the ODE forward and compute L2-on-data,
  then re-rank by that. Truncate to M after.
- This is what numbat-06 was effectively doing (row 0 ≈ oracle).
- Expected recovery: 10-20 of the 39, esp. cells in the "0.5-1.0" closeness
  tier where the right answer was probably in the candidate pool but mis-ranked.

### Tier 2 — medium impact

**3. Parameter-space clustering (mult-2 specific)**

- Targets: the 3 mult-2 cells where wallaby returned duplicate near-identical rows
  (seir_7_1em2, seir_7_1em4, slow_fast_8_1em2).
- When M>1, enforce minimum L∞ separation in normalized param space between
  kept reps. Don't merge candidates with similar residuals if their params
  differ macroscopically.
- Expected recovery: ~3 cells outright; possibly enables Mode-B mult-2 cells
  to get a second-row hit.

**4. Multi-start polish for single-trouble-parameter cases**

- Targets: sirt.a, fitzhugh.b, daisy_mamil3.a31, brusselator.a, cstr.* (low-sensitivity).
- Run polish from multiple jittered starting points along the trouble direction;
  keep best.
- Expected recovery: ~5-10 cells.

### Tier 3 — large refactor, future work

**5. Denoised polish target** *(per `INVESTIGATION_denoised_polish_target.md`)*

- Polish against the GP-denoised mean rather than the raw noisy data.
- Targets: the 29 high-noise (1e-4, 1e-2) regression cells.
- Big refactor; existing investigation has details.

**6. Per-system K policy**

- M=2 systems keep K=50 (or numbat-06's K=100); others stay at K=20.
- Cheapest patch but smallest effect. Most of the lost cells are
  algorithmic, not "answer was in row 23+".

## Recommended off-cluster experiment order

1. **Single-cell deep dive on cstr_1_1em6** (the 3419× miss at noise=1e-6).
   - Re-run with diagnostics enabled. Compare what numbat-06 got vs what wallaby got.
   - Is the right candidate in the raw candidate pool (pre-clustering, pre-ranking)?
   - If yes → ranking issue (suspect: S2 sat_neg1_err mis-scoring at low noise).
   - If no → solver/HC.jl basin issue (column scaling needed).
2. **Toy column-scaling prototype** on the cstr polynomial system. Even a
   crude diagonal preconditioning may shift the catastrophic cells dramatically.
3. **Forward-sim re-rank prototype** in pure Python or Julia: read existing
   result.csv per cell, simulate ODE forward for each row, score by L2 on
   data, re-rank. Test how much of the @50% gap closes.
4. **mult-2 cluster-collapse test on seir_7_1em2**: re-run with cluster_eps
   smaller (forcing more separation) and see if a distinct second branch
   appears.

## Full cell list

39 regression cells (3 still running on cluster as of 14:15 EDT 2026-05-21):

```
cell                            | system               | M | noise | nrows | n06_orcl | wal_orcl | worst3 (rel_err)
biohydrogenation_2_1em6         | biohydrogenation     | 2 | 1em6  | 2     | 1.07e-01 | 5.76e+00 | k10(5.8), k9(0.024), x6(0.0077)
biohydrogenation_4_1em8         | biohydrogenation     | ? | 1em8  | 0     | 6.63e-06 | NA       | NO_RESULT (running)
brusselator_2_1em2              | brusselator          | 1 | 1em2  | 1     | 6.43e-02 | 6.96e-01 | a(0.7), X(0.49), Yc(0.3)
brusselator_4_1em4              | brusselator          | 1 | 1em4  | 1     | 1.70e-03 | 8.46e+00 | Yc(8.5), X(1), a(0.44)
brusselator_7_1em4              | brusselator          | 1 | 1em4  | 1     | 1.24e-01 | 5.23e-01 | a(0.52), Yc(0.045), X(0.014)
crauste_7_1em4                  | crauste              | ? | 1em4  | 0     | 4.99e-01 | NA       | NO_RESULT (running)
crauste_9_1em8                  | crauste              | ? | 1em8  | 0     | 1.58e-01 | NA       | NO_RESULT (running)
cstr_0_0                        | cstr                 | 1 | 0     | 1     | 1.89e-04 | 5.23e-01 | dH_rhoCP(0.52), r_eff(0.058), C(0.049)
cstr_0_1em8                     | cstr                 | 1 | 1em8  | 1     | 1.87e-01 | 1.54e+02 | r_eff(1.5e+02), C(1.3), dH_rhoCP(1)
cstr_1_1em6                     | cstr                 | 1 | 1em6  | 1     | 2.50e-01 | 3.42e+03 | C(3.4e+03), r_eff(3.4), dH_rhoCP(1)
cstr_2_1em2                     | cstr                 | 1 | 1em2  | 1     | 4.74e-01 | 4.35e+00 | dH_rhoCP(4.3), C(1.2), r_eff(0.54)
cstr_2_1em4                     | cstr                 | 1 | 1em4  | 1     | 2.21e-01 | 6.27e-01 | dH_rhoCP(0.63), C(0.38), r_eff(0.072)
cstr_6_1em6                     | cstr                 | 1 | 1em6  | 1     | 2.60e-01 | 5.41e+01 | r_eff(54), C(5.3), dH_rhoCP(0.89)
cstr_6_1em8                     | cstr                 | 1 | 1em8  | 1     | 2.18e-02 | 1.10e+00 | r_eff(1.1), C(0.7), dH_rhoCP(0.38)
daisy_mamil3_0_1em2             | daisy_mamil3         | 1 | 1em2  | 1     | 4.07e-01 | 7.39e-01 | a31(0.74), x3(0.51), a01(0.29)
daisy_mamil3_9_1em2             | daisy_mamil3         | 1 | 1em2  | 1     | 2.02e-01 | 6.13e-01 | a31(0.61), a13(0.17), x3(0.085)
daisy_mamil4_4_1em2             | daisy_mamil4         | 2 | 1em2  | 2     | 1.56e-01 | 1.13e+00 | x3(1.1), k41(1), x4(0.92)
daisy_mamil4_8_1em6             | daisy_mamil4         | 2 | 1em6  | 2     | 3.65e-02 | 8.49e-01 | x3(0.85), x4(0.16), k41(0.07)
fitzhugh_nagumo_1_1em2          | fitzhugh_nagumo      | 1 | 1em2  | 1     | 4.27e-01 | 1.00e+00 | b(1), a(0.36), g(0.048)
fitzhugh_nagumo_1_1em4          | fitzhugh_nagumo      | 1 | 1em4  | 1     | 2.30e-03 | 5.17e-01 | b(0.52), a(0.15), g(0.0074)
fitzhugh_nagumo_4_1em2          | fitzhugh_nagumo      | 1 | 1em2  | 1     | 4.87e-01 | 1.95e+01 | b(20), a(3.7), g(1.4)
forced_lotka_volterra_7_1em2    | forced_lotka_volterra| 1 | 1em2  | 1     | 1.27e-01 | 7.92e+00 | yv(7.9), x(1.4), gamma(0.23)
forced_lotka_volterra_7_1em4    | forced_lotka_volterra| 1 | 1em4  | 1     | 2.21e-02 | 5.06e-01 | yv(0.51), x(0.085), gamma(0.082)
lotka_volterra_6_1em2           | lotka_volterra       | 1 | 1em2  | 1     | 9.18e-03 | 3.97e+01 | w(40), k1(18), k3(0.62)
seir_1_1em6                     | seir                 | 2 | 1em6  | 2     | 1.52e-03 | 3.09e+00 | E(3.1), S(2.1), a(2)
seir_5_1em4                     | seir                 | 2 | 1em4  | 2     | 1.07e-02 | 1.37e+01 | E(14), a(3.4), S(3.4)
seir_7_1em2                     | seir                 | 2 | 1em2  | 2     | 2.42e-01 | 7.42e-01 | E(0.74), a(0.59), S(0.48)
seir_7_1em4                     | seir                 | 2 | 1em4  | 2     | 2.96e-01 | 6.05e-01 | S(0.61), E(0.46), a(0.39)
seir_8_1em4                     | seir                 | 2 | 1em4  | 2     | 4.04e-01 | 8.16e-01 | E(0.82), b(0.5), S(0.34)
sirt_treatment_3_1em2           | sirt_treatment       | 1 | 1em2  | 1     | 2.00e-01 | 2.04e+01 | a(20), S(7.4), d(0.78)
sirt_treatment_7_1em2           | sirt_treatment       | 1 | 1em2  | 1     | 2.23e-01 | 2.90e+00 | a(2.9), S(0.95), d(0.23)
sirt_treatment_9_1em4           | sirt_treatment       | 1 | 1em4  | 1     | 1.53e-02 | 7.54e+00 | a(7.5), S(0.73), d(0.58)
slow_fast_1_1em4                | slow_fast            | 2 | 1em4  | 2     | 4.01e-04 | 1.36e+00 | xA(1.4), eB(1), k2(0.9)
slow_fast_5_1em2                | slow_fast            | 2 | 1em2  | 2     | 7.84e-02 | 9.38e-01 | xA(0.94), k1(0.65), xB(0.42)
slow_fast_6_1em4                | slow_fast            | 2 | 1em4  | 2     | 1.24e-04 | 2.83e+01 | xB(28), xA(5.6), k1(3.5)
slow_fast_8_1em2                | slow_fast            | 2 | 1em2  | 2     | 1.31e-01 | 8.46e-01 | xA(0.85), k2(0.36), xB(0.26)
slow_fast_9_1em4                | slow_fast            | 2 | 1em4  | 2     | 5.22e-03 | 6.42e+00 | k1(6.4), xA(1), xB(0.9)
vanderpol_5_1em2                | vanderpol            | 1 | 1em2  | 1     | 6.65e-03 | 1.67e+00 | b(1.7), x1(0.9), x2(0.79)
vanderpol_9_1em2                | vanderpol            | 1 | 1em2  | 1     | 7.19e-03 | 1.03e+01 | x2(10), x1(0.71), b(0.59)
```

## Reproduction

Two cell-by-cell oracle comparison scripts were used (inline in chat,
both reproduce the table above). The first 3 NO_RESULT cells should be
re-evaluated once the cluster run completes; their final state will appear
in `benchmark_wallaby_2026-05-17/filetree/odepe_v2_polish_run/<cell>/`.

Key paths:
- archived original wallaby polish: `benchmark_wallaby_2026-05-17/filetree/_archive_pre_M_truncation/odepe_v2_polish_run/`
- new wallaby polish (this rerun): `benchmark_wallaby_2026-05-17/filetree/odepe_v2_polish_run/`
- numbat-06 polish: `benchmark_numbat_2026-05-06/filetree/odepe_v2_polish_run/`
- truth: `benchmark_wallaby_2026-05-17/huge_json.json[instances][*][{state_values, parameter_values}]`
- per-cell unidentifiability: `odepe_metadata.json[best][all_unidentifiable]`
