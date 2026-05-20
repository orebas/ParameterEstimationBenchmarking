# Per-cell callouts — wallaby vs 06 baseline

Generated from `accuracy_five_way.csv` (oracle metric: argmin over all
rows of result.csv on identifiable axes).

## Summary counts

- **1** catastrophic regressions (wallaby > 100% rel-error while 06 < 10%)
- **254** material regressions (wallaby ≥10× worse than 06)
- **5** missing in wallaby but completed in 06
- **16** improvements (wallaby ≥3× better than 06, with 06 above 1e-3)

## Catastrophic regressions

### aircraft_pitch
  - `aircraft_pitch_5_1em6` / `odepe_v2_nopolish`: 06=8.53e-02, wallaby=1.02e+00 (×12)

## Material regressions (≥10×)

### aircraft_pitch
  - `aircraft_pitch_6_1em6` / `odepe_v2_polish`: 06=7.66e-06, wallaby=2.91e-03 (×381)
  - `aircraft_pitch_9_0` / `odepe_v2_polish`: 06=5.30e-10, wallaby=1.18e-07 (×222)
  - `aircraft_pitch_0_1em6` / `odepe_v2_polish`: 06=6.60e-06, wallaby=9.47e-04 (×143)
  - `aircraft_pitch_6_1em8` / `odepe_v2_polish`: 06=7.66e-06, wallaby=9.60e-04 (×125)
  - `aircraft_pitch_7_1em6` / `odepe_v2_polish`: 06=3.34e-06, wallaby=3.05e-04 (×91)
  - `aircraft_pitch_9_1em6` / `odepe_v2_polish`: 06=7.74e-06, wallaby=7.07e-04 (×91)
  - `aircraft_pitch_3_1em4` / `odepe_v2_polish`: 06=4.13e-06, wallaby=3.74e-04 (×90)
  - `aircraft_pitch_3_0` / `odepe_v2_polish`: 06=2.02e-08, wallaby=1.49e-06 (×74)
  - `aircraft_pitch_3_0` / `odepe_v2_nopolish`: 06=2.02e-08, wallaby=1.49e-06 (×74)
  - `aircraft_pitch_9_0` / `odepe_v2_nopolish`: 06=5.30e-10, wallaby=3.76e-08 (×71)
  - `aircraft_pitch_8_1em6` / `odepe_v2_polish`: 06=5.26e-06, wallaby=2.53e-04 (×48)
  - `aircraft_pitch_2_1em8` / `odepe_v2_polish`: 06=2.09e-06, wallaby=9.24e-05 (×44)
  - `aircraft_pitch_8_0` / `odepe_v2_nopolish`: 06=1.63e-10, wallaby=7.16e-09 (×44)
  - `aircraft_pitch_8_0` / `odepe_v2_polish`: 06=1.63e-10, wallaby=6.57e-09 (×40)
  - `aircraft_pitch_3_1em6` / `odepe_v2_nopolish`: 06=9.87e-07, wallaby=3.88e-05 (×39)
  - `aircraft_pitch_6_1em8` / `odepe_v2_nopolish`: 06=9.05e-05, wallaby=3.28e-03 (×36)
  - `aircraft_pitch_4_1em8` / `odepe_v2_polish`: 06=3.86e-06, wallaby=1.16e-04 (×30)
  - `aircraft_pitch_2_1em6` / `odepe_v2_polish`: 06=2.09e-06, wallaby=6.23e-05 (×30)
  - `aircraft_pitch_8_1em8` / `odepe_v2_polish`: 06=3.71e-06, wallaby=9.83e-05 (×27)
  - `aircraft_pitch_5_1em8` / `odepe_v2_polish`: 06=1.96e-03, wallaby=4.92e-02 (×25)
  - `aircraft_pitch_6_1em4` / `odepe_v2_polish`: 06=3.21e-05, wallaby=7.57e-04 (×24)
  - `aircraft_pitch_8_1em2` / `odepe_v2_polish`: 06=7.70e-03, wallaby=1.44e-01 (×19)
  - `aircraft_pitch_2_1em6` / `odepe_v2_nopolish`: 06=1.92e-04, wallaby=3.58e-03 (×19)
  - `aircraft_pitch_1_1em8` / `odepe_v2_polish`: 06=3.45e-06, wallaby=6.42e-05 (×19)
  - `aircraft_pitch_4_1em8` / `odepe_v2_nopolish`: 06=5.65e-06, wallaby=9.53e-05 (×17)
  - `aircraft_pitch_9_1em2` / `odepe_v2_polish`: 06=1.73e-03, wallaby=2.70e-02 (×16)
  - `aircraft_pitch_8_1em2` / `odepe_v2_nopolish`: 06=7.70e-03, wallaby=1.19e-01 (×15)
  - `aircraft_pitch_7_1em8` / `odepe_v2_polish`: 06=3.34e-06, wallaby=4.91e-05 (×15)
  - `aircraft_pitch_3_1em6` / `odepe_v2_polish`: 06=3.66e-06, wallaby=3.88e-05 (×11)
  - `aircraft_pitch_4_1em6` / `odepe_v2_polish`: 06=3.86e-06, wallaby=3.91e-05 (×10)

