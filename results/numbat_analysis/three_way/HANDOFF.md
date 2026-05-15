# Handoff: clustering, polish, and practical identifiability in ODEPE numbat 2026-05

This document summarizes what we learned across four numbat benchmark runs and
the resulting open questions. Audience: Claude (or future Claude) on a local
machine, working in this same repo (or a clone). Goal: be able to pick up the
clustering / polish / output-filtering investigation without re-deriving
context.

---

## Repos and versions of record

- **PEB (this repo)**: `/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking`. Master.
- **ODEPE** is a sub-repo at `environments/ODEParameterEstimation/` (its own git
  history). Main branch.
- **julia_odepe env** at `environments/julia_odepe/Manifest.toml`.
  Manifest sha256 used by both 13 and 14 reruns: `ce3fe70d3619e0b61cf00cb3c7575949884ea463df803aef270fc83c2812afb9`.
  Stack: Optim 2.0.1, ModelingToolkit 11.26, SciMLBase 3.10, OrdinaryDiffEq 7.0,
  GaussianProcesses 0.12.6 via the `orebas/GaussianProcesses.jl#optim2-compat`
  hacky fork.
- **GP fork** is mandatory until upstream GaussianProcesses patches its Optim
  use. ODEPE's `src/ODEParameterEstimation.jl` no longer reapplies its own
  ldiv! monkey-patch (the GP fork provides it; Julia 1.12 turns method-overwrite
  during precompilation into a hard error, so the override had to go).

### ODEPE commits relevant to this investigation

- `a4f5058` — pre-branch-detection. Benchmark `2026-05-06` ran on this.
- `5853a07` — ecosystem migration (NLsolve→NonlinearSolve, Optim 2 API, default ODE solver Rodas4P→Rodas5P, polish-timeout enforcement starts here)
- `216e548` — `polish_residual`: enforce `polish_maxtime` via deadline-throwing residual closure
- `91b99d7` — branch-detection candidate-reduction pipeline added (default-on)
- `6c17324` — 2026-05-13 patches: `polish_max_concurrency` bounded dispatch, `polish_maxtime` 300→3600, `branch_cluster_eps` 0.05→0.001, `branch_top_k=20`. Benchmark `2026-05-13` ran on this.
- `ed0d195` — 2026-05-14 patch: skip `_detect_branches` at output stage, take top-K of err-sorted cluster_reps directly. `branch_top_k` 20→100. Benchmark `2026-05-14` runs on this.

### Benchmark directories

All under `benchmark_numbat_<date>/`. Each has the same shape: `config/`, `filetree/<estimator>_run/<cell_id>/{script.jl, result.csv, odepe_metadata.json, stdout.txt, stderr.txt, wall_time_seconds.txt}`, plus `huge_json.json` (truth + ODE definitions), plus `MANIFEST.toml` (run lineage).

- `benchmark_numbat_2026-05-06` — original, pre-branch-detection. 2,805 CPU-hr. Median oracle 1.9e-4. Returned 500-2000 oracle-cheat-sorted rows per cell.
- `benchmark_numbat_2026-05-12` — first replacement. Median oracle 6.9e-4. 107 cells regressed. Wall time 1,081 CPU-hr (-61%). **Rejected.**
- `benchmark_numbat_2026-05-13` — third rerun with concurrency + maxtime + eps + top_k fixes. Median oracle 4.8e-4. 35 new regressions vs 12. Wall time 1,345 CPU-hr.
- `benchmark_numbat_2026-05-14` — fourth rerun with `_detect_branches` skipped at output stage and K=100. Median oracle **1.0e-4** (best of the four). Wall time ~950 CPU-hr (partial). Final cells still completing as of writeup.

---

## Pipeline (ODEPE polish path)

For each cell:

