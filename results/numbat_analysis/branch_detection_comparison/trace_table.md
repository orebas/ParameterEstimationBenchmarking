# Where did the truth-recovering candidate go?

For each polish probe cell: find the truth-near polished output from `no_clustering` (legacy/no-err-filter), match it back to a raw HC in `deep_dump` (new pipeline), and report whether the err filter dropped it.

| cell | nc_oracle | dd_best_overall | matched_raw_hc | match_dist | raw_err | err_cap | filter | polished | dd_polish_oracle_from_matched_raw |
|------|----------:|----------------:|----------------:|-----------:|--------:|--------:|:------:|:--------:|----------------------------------:|
| flexible_arm_0_1em8 | 4.78e-06 | 5.12e-01 | 160 | 7.62e-01 | 1.87e+06 | 6.13e-02 | ✗ | ✗ | - |
| daisy_mamil4_8_1em8 | 3.09e-01 | 1.78e-01 | 512 | 5.19e-03 | 1.58e-08 | 8.31e-07 | ✓ | ✓ | 1.78e-01 |
| seir_3_0 | 6.11e-11 | 7.08e-12 | 819 | 3.03e-09 | 1.88e-10 | 4.09e-09 | ✓ | ✓ | 7.98e-09 |
| vanderpol_6_1em2 | 2.82e-04 | 2.82e-04 | 217 | 4.54e-04 | 6.75e-05 | 3.01e-03 | ✓ | ✓ | 2.82e-04 |
| quadrotor_9_1em4 | 2.75e-04 | 8.20e-04 | 94 | 7.17e-04 | 6.79e-05 | 2.76e-03 | ✓ | ✓ | 2.13e-03 |
| fitzhugh_nagumo_4_1em6 | 1.59e-03 | 2.35e-02 | 160 | 1.66e-10 | 4.09e-07 | 3.50e-06 | ✓ | ✓ | 2.35e-02 |
| fitzhugh_nagumo_0_1em4 | 1.46e-02 | 1.46e-02 | 96 | 8.88e-02 | 3.25e-06 | 3.25e-04 | ✓ | ✓ | 1.46e-02 |