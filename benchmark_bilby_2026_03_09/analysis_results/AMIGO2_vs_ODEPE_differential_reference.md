# AMIGO2 vs ODEPE: Differential Instance Reference

**Benchmark:** bilby (2026-03-09)
**Tolerance:** 10% relative error on all identifiable parameters
**Runs compared:** `amigo2_run` vs `odepe_nopolish` (920 instances, 24 systems, 5 noise levels)

---

## Overall Summary

| Category | Count | % |
|----------|------:|--:|
| Both succeed | 555 | 60.3% |
| Both fail | 215 | 23.4% |
| AMIGO2 only | 118 | 12.8% |
| ODEPE only | 32 | 3.5% |

AMIGO2 has a 3.7x advantage in differentiating instances (118 vs 32). The gap widens
with increasing noise.

---

## Non-Differentiating Systems

These systems produce **identical success/failure outcomes** for both methods across
all noise levels and all 8 replicas (40 instances each):

| System | Outcome |
|--------|---------|
| **harmonic_oscillator** | Both succeed 40/40 (perfect agreement, both always solve it) |
| **vanderpol** | Both succeed 40/40 (perfect agreement, both always solve it) |

These are the simplest 2-state systems in the benchmark and are not useful for
distinguishing the methods.

---

## Systems That Barely Differentiate

These systems have only 1-2 differentiating instances total:

| System | AMIGO2-only | ODEPE-only | Both OK | Both Fail | Notes |
|--------|:-----------:|:----------:|--------:|----------:|-------|
| bicycle_model | 1 | 0 | 39 | 0 | Single edge case at 1e-2 noise |
| mass_spring_damper | 1 | 0 | 39 | 0 | Single edge case at 1e-2 noise |
| biohydrogenation | 0 | 2 | 1 | 37 | Both mostly fail; ODEPE wins 2 at low noise |

---

## Noise Level Breakdown

### Noise 0 (zero noise)

| | Count |
|--|------:|
| Both succeed | 145 (78.8%) |
| Both fail | 16 (8.7%) |
| AMIGO2 only | 7 (3.8%) |
| ODEPE only | **16 (8.7%)** |

**This is ODEPE's best noise level.** At zero noise, ODEPE actually matches AMIGO2 in
differentiating instances (16 vs 7). The GP interpolation works well with clean data.

#### AMIGO2 wins (7 instances)

**cstr** (6/8 instances): ODEPE collapses parameters `C`, `dH_rhoCP`, and `r_eff` to zero.
This is a consistent structural failure -- the GP interpolation cannot recover these
parameters from the CSTR dynamics.

| Instance | ODEPE max_err | Key failing params |
|----------|:------------:|-------------------|
| `cstr_1_0` | 1.00 | C=0, dH_rhoCP=0, r_eff=0 |
| `cstr_2_0` | 1.00 | C=0, r_eff=0 |
| `cstr_4_0` | 1.00 | C=0, dH_rhoCP=0, r_eff=0 |
| `cstr_5_0` | 1.00 | dH_rhoCP=0, r_eff=0 |
| `cstr_6_0` | 1.00 | dH_rhoCP~0, r_eff=0 |
| `cstr_7_0` | 1.00 | C=51.8%, dH_rhoCP=0, r_eff=0 |

**forced_lotka_volterra** (1/8): `forced_lotka_volterra_0_0` -- ODEPE gets beta wrong
(18.8% error) and state variables yv (26.5% error).

#### ODEPE wins (16 instances)

**daisy_mamil4** (7/8 instances): AMIGO2 consistently struggles with the k13/k14/k31/k41
parameter exchange -- it finds solutions where these parameters are permuted or swapped.
ODEPE gets all 7 perfectly (0.0% error).

| Instance | AMIGO2 max_err | Key failing params |
|----------|:--------------:|-------------------|
| `daisy_mamil4_0_0` | 1.17 | k41=117%, k13=24%, k14=19% |
| `daisy_mamil4_1_0` | 3.73 | k14=373%, k41=46%, k13=79% |
| `daisy_mamil4_2_0` | 0.32 | k31=20%, x3=32%, x4=25% |
| `daisy_mamil4_4_0` | 1.02 | k13=102%, k14=51% |
| `daisy_mamil4_5_0` | 4.55 | k41=456%, k31=82% |
| `daisy_mamil4_6_0` | 1.41 | k13=141%, k14=59% |
| `daisy_mamil4_7_0` | 0.63 | x3=63%, x4=39% |