### bicycle_model
  - `bicycle_model_7_1em8` / `odepe_v2_nopolish`: 06=5.63e-06, wallaby=5.37e-03 (×952)
  - `bicycle_model_7_1em8` / `odepe_v2_polish`: 06=5.63e-06, wallaby=4.07e-03 (×722)
  - `bicycle_model_5_1em4` / `odepe_v2_nopolish`: 06=1.05e-04, wallaby=7.44e-03 (×71)
  - `bicycle_model_8_1em6` / `odepe_v2_polish`: 06=1.06e-06, wallaby=4.33e-05 (×41)
  - `bicycle_model_8_1em4` / `odepe_v2_nopolish`: 06=7.55e-05, wallaby=2.47e-03 (×33)
  - `bicycle_model_0_1em4` / `odepe_v2_nopolish`: 06=6.85e-04, wallaby=1.92e-02 (×28)
  - `bicycle_model_6_1em4` / `odepe_v2_polish`: 06=8.22e-06, wallaby=1.31e-04 (×16)
  - `bicycle_model_5_1em8` / `odepe_v2_polish`: 06=4.03e-08, wallaby=4.62e-07 (×11)
  - `bicycle_model_5_1em8` / `odepe_v2_nopolish`: 06=4.03e-08, wallaby=4.62e-07 (×11)

### biohydrogenation
  - `biohydrogenation_1_0` / `odepe_v2_polish`: 06=2.76e-11, wallaby=3.16e-06 (×114771)
  - `biohydrogenation_7_0` / `odepe_v2_polish`: 06=2.23e-12, wallaby=1.28e-07 (×57301)
  - `biohydrogenation_9_0` / `odepe_v2_polish`: 06=1.73e-11, wallaby=5.04e-07 (×29072)
  - `biohydrogenation_2_0` / `odepe_v2_polish`: 06=1.08e-09, wallaby=6.08e-06 (×5605)
  - `biohydrogenation_3_0` / `odepe_v2_polish`: 06=9.16e-11, wallaby=2.13e-07 (×2329)
  - `biohydrogenation_6_0` / `odepe_v2_polish`: 06=2.48e-10, wallaby=1.92e-08 (×77)
  - `biohydrogenation_6_0` / `odepe_v2_nopolish`: 06=2.85e-06, wallaby=8.21e-05 (×29)
  - `biohydrogenation_4_0` / `odepe_v2_nopolish`: 06=4.19e-09, wallaby=9.78e-08 (×23)
  - `biohydrogenation_1_1em2` / `odepe_v2_polish`: 06=1.00e+00, wallaby=2.09e+01 (×21)
  - `biohydrogenation_0_1em8` / `odepe_v2_nopolish`: 06=1.19e-02, wallaby=2.35e-01 (×20)
  - `biohydrogenation_1_1em2` / `odepe_v2_nopolish`: 06=1.01e+00, wallaby=1.88e+01 (×19)
  - `biohydrogenation_5_0` / `odepe_v2_nopolish`: 06=4.13e-07, wallaby=4.97e-06 (×12)
  - `biohydrogenation_8_1em2` / `odepe_v2_polish`: 06=8.10e-01, wallaby=8.26e+00 (×10)

### boost_converter
  - `boost_converter_5_0` / `odepe_v2_nopolish`: 06=1.86e-08, wallaby=3.43e-06 (×185)
  - `boost_converter_5_0` / `odepe_v2_polish`: 06=1.86e-08, wallaby=1.07e-06 (×58)
  - `boost_converter_8_1em8` / `odepe_v2_nopolish`: 06=2.96e-07, wallaby=9.70e-06 (×33)
  - `boost_converter_2_1em6` / `odepe_v2_nopolish`: 06=7.58e-06, wallaby=2.09e-04 (×28)
  - `boost_converter_3_0` / `odepe_v2_polish`: 06=8.22e-10, wallaby=1.58e-08 (×19)
  - `boost_converter_1_1em8` / `odepe_v2_nopolish`: 06=7.00e-07, wallaby=1.22e-05 (×17)
  - `boost_converter_0_1em8` / `odepe_v2_nopolish`: 06=1.97e-07, wallaby=2.62e-06 (×13)
  - `boost_converter_2_1em6` / `odepe_v2_polish`: 06=5.88e-06, wallaby=7.14e-05 (×12)

