# Investigation A — Success-rate drop catalog

**Comparable cell pairs**: 2283  (cells where both new and old have a finite oracle err)

## Top-line success rates

| threshold | new | old | delta (pp) |
|----------:|----:|----:|-----------:|
| 0.1% | 51.3% | 57.6% | -6.2 |
| 1% | 61.6% | 67.0% | -5.3 |
| 10% | 75.4% | 76.8% | -1.4 |
| 50% | 82.8% | 83.7% | -1.0 |

## Per-noise summary (success @ 1%)

| noise | n | new | old | delta (pp) |
|-------|--:|----:|----:|-----------:|
| 0 | 457 | 93.7% | 95.0% | -1.3 |
| 1em2 | 459 | 12.2% | 19.4% | -7.2 |
| 1em4 | 454 | 47.1% | 57.0% | -9.9 |
| 1em6 | 455 | 72.7% | 78.9% | -6.2 |
| 1em8 | 458 | 82.5% | 84.7% | -2.2 |

## Per-run summary (success @ 1%)

| run | n | new | old | delta (pp) |
|-----|--:|----:|----:|-----------:|
| odepe_v2_nopolish | 1141 | 55.6% | 61.6% | -6.0 |
| odepe_v2_polish | 1142 | 67.7% | 72.3% | -4.6 |

## Bucket-level shape (per 230 buckets)

- Buckets where new lost > 5pp at 1%: **61**
- Buckets where new won > 5pp at 1%: **2**
- Buckets within ±5pp: 167

## Top 15 most-regressed buckets (success @ 1%)

| system | run | noise | n | new | old | delta (pp) |
|--------|-----|-------|--:|----:|----:|-----------:|
| mass_spring_damper | odepe_v2_polish | 1em2 | 10 | 20% | 90% | -70 |
| aircraft_pitch | odepe_v2_nopolish | 1em4 | 10 | 30% | 90% | -60 |
| sirt_treatment | odepe_v2_polish | 1em4 | 10 | 0% | 60% | -60 |
| boost_converter | odepe_v2_polish | 1em2 | 10 | 0% | 50% | -50 |
| daisy_mamil4 | odepe_v2_nopolish | 1em6 | 10 | 30% | 70% | -40 |
| fitzhugh_nagumo | odepe_v2_nopolish | 1em6 | 10 | 60% | 100% | -40 |
| flexible_arm | odepe_v2_nopolish | 1em6 | 10 | 20% | 60% | -40 |
| quadrotor | odepe_v2_polish | 1em2 | 10 | 0% | 40% | -40 |
| seir | odepe_v2_nopolish | 1em6 | 10 | 20% | 60% | -40 |
| vanderpol | odepe_v2_nopolish | 1em2 | 10 | 50% | 90% | -40 |
| vanderpol | odepe_v2_polish | 1em2 | 10 | 60% | 100% | -40 |
| dc_motor | odepe_v2_nopolish | 1em4 | 10 | 60% | 90% | -30 |
| lotka_volterra | odepe_v2_nopolish | 1em4 | 10 | 30% | 60% | -30 |
| lotka_volterra | odepe_v2_polish | 1em2 | 10 | 30% | 60% | -30 |
| seir | odepe_v2_polish | 1em6 | 10 | 30% | 60% | -30 |

## Top 10 most-improved buckets (success @ 1%)

| system | run | noise | n | new | old | delta (pp) |
|--------|-----|-------|--:|----:|----:|-----------:|
| crauste | odepe_v2_polish | 1em6 | 10 | 20% | 10% | +10 |
| crauste | odepe_v2_polish | 1em8 | 10 | 70% | 60% | +10 |

## Flip counts (per threshold)

| threshold | regressions (old✓→new✗) | rescues (old✗→new✓) | net |
|----------:|------------------------:|--------------------:|----:|
| 0.1% | 145 | 3 | -142 |
| 1% | 125 | 3 | -122 |
| 10% | 39 | 6 | -33 |
| 50% | 29 | 7 | -22 |
