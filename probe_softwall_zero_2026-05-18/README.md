# probe_softwall_zero_2026-05-18

Independent probe to test whether `polish_softwall_lambda = 1e-2` (the new
282fe1a default) is responsible for the polish-precision regressions
observed in `benchmark_wallaby_2026-05-17` vs `benchmark_numbat_2026-05-14`
and `_06`.

## Hypothesis

For 47 cells where wallaby's polish oracle is >1.5× worse than 14's at
≤1e-4 threshold, deep-dive showed wallaby's `post_polish_error` was
sometimes 4 orders of magnitude looser than 14's (e.g. bicycle_model_7_1em8
landed at 2e-2 vs 14's 3e-6). The most likely cause is the new soft-wall
regularization rows in `polish_residual.jl` (lambda=1e-2 by default,
introduced in 282fe1a).

If we set `polish_softwall_lambda = 0.0` and re-polish the same data,
oracle error should drop back to numbat-14-like levels.

## Setup

- **Cells**: 47 cells from `cells.txt`. List built by filtering wallaby's
  polish regressions vs 06 at ≤1e-4 where wallaby was >1.5× worse than 14.
- **Data**: symlinked from `benchmark_wallaby_2026-05-17/filetree/odepe_v2_polish_run/<cell>/`
  (data.csv, data.csv.sha256, cell_seed.txt).
- **Script**: copied from wallaby and modified to add
  `polish_softwall_lambda = 0.0, polish_softwall_epsilon = 0.0` to opts.
  Everything else identical to the wallaby polish run.
- **SLURM job**: `run_probe.s`. SLURM_ARRAY_TASK_ID indexes into `cells.txt`.

## Submission record

- jid 72314, --array=0-46%30, 8 CPUs/task, --time=18:00:00, --exclude=n3,n11
- Submitted 2026-05-18

## How to analyze

Compare `filetree/<cell>/result.csv` here vs the wallaby/14/06 result.csv
for the same cell. Same oracle metric (argmin max-rel-err over identifiable
axes).