### brusselator
  - `brusselator_5_0` / `odepe_v2_nopolish`: 06=2.91e+01, wallaby=6.25e+07 (×2151537)
  - `brusselator_6_1em4` / `odepe_v2_polish`: 06=1.44e+01, wallaby=8.31e+06 (×578588)
  - `brusselator_4_1em8` / `odepe_v2_nopolish`: 06=8.96e-07, wallaby=3.63e-05 (×41)
  - `brusselator_5_0` / `odepe_v2_polish`: 06=5.93e-01, wallaby=2.03e+01 (×34)
  - `brusselator_9_1em4` / `odepe_v2_polish`: 06=2.39e-04, wallaby=7.13e-03 (×30)
  - `brusselator_7_1em8` / `odepe_v2_nopolish`: 06=1.07e-03, wallaby=2.49e-02 (×23)
  - `brusselator_7_0` / `odepe_v2_polish`: 06=9.68e-11, wallaby=2.14e-09 (×22)
  - `brusselator_6_0` / `odepe_v2_nopolish`: 06=1.15e-01, wallaby=2.54e+00 (×22)
  - `brusselator_4_1em4` / `odepe_v2_polish`: 06=1.70e-03, wallaby=2.35e-02 (×14)
  - `brusselator_4_1em4` / `odepe_v2_nopolish`: 06=1.74e-03, wallaby=2.35e-02 (×14)
  - `brusselator_8_0` / `odepe_v2_polish`: 06=4.09e+00, wallaby=5.49e+01 (×13)
  - `brusselator_3_1em4` / `odepe_v2_polish`: 06=4.27e-04, wallaby=5.41e-03 (×13)
  - `brusselator_2_1em4` / `odepe_v2_polish`: 06=3.80e-03, wallaby=4.13e-02 (×11)

### crauste
  - `crauste_2_0` / `odepe_v2_nopolish`: 06=5.97e-06, wallaby=2.54e-03 (×427)
  - `crauste_8_0` / `odepe_v2_nopolish`: 06=2.30e-05, wallaby=2.03e-03 (×88)
  - `crauste_9_1em2` / `odepe_v2_nopolish`: 06=1.24e+02, wallaby=1.05e+04 (×84)
  - `crauste_0_0` / `odepe_v2_nopolish`: 06=1.99e-05, wallaby=1.13e-03 (×57)
  - `crauste_1_1em4` / `odepe_v2_nopolish`: 06=1.06e+02, wallaby=2.52e+03 (×24)
  - `crauste_8_1em4` / `odepe_v2_nopolish`: 06=1.59e+01, wallaby=2.41e+02 (×15)
  - `crauste_5_1em4` / `odepe_v2_polish`: 06=1.00e+00, wallaby=1.27e+01 (×13)
  - `crauste_1_0` / `odepe_v2_nopolish`: 06=2.55e-05, wallaby=3.24e-04 (×13)
  - `crauste_7_1em2` / `odepe_v2_nopolish`: 06=1.30e+02, wallaby=1.58e+03 (×12)
  - `crauste_5_1em2` / `odepe_v2_polish`: 06=1.00e+00, wallaby=1.20e+01 (×12)
  - `crauste_1_1em2` / `odepe_v2_polish`: 06=1.25e+00, wallaby=1.41e+01 (×11)

### cstr
  - `cstr_3_1em6` / `odepe_v2_polish`: 06=1.25e+00, wallaby=3.69e+02 (×295)
  - `cstr_6_0` / `odepe_v2_nopolish`: 06=2.49e-08, wallaby=2.52e-06 (×101)
  - `cstr_6_0` / `odepe_v2_polish`: 06=2.49e-08, wallaby=1.91e-06 (×77)
  - `cstr_0_0` / `odepe_v2_polish`: 06=1.89e-04, wallaby=4.76e-03 (×25)
  - `cstr_0_0` / `odepe_v2_nopolish`: 06=1.89e-04, wallaby=4.76e-03 (×25)
  - `cstr_1_1em6` / `odepe_v2_polish`: 06=2.50e-01, wallaby=6.29e+00 (×25)
  - `cstr_2_1em8` / `odepe_v2_nopolish`: 06=9.92e-04, wallaby=2.20e-02 (×22)
  - `cstr_6_1em8` / `odepe_v2_polish`: 06=2.18e-02, wallaby=4.09e-01 (×19)
  - `cstr_1_1em4` / `odepe_v2_nopolish`: 06=1.06e+00, wallaby=1.42e+01 (×13)
  - `cstr_0_1em4` / `odepe_v2_polish`: 06=1.06e+00, wallaby=1.32e+01 (×12)
  - `cstr_0_1em8` / `odepe_v2_polish`: 06=1.87e-01, wallaby=2.25e+00 (×12)
  - `cstr_3_1em4` / `odepe_v2_polish`: 06=1.04e+00, wallaby=1.08e+01 (×10)