**Suggested investigation files:**
- `filetree/odepe_nopolish/daisy_mamil4_0_0/` (ODEPE success)
- `filetree/amigo2_run/daisy_mamil4_0_0/` (AMIGO2 failure)

**seir** (3/8 instances): AMIGO2 fails on initial state estimation (S, E) and
transmission rate (b, nu). Errors up to 702%.

| Instance | AMIGO2 max_err | Key failing params |
|----------|:--------------:|-------------------|
| `seir_0_0` | 7.02 | E=702%, b=600%, S=91% |
| `seir_1_0` | 0.49 | E=42%, S=33%, nu=49% |
| `seir_5_0` | 6.01 | E=601%, S=171%, a=171% |

**brusselator** (3/8 instances): AMIGO2 struggles with the initial conditions (X, Yc).

| Instance | AMIGO2 max_err | Key failing params |
|----------|:--------------:|-------------------|
| `brusselator_0_0` | 1.08 | X=87%, Yc=108% |
| `brusselator_3_0` | 0.23 | X=23%, Yc=19%, a=16% |
| `brusselator_4_0` | 1.64 | Yc=164%, X=22% |

**aircraft_pitch** (1/8): `aircraft_pitch_5_0` -- AMIGO2 gets theta wrong (102% error).

**biohydrogenation** (1/8): `biohydrogenation_5_0` -- AMIGO2 gets x7 wrong (124% error).

**crauste** (1/8): `crauste_7_0` -- AMIGO2 gets M wrong (99%), L wrong (65%).

---

### Noise 1e-8

| | Count |
|--|------:|
| Both succeed | 134 (72.8%) |
| Both fail | 24 (13.0%) |
| AMIGO2 only | **19 (10.3%)** |
| ODEPE only | 7 (3.8%) |

**AMIGO2 starts pulling ahead.** Even tiny noise degrades ODEPE's GP interpolation.

#### AMIGO2 wins (19 instances)

- **cstr** (7/8): Same structural failure as noise=0, but now only 1/8 instance survives.
- **hiv** (6/8): Large parameter space (10+ params), ODEPE hits local optima.
  Suggested: `filetree/amigo2_run/hiv_1_1em8/` vs `filetree/odepe_nopolish/hiv_1_1em8/`
- **crauste** (4/8): ODEPE errors range from moderate (0.07 max) to catastrophic (11769 max).
- **forced_lotka_volterra** (1/8): Same instance 0 as at noise=0.
- **aircraft_pitch** (1/8): `aircraft_pitch_0_1em8`.

#### ODEPE wins (7 instances)

- **seir** (3/8): seir_1, seir_2, seir_3 -- ODEPE still handles SEIR well at tiny noise.
- **aircraft_pitch** (2/8): aircraft_pitch_1, aircraft_pitch_5.
- **brusselator** (1/8): brusselator_3 -- consistent with noise=0 win.
- **daisy_mamil4** (1/8): daisy_mamil4_4 -- ODEPE's advantage eroding (was 7/8 at noise=0).

---

### Noise 1e-6

| | Count |
|--|------:|
| Both succeed | 125 (67.9%) |
| Both fail | 32 (17.4%) |
| AMIGO2 only | **22 (12.0%)** |
| ODEPE only | 5 (2.7%) |

#### AMIGO2 wins (22 instances)

- **cstr** (7/8): Persistent.
- **crauste** (5/8): Worsening for ODEPE.
- **seir** (4/8): AMIGO2 *flips* SEIR -- was losing it at noise=0, now winning it.
  Suggested: `filetree/amigo2_run/seir_2_1em6/` vs `filetree/odepe_nopolish/seir_2_1em6/`
- **hiv** (2/8), **flexible_arm** (2/8), **forced_lotka_volterra** (1/8), **daisy_mamil4** (1/8).

#### ODEPE wins (5 instances)

- **daisy_mamil4** (2/8): Down from 7/8 at noise=0.
- **aircraft_pitch** (1/8), **biohydrogenation** (1/8), **slow_fast** (1/8).

---

### Noise 1e-4

