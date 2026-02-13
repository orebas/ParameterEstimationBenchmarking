# Software Performance Analysis

**Dataset**: `../results/october_5_2025/result.csv`

**Analysis Date**: 2025-11-11

---

## Dataset Overview

- Total experiments: 3300
- Successful results: 2992 (90.7%)
- Software variants: 6
- Systems: 11
- Noise levels: 5

## Key Findings

### 1. Best Overall Performance: **amigo2_0_1**

   - Mean error: 0.133533
   - Success count: 548

### 2. AMIGO Search Bound Sensitivity

   - **amigo2_0_1**: 99.6% success, 0.133533 mean error
   - **amigo2_0_10**: 99.5% success, 0.500693 mean error
   - **amigo2_m100_100**: 46.5% success, 5.258876 mean error

### 3. ODEPE Multiple Solutions Analysis

   - Average candidate solutions per experiment: 42.5
   - Experiments with multiple solutions: 1044
   - **odepe**: 99.6% success, 0.408958 mean error
   - **odepe_polish**: 99.1% success, 0.396807 mean error

### 4. System Difficulty Ranking (by mean error across all software)

   1. **daisy_mamil3**: 2.243224
   2. **hiv**: 1.907676
   3. **daisy_mamil4**: 0.847153
   4. **crauste**: 0.774809
   5. **biohydrogenation**: 0.681096
   6. **seir**: 0.458453
   7. **slowfast**: 0.394013
   8. **lotka_volterra**: 0.338098
   9. **fitzhugh_nagumo**: 0.061979
   10. **harmonic**: 0.002630
   11. **vanderpol**: 0.000771

## Software Performance Comparison

### Overall Statistics by Software

| Software | Total | Success | Success Rate | Mean Error | Median Error | Mean Time (s) |
|----------|-------|---------|--------------|------------|--------------|---------------|
| amigo2_0_1      |   550 |     548 |        99.6% |   0.133533 |     0.000673 |        714.63 |
| sciml           |   550 |     548 |        99.6% |   0.148242 |     0.003841 |        222.11 |
| odepe_polish    |   550 |     545 |        99.1% |   0.396807 |     0.001056 |       1571.92 |
| odepe           |   550 |     548 |        99.6% |   0.408958 |     0.002537 |        527.57 |
| amigo2_0_10     |   550 |     547 |        99.5% |   0.500693 |     0.001417 |        706.38 |
| amigo2_m100_100 |   550 |     256 |        46.5% |   5.258876 |     0.095189 |        925.51 |

### Performance by System

**Mean Error by System and Software:**

| System | amigo2_0_1 | amigo2_0_10 | amigo2_m100_100 | odepe | odepe_polish | sciml |
|--------|------------|-------------|-----------------|-------|--------------|-------|
| biohydrogenation | 0.289509 | 1.788527 | N/A | 0.380477 | 0.376817 | 0.590490 |
| crauste | 0.134256 | 0.553681 | 1.882397 | 0.932874 | 0.973546 | 0.166340 |
| daisy_mamil3 | 0.100746 | 0.199940 | 12.319150 | 0.471326 | 0.462355 | 0.107346 |
| daisy_mamil4 | 0.354975 | 0.720363 | 1.201156 | 1.320244 | 1.238390 | 0.237944 |
| fitzhugh_nagumo | 0.030036 | 0.045807 | N/A | 0.087482 | 0.076623 | 0.070109 |
| harmonic | 0.000234 | 0.000234 | N/A | 0.000192 | 0.000177 | 0.012312 |
| hiv | 0.138319 | 0.572405 | 10.206945 | 0.203969 | 0.200274 | 0.089997 |
| lotka_volterra | 0.113361 | 0.350233 | N/A | 0.551344 | 0.547830 | 0.127724 |
| seir | 0.231702 | 0.859566 | N/A | 0.505300 | 0.496806 | 0.198892 |
| slowfast | 0.079241 | 0.443819 | 2.693232 | 0.029450 | 0.033570 | 0.035858 |
| vanderpol | 0.000927 | 0.000927 | 0.000191 | 0.000703 | 0.000697 | 0.000927 |

### Performance by Noise Level

**Mean Error by Noise Level and Software:**

| Noise | amigo2_0_1 | amigo2_0_10 | amigo2_m100_100 | odepe | odepe_polish | sciml |
|-------|------------|-------------|-----------------|-------|--------------|-------|
| 0.0 | 0.059546 | 0.271088 | 3.944122 | 0.000072 | 0.000072 | 0.078490 |
| 1e-08 | 0.071789 | 0.224037 | 3.718349 | 0.045683 | 0.048389 | 0.076037 |
| 1e-06 | 0.057891 | 0.309679 | 1.834608 | 0.302197 | 0.292413 | 0.106358 |
| 0.0001 | 0.145235 | 0.400497 | 3.979098 | 0.344435 | 0.292584 | 0.142632 |
| 0.01 | 0.334357 | 1.301190 | 13.205816 | 1.345799 | 1.357665 | 0.337260 |