### daisy_mamil3
  - `daisy_mamil3_5_0` / `odepe_v2_polish`: 06=1.68e-12, wallaby=1.78e-07 (×106359)
  - `daisy_mamil3_6_0` / `odepe_v2_polish`: 06=7.79e-14, wallaby=2.00e-09 (×25703)
  - `daisy_mamil3_4_0` / `odepe_v2_polish`: 06=4.61e-13, wallaby=2.95e-09 (×6405)
  - `daisy_mamil3_9_0` / `odepe_v2_polish`: 06=2.55e-12, wallaby=6.19e-09 (×2428)
  - `daisy_mamil3_0_0` / `odepe_v2_polish`: 06=9.93e-13, wallaby=1.24e-09 (×1253)
  - `daisy_mamil3_4_0` / `odepe_v2_nopolish`: 06=1.72e-09, wallaby=9.50e-08 (×55)
  - `daisy_mamil3_0_1em6` / `odepe_v2_nopolish`: 06=8.40e-04, wallaby=2.08e-02 (×25)
  - `daisy_mamil3_2_1em6` / `odepe_v2_nopolish`: 06=3.18e-04, wallaby=5.86e-03 (×18)
  - `daisy_mamil3_4_1em6` / `odepe_v2_nopolish`: 06=4.62e-04, wallaby=7.63e-03 (×17)
  - `daisy_mamil3_7_1em8` / `odepe_v2_nopolish`: 06=4.28e-05, wallaby=6.28e-04 (×15)
  - `daisy_mamil3_3_1em6` / `odepe_v2_nopolish`: 06=2.17e-04, wallaby=2.83e-03 (×13)
  - `daisy_mamil3_7_1em6` / `odepe_v2_nopolish`: 06=6.42e-04, wallaby=6.84e-03 (×11)
  - `daisy_mamil3_6_1em6` / `odepe_v2_nopolish`: 06=3.29e-04, wallaby=3.50e-03 (×11)
  - `daisy_mamil3_9_0` / `odepe_v2_nopolish`: 06=7.64e-09, wallaby=8.05e-08 (×11)

### daisy_mamil4
  - `daisy_mamil4_0_0` / `odepe_v2_polish`: 06=1.76e-12, wallaby=4.83e-09 (×2749)
  - `daisy_mamil4_7_0` / `odepe_v2_polish`: 06=4.05e-12, wallaby=6.35e-09 (×1570)
  - `daisy_mamil4_5_0` / `odepe_v2_polish`: 06=2.14e-12, wallaby=2.71e-09 (×1270)
  - `daisy_mamil4_4_0` / `odepe_v2_polish`: 06=1.18e-11, wallaby=7.95e-09 (×676)
  - `daisy_mamil4_1_0` / `odepe_v2_polish`: 06=1.27e-11, wallaby=5.53e-09 (×434)
  - `daisy_mamil4_9_1em8` / `odepe_v2_nopolish`: 06=9.49e-05, wallaby=6.10e-03 (×64)
  - `daisy_mamil4_7_1em8` / `odepe_v2_nopolish`: 06=4.36e-04, wallaby=1.84e-02 (×42)
  - `daisy_mamil4_4_1em6` / `odepe_v2_nopolish`: 06=1.29e-03, wallaby=2.66e-02 (×21)
  - `daisy_mamil4_2_1em6` / `odepe_v2_nopolish`: 06=3.93e-04, wallaby=7.70e-03 (×20)
  - `daisy_mamil4_8_0` / `odepe_v2_polish`: 06=1.14e-07, wallaby=2.00e-06 (×18)
  - `daisy_mamil4_8_1em8` / `odepe_v2_polish`: 06=6.19e-03, wallaby=7.11e-02 (×11)
  - `daisy_mamil4_4_1em8` / `odepe_v2_nopolish`: 06=2.25e-03, wallaby=2.32e-02 (×10)

### dc_motor
  - `dc_motor_0_1em4` / `odepe_v2_nopolish`: 06=1.34e-03, wallaby=3.23e-02 (×24)
  - `dc_motor_4_1em4` / `odepe_v2_nopolish`: 06=9.42e-04, wallaby=1.72e-02 (×18)
  - `dc_motor_2_1em6` / `odepe_v2_polish`: 06=8.44e-06, wallaby=1.40e-04 (×17)
  - `dc_motor_4_1em6` / `odepe_v2_polish`: 06=2.01e-05, wallaby=2.46e-04 (×12)

### fitzhugh_nagumo
  - `fitzhugh_nagumo_3_0` / `odepe_v2_nopolish`: 06=1.28e-08, wallaby=2.82e-05 (×2200)
  - `fitzhugh_nagumo_1_0` / `odepe_v2_polish`: 06=9.36e-12, wallaby=1.88e-08 (×2011)
  - `fitzhugh_nagumo_2_0` / `odepe_v2_polish`: 06=1.23e-11, wallaby=1.55e-08 (×1262)
  - `fitzhugh_nagumo_7_0` / `odepe_v2_polish`: 06=3.00e-12, wallaby=3.33e-09 (×1113)
  - `fitzhugh_nagumo_6_0` / `odepe_v2_polish`: 06=4.64e-12, wallaby=5.10e-09 (×1099)
  - `fitzhugh_nagumo_1_0` / `odepe_v2_nopolish`: 06=1.14e-11, wallaby=7.02e-09 (×617)
  - `fitzhugh_nagumo_3_0` / `odepe_v2_polish`: 06=3.48e-11, wallaby=1.32e-08 (×379)
  - `fitzhugh_nagumo_4_0` / `odepe_v2_polish`: 06=4.50e-11, wallaby=1.67e-08 (×372)
  - `fitzhugh_nagumo_7_0` / `odepe_v2_nopolish`: 06=2.44e-09, wallaby=6.04e-07 (×248)
  - `fitzhugh_nagumo_3_1em6` / `odepe_v2_nopolish`: 06=1.18e-04, wallaby=8.44e-03 (×71)
  - `fitzhugh_nagumo_7_1em8` / `odepe_v2_nopolish`: 06=3.35e-05, wallaby=1.54e-03 (×46)
  - `fitzhugh_nagumo_1_1em4` / `odepe_v2_polish`: 06=2.30e-03, wallaby=8.19e-02 (×36)
  - `fitzhugh_nagumo_4_1em8` / `odepe_v2_nopolish`: 06=4.35e-04, wallaby=7.65e-03 (×18)
  - `fitzhugh_nagumo_9_0` / `odepe_v2_polish`: 06=9.62e-11, wallaby=1.47e-09 (×15)
  - `fitzhugh_nagumo_4_1em6` / `odepe_v2_polish`: 06=1.59e-03, wallaby=2.35e-02 (×15)
  - `fitzhugh_nagumo_9_1em6` / `odepe_v2_nopolish`: 06=8.99e-04, wallaby=1.18e-02 (×13)
  - `fitzhugh_nagumo_4_1em6` / `odepe_v2_nopolish`: 06=1.59e-03, wallaby=1.95e-02 (×12)
  - `fitzhugh_nagumo_8_1em8` / `odepe_v2_nopolish`: 06=4.21e-05, wallaby=4.90e-04 (×12)

