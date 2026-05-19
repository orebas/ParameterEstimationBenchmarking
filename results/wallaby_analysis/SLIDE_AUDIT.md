# Slide audit — wallaby presentation (dual-metric plan)

Audit of every slide currently in
`results/numbat_analysis/independent_analysis/presentation.html`,
with a decision on whether the wallaby version should:

- **single** — slide doesn't depend on the metric choice; one version
- **dual** — slide depends on accuracy metric; show both top-1 and best-of-K
- **drop** — slide isn't useful for the discussion meeting

## Naming convention (placeholder — pick before final build)

Two metric families per cell, per estimator:

- **Top-1 (algorithmic pick)** — score the first row of `result.csv`
  (sorted by `err` for ODEPE, single answer for AMIGO2/SHADE)
- **Best-of-K (set credit)** — argmin over all rows of `max_rel_error`
  on identifiable axes (excluding `all_unidentifiable` from metadata)

For AMIGO2 and SHADE, the two metrics are identical (K=1). For ODEPE
polish and nopolish, they can differ because K=20 with `:err` ranking
may not put the truthiest candidate at row 0.

## Slide-by-slide decisions

| # | Title (numbat) | Decision | Notes |
|---|---|---|---|
| 1 | Title / "Wallaby Benchmark (Complete)" | **single** | header only |
| 2 | Benchmark Overview / Scope | **single** | description |
| 3 | Methods | **single** | description |
| 4 | Benchmark Design / Noise Levels | **single** | config |
| 5 | Success Thresholds | **single (+expand)** | add the dual-metric definition here too, before any data slide |
| 6 | System Domains | **single** | description |
| 7 | Parameter Ranges | **single** | description |
| 8 | Data Note | **single** | mention deterministic seeds + OrdinaryDiffEq 7.0.0 byte shifts |
| 9 | **Executive Summary** | **dual** | top-line headline numbers per estimator |
| 10 | **Overall Method Comparison** | **dual** | barchart of overall success rate |
| 11 | **Success Rate vs Noise Level** | **dual** | success curves per noise |
| 12 | **Method Rankings** | **dual** | by overall success |
| 13 | **System-Level Heatmap (@50%)** | **dual** | shows system×method success |
| 14 | **System-Level Heatmap (@10%)** | **dual** | shows system×method success |
| 15 | **System-Level Heatmap (@1%)** | **dual** | shows system×method success |
| 16 | **Per-Method Breakdown (×4)** | **dual** | profile + best systems for each estimator |
| 17 | Noise Degradation Analysis | **dual** | accuracy vs noise curves |
| 18 | Method × Noise Detail | **dual** | per-cell drift |
| 19 | Noise Cliffs | **dual** | success drop between adjacent noise levels |
| 20 | Worst Noise Cliffs | **dual** | top-N worst |
| 21 | **The Polishing Effect** | **dual + commentary** | this is the slide that the metric-choice fight matters most for. Polish wins big under best-of-K, less so under top-1. |
| 22 | Polishing: Success by Noise | **dual** | barchart split |
| 23 | Polishing by Noise Level | **dual** | per-noise breakdown |
| 24 | Per-System Polishing Uplift | **dual** | per-system polish vs nopolish |
| 25 | When Does Polishing Hurt? | **dual** | cases where nopolish beats polish — interesting under both metrics; should be a centerpiece slide |
| 26 | System Difficulty Spectrum | **dual** | by aggregate success |
| 27 | Hardest & Easiest Systems | **dual** | top-N / bottom-N |
| 28 | Parameter Count vs Difficulty | **dual** | scatter |
| 29 | Full System Ranking | **dual** | long table |
| 30 | Domain Analysis | **dual** | by domain (bio / chem / control / ...) |
| 31 | Domain × Method | **dual** | per-domain heatmap |
| 32 | **Replica Stability** | **single** | spread across instances (independent of pick) |
| 33 | Error Spread by Method & Noise | **single** | distribution of all errors |
| 34 | Per-System Replica Variability | **single** | within-system spread |
| 35 | **Failure Analysis** | **single** | did the job crash? metric-independent |
| 36 | Outcome Breakdown | **single** | crashed/finished/timeout/etc. |
| 37 | **Execution Time** | **single** | wall-clock |
| 38 | Timing Statistics | **single** | wall-clock |
| 39 | Speed-Accuracy Trade-off | **dual** | accuracy axis depends on metric |
| 40 | Conclusions: Method Rankings | **dual** | summary |
| 41 | Key Takeaways | **dual + commentary** | this is the slide where the metric choice is highlighted explicitly |
| 42 | Recommendations | **single** | takeaways |
| 43 | Appendix F01-F14 | **per-figure** (see below) | |
| 44 | Thank You | **single** | |

### Appendix figures

| F# | Title | Decision |
|---|---|---|
| F01 | Success Rate vs Noise Level | **dual** |
| F02 | System × Method Heatmap | **dual** |
| F03 | System Difficulty Ranking | **dual** |
| F04 | Polishing Effect by Noise | **dual** |
| F05 | Polishing Uplift Heatmap | **dual** |
| F06 | Domain Radar Chart | **dual** |
| F07 | Replica Stability Box Plots | **single** |
| F08 | Per-System Replica Strips | **single** |
| F09 | Failure Mode Breakdown | **single** |
| F10 | Noise Cliff Heatmap | **dual** |
| F11 | Timing Comparison | **single** |
| F12 | Speed-Accuracy Scatter | **dual** |
| F13 | Param Count vs Difficulty | **dual** |
| F14 | Method Rank Distribution | **dual** |

## Slide additions specific to wallaby

These don't exist in numbat's deck; worth adding for the meeting:

1. **The metric choice** (~slide 5 or 9): one full slide spelling out the
   top-1 vs best-of-K distinction, with a worked numerical example
   (e.g., aircraft_pitch_1_1em4 where wallaby's best-of-K is 1.3e-4 and
   wallaby's top-1 is similar; vs a case where they diverge by 5×).
2. **Why this matters: local identifiability** (~slide 8): a paragraph
   on how algebraic methods naturally return multiple solutions when
   the system has local non-identifiability (multiple algebraic
   branches), and why "best of K" is theoretically defensible for some
   subset of cells but not others.
3. **5-way comparison vs prior benches** (~slide 30): wallaby vs 06 vs
   12 vs 13 vs 14 at the polish-1pct threshold. Helps situate this
   benchmark in the lineage.
4. **OrdinaryDiffEq sensitivity caveat** (~slide 35 or appendix):
   short note on the OrdinaryDiffEq 6.x → 7.0.0 bump and its impact
   on the fine-threshold polish results. Link to the investigation doc.

## Slide count estimate

- ~28 "always single" slides (intro/structure/timing/failure)
- ~22 "dual" slides → 44 actual presented slides if shown sequentially,
  or 22 if shown side-by-side or paginated

Total reveal.js slide count: ~70 on the high end. That's a lot. The
prior numbat deck is ~50-60 slides. For an internal-discussion meeting
this is probably fine.

## Implementation work needed

1. **`build_flat_metrics_wallaby.py`** — extend to compute both `top1_*`
   and `oracle_*` columns. (PR-sized change to the row-picker logic;
   currently uses `df.iloc[0]` only.)
2. **`run_analysis.py`** — for each tabular/figure output, emit a
   variant per metric. Suggest a `METRIC_VARIANTS = ["top1", "oracle"]`
   loop wrapper.
3. **`make_presentation.py`** — for "dual" slides, generate the two
   variants side-by-side or stacked. Tag each section with the metric.

Once these are in place, the same scripts will work for any future
benchmark that includes the dual-metric columns.