| | Count |
|--|------:|
| Both succeed | 105 (57.1%) |
| Both fail | 52 (28.3%) |
| AMIGO2 only | **26 (14.1%)** |
| ODEPE only | **1 (0.5%)** |

**ODEPE nearly disappears as a differentiator.** Only 1 instance.

#### AMIGO2 wins (26 instances)

- **flexible_arm** (7/8): Near-total dominance. ODEPE fails with errors 0.15-1.34.
  Suggested: `filetree/amigo2_run/flexible_arm_0_1em4/` vs `filetree/odepe_nopolish/flexible_arm_0_1em4/`
- **seir** (4/8), **daisy_mamil3** (3/8), **daisy_mamil4** (3/8).
- **cstr** (2/8): Down from 7/8 because both fail on remaining instances.
- **fitzhugh_nagumo** (2/8), **sirt_treatment** (2/8).
- **brusselator** (1/8), **crauste** (1/8), **forced_lotka_volterra** (1/8).

#### ODEPE wins (1 instance)

- **slow_fast** (1/8): `slow_fast_7_1em4` -- barely (AMIGO2 max_err=0.1002, just over 10% threshold).

---

### Noise 1e-2 (highest noise)

| | Count |
|--|------:|
| Both succeed | 46 (25.0%) |
| Both fail | 91 (49.5%) |
| AMIGO2 only | **44 (23.9%)** |
| ODEPE only | 3 (1.6%) |

**AMIGO2's strongest advantage.** Nearly 1 in 4 instances are AMIGO2-only wins.
Half of all instances fail for both methods.

#### AMIGO2 wins (44 instances)

- **forced_lotka_volterra** (8/8): **Total dominance** -- AMIGO2 wins every single
  replica. ODEPE errors 0.04-3.36 while AMIGO2 stays under 0.3%.
  Suggested: Any instance, e.g. `filetree/amigo2_run/forced_lotka_volterra_0_1em2/`
- **daisy_mamil3** (6/8), **dc_motor** (5/8), **lotka_volterra** (5/8), **repressilator** (5/8).
- **boost_converter** (4/8), **quadrotor** (4/8).
- **seir** (2/8), **sirt_treatment** (2/8).
- **bicycle_model** (1/8), **mass_spring_damper** (1/8), **slow_fast** (1/8).

#### ODEPE wins (3 instances)

- **slow_fast** (2/8): slow_fast_1 and slow_fast_5.
- **daisy_mamil3** (1/8): daisy_mamil3_5.

---

## Key Differentiating Files for Investigation

These are the most informative instances to examine when comparing the two methods.

### AMIGO2's signature wins

| System | Instance | Noise | Why interesting |
|--------|----------|:-----:|-----------------|
| cstr | `cstr_1_0` | 0 | Canonical ODEPE failure: C, dH_rhoCP, r_eff collapse to 0 |
| cstr | `cstr_1_1em8` | 1e-8 | Same pattern persists with noise |
| forced_lotka_volterra | `forced_lotka_volterra_0_1em2` | 1e-2 | AMIGO2 wins 8/8 at highest noise |
| flexible_arm | `flexible_arm_0_1em4` | 1e-4 | AMIGO2 wins 7/8 |
| hiv | `hiv_1_1em8` | 1e-8 | Large system, ODEPE hits local optima |
| crauste | `crauste_3_1em8` | 1e-8 | ODEPE max_err=11769 (catastrophic) |

### ODEPE's signature wins

| System | Instance | Noise | Why interesting |
|--------|----------|:-----:|-----------------|
| daisy_mamil4 | `daisy_mamil4_1_0` | 0 | AMIGO2 permutes k13/k14/k31/k41 (max 373%) |
| seir | `seir_0_0` | 0 | AMIGO2 gets E, b wrong by 600-700% |
| brusselator | `brusselator_0_0` | 0 | AMIGO2 gets X, Yc wrong (87%, 108%) |
| slow_fast | `slow_fast_5_1em2` | 1e-2 | Rare ODEPE win at high noise |

### Noise-crossover systems (method advantage flips with noise)

| System | Low noise winner | High noise winner | Crossover |
|--------|:----------------:|:-----------------:|:---------:|
| seir | ODEPE (3/8 at 0) | AMIGO2 (4/8 at 1e-6) | ~1e-6 |
| daisy_mamil4 | ODEPE (7/8 at 0) | AMIGO2 (3/8 at 1e-4) | ~1e-6 |