### flexible_arm
  - `flexible_arm_3_1em8` / `odepe_v2_nopolish`: 06=3.21e-04, wallaby=4.27e-03 (×13)

### forced_lotka_volterra
  - `forced_lotka_volterra_9_0` / `odepe_v2_nopolish`: 06=5.72e-11, wallaby=3.50e-09 (×61)
  - `forced_lotka_volterra_3_1em6` / `odepe_v2_polish`: 06=3.67e-04, wallaby=1.32e-02 (×36)
  - `forced_lotka_volterra_1_1em6` / `odepe_v2_polish`: 06=2.20e-04, wallaby=5.34e-03 (×24)
  - `forced_lotka_volterra_9_1em6` / `odepe_v2_nopolish`: 06=2.65e-04, wallaby=6.22e-03 (×23)
  - `forced_lotka_volterra_0_0` / `odepe_v2_nopolish`: 06=6.04e-10, wallaby=1.39e-08 (×23)
  - `forced_lotka_volterra_3_1em6` / `odepe_v2_nopolish`: 06=1.61e-03, wallaby=3.56e-02 (×22)
  - `forced_lotka_volterra_9_1em6` / `odepe_v2_polish`: 06=1.89e-04, wallaby=4.04e-03 (×21)
  - `forced_lotka_volterra_9_1em8` / `odepe_v2_nopolish`: 06=2.52e-05, wallaby=4.18e-04 (×17)
  - `forced_lotka_volterra_3_0` / `odepe_v2_polish`: 06=8.63e-10, wallaby=1.14e-08 (×13)
  - `forced_lotka_volterra_9_1em8` / `odepe_v2_polish`: 06=1.21e-05, wallaby=1.38e-04 (×11)
  - `forced_lotka_volterra_6_1em8` / `odepe_v2_polish`: 06=1.14e-05, wallaby=1.17e-04 (×10)

### harmonic_oscillator
  - `harmonic_oscillator_1_1em8` / `odepe_v2_nopolish`: 06=1.96e-09, wallaby=4.58e-08 (×23)
  - `harmonic_oscillator_5_1em2` / `odepe_v2_polish`: 06=2.81e-05, wallaby=3.27e-04 (×12)

