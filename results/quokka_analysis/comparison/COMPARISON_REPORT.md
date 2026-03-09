# Wombat vs Quokka Benchmark Comparison

**Generated:** 2026-03-06
**Wombat:** benchmark_wombat_2026_02_26 (23 shared systems)
**Quokka:** benchmark_quokka_2026_03_05 (23 systems)

**Note:** Different random parameter instances are used in each benchmark,
so this is a statistical comparison (not paired).

---

## Overall Success@10% by Method

| Method | Wombat | Quokka | Delta |
|--------|--------|--------|-------|
| ODEPE (polish) | 65.0% | 68.3% | +3.3 pp |
| ODEPE (no polish) | 54.8% | 60.5% | +5.8 pp |
| AMIGO2 | 71.1% | 78.5% | +7.4 pp |
| SciML | 38.4% | 39.5% | +1.1 pp |

---

## Timing Comparison

| Method | Wombat Median (s) | Quokka Median (s) | Delta (s) | Speedup |
|--------|-------------------|-------------------|-----------|---------|
| ODEPE (polish) | 327 | 2717 | +2390 | 0.12x |
| ODEPE (no polish) | 241 | 2327 | +2086 | 0.10x |
| AMIGO2 | 554 | 601 | +47 | 0.92x |
| SciML | 230 | 221 | -10 | 1.04x |

---

## Biggest Improvements (Quokka vs Wombat)

| System | Method | Wombat | Quokka | Delta |
|--------|--------|--------|--------|-------|
| fitzhugh_nagumo | SciML | 0.0% | 72.5% | +72.5 pp |
| fitzhugh_nagumo | AMIGO2 | 12.5% | 72.5% | +60.0 pp |
| fitzhugh_nagumo | ODEPE (polish) | 20.0% | 72.5% | +52.5 pp |
| fitzhugh_nagumo | ODEPE (no polish) | 20.0% | 72.5% | +52.5 pp |
| bicycle_model | ODEPE (polish) | 50.0% | 100.0% | +50.0 pp |
| bicycle_model | AMIGO2 | 50.0% | 97.5% | +47.5 pp |
| bicycle_model | ODEPE (no polish) | 47.5% | 92.5% | +45.0 pp |
| aircraft_pitch | ODEPE (no polish) | 32.5% | 75.0% | +42.5 pp |
| bicycle_model | SciML | 47.5% | 80.0% | +32.5 pp |
| forced_lotka_volterra | ODEPE (no polish) | 40.0% | 72.5% | +32.5 pp |

## Biggest Regressions (Quokka vs Wombat)

| System | Method | Wombat | Quokka | Delta |
|--------|--------|--------|--------|-------|
| daisy_mamil4 | ODEPE (no polish) | 40.0% | 7.5% | -32.5 pp |
| biohydrogenation | ODEPE (no polish) | 25.0% | 0.0% | -25.0 pp |
| brusselator | ODEPE (polish) | 70.0% | 47.5% | -22.5 pp |
| brusselator | ODEPE (no polish) | 70.0% | 47.5% | -22.5 pp |
| seir | ODEPE (no polish) | 30.0% | 7.5% | -22.5 pp |
| sirt_treatment | SciML | 62.5% | 40.0% | -22.5 pp |
| boost_converter | SciML | 32.5% | 12.5% | -20.0 pp |
| daisy_mamil4 | ODEPE (polish) | 45.0% | 25.0% | -20.0 pp |
| lotka_volterra | SciML | 42.5% | 22.5% | -20.0 pp |
| biohydrogenation | ODEPE (polish) | 22.5% | 5.0% | -17.5 pp |

---

## Method x Noise Breakdown

| Method | Noise | Wombat | Quokka | Delta |
|--------|-------|--------|--------|-------|
| ODEPE (polish) | 0 | 90.8% | 82.6% | -8.2 pp |
| ODEPE (polish) | 1e-08 | 72.3% | 76.1% | +3.8 pp |
| ODEPE (polish) | 1e-06 | 65.8% | 75.0% | +9.2 pp |
| ODEPE (polish) | 0.0001 | 57.1% | 64.7% | +7.6 pp |
| ODEPE (polish) | 0.01 | 39.1% | 42.9% | +3.8 pp |
| ODEPE (no polish) | 0 | 89.1% | 79.3% | -9.8 pp |
| ODEPE (no polish) | 1e-08 | 67.9% | 72.3% | +4.3 pp |
| ODEPE (no polish) | 1e-06 | 56.5% | 69.6% | +13.0 pp |
| ODEPE (no polish) | 0.0001 | 42.9% | 59.8% | +16.8 pp |
| ODEPE (no polish) | 0.01 | 17.4% | 21.7% | +4.3 pp |
| AMIGO2 | 0 | 84.8% | 88.6% | +3.8 pp |
| AMIGO2 | 1e-08 | 79.9% | 91.8% | +12.0 pp |
| AMIGO2 | 1e-06 | 75.5% | 87.5% | +12.0 pp |
| AMIGO2 | 0.0001 | 66.3% | 75.5% | +9.2 pp |
| AMIGO2 | 0.01 | 48.9% | 48.9% | +0.0 pp |
| SciML | 0 | 40.8% | 44.0% | +3.3 pp |
| SciML | 1e-08 | 42.9% | 45.7% | +2.7 pp |
| SciML | 1e-06 | 42.4% | 42.9% | +0.5 pp |
| SciML | 0.0001 | 37.0% | 40.2% | +3.3 pp |
| SciML | 0.01 | 28.8% | 24.5% | -4.3 pp |

---

## Summary

- **23 shared systems** compared across both benchmarks.
- Per-system deltas range from -32.5 pp to +72.5 pp.
- Mean delta across all (system, method) pairs: +4.4 pp.
- These differences reflect random sampling variation in true parameter values, not systematic changes.
