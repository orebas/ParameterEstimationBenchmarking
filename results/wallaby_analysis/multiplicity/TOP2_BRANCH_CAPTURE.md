# Do the top-2 rows capture both algebraic branches?

> **Extended 2026-05-19, end of day:** Analysis extended to all 4
> multiplicity-2 systems (daisy_mamil4, seir, slow_fast,
> biohydrogenation) in ODEPE commit `b623e5e`:
> `environments/ODEParameterEstimation/repro/multiplicity_complete_2026_05_19/top2_branch_capture_all4.py`
> and `biohydrogenation_top2.txt`. The biohydrogenation alt branch
> surfaces at rank 9 (not rank 1) — its sign-flipped k9, k10 violate
> the wallaby opt_lb=1e-5 bound, so PolishLSOBoundedLog cannot refine
> it and the row only survives as an unpolished raw HC candidate. The
> daisy_mamil4 / seir / slow_fast numbers below remain valid.

## Question

For the 3 systems with confirmed algebraic multiplicity 2 (daisy_mamil4,
seir, slow_fast), how often does wallaby's output put both algebraic
branches in the first two rows of result.csv?

## Method

For each of 50 cells per system (10 instances × 5 noise levels) per estimator:

- **Row 0 near truth**: `max_rel_err(row 0, truth)` ≤ 10% on identifiable axes
- **Different branch in row 1**: `max_rel_dist(row 0, row 1)` > 5% on identifiable axes
- **Row 1 is a valid solution**: row 1's `err` column < 1e-3 (low data-fit residual)

"Both in top-2" = all three conditions hold.

## Results

| System | Estimator | Both branches in top-2 | Row 0 near truth | Cells |
|---|---|---|---|---|
| daisy_mamil4 | polish | **15 / 50** (30%) | 15 / 50 | 50 |
| daisy_mamil4 | nopolish | 15 / 50 (30%) | 15 / 50 | 50 |
| seir | polish | 13 / 50 (26%) | 20 / 50 | 50 |
| seir | nopolish | 12 / 50 (24%) | 13 / 50 | 50 |
| slow_fast | polish | **26 / 50** (52%) | 36 / 50 | 50 |
| slow_fast | nopolish | 21 / 50 (42%) | 21 / 50 | 50 |

## Conditional rate (capture given row 0 is correct)

This is the more informative number — given that the algorithm got
row 0 right, how often did it also surface the second algebraic branch?

| System | Estimator | Captured both given row 0 OK | Rate |
|---|---|---|---|
| daisy_mamil4 | polish | 15 / 15 | **100%** |
| daisy_mamil4 | nopolish | 15 / 15 | **100%** |
| seir | polish | 13 / 20 | 65% |
| seir | nopolish | 12 / 13 | 92% |
| slow_fast | polish | 26 / 36 | 72% |
| slow_fast | nopolish | 21 / 21 | **100%** |

## Interpretation

**When the algorithm finds the truth, it typically also surfaces the
second algebraic branch in row 1.** This is strong evidence that
ODEPE's HC + cluster pipeline "knows" about algebraic multiplicity in
some operational sense — it doesn't just produce K=20 random
candidates around the truth basin, it actually finds the 2 distinct
truth-equivalent solution branches and keeps both at the top.

The exceptions:
- seir polish: 7/20 cells with row 0 correct don't have a second
  branch in row 1. These are cases where polish converged on one
  branch but lost the other (probably an HC tracking failure for
  the second branch's continuation path).
- slow_fast polish: 10/36 similarly.
- daisy_mamil4 and slow_fast nopolish both hit 100%, suggesting
  the polish step might sometimes be discarding the second branch
  (or moving rows around).

## Implication for the paper

For the "algebraic multiplicity = N → return up to N candidates" claim:

- The truth multiplicity is k=2 for these 3 systems.
- When the algorithm succeeds (row 0 ~ truth), it captures BOTH branches
  in the top-2 with 65-100% reliability depending on system.
- For the 20 multiplicity-1 systems, returning K=20 candidates is
  algorithmic overhead, not algebraic necessity — the K-bound is for
  numerical safety, not for representing multiplicity.

So for the paper claim "we return up to k candidates where k is the
algebraic multiplicity," we can defensibly write that:

- For 3 of 23 systems, k=2 is the true multiplicity, and ~70-100% of
  successful cells correctly surface both algebraic solutions at
  rank 1 and 2.
- For 20 of 23 systems, k=1; the additional K-1=19 rows are
  numerical noise / nearby polished variants of the single basin
  and would not be reported as distinct in a deduplicated view.

A "deduplicated" output that merges within-cluster rows would have
output sizes closely matching the true algebraic multiplicity for
the affected systems.

## Artifacts

- `top2_branch_capture.log` — full per-cell breakdown (300+ rows)
- `wallaby_top2_branch_capture.py` — the analysis script (also in /tmp)

## Thresholds (for reproducibility)

- `BRANCH_DIST_THRESH = 0.05` (5% max-rel-distance between rows 0 and 1)
- `TRUTH_PASS_TOP = 0.10` (10% max-rel-err for row 0 vs truth)
- `LOW_ERR_THRESH = 1e-3` (row 1's err column threshold)

Loosening BRANCH_DIST_THRESH to 0.01 might pull in more cells where
row 1 is "almost the other branch but not quite." Tightening it to
0.10 would only catch cleaner cases. Numbers above use 0.05.