### hiv
  - `hiv_6_1em2` / `odepe_v2_polish`: 06=1.00e+00, wallaby=9.67e+02 (×967)
  - `hiv_4_1em2` / `odepe_v2_nopolish`: 06=1.49e+01, wallaby=9.74e+03 (×654)
  - `hiv_0_1em2` / `odepe_v2_polish`: 06=1.00e+00, wallaby=4.35e+02 (×435)
  - `hiv_2_1em2` / `odepe_v2_nopolish`: 06=9.28e+01, wallaby=2.43e+04 (×262)
  - `hiv_3_1em2` / `odepe_v2_nopolish`: 06=9.94e+01, wallaby=2.58e+04 (×260)
  - `hiv_7_0` / `odepe_v2_nopolish`: 06=1.86e-05, wallaby=3.47e-03 (×186)
  - `hiv_2_1em4` / `odepe_v2_nopolish`: 06=1.02e+01, wallaby=1.47e+03 (×143)
  - `hiv_8_0` / `odepe_v2_nopolish`: 06=9.20e-06, wallaby=1.05e-03 (×114)
  - `hiv_9_1em2` / `odepe_v2_nopolish`: 06=2.34e+01, wallaby=2.29e+03 (×98)
  - `hiv_6_1em6` / `odepe_v2_nopolish`: 06=1.00e+00, wallaby=9.25e+01 (×92)
  - `hiv_9_1em4` / `odepe_v2_nopolish`: 06=1.15e+01, wallaby=1.05e+03 (×92)
  - `hiv_6_1em2` / `odepe_v2_nopolish`: 06=1.22e+01, wallaby=9.67e+02 (×79)
  - `hiv_0_1em4` / `odepe_v2_nopolish`: 06=9.27e+00, wallaby=6.88e+02 (×74)
  - `hiv_1_1em4` / `odepe_v2_nopolish`: 06=1.95e+00, wallaby=9.23e+01 (×47)
  - `hiv_6_0` / `odepe_v2_nopolish`: 06=4.64e-06, wallaby=2.16e-04 (×47)
  - `hiv_8_1em4` / `odepe_v2_nopolish`: 06=6.39e+01, wallaby=2.47e+03 (×39)
  - `hiv_6_1em4` / `odepe_v2_nopolish`: 06=1.77e+00, wallaby=6.48e+01 (×37)
  - `hiv_0_1em6` / `odepe_v2_nopolish`: 06=7.37e+00, wallaby=1.69e+02 (×23)
  - `hiv_1_0` / `odepe_v2_nopolish`: 06=1.36e-05, wallaby=3.10e-04 (×23)
  - `hiv_3_1em4` / `odepe_v2_nopolish`: 06=1.98e+01, wallaby=3.58e+02 (×18)
  - `hiv_4_1em6` / `odepe_v2_nopolish`: 06=2.21e+00, wallaby=3.56e+01 (×16)
  - `hiv_0_1em2` / `odepe_v2_nopolish`: 06=2.04e+01, wallaby=3.10e+02 (×15)
  - `hiv_8_1em2` / `odepe_v2_nopolish`: 06=2.98e+01, wallaby=3.89e+02 (×13)
  - `hiv_9_1em6` / `odepe_v2_nopolish`: 06=3.35e+01, wallaby=4.07e+02 (×12)
  - `hiv_6_1em8` / `odepe_v2_nopolish`: 06=1.60e-01, wallaby=1.87e+00 (×12)
  - `hiv_4_1em2` / `odepe_v2_polish`: 06=1.00e+00, wallaby=1.15e+01 (×11)
  - `hiv_1_1em8` / `odepe_v2_nopolish`: 06=2.72e-01, wallaby=3.03e+00 (×11)
  - `hiv_1_0` / `odepe_v2_polish`: 06=1.33e-09, wallaby=1.37e-08 (×10)

### lotka_volterra
  - `lotka_volterra_2_1em6` / `odepe_v2_nopolish`: 06=3.26e-04, wallaby=8.97e-03 (×27)
  - `lotka_volterra_5_0` / `odepe_v2_nopolish`: 06=2.78e-10, wallaby=4.16e-09 (×15)
  - `lotka_volterra_1_1em6` / `odepe_v2_nopolish`: 06=4.72e-04, wallaby=5.30e-03 (×11)

### mass_spring_damper
  - `mass_spring_damper_6_0` / `odepe_v2_nopolish`: 06=7.62e-12, wallaby=1.26e-08 (×1652)
  - `mass_spring_damper_3_0` / `odepe_v2_nopolish`: 06=2.01e-10, wallaby=3.63e-08 (×181)
  - `mass_spring_damper_0_1em4` / `odepe_v2_polish`: 06=3.24e-05, wallaby=1.01e-03 (×31)
  - `mass_spring_damper_2_1em4` / `odepe_v2_nopolish`: 06=1.66e-04, wallaby=2.31e-03 (×14)
  - `mass_spring_damper_3_1em6` / `odepe_v2_nopolish`: 06=1.38e-05, wallaby=1.79e-04 (×13)
  - `mass_spring_damper_4_1em2` / `odepe_v2_polish`: 06=2.95e-03, wallaby=3.32e-02 (×11)
  - `mass_spring_damper_2_1em8` / `odepe_v2_nopolish`: 06=5.89e-06, wallaby=6.29e-05 (×11)

### quadrotor
  - `quadrotor_3_1em4` / `odepe_v2_polish`: 06=1.84e-04, wallaby=5.76e-03 (×31)
  - `quadrotor_9_1em4` / `odepe_v2_polish`: 06=2.75e-04, wallaby=6.38e-03 (×23)
  - `quadrotor_7_1em8` / `odepe_v2_nopolish`: 06=1.28e-07, wallaby=2.01e-06 (×16)
  - `quadrotor_8_1em2` / `odepe_v2_polish`: 06=1.47e-02, wallaby=1.50e-01 (×10)

### repressilator
  - `repressilator_1_1em4` / `odepe_v2_polish`: 06=1.00e-04, wallaby=5.70e-03 (×57)
  - `repressilator_3_1em4` / `odepe_v2_polish`: 06=2.37e-04, wallaby=5.23e-03 (×22)
  - `repressilator_5_1em4` / `odepe_v2_polish`: 06=1.35e-04, wallaby=2.74e-03 (×20)
  - `repressilator_7_1em4` / `odepe_v2_polish`: 06=3.75e-04, wallaby=6.41e-03 (×17)
  - `repressilator_4_1em4` / `odepe_v2_polish`: 06=2.22e-04, wallaby=2.77e-03 (×12)
  - `repressilator_8_1em4` / `odepe_v2_polish`: 06=7.13e-04, wallaby=7.15e-03 (×10)