These crossover systems are the most scientifically interesting -- they show where
the GP interpolation's advantage in clean-data settings gets overwhelmed by noise
sensitivity.

---

## Per-System Summary (all noise levels combined)

| System | AMIGO2-only | ODEPE-only | Both OK | Both Fail | Net advantage |
|--------|:-----------:|:----------:|--------:|----------:|:-------------:|
| cstr | **22** | 0 | 2 | 16 | AMIGO2 +22 |
| forced_lotka_volterra | **12** | 0 | 28 | 0 | AMIGO2 +12 |
| crauste | **10** | 1 | 7 | 22 | AMIGO2 +9 |
| daisy_mamil3 | **9** | 1 | 29 | 1 | AMIGO2 +8 |
| flexible_arm | **9** | 0 | 23 | 8 | AMIGO2 +9 |
| seir | **10** | 6 | 12 | 12 | AMIGO2 +4 |
| hiv | **8** | 0 | 8 | 24 | AMIGO2 +8 |
| daisy_mamil4 | 4 | **10** | 8 | 18 | ODEPE +6 |
| dc_motor | **5** | 0 | 34 | 1 | AMIGO2 +5 |
| lotka_volterra | **5** | 0 | 35 | 0 | AMIGO2 +5 |
| repressilator | **5** | 0 | 34 | 1 | AMIGO2 +5 |
| brusselator | 1 | **4** | 16 | 19 | ODEPE +3 |
| boost_converter | **4** | 0 | 35 | 1 | AMIGO2 +4 |
| quadrotor | **4** | 0 | 36 | 0 | AMIGO2 +4 |
| sirt_treatment | **4** | 0 | 30 | 6 | AMIGO2 +4 |
| aircraft_pitch | 1 | **4** | 0 | 35 | ODEPE +3 |
| slow_fast | 1 | **4** | 31 | 4 | ODEPE +3 |
| fitzhugh_nagumo | **2** | 0 | 28 | 10 | AMIGO2 +2 |
| biohydrogenation | 0 | **2** | 1 | 37 | ODEPE +2 |
| bicycle_model | 1 | 0 | 39 | 0 | AMIGO2 +1 |
| mass_spring_damper | 1 | 0 | 39 | 0 | AMIGO2 +1 |
| harmonic_oscillator | 0 | 0 | 40 | 0 | Tie (trivial) |
| vanderpol | 0 | 0 | 40 | 0 | Tie (trivial) |

**AMIGO2 advantage:** 17 systems
**ODEPE advantage:** 5 systems (daisy_mamil4, brusselator, aircraft_pitch, slow_fast, biohydrogenation)
**Tie:** 2 systems (harmonic_oscillator, vanderpol)

---

## How to Reproduce / Investigate

```bash
# Regenerate this analysis
python3 src/compare_runs.py benchmark_bilby_2026_03_09 amigo2_run odepe_nopolish

# Drill into a specific system with parameter-level detail
python3 src/compare_runs.py benchmark_bilby_2026_03_09 amigo2_run odepe_nopolish \
    --mode detail --system cstr --show-params

# Filter to a specific noise level
python3 src/compare_runs.py benchmark_bilby_2026_03_09 amigo2_run odepe_nopolish \
    --noise 0 --mode detail --show-params

# Export all comparison data as CSV
python3 src/compare_runs.py benchmark_bilby_2026_03_09 amigo2_run odepe_nopolish --mode export

# Compare with odepe_multipoint instead
python3 src/compare_runs.py benchmark_bilby_2026_03_09 amigo2_run odepe_multipoint

# Look at a specific instance's estimation script and results:
# AMIGO2 side:
#   filetree/amigo2_run/<instance_id>/script.m
#   filetree/amigo2_run/<instance_id>/stdout.txt
# ODEPE side:
#   filetree/odepe_nopolish/<instance_id>/script.jl
#   filetree/odepe_nopolish/<instance_id>/stdout.txt
#   filetree/odepe_nopolish/<instance_id>/result.csv
```

---

*Generated 2026-03-31 using `src/compare_runs.py` against bilby benchmark data.*
