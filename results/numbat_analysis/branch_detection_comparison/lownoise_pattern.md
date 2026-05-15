# Investigation D Phase A — low-noise regression pattern

**Cells analyzed**: 12 (low-noise regressions where new is >10× worse than old, old < 0.1, new > 0.01)

## Classification summary

| classification | count | meaning |
|----------------|------:|---------|
| intermediate_only_truth_near_absent | 8 | Result.csv has candidates within 10% of truth but none within 1%. Polish or solver didn't refine far enough. |
| no_truth_near_candidate_in_list | 4 | Result.csv has NO candidate within 10% of truth. Solver/HC/pre-polish-filter failed to find truth basin. |

## Cell-level detail

| cell | run | new_best | new_row0 | old_best | n_rows | raw_count | best_idx | class |
|------|-----|---------:|---------:|---------:|-------:|----------:|---------:|-------|
| flexible_arm_0_0 | v2_polish | 6.22e-01 | 1.16e+00 | 4.45e-12 | 61 | 225 | 12 | no_truth_near_candid |
| seir_8_1em8 | v2_nopolish | 3.84e-01 | 3.96e-01 | 3.27e-02 | 84 | 1313 | 37 | no_truth_near_candid |
| flexible_arm_0_1em8 | v2_polish | 3.78e-01 | 1.16e+00 | 4.78e-06 | 66 | 224 | 2 | no_truth_near_candid |
| daisy_mamil4_8_1em8 | v2_polish | 1.49e-01 | 1.49e-01 | 6.19e-03 | 14 | 708 | 0 | no_truth_near_candid |
| seir_3_0 | v2_polish | 9.19e-02 | 9.19e-02 | 3.61e-13 | 1 | 1063 | 0 | intermediate_only_tr |
| brusselator_7_1em8 | v2_nopolish | 2.49e-02 | 2.49e-02 | 1.07e-03 | 4 | 330 | 0 | intermediate_only_tr |
| aircraft_pitch_5_1em8 | v2_polish | 2.43e-02 | 9.20e-02 | 1.96e-03 | 15 | 242 | 1 | intermediate_only_tr |
| crauste_1_0 | v2_nopolish | 2.16e-02 | 2.16e-02 | 2.55e-05 | 1 | 723 | 0 | intermediate_only_tr |
| sirt_treatment_0_1em8 | v2_nopolish | 1.79e-02 | 1.79e-02 | 3.42e-04 | 7 | 1130 | 0 | intermediate_only_tr |
| hiv_8_0 | v2_nopolish | 1.41e-02 | 1.41e-02 | 9.20e-06 | 5 | 1103 | 0 | intermediate_only_tr |
| biohydrogenation_2_0 | v2_nopolish | 1.10e-02 | 1.10e-02 | 1.21e-05 | 5 | 1239 | 0 | intermediate_only_tr |
| fitzhugh_nagumo_4_1em8 | v2_nopolish | 1.06e-02 | 1.06e-02 | 4.35e-04 | 5 | 710 | 0 | intermediate_only_tr |

## Interpretation

- If `truth_near_in_list_but_not_row0` dominates: branch detection / clustering is dropping the best candidate from row 0. Fix: tighter eps, or different cluster-rep selection. Can probably recover by re-analyzing the result.csv offline.
- If `no_truth_near_candidate_in_list` dominates: solver/HC is the problem. The pre-polish filter (or process_raw_solution under Rodas5P) is rejecting candidates that the old stack found. Cannot recover offline; need a probe re-run.
- Mix: probably both effects. Probe a representative of each class.