### seir
  - `seir_8_0` / `odepe_v2_polish`: 06=4.49e-10, wallaby=4.72e-05 (×104989)
  - `seir_9_0` / `odepe_v2_nopolish`: 06=2.28e-11, wallaby=1.72e-08 (×758)
  - `seir_2_0` / `odepe_v2_polish`: 06=1.23e-11, wallaby=8.50e-09 (×693)
  - `seir_5_0` / `odepe_v2_nopolish`: 06=1.83e-10, wallaby=7.23e-08 (×394)
  - `seir_6_0` / `odepe_v2_polish`: 06=8.51e-10, wallaby=2.02e-07 (×237)
  - `seir_9_1em6` / `odepe_v2_polish`: 06=1.55e-04, wallaby=1.87e-02 (×120)
  - `seir_0_1em6` / `odepe_v2_polish`: 06=8.39e-05, wallaby=5.12e-03 (×61)
  - `seir_6_1em8` / `odepe_v2_polish`: 06=8.67e-04, wallaby=4.51e-02 (×52)
  - `seir_3_1em6` / `odepe_v2_polish`: 06=4.96e-04, wallaby=2.18e-02 (×44)
  - `seir_7_0` / `odepe_v2_polish`: 06=7.85e-10, wallaby=3.18e-08 (×41)
  - `seir_9_1em6` / `odepe_v2_nopolish`: 06=6.36e-04, wallaby=1.87e-02 (×29)
  - `seir_2_1em6` / `odepe_v2_polish`: 06=4.01e-04, wallaby=1.15e-02 (×29)
  - `seir_1_1em6` / `odepe_v2_polish`: 06=1.52e-03, wallaby=2.56e-02 (×17)
  - `seir_6_1em6` / `odepe_v2_polish`: 06=1.98e-02, wallaby=2.09e-01 (×11)
  - `seir_3_1em6` / `odepe_v2_nopolish`: 06=2.14e-03, wallaby=2.18e-02 (×10)

### sirt_treatment
  - `sirt_treatment_1_1em6` / `odepe_v2_polish`: 06=9.21e-06, wallaby=3.25e-03 (×352)
  - `sirt_treatment_4_1em6` / `odepe_v2_polish`: 06=1.72e-05, wallaby=2.52e-03 (×147)
  - `sirt_treatment_0_1em6` / `odepe_v2_polish`: 06=9.87e-05, wallaby=1.22e-02 (×124)
  - `sirt_treatment_6_1em4` / `odepe_v2_polish`: 06=6.45e-04, wallaby=4.05e-02 (×63)
  - `sirt_treatment_6_1em6` / `odepe_v2_polish`: 06=5.64e-05, wallaby=2.86e-03 (×51)
  - `sirt_treatment_8_1em8` / `odepe_v2_nopolish`: 06=1.34e-05, wallaby=5.31e-04 (×40)
  - `sirt_treatment_6_1em6` / `odepe_v2_nopolish`: 06=6.00e-05, wallaby=1.95e-03 (×33)
  - `sirt_treatment_9_1em8` / `odepe_v2_nopolish`: 06=7.85e-06, wallaby=2.43e-04 (×31)
  - `sirt_treatment_8_1em6` / `odepe_v2_polish`: 06=1.98e-05, wallaby=5.81e-04 (×29)
  - `sirt_treatment_3_1em6` / `odepe_v2_polish`: 06=4.87e-05, wallaby=1.38e-03 (×28)
  - `sirt_treatment_7_1em8` / `odepe_v2_nopolish`: 06=1.68e-06, wallaby=4.63e-05 (×28)
  - `sirt_treatment_4_1em4` / `odepe_v2_polish`: 06=1.41e-03, wallaby=3.55e-02 (×25)
  - `sirt_treatment_9_1em6` / `odepe_v2_polish`: 06=5.71e-05, wallaby=1.18e-03 (×21)
  - `sirt_treatment_3_1em4` / `odepe_v2_nopolish`: 06=8.30e-03, wallaby=1.35e-01 (×16)
  - `sirt_treatment_0_1em8` / `odepe_v2_nopolish`: 06=3.42e-04, wallaby=5.27e-03 (×15)
  - `sirt_treatment_8_1em4` / `odepe_v2_polish`: 06=1.48e-03, wallaby=1.82e-02 (×12)
  - `sirt_treatment_3_1em6` / `odepe_v2_nopolish`: 06=1.16e-04, wallaby=1.35e-03 (×12)

### slow_fast
  - `slow_fast_7_1em6` / `odepe_v2_nopolish`: 06=1.03e-05, wallaby=3.25e-04 (×31)
  - `slow_fast_6_1em4` / `odepe_v2_polish`: 06=1.24e-04, wallaby=2.86e-03 (×23)
  - `slow_fast_5_1em4` / `odepe_v2_polish`: 06=5.92e-04, wallaby=7.01e-03 (×12)
  - `slow_fast_7_1em4` / `odepe_v2_polish`: 06=1.10e-03, wallaby=1.25e-02 (×11)
  - `slow_fast_7_1em4` / `odepe_v2_nopolish`: 06=1.10e-03, wallaby=1.25e-02 (×11)

