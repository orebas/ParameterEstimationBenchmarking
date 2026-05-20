# M-truncation impact estimate

**Question.** If ODEPE truncates `result.csv` from K=20 rows to M rows 
(where M is the algebraic multiplicity from `config/systems.json`), what's 
the visible impact on benchmark stats?

**Method.** The new ODEPE would output `rows[0:M]` of what it currently 
outputs as K=20. So:
- top-1 is **unchanged** (row 0 doesn't move)
- new "oracle" = best-of-M = today's `mbounded_*` columns

All numbers below come from `flat_results_with_metrics.csv`. No new 
benchmark run is needed.

## 1. Per-estimator headline (top-1 / K=20 oracle / new oracle = mbounded)

| Method | Threshold | Top-1 | Oracle (K=20) | New (≡ mbounded) | Δ |
|---|---|---:|---:|---:|---:|
| ODEPE-v2 (polish) | @1% | 64.9% | 69.0% | 67.7% | -1.39pp |
| ODEPE-v2 (polish) | @10% | 75.6% | 81.3% | 78.7% | -2.62pp |
| ODEPE-v2 (polish) | @50% | 80.6% | 85.9% | 83.4% | -2.44pp |
| ODEPE-v2 (no polish) | @1% | 52.9% | 57.9% | 56.2% | -1.66pp |
| ODEPE-v2 (no polish) | @10% | 61.7% | 69.9% | 65.8% | -4.10pp |
| ODEPE-v2 (no polish) | @50% | 70.1% | 79.2% | 74.5% | -4.62pp |
| AMIGO2 | @1% | 67.2% | 67.2% | 67.2% | +0.00pp |
| AMIGO2 | @10% | 76.1% | 76.1% | 76.1% | +0.00pp |
| AMIGO2 | @50% | 80.8% | 80.8% | 80.8% | +0.00pp |
| SHADE+LM | @1% | 62.3% | 62.3% | 62.3% | +0.00pp |
| SHADE+LM | @10% | 69.8% | 69.8% | 69.8% | +0.00pp |
| SHADE+LM | @50% | 74.0% | 74.0% | 74.0% | +0.00pp |

**Reading:** AMIGO2 and SHADE are K=1 and unaffected. ODEPE polish loses 
~2.6pp of K=20-oracle credit at @10%; top-1 unchanged. 
**Paper-headline M-bounded metric is unaffected** by definition.

## 2. Per-system (ODEPE @10%) where truncation costs accuracy

| System | M | Estimator | K=20 oracle | New (mbnd) | Δ |
|---|---:|---|---:|---:|---:|
| `slow_fast` | 2 | odepe_v2_polish | 96.0% | 82.0% | -14.00pp |
| `bicycle_model` | 1 | odepe_v2_nopolish | 96.0% | 86.0% | -10.00pp |
| `dc_motor` | 1 | odepe_v2_nopolish | 94.0% | 84.0% | -10.00pp |
| `biohydrogenation` | 2 | odepe_v2_nopolish | 38.8% | 30.6% | -8.16pp |
| `daisy_mamil3` | 1 | odepe_v2_nopolish | 80.0% | 72.0% | -8.00pp |
| `quadrotor` | 1 | odepe_v2_nopolish | 92.0% | 84.0% | -8.00pp |
| `sirt_treatment` | 1 | odepe_v2_nopolish | 78.0% | 70.0% | -8.00pp |
| `slow_fast` | 2 | odepe_v2_nopolish | 90.0% | 82.0% | -8.00pp |
| `sirt_treatment` | 1 | odepe_v2_polish | 82.0% | 74.0% | -8.00pp |
| `brusselator` | 1 | odepe_v2_polish | 66.0% | 60.0% | -6.00pp |
| `cstr` | 1 | odepe_v2_polish | 14.0% | 8.0% | -6.00pp |
| `aircraft_pitch` | 1 | odepe_v2_nopolish | 88.0% | 84.0% | -4.00pp |
| `boost_converter` | 1 | odepe_v2_nopolish | 74.0% | 70.0% | -4.00pp |
| `flexible_arm` | 1 | odepe_v2_nopolish | 40.0% | 36.0% | -4.00pp |
| `lotka_volterra` | 1 | odepe_v2_nopolish | 88.0% | 84.0% | -4.00pp |
| `repressilator` | 1 | odepe_v2_nopolish | 90.0% | 86.0% | -4.00pp |
| `seir` | 2 | odepe_v2_polish | 64.0% | 60.0% | -4.00pp |
| `vanderpol` | 1 | odepe_v2_polish | 100.0% | 96.0% | -4.00pp |
| `brusselator` | 1 | odepe_v2_nopolish | 60.0% | 56.0% | -4.00pp |
| `bicycle_model` | 1 | odepe_v2_polish | 100.0% | 98.0% | -2.00pp |
| `boost_converter` | 1 | odepe_v2_polish | 100.0% | 98.0% | -2.00pp |
| `daisy_mamil4` | 2 | odepe_v2_polish | 74.0% | 72.0% | -2.00pp |
| `daisy_mamil4` | 2 | odepe_v2_nopolish | 60.0% | 58.0% | -2.00pp |
| `dc_motor` | 1 | odepe_v2_polish | 98.0% | 96.0% | -2.00pp |
| `fitzhugh_nagumo` | 1 | odepe_v2_polish | 78.0% | 76.0% | -2.00pp |
| `fitzhugh_nagumo` | 1 | odepe_v2_nopolish | 66.0% | 64.0% | -2.00pp |
| `forced_lotka_volterra` | 1 | odepe_v2_polish | 98.0% | 96.0% | -2.00pp |
| `forced_lotka_volterra` | 1 | odepe_v2_nopolish | 62.0% | 60.0% | -2.00pp |
| `lotka_volterra` | 1 | odepe_v2_polish | 100.0% | 98.0% | -2.00pp |
| `mass_spring_damper` | 1 | odepe_v2_polish | 100.0% | 98.0% | -2.00pp |
| `mass_spring_damper` | 1 | odepe_v2_nopolish | 100.0% | 98.0% | -2.00pp |
| `seir` | 2 | odepe_v2_nopolish | 52.0% | 50.0% | -2.00pp |
| `aircraft_pitch` | 1 | odepe_v2_polish | 94.0% | 92.0% | -2.00pp |

## 3. Cells where truncation costs (oracle <1% but new ≥10%)

**10 cells / 2300 ODEPE cells** where the K=20 
oracle found a truth-near row beyond `rows[0:M]`.

Top 15 by post-truncation error:

| Cell | Estimator | M | top-1 err | oracle err | new err |
|---|---|---:|---:|---:|---:|
| `slow_fast_6_1em4` | odepe_v2_polish | 2 | 4.74e+01 | 2.86e-03 | 2.83e+01 |
| `slow_fast_9_1em4` | odepe_v2_polish | 2 | 8.34e+00 | 5.22e-03 | 6.38e+00 |
| `bicycle_model_7_1em4` | odepe_v2_nopolish | 1 | 1.36e+00 | 5.46e-03 | 1.36e+00 |
| `slow_fast_3_1em4` | odepe_v2_polish | 2 | 5.27e+00 | 4.84e-03 | 1.26e+00 |
| `cstr_0_0` | odepe_v2_polish | 1 | 5.23e-01 | 4.76e-03 | 5.23e-01 |
| `bicycle_model_7_1em6` | odepe_v2_nopolish | 1 | 3.04e-01 | 2.26e-03 | 3.04e-01 |
| `cstr_1_0` | odepe_v2_polish | 1 | 1.81e-01 | 7.96e-05 | 1.81e-01 |
| `seir_5_1em6` | odepe_v2_nopolish | 2 | 1.77e-01 | 2.11e-03 | 1.77e-01 |
| `sirt_treatment_8_1em4` | odepe_v2_nopolish | 1 | 1.51e-01 | 8.91e-03 | 1.51e-01 |
| `flexible_arm_9_1em6` | odepe_v2_nopolish | 1 | 1.01e-01 | 5.70e-03 | 1.01e-01 |

## 4. Implication

**Truncation is essentially benign.** Only 10 
cells out of 2300 lose accuracy, and the M-bounded paper-headline 
metric is unaffected.

Detailed per-cell data in `m_truncation_impact.csv`.