1. **SI** structural identifiability (`StructuralIdentifiability.jl` + SIAN). Detects parameter-level unidentifiability per system.
2. **HC** (HomotopyContinuation.jl) solves the polynomial system to produce raw candidates. ~50–2000 raw candidates depending on system.
3. **`synthesize_aggregate_candidates`** (`src/core/synthesize_aggregates.jl`) creates additional "aggregate" candidates from the raw HC list. Examples: median across SP candidates, per-SP per-component aggregates. Added post-`91b99d7` (commits `6914363`, `a390793`). Significantly improves coverage on practically-non-identifiable cells.
4. **Pre-polish err filter** at `_polish_cluster_metadata`: drops raw candidates with `err > branch_err_factor × min_err`. Default `branch_err_factor = 100`. **Confirmed to occasionally drop truth-near aggregates** (see flexible_arm deep dive at `results/numbat_analysis/branch_detection_comparison/flexible_arm_deepdive/`).
5. **Pre-polish clustering**: L∞-MAD on identifiable axes at `branch_cluster_eps = 0.001`. Picks one rep per cluster to polish.
6. **Polish** (`_polish_batch_from_context`, `src/core/parameter_estimation.jl`). Default `polish_method = PolishLSOBoundedLog` (Levenberg-Marquardt via `LeastSquaresOptim`). Each rep polished independently. **As of `6c17324`** uses a bounded Channel-based worker pool capped at `polish_max_concurrency = Threads.nthreads()`. Each polish has `polish_maxtime = 3600` deadline (default).
7. **Output filtering** at `analysis_utils.jl:633-642`:
   - `cluster_solutions` (analysis_utils.jl:50) dedups bit-identical convergences at `CLUSTERING_THRESHOLD = 1e-5`. Distance: `max |x-y| / (|x|+|y|+1)` over all variables (including unident). Threshold is so tight it only merges literal duplicates — does NOT collapse different basins.
   - **`_detect_branches`** (analysis_utils.jl:205) used to be applied at this stage. It clusters by L∞-MAD on identifiable axes at `branch_cluster_eps`, then filters by `branch_resid_factor` and `branch_min_size`. **Empirically over-aggressive**: drops truth-near candidates in 43% of regression cells. As of `ed0d195` it is NO LONGER applied to the user-visible output; instead we take top-K of err-sorted cluster_reps (where K = `branch_top_k`, default 100).
   - Top-K slice on err-ordered cluster_reps.
8. **Result.csv writer** in `templates/julia_template_for_estimation_odepe_v2.jl`: dumps the returned reps as rows, with `err`, `post_polish_error`, `polish_source_hc_idx`, `branch_size`, `all_unidentifiable` columns.

---

## Key findings

### 1. `Threads.@spawn` concurrency bug (fixed in `6c17324`)

In `_polish_batch_from_context` pre-`6c17324`, every cluster rep got its own `Threads.@spawn`. With ~50–200 reps per cell and 8 cores, each polish ran roughly N/T× slower than serial because ForwardDiff Jacobian assembly is heavy and contended for cores. The `polish_maxtime=300` deadline (in commit `216e548`) then fired on every polish before convergence, leaving the polished candidates stranded at random points along their gradient paths.

**Symptom in benchmark 12**: 107 cells regressed. Most had err that polish "started to fix" but stopped at the deadline.

**Fix in 13**: Channel-based bounded dispatch, capped at `Threads.nthreads()`. With 8 workers polishing 50 candidates sequentially in batches of 8, each polish now gets its CPU share and converges in ~50–100s actual work. Combined with `polish_maxtime` bumped to 3600s, the deadline almost never fires.

### 2. `_detect_branches` over-clustering (fixed in `ed0d195`)

`_detect_branches` clusters polished cluster reps by L∞-MAD-normalized distance on identifiable axes at `branch_cluster_eps`. The MAD denominator is computed from the entire surviving population. At high noise (1em2, 1em4) the population is wide, MAD is large, and the eps-relative threshold collapses near-truth and far-from-truth reps into the same cluster. The err-best of that cluster — which `_detect_branches` picks — may not be the truth-near one.

**Empirical fraction of regressions where `_detect_branches` dropped the truth-near candidate** (from `results/numbat_analysis/three_way/raw_to_polished_trace.csv`): ~43% of 23 unrecovered cells in benchmark 13 → fixed by `ed0d195`.

**Fix in 14**: skip `_detect_branches` at the output filtering stage. Just take top-K of err-sorted cluster_reps (which already come out of `cluster_solutions` in err order, since `sorted_results` is err-sorted and cluster_solutions iterates it in order). `_detect_branches` is still callable for diagnostics; just not used as the user-visible output filter.

**Offline simulation result** (`results/numbat_analysis/three_way/offline_fix_sim.csv`): on 101 regression probe cells, current 13 (clustering + top_k=20) recovers 3% within 2× of 06. fixA K=100 (no `_detect_branches` + top_k=100) recovers 77%. Increasing K past 100 gives diminishing returns (K=200 → 79%, K=500 → 80%).

### 3. Practical non-identifiability — the dominant "lots of rows" cause

For some cells, multiple parameter combinations produce nearly-identical observations. Two characteristic examples we deep-dived:

**daisy_mamil4 (the x3↔x4 subsystem)**:
- ODE has 4 compartments with rate constants `k01, k12, k13, k14, k21, k31, k41`.
- Observable: just one of the compartments (in our config, x1+x2 transitions).
- Symptom: in `daisy_mamil4_4_1em8` nopolish result.csv: x1, x2, k01, k12, k21 are identical to 4+ decimals across all 100 rows; **x3, x4, k13, k14, k31, k41 vary wildly** (x3 from 0.24 to 2.20, etc.) yet all rows have err 1e-7 to 3e-6 (only 20× spread). The data residual is essentially flat in a 6-dim subspace.
- Polish on this cell (`daisy_mamil4_4_1em8` polish): **rank 1 finds truth precisely** at err 1.47e-13, oracle 2.76e-5. Polish's gradient descent collapses the ridge to a single point.

**hiv (the vv coefficient problem)**:
- Observables: `y3 = 2000*x, y1 = 2*w, y4 = 0.002*vv + 2*yv, y2 = z`. The `vv` coefficient is 0.002.
- `vv` is barely observable. y4 is dominated by yv.
- Symptom in `hiv_2_1em8` nopolish: all other params nearly identical across rows; **vv ranges from -726 to +632** while truth is 0.272. Polish nopolish err range: 1.2e-5 to 1.2e-2.
- Polish on the same cell: rank 1 has vv=0.2703 (exact match), oracle=6.3e-3.

**Conclusion**: practical non-identifiability does NOT make a problem unsolvable — it makes the data residual flat in some directions. Polish collapses the ridge to the actual minimum (truth, by construction of the inverse problem). Without polish you get many "equally-valid" rows on the ridge.

### 4. ODE-solver-induced polish failures (column scaling)

Some systems (notably **brusselator**) have parameter regimes where the ODE is stiff oscillatory. The integrator (default `Rodas5P` in the new stack) struggles or hits `polish_ode_maxiters=20000` mid-integration, returning corrupted state. The polish loss then reports huge err on candidates that ARE close to truth.

**Concrete example**: `brusselator_6_0` (noise=0!). Truth: X=0.380, Yc=0.164, a=0.818, b=0.651.
- result.csv top-1 by err: X=0.368, a=0.769, b=0.651, err=146 (huge, for noise=0!). Most other rows have X=5959 (a complete blow-up — likely an integration explosion).
- Truth-best is at rank 60: X=0.377, a=0.912, b=0.669, oracle 0.115. Still not truth (a is 0.912 vs 0.818).
- **No row in this cell is anywhere near truth**. Raising K doesn't help.

This pattern affects 3-4 of 10 brusselator noise-free instances. It's the open `Variable (column) scaling of the polynomial system` investigation referenced at the top of `environments/ODEParameterEstimation/CLAUDE.md`. Jacobian condition numbers 1e6-1e10 at low noise drive recovery error far above what derivative accuracy alone predicts. HC.jl does Skeel row scaling automatically; ODEPE does no column scaling.

### 5. `branch_err_factor = 100` occasionally drops truth-near (deferred upstream fix)