### vanderpol
  - `vanderpol_0_0` / `odepe_v2_nopolish`: 06=3.14e-11, wallaby=1.04e-07 (×3313)
  - `vanderpol_5_1em4` / `odepe_v2_polish`: 06=1.52e-05, wallaby=3.80e-03 (×250)
  - `vanderpol_9_1em4` / `odepe_v2_polish`: 06=9.29e-05, wallaby=7.56e-03 (×81)
  - `vanderpol_8_1em2` / `odepe_v2_polish`: 06=5.00e-04, wallaby=2.99e-02 (×60)
  - `vanderpol_0_1em2` / `odepe_v2_polish`: 06=1.98e-04, wallaby=9.75e-03 (×49)
  - `vanderpol_9_1em6` / `odepe_v2_nopolish`: 06=1.09e-05, wallaby=5.04e-04 (×46)
  - `vanderpol_0_1em2` / `odepe_v2_nopolish`: 06=1.98e-04, wallaby=8.47e-03 (×43)
  - `vanderpol_3_1em2` / `odepe_v2_polish`: 06=2.35e-04, wallaby=9.04e-03 (×39)
  - `vanderpol_7_1em2` / `odepe_v2_polish`: 06=1.19e-05, wallaby=3.59e-04 (×30)
  - `vanderpol_4_1em2` / `odepe_v2_polish`: 06=9.29e-06, wallaby=2.81e-04 (×30)
  - `vanderpol_9_1em4` / `odepe_v2_nopolish`: 06=2.69e-04, wallaby=7.56e-03 (×28)

## Missing in wallaby

### biohydrogenation
  - `biohydrogenation_4_1em8` / `odepe_v2_polish`: 06=6.63e-06, wallaby=MISSING
  - `biohydrogenation_3_1em6` / `odepe_v2_nopolish`: 06=5.86e-02, wallaby=MISSING

### crauste
  - `crauste_2_1em4` / `odepe_v2_polish`: 06=1.00e+00, wallaby=MISSING
  - `crauste_9_0` / `odepe_v2_polish`: 06=9.19e-10, wallaby=MISSING
  - `crauste_3_1em8` / `odepe_v2_nopolish`: 06=1.34e-02, wallaby=MISSING

## Improvements (≥3×, with 06 above 1e-3)

### bicycle_model
  - `bicycle_model_7_1em4` / `odepe_v2_nopolish`: 06=1.71e-02, wallaby=5.46e-03 (×3 better)

### brusselator
  - `brusselator_6_1em6` / `odepe_v2_nopolish`: 06=2.33e+04, wallaby=4.92e+03 (×5 better)

### crauste
  - `crauste_9_1em8` / `odepe_v2_polish`: 06=1.58e-01, wallaby=7.26e-05 (×2182 better)
  - `crauste_1_1em8` / `odepe_v2_polish`: 06=4.47e-01, wallaby=2.24e-04 (×1996 better)
  - `crauste_4_1em6` / `odepe_v2_polish`: 06=1.00e+00, wallaby=2.82e-03 (×354 better)
  - `crauste_9_1em4` / `odepe_v2_nopolish`: 06=7.25e+01, wallaby=4.07e+00 (×18 better)
  - `crauste_9_1em6` / `odepe_v2_nopolish`: 06=8.13e+00, wallaby=1.91e+00 (×4 better)

### cstr
  - `cstr_3_0` / `odepe_v2_polish`: 06=9.70e-03, wallaby=4.32e-04 (×22 better)
  - `cstr_3_0` / `odepe_v2_nopolish`: 06=9.70e-03, wallaby=4.77e-04 (×20 better)
  - `cstr_7_1em8` / `odepe_v2_polish`: 06=9.91e-01, wallaby=3.29e-01 (×3 better)

### daisy_mamil4
  - `daisy_mamil4_7_1em4` / `odepe_v2_nopolish`: 06=6.96e-01, wallaby=1.61e-01 (×4 better)

### forced_lotka_volterra
  - `forced_lotka_volterra_2_1em4` / `odepe_v2_nopolish`: 06=1.29e-01, wallaby=3.93e-03 (×33 better)
  - `forced_lotka_volterra_8_1em6` / `odepe_v2_nopolish`: 06=2.57e-03, wallaby=5.13e-04 (×5 better)

### hiv
  - `hiv_5_1em8` / `odepe_v2_nopolish`: 06=7.40e-02, wallaby=8.44e-03 (×9 better)

### sirt_treatment
  - `sirt_treatment_6_1em2` / `odepe_v2_polish`: 06=3.17e-01, wallaby=4.69e-02 (×7 better)

### slow_fast
  - `slow_fast_7_1em2` / `odepe_v2_polish`: 06=9.59e-02, wallaby=1.14e-02 (×8 better)
