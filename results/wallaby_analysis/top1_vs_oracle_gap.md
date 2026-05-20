# Top-1 vs oracle gap analysis

Per-cell breakdown of the 2294 ODEPE polish + nopolish cells.

**Significant gap** = top-1 fails @10% (max-rel-err > 0.10) while
the oracle row passes @1% (max-rel-err < 0.01). These are cells where
the algorithm clearly had a truth-near row in the K=20 set but its
row-0 sort surfaced something far worse.

- **Total significant-gap cells:** 80 / 2294 (3.5%)
- **Cells with gap_ratio ≥ 3× and oracle < 10%:** 311 / 2294 (13.6%)

## Where does the oracle row live in result.csv? (rank distribution)

Among the significant-gap cells:

| Oracle rank | Count | % of sig-gap |
|---:|---:|---:|
| 1 | 69 | 86.2% |
| 2 | 3 | 3.8% |
| 3 | 5 | 6.2% |
| 4 | 1 | 1.2% |
| 8 | 2 | 2.5% |

- Oracle row within rows 0-2: **72/80** (90.0%)
- Oracle row within rows 0-9: **80/80** (100.0%)

## Per-system significant-gap counts

(50 cells per system per estimator = 100 per system row)

| System | Mult? | polish gaps | nopolish gaps | Total |
|---|:---:|---:|---:|---:|
| daisy_mamil4 | **2** | 19 | 11 | 30 |
| slow_fast | **2** | 6 | 20 | 26 |
| seir | **2** | 9 | 9 | 18 |
| cstr | 1 | 2 | 0 | 2 |
| bicycle_model | 1 | 0 | 2 | 2 |
| flexible_arm | 1 | 0 | 1 | 1 |
| sirt_treatment | 1 | 0 | 1 | 1 |

## Per-noise significant-gap counts

| Noise | polish gaps | nopolish gaps | Total |
|---|---:|---:|---:|
| 0 | 9 | 18 | 27 |
| 1em4 | 7 | 6 | 13 |
| 1em6 | 9 | 7 | 16 |
| 1em8 | 11 | 13 | 24 |

## Algebraic-branch breakdown (the 4 multiplicity-2 systems)

For each multiplicity-2 system, of the cells where row 0 is
significantly worse than oracle, how often was row 0 the
**alt algebraic branch** (the sign-flipped or swapped solution)?

Branch detection rules:
- **daisy_mamil4**: row 0 has (k13, k31, x3) ↔ (k14, k41, x4) swapped from truth
- **seir**: row 0 satisfies a·nu = truth's a·nu, but a is far from truth
- **slow_fast**: row 0 has k1, k2 swapped (k1*k2 preserved, ratio flipped)
- **biohydrogenation**: row 0 has k9 or k10 negative (sign-flipped from truth)

| System | Estimator | Cells | Row-0=alt-branch | Sig-gap | Sig-gap & alt | Sig-gap & not-alt |
|---|---|---:|---:|---:|---:|---:|
| biohydrogenation | odepe_v2_nopolish | 49 | 9 | 0 | 0 | 0 |
| biohydrogenation | odepe_v2_polish | 49 | 0 | 0 | 0 | 0 |
| daisy_mamil4 | odepe_v2_nopolish | 50 | 14 | 11 | 9 | 2 |
| daisy_mamil4 | odepe_v2_polish | 50 | 20 | 19 | 16 | 3 |
| seir | odepe_v2_nopolish | 50 | 15 | 9 | 7 | 2 |
| seir | odepe_v2_polish | 50 | 15 | 9 | 8 | 1 |
| slow_fast | odepe_v2_nopolish | 50 | 12 | 20 | 12 | 8 |
| slow_fast | odepe_v2_polish | 50 | 0 | 6 | 0 | 6 |

## Top 15 most extreme gap cells (largest top1/oracle ratio, oracle < 1%)

| Cell | Estimator | top1_err | oracle_err | gap_ratio | oracle_rank | row0_alt |
|---|---|---:|---:|---:|---:|:---:|
| `slow_fast_0_0` | odepe_v2_nopolish | 3.29e+01 | 3.77e-13 | ×87149951356346 | rank 1 | ✓ |
| `slow_fast_6_0` | odepe_v2_nopolish | 2.59e+01 | 7.34e-13 | ×35330085935300 | rank 1 | ✓ |
| `slow_fast_2_0` | odepe_v2_nopolish | 4.92e+01 | 2.54e-11 | ×1934662595430 | rank 1 | ✓ |
| `slow_fast_7_0` | odepe_v2_nopolish | 1.17e+00 | 7.53e-12 | ×155219438242 | rank 1 |  |
| `slow_fast_4_0` | odepe_v2_nopolish | 2.14e+00 | 2.95e-11 | ×72715955025 | rank 1 | ✓ |
| `slow_fast_8_0` | odepe_v2_nopolish | 2.59e+00 | 9.66e-11 | ×26762592007 | rank 1 |  |
| `slow_fast_9_0` | odepe_v2_nopolish | 1.80e+00 | 9.23e-11 | ×19483338840 | rank 1 | ✓ |
| `daisy_mamil4_3_0` | odepe_v2_nopolish | 4.24e+00 | 3.01e-10 | ×14091254781 | rank 1 | ✓ |
| `daisy_mamil4_3_0` | odepe_v2_polish | 4.24e+00 | 3.01e-10 | ×14089070305 | rank 1 | ✓ |
| `daisy_mamil4_2_0` | odepe_v2_nopolish | 2.98e+00 | 2.50e-10 | ×11926603070 | rank 1 |  |
| `daisy_mamil4_9_0` | odepe_v2_nopolish | 4.20e+00 | 3.76e-10 | ×11170797065 | rank 1 | ✓ |
| `daisy_mamil4_2_0` | odepe_v2_polish | 2.98e+00 | 3.16e-10 | ×9433933700 | rank 1 |  |
| `slow_fast_3_0` | odepe_v2_nopolish | 1.26e+00 | 2.17e-10 | ×5819879385 | rank 1 |  |
| `daisy_mamil4_5_0` | odepe_v2_polish | 3.52e+00 | 2.71e-09 | ×1296429572 | rank 1 | ✓ |
| `quadrotor_9_0` | odepe_v2_polish | 3.59e-04 | 3.90e-13 | ×921094438 | rank 1 |  |

## Headline answer

Drivers of the top-1 vs oracle gap, in priority order:

1. Of 80 significant-gap cells:
   - 36 are in polish, 44 are in nopolish
   - 74 are in the 4 multiplicity-2 systems
   - 52 have row 0 = the alt algebraic branch