The pre-polish err filter drops raw HC candidates with `err > 100 × min_err`. Diagnosed in `raw_to_polished_trace.csv`: 1 of 23 unrecovered cells (in benchmark 13's regression set) had a truth-near raw candidate dropped here. Widening to 1000× would let that cell's truth-near through. Not a dominant issue — but worth widening or replacing with a relative basin-of-attraction filter.

---

## Headline benchmark numbers (apples-to-apples on 2091 cells with results in all 4)

| Metric | 06 (original) | 12 (rejected) | 13 (3rd) | 14 (4th, fixA) |
|---|---|---|---|---|
| Median oracle | 8.75e-5 | 3.00e-4 | 2.44e-4 | **1.04e-4** |
| succ @ 0.1% | 61.6% | 55.5% | 58.6% | 60.8% |
| succ @ 1% | 70.5% | 65.4% | 68.4% | 69.7% |
| succ @ 10% | 79.8% | 78.8% | 77.0% | 79.0% |
| succ @ 50% | 86.4% | 85.7% | 84.6% | 85.8% |
| succ @ 100% | 93.1% | 90.8% | 89.1% | 90.9% |
| Total CPU-hr | 2124 | 927 | 1005 | **938** |
| Median wall/cell | 713s | 655s | 646s | **625s** |
| Max wall (any cell) | **35 hours** | 3.6h | 8.1h | 8.2h |
| Median n_rows returned | **339** | 2 | 16 | **100** |
| n_rows max | 2849 | 563 | 20 | 100 |

**Headline**: 14 is back to ~06 accuracy (basically tied within 1pp at every threshold; median oracle is slightly better than 06's). And wall time is 56% lower, with pathological-cell wall times capped.

---

## Open questions / future investigation

### A. Column scaling for stiff ODEs (highest impact)

The CLAUDE.md flagged this. Brusselator, biohydrogenation, and some daisy_mamil4 instances at noise-free fail polish convergence because the ODE integrator gets corrupted by ill-conditioning. Three implementation levels (lowest cost to highest):

1. Adjust ODE solver tolerances based on parameter magnitudes (cheap diagnostic).
2. Symbolic column scaling on the polynomial system before HC (medium cost).
3. Variable rescaling in the polish loss function (highest impact, biggest change).

Reference investigation: `environments/ODEParameterEstimation/docs/2026-05-01_variable_scaling_investigation.md`.

### B. Top-K parameterization vs adaptive

Current `branch_top_k = 100` covers ~all observed buckets. Two polish buckets max out exactly at K=100 (`harmonic_oscillator_1em2`, `quadrotor_1em2`) — might benefit from K=150-200, but cost is more row clutter.

User has rejected noise-adaptive K (noise level is estimated, not reliable). Fixed K=100 stays the default. The clutter problem at K=100 is mostly cosmetic — users care about row 1, the K=100 rows past rank 1-5 reflect practical non-identifiability and are honest information.

Possible alternative: **identifiability-aware deduplication**. Cluster polished outputs by their projection onto the IDENTIFIABLE subspace only (skip vv, x3-x4, etc. on cells that have them). Would collapse the 100 rows to maybe 5-10 substantively-different candidates. Requires runtime detection of practical-non-id (which the column scaling investigation will produce).

### C. `branch_err_factor` widening (low impact, easy)

The pre-polish err filter at 100× catches 1 cell out of 23 unrecovered regressions. Widening to 1000× or replacing with a relative-basin filter would close that 1. Low priority but cheap.

### D. Pre-polish clustering — do we need it?

Currently `_polish_cluster_metadata` (the pre-polish stage) uses the same `branch_cluster_eps=0.001` and similar logic to `_detect_branches`. The 3/23 unrecovered cells diagnosed as "DROPPED_BY_PRE_POLISH_CLUSTERING" had their truth-near raw HC merged with another candidate that wasn't truth-near. Polishing ALL raw HC candidates (rather than just cluster reps) would help these. Cost: ~5-10× more polishes per cell, so wall time goes up ~5-10×. Probably not worth it for 3 cells out of thousands.

### E. POLISHED_BUT_WRONG_BASIN cases (14 of 23 unrecovered)

For these cells, the best raw HC candidate WAS polished, but polish converged to a non-truth basin even from a truth-near starting point. Suggests the polish loss landscape (ODE solver + parameter scaling) has spurious local minima near truth. Likely the same underlying cause as the brusselator pathology — column scaling investigation again.

---

## Repro recipes

### Reproduce the four-way comparison

```bash
cd /pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking
source environments/venv/bin/activate
python3 results/numbat_analysis/three_way/four_way_compare.py
```

Reads from all 4 benchmark dirs, writes `accuracy_four_way.csv`.

### Reproduce the max-K-by-system-noise tables

```bash
python3 results/numbat_analysis/three_way/max_k_by_system_noise.py
```

Outputs `oracle_best_rank_per_cell.csv`, `max_k_polish.csv`, `max_k_nopolish.csv`, `max_k_tables.md`.

### Reproduce the regression-trajectory analysis

```bash
python3 results/numbat_analysis/three_way/three_way_compare.py   # 06 vs 12 vs 13
```

Outputs `regression_trajectory.csv` (cells categorized by 06→12→13 trajectory).

### Reproduce the offline fix simulation (uses probe data from 13)

```bash
python3 results/numbat_analysis/three_way/offline_fix_sim.py
```

Uses `benchmark_numbat_2026-05-13/probes/*/dump/polished_dump.csv` to simulate fix variants. Outputs `offline_fix_sim.csv` and `offline_fix_sim.md`.

### Reproduce the upstream diagnosis on unrecovered cells

```bash
python3 results/numbat_analysis/three_way/raw_to_polished_trace.py
```

Traces each unrecovered cell's best raw HC candidate through the pipeline. Outputs `raw_to_polished_trace.csv`.

### Run a fresh probe on a cell

Each probe sets `branch_top_k = 0` (disable cap) and instrumentation (`dump_polished_path`, `dump_raw_candidates_path`). Pattern:

```bash
# Create probe dir
mkdir -p benchmark_numbat_2026-05-14/probes/manual_probe/<cell_id>/
cd benchmark_numbat_2026-05-14/probes/manual_probe/<cell_id>/
ln -s ../../../filetree/odepe_v2_polish_run/<cell_id>/data.csv data.csv
# Edit script.jl from filetree, add branch_top_k=0 + dump paths
sbatch --exclude=n3 hpc/cuny/probe_one_cell.s $PWD
```

For batch probes, see `results/numbat_analysis/three_way/make_regression_probes.py` and `hpc/cuny/array_probe_regressions.s`.

---

## Specific systems to target (hardest cases by category)

| System | Hardest noise | Why | Most promising fix |
|---|---|---|---|
| brusselator | 0, 1em8 | Stiff oscillator; ODE solver corruption at certain (a,b) regimes | Column scaling (A above) |
| biohydrogenation | 0 (very slow), 1em4 (1 unrecoverable) | Stiff at noise-free; x7 is structurally non-id (state with decoupled ODE branch) | Confirm `x7(t)` is in `all_unidentifiable` (yes, ODEPE writes it). The 1em4 cell needs branch_err_factor widening |
| crauste | 1em6, 1em8 | Limit-cycle behavior, polish convergence sensitive | Investigate polish algorithm; possibly QNDF instead of Rodas5P |
| daisy_mamil4 | 1em8 | x3/x4/k13/k14/k31/k41 practical non-id subspace | Identifiability-aware dedup at output |
| hiv | 1em4 (8 cells, no polish recovery) | y4 = 0.002*vv + 2*yv (vv barely observable). At low noise, polish basin for vv is wide | Identifiability-aware dedup OR widen `branch_err_factor` |
| flexible_arm | 1em8 | Synthesized aggregate is the truth-finder; err filter drops it | Widen `branch_err_factor` |
| forced_lotka_volterra | 1em2 | Stiff with forcing term; polish basin reduced by noise | Re-test with K=200 |
| harmonic_oscillator | 1em2 | Outlier: 1 cell needs K=100 exactly | Possibly K=200 needed for the one cell; otherwise this system is trivial |
| quadrotor | 1em2 | Multiple polish basins at the cap | K=200 might recover the truth basin |

For the column scaling investigation specifically, the SHORTLIST of "absolutely needs column scaling" cells is:
- `brusselator_5_0`, `brusselator_6_0`, `brusselator_8_0` (3 of 10 noise-free instances fail polish)
- `biohydrogenation_9_0` (still running at 13h walltime — same long-tail as 13)
- `daisy_mamil4_8_1em8` (the "practical identifiability deep dive" cell from the 12 deep dives — never quite recovered to 06 quality)

---

## File inventory (analysis scripts written during this investigation)

Under `results/numbat_analysis/three_way/`:

- `three_way_compare.py` — 06 vs 12 vs 13 per-cell, aggregate, regression trajectory
- `four_way_compare.py` — extends to 14
- `max_k_by_system_noise.py` — generates the max-K tables in this doc
- `offline_fix_sim.py` — offline simulation of fix variants using polish dumps
- `upstream_diagnosis.py` — for unrecovered cells, categorize as "C_truth_not_in_raw", "B_err_filter_drops", "A_polish_or_pre_clustering_loses"
- `raw_to_polished_trace.py` — trace each cell's best raw HC through pre-polish to polished output, identify which step dropped it
- `make_regression_probes.py` — create probe dirs for 124 regression cells with instrumentation flags

Also under `results/numbat_analysis/branch_detection_comparison/` (earlier investigation, mostly 06 vs 12):

- `compare_v2_to_v1.py` — 06 vs 12 per-cell comparison
- `wall_time_aggregate.py` — wall time totals per (system, run, noise)
- `success_drop_catalog.py` — success rate drops per bucket
- `flexible_arm_deepdive/build_report.py` — system-specific deep dive (flexible_arm)
- `eps_grid.py` — 2D `(pre_eps, post_eps)` clustering parameter sweep

---

## Memory entries persisted in this session

Stored at `/scratch/oren-qc-13/.claude/projects/-pfssfs1-scratch-oren-qc-13-ParameterEstimationBenchmarking/memory/`:

- `feedback_oracle_metric_identifiability.md` — Source the `all_unidentifiable` list from `odepe_metadata.json[best]`, NOT from `huge_json[non_identifiable]` (latter is parameter-only and misses unobservable state ICs like aircraft_pitch's theta(t) or bioH's x7(t)).
- `project_oracle_ranking_cheat.md` (older) — older note about `analysis_utils.jl:426` sorting user-visible solutions by oracle key (the "cheat"). 06's row 0 was oracle-cheat-sorted. 13 and 14 are err-sorted instead.
- `cuny_broken_nodes.md` — some CUNY arrow nodes (n3, possibly others) silently kill tasks. Use `--exclude=n3` on sbatch.
