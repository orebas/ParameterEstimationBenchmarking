# Wallaby analysis preview — status

## What's ready right now

- **`build_flat_metrics_wallaby.py`** — adapted from numbat's builder; reads
  every cell's `result.csv` and emits BOTH `top1_*` and `oracle_*` metric
  families per cell. Legacy `median_rel_error`/`success_at_*pct` columns
  are kept and alias the **top-1** metric for downstream backward compat.
- **`flat_results_with_metrics.csv`** — 4600 rows (4 estimators × 1150
  cells). 4594 have `has_result=1`. The 6 with `has_result=0` are the
  hard-tail polish/nopolish cells still in SLURM at the time of build.
  Schema: 38 columns (the original 23 + 1 `n_returned` + 7 `top1_*` + 7
  `oracle_*`).
- **`independent_analysis/presentation.html`** — 5.4 MB, 70 slides,
  reveal.js. Title "Wallaby Analysis (PREVIEW)". Generated with the
  numbat scripts unchanged, so all slides currently use the TOP-1
  metric only. Figures (F01-F14) and tables (T01-T08) all regenerated.
- **`SLIDE_AUDIT.md`** — per-slide decision: which slides need dual
  versions, which stay single.
- **`INVESTIGATION_polish_regression_root_cause.md`** — companion doc
  on the polish-precision regression (soft-wall ruled out, OrdinaryDiffEq
  7.0.0 prime suspect).

## What's NOT done yet (the dual-metric work)

The current preview uses TOP-1 only. The oracle slides need:

1. **`run_analysis.py` upgrade**: have it generate per-figure / per-table
   variants for both metrics. Suggested loop:
   ```python
   for metric_family in ["top1", "oracle"]:
       suffix = "" if metric_family == "top1" else "_oracle"
       # use df[f"{metric_family}_success_at_1pct"] etc.
       # save F01{suffix}.png, T01{suffix}.csv, etc.
   ```
2. **`make_presentation.py` upgrade**: for each "dual" slide per
   `SLIDE_AUDIT.md`, emit two side-by-side `<section>` blocks (one
   per metric) or two adjacent slides with the metric in the heading.
3. **New explainer slide near slide 9**: define top-1 vs oracle with
   a worked example (e.g., `aircraft_pitch_1_1em4` where they diverge,
   plus the amigo2/shade case where they're identical by construction).

Each is ~30-60 min of work; full dual deck achievable in 2-3 hours
once metric names are picked. See `SLIDE_AUDIT.md` for the naming
shortlist.

## Re-running the preview

If the main wallaby run completes (or you want to re-render after a code
edit):

```bash
cd /pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking
source environments/venv/bin/activate

# rebuild flat_results CSV (reads the latest result.csv files)
python3 results/wallaby_analysis/build_flat_metrics_wallaby.py

# regenerate figures + tables
python3 results/wallaby_analysis/independent_analysis/run_analysis.py

# regenerate HTML deck
python3 results/wallaby_analysis/independent_analysis/make_presentation.py
```

Each step takes 10-60 seconds.

## Caveats for the meeting

- 6 cells (3 polish + 3 nopolish, the slowest crauste/bioh at low noise)
  may still be missing from this preview. Their contribution to overall
  rates is ~0.1pp at most.
- amigo2 and shade success columns are identical between top1 and oracle
  (K=1 for both). Only polish/nopolish change between the two metrics.
- The "PREVIEW" tag is in the title and on the first slide.

## Key numbers from the preview (top-1, has_result==1, n=4594)

| Estimator | s@1% | s@10% | s@50% |
|---|---|---|---|
| odepe_v2_polish | 64.9% | 75.6% | 80.6% |
| odepe_v2_nopolish | 52.9% | 61.7% | 70.1% |
| odepe_shade | 62.3% | 69.8% | 74.0% |
| amigo2 | 67.2% | 76.1% | 80.8% |

For comparison, oracle:

| Estimator | s@1% (oracle) | s@10% (oracle) | s@50% (oracle) |
|---|---|---|---|
| odepe_v2_polish | 69.0% (+4.2) | 81.3% (+5.8) | 85.9% (+5.2) |
| odepe_v2_nopolish | 57.9% (+5.0) | 69.9% (+8.2) | 79.2% (+9.1) |
| odepe_shade | 62.3% (=) | 69.8% (=) | 74.0% (=) |
| amigo2 | 67.2% (=) | 76.1% (=) | 80.8% (=) |
