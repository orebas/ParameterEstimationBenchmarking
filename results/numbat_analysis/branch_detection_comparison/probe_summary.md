# No-clustering probe results

**Setup**: 10 cells re-run with `branch_cluster_eps=1e-9` + `branch_detection=false`.
Every HC candidate becomes its own pre-polish cluster (all polished, no merging),
post-polish branch detection skipped (full polished list returned, oracle-sorted).

**Verdict legend:**
- `CLUSTERING_RECOVERED`: probe oracle-best < 1% → disabling clustering recovers truth-near candidate. **User hypothesis confirmed.**
- `PARTIAL_RECOVERY`: probe is at least 2× better than original benchmark, but still >1% off truth.
- `NO_RECOVERY`: probe is similar to original (within 2×) — clustering was NOT the dominant issue.
- `WORSE_THAN_ORIG`: probe is >2× worse than original benchmark (unexpected; possibly a different basin).

## Per-cell results

| cell | run | verdict | probe rows | probe best | orig rows | orig best | old rows | old best |
|------|-----|---------|-----------:|-----------:|----------:|----------:|---------:|---------:|
| flexible_arm_0_1em8 | polish | **CLUSTERING_RECOVERED** | 316 | 4.78e-06 | 66 | 3.78e-01 | 208 | 4.78e-06 |
| daisy_mamil4_8_1em8 | polish | **WORSE_THAN_ORIG** | 998 | 3.09e-01 | 14 | 1.49e-01 | 884 | 6.19e-03 |
| seir_3_0 | polish | **CLUSTERING_RECOVERED** | 838 | 6.11e-11 | 1 | 9.19e-02 | 895 | 3.62e-13 |
| hiv_8_0 | nopolish | **CLUSTERING_RECOVERED** | 1039 | 9.20e-06 | 5 | 1.41e-02 | 1064 | 9.20e-06 |
| biohydrogenation_2_0 | nopolish | **CLUSTERING_RECOVERED** | 1107 | 1.21e-06 | 5 | 1.10e-02 | 1106 | 1.21e-05 |
| vanderpol_6_1em2 | polish | **CLUSTERING_RECOVERED** | 189 | 2.82e-04 | 25 | 1.63e-02 | 186 | 2.82e-04 |
| quadrotor_9_1em4 | polish | **CLUSTERING_RECOVERED** | 240 | 2.75e-04 | 8 | 1.47e-02 | 240 | 2.75e-04 |
| fitzhugh_nagumo_4_1em6 | polish | **CLUSTERING_RECOVERED** | 566 | 1.59e-03 | 6 | 2.35e-02 | 556 | 1.59e-03 |
| dc_motor_4_1em4 | nopolish | **CLUSTERING_RECOVERED** | 188 | 9.42e-04 | 26 | 1.72e-02 | 193 | 9.42e-04 |
| fitzhugh_nagumo_0_1em4 | polish | **PARTIAL_RECOVERY** | 450 | 1.46e-02 | 81 | 4.20e-01 | 446 | 1.46e-02 |

## Verdict summary

- CLUSTERING_RECOVERED: **8** / 10
- WORSE_THAN_ORIG: **1** / 10
- PARTIAL_RECOVERY: **1** / 10

## Row-count blowup (clustering was doing real work)

| cell | orig rows (clustered) | probe rows (raw) | compression factor (orig/probe) |
|------|-----:|-----:|-----:|
| flexible_arm_0_1em8 | 66 | 316 | 5× |
| daisy_mamil4_8_1em8 | 14 | 998 | 71× |
| seir_3_0 | 1 | 838 | 838× |
| hiv_8_0 | 5 | 1039 | 208× |
| biohydrogenation_2_0 | 5 | 1107 | 221× |
| vanderpol_6_1em2 | 25 | 189 | 8× |
| quadrotor_9_1em4 | 8 | 240 | 30× |
| fitzhugh_nagumo_4_1em6 | 6 | 566 | 94× |
| dc_motor_4_1em4 | 26 | 188 | 7× |
| fitzhugh_nagumo_0_1em4 | 81 | 450 | 6× |
