# Quokka vs Bilby Benchmark Comparison

**Generated:** 2026-03-10
**Quokka:** benchmark_quokka_2026_03_05 (23 shared systems, multiplicative noise)
**Bilby:** benchmark_bilby_2026_03_09 (23 systems, additive noise)

**Note:** Different random parameter instances and different noise models are used in each benchmark,
so this is a statistical comparison (not paired). Quokka uses multiplicative noise; Bilby uses additive noise.

---

## Overall Success@10% by Method

| Method | Quokka | Bilby | Delta |
|--------|--------|-------|-------|
| ODEPE (polish) | 68.3% | 75.3% | +7.1 pp |
| ODEPE (no polish) | 60.5% | 69.2% | +8.7 pp |
| AMIGO2 | 78.5% | 79.1% | +0.7 pp |
| SciML | 39.5% | 42.3% | +2.8 pp |

---

## Timing Comparison

| Method | Quokka Median (s) | Bilby Median (s) | Delta (s) | Speedup |
|--------|-------------------|-------------------|-----------|---------|
| ODEPE (polish) | 2717 | 3751 | +1034 | 0.72x |
| ODEPE (no polish) | 2327 | 3120 | +793 | 0.75x |
| AMIGO2 | 601 | 660 | +59 | 0.91x |
| SciML | 221 | 226 | +6 | 0.98x |

---

## Biggest Improvements (Bilby vs Quokka)

| System | Method | Quokka | Bilby | Delta |
|--------|--------|--------|-------|-------|
| biohydrogenation | ODEPE (no polish) | 0.0% | 50.0% | +50.0 pp |
| biohydrogenation | ODEPE (polish) | 5.0% | 50.0% | +45.0 pp |
| daisy_mamil4 | ODEPE (no polish) | 7.5% | 45.0% | +37.5 pp |
| seir | ODEPE (no polish) | 7.5% | 45.0% | +37.5 pp |
| daisy_mamil4 | ODEPE (polish) | 25.0% | 57.5% | +32.5 pp |
| cstr | SciML | 12.5% | 37.5% | +25.0 pp |
| seir | ODEPE (polish) | 37.5% | 55.0% | +17.5 pp |
| aircraft_pitch | ODEPE (no polish) | 75.0% | 92.5% | +17.5 pp |
| aircraft_pitch | AMIGO2 | 82.5% | 100.0% | +17.5 pp |
| aircraft_pitch | SciML | 82.5% | 100.0% | +17.5 pp |

## Biggest Regressions (Bilby vs Quokka)

| System | Method | Quokka | Bilby | Delta |
|--------|--------|--------|-------|-------|
| harmonic_oscillator | SciML | 37.5% | 27.5% | -10.0 pp |
| biohydrogenation | AMIGO2 | 50.0% | 42.5% | -7.5 pp |
| brusselator | SciML | 12.5% | 5.0% | -7.5 pp |
| seir | AMIGO2 | 62.5% | 55.0% | -7.5 pp |
| brusselator | AMIGO2 | 47.5% | 42.5% | -5.0 pp |
| flexible_arm | SciML | 60.0% | 55.0% | -5.0 pp |
| biohydrogenation | SciML | 15.0% | 12.5% | -2.5 pp |
| boost_converter | AMIGO2 | 100.0% | 97.5% | -2.5 pp |
| fitzhugh_nagumo | ODEPE (no polish) | 72.5% | 70.0% | -2.5 pp |
| forced_lotka_volterra | ODEPE (no polish) | 72.5% | 70.0% | -2.5 pp |

---

## Method x Noise Breakdown

| Method | Noise | Quokka | Bilby | Delta |
|--------|-------|--------|-------|-------|
| ODEPE (polish) | 0 | 82.6% | 95.7% | +13.0 pp |
| ODEPE (polish) | 1e-08 | 76.1% | 84.8% | +8.7 pp |
| ODEPE (polish) | 1e-06 | 75.0% | 78.8% | +3.8 pp |
| ODEPE (polish) | 0.0001 | 64.7% | 67.4% | +2.7 pp |
| ODEPE (polish) | 0.01 | 42.9% | 50.0% | +7.1 pp |
| ODEPE (no polish) | 0 | 79.3% | 95.1% | +15.8 pp |
| ODEPE (no polish) | 1e-08 | 72.3% | 83.7% | +11.4 pp |
| ODEPE (no polish) | 1e-06 | 69.6% | 76.1% | +6.5 pp |
| ODEPE (no polish) | 0.0001 | 59.8% | 62.0% | +2.2 pp |
| ODEPE (no polish) | 0.01 | 21.7% | 29.3% | +7.6 pp |
| AMIGO2 | 0 | 88.6% | 90.8% | +2.2 pp |
| AMIGO2 | 1e-08 | 91.8% | 89.7% | -2.2 pp |
| AMIGO2 | 1e-06 | 87.5% | 86.4% | -1.1 pp |
| AMIGO2 | 0.0001 | 75.5% | 75.5% | +0.0 pp |
| AMIGO2 | 0.01 | 48.9% | 53.3% | +4.3 pp |
| SciML | 0 | 44.0% | 45.7% | +1.6 pp |
| SciML | 1e-08 | 45.7% | 45.1% | -0.5 pp |
| SciML | 1e-06 | 42.9% | 48.9% | +6.0 pp |
| SciML | 0.0001 | 40.2% | 42.4% | +2.2 pp |
| SciML | 0.01 | 24.5% | 29.3% | +4.9 pp |

---

## Summary

- **23 shared systems** compared across both benchmarks.
- **Noise model difference:** Quokka uses multiplicative noise, Bilby uses additive noise.
- Per-system deltas range from -10.0 pp to +50.0 pp.
- Mean delta across all (system, method) pairs: +4.8 pp.
- Differences reflect both random sampling variation and the change in noise model.
