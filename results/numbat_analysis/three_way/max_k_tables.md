# Max K needed for oracle-best, by system × noise

For each cell in benchmark_numbat_2026-05-14, we sort result.csv rows by err ascending
and find the rank (1-based) of the row that minimizes max-rel-err vs truth
(excluding structurally unidentifiable axes). Each cell value below is the MAX
such rank across the 10 instances in that (system, noise) bucket.

## POLISH

| system | 0 | 1em8 | 1em6 | 1em4 | 1em2 |
|---|---:|---:|---:|---:|---:|
| aircraft_pitch | 9 | 25 | **63** | **98** | **98** |
| bicycle_model | 1 | 6 | **99** | 31 | **96** |
| biohydrogenation | 5 | **57** | **87** | **77** | 42 |
| boost_converter | 14 | 1 | 40 | **58** | **99** |
| brusselator | **60** | **97** | **80** | **62** | **85** |
| crauste | 1 | 7 | **87** | **95** | — |
| cstr | 39 | 18 | 21 | 37 | **87** |
| daisy_mamil3 | 1 | 1 | 1 | 1 | **65** |
| daisy_mamil4 | 2 | 2 | 12 | **52** | **83** |
| dc_motor | 1 | 48 | **59** | **87** | **99** |
| fitzhugh_nagumo | 1 | 1 | **52** | **52** | **87** |
| flexible_arm | 1 | 1 | 1 | 32 | **81** |
| forced_lotka_volterra | 1 | 37 | **66** | **87** | **97** |
| harmonic_oscillator | 1 | 1 | 1 | 1 | **100** |
| hiv | 1 | 6 | 23 | **76** | **95** |
| lotka_volterra | 1 | 1 | 1 | 1 | 31 |
| mass_spring_damper | 1 | 1 | 1 | 24 | **99** |
| quadrotor | 1 | 1 | 30 | **77** | **100** |
| repressilator | 1 | 1 | 1 | **72** | **89** |
| seir | 4 | 2 | **79** | **80** | **99** |
| sirt_treatment | 1 | 1 | **77** | **77** | **72** |
| slow_fast | 1 | 2 | 17 | **89** | 44 |
| vanderpol | 1 | 1 | 1 | **53** | **97** |

## NOPOLISH

| system | 0 | 1em8 | 1em6 | 1em4 | 1em2 |
|---|---:|---:|---:|---:|---:|
| aircraft_pitch | 8 | 34 | 34 | 30 | **92** |
| bicycle_model | 1 | 6 | **78** | **94** | **73** |
| biohydrogenation | 11 | **58** | 46 | **91** | **86** |
| boost_converter | 21 | 21 | 31 | 21 | **78** |
| brusselator | **58** | **94** | 22 | **81** | **85** |
| crauste | 7 | 17 | **75** | **79** | **97** |
| cstr | 33 | **81** | 23 | **100** | **87** |
| daisy_mamil3 | 1 | 7 | 44 | **93** | **74** |
| daisy_mamil4 | 2 | **85** | 38 | **89** | 43 |
| dc_motor | 1 | 34 | 47 | **93** | 30 |
| fitzhugh_nagumo | 1 | 28 | 47 | 27 | **87** |
| flexible_arm | 25 | 35 | 42 | **50** | **79** |
| forced_lotka_volterra | 1 | 31 | 34 | 9 | **91** |
| harmonic_oscillator | 1 | 1 | 1 | 1 | **84** |
| hiv | 5 | **86** | **76** | **94** | **99** |
| lotka_volterra | 1 | 4 | 12 | 29 | 32 |
| mass_spring_damper | 1 | 23 | 20 | 29 | 38 |
| quadrotor | 1 | 1 | **73** | **66** | **85** |
| repressilator | 1 | 10 | **68** | 19 | 42 |
| seir | 4 | **94** | **75** | **78** | **99** |
| sirt_treatment | 1 | 32 | 43 | 38 | **78** |
| slow_fast | 2 | 4 | **53** | **92** | 44 |
| vanderpol | 1 | 1 | 2 | 38 | **98** |


## How to read this

- **K=1** means the err-sorted top-1 row is the truth-best (polish converged tightly).
- **K=20** means the truth-near row is somewhere in the top-20; was the K cap in benchmark 13 (caused regressions).
- **K=100** is the current cap in benchmark 14. Buckets with max_K=100 are at the cap (may have lost truth-near).
- **K=200+** (we can't see past 100 since that's the cap): if the cap were higher we'd see this.

Pattern: K grows with noise. Polish dramatically reduces K (gradient-descent collapses the residual ridge to a single point).
Nopolish at low noise still needs large K because the data residual is near-flat in degenerate parameter subspaces.
