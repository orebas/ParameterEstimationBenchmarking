# Wallaby polish precision regression — root-cause investigation

## Status

**RESOLVED 2026-05-19** by local-claude in ODEPE commit `84553a3`
("Revert rank_strategy default to :err_only — fixes wallaby polish regression").

**Actual root cause:** the `is_neg1` secondary key in the S2 sort
(`rank_strategy = :sat_neg1_err`, the new default in 282fe1a)
systematically demoted truth-near rows with `polish_source_hc_idx = -1`
(synthesized aggregates / multipoint candidates / fallback rescues)
below worse HC-tagged rows. The 282fe1a pipeline (with soft-wall +
identifiable-subspace clustering) produces more psh=-1 rows than 14
did, so the heuristic flipped from benign tiebreaker to active
truth-suppressor.

**Fix:** default `rank_strategy` reverted to `:err_only`. A new opt-in
`:sat_err` (saturation-demotion without is_neg1) added for callers
who specifically want the bound-saturation demotion without the
multipoint/aggregate demotion.

**My investigation doc was wrong about the prime suspect.** I claimed
OrdinaryDiffEq 6.x → 7.0.0 was the most likely cause based on the
bicycle_model_7_1em8 polish-residual plateau. But: numbat-14 already
had OrdinaryDiffEq 7.0.0 (per PEB 272f64319's Manifest.toml). The
6→7 bump happened pre-14, not into wallaby. My Pkg.update version-diff
list confused "what's in wallaby's manifest" with "what changed from
14 to wallaby" — only SciMLBase 3.10→3.13, MTK 11.26.0→11.26.3,
LinearSolve 3.76.0→3.80.0, Symbolics 7.22.0→7.24.0 actually changed
between 14 and wallaby; OrdinaryDiffEq was unchanged.

Local-claude tested this directly with two controlled envs:
- `env_ode6`: OrdinaryDiffEq 6.111 + 282fe1a source → 3.5e-4 (still bad)
- `env_n14`: exact 14 Manifest + 282fe1a source → 3.5e-4 (still bad)

Then the smoking gun: inspecting env_n14's result.csv for
bicycle_model_7_1em8 showed the truth-near row (err=1.65e-7, psh=-1)
existed at **rank 4**, but S2 surfaced a worse HC-tagged row
(err=3.46e-4, psh=69) at rank 1.

## Offline scheme survey (1147 wallaby polish cells)

| Scheme | ≤1e-9 | ≤1e-4 | ≤1e-3 | ≤0.1 |
|---|---|---|---|---|
| `:err_only` (new default) | **36.3%** | **69.7%** | **79.3%** | **87.0%** |
| `:sat_err` (new opt-in) | 36.3% | 69.6% | 78.6% | 84.8% |
| `:sat_neg1_err` (was 282fe1a default) | 32.2% | 60.2% | 67.9% | 77.9% |

S2 was -9.5pp at ≤1e-4 and -11.4pp at ≤1e-3 vs err_only on the wallaby
candidate distribution. The fix recovers all of that gap by changing
the sort, no re-running needed in principle (the truth-near rows are
already in result.csv at rank 2-20 for the affected cells).

## What this means for the wallaby paper deck

The wallaby result.csv files contain 20 rows per polish cell, with
the `err` column and (per local-claude's offline survey) enough
information to compute the corrected rank-1 selection offline. The
dual-metric build (see `SLIDE_AUDIT.md`) should add a third metric
variant: **post-fix rank-1** = lowest-err row from wallaby's existing
top-20 — which simulates what the fix shipped in ODEPE 84553a3 would
produce. This is a single-Python-pass change, no rerun needed.

The three metric variants for the deck:
1. **Top-1 as-shipped (S2)** — what wallaby actually surfaced as rank 1.
   The numbers in `flat_results_with_metrics.csv`'s `top1_*` columns.
2. **Top-1 post-fix (err_only sort)** — what wallaby WOULD have surfaced
   if 84553a3 had been in force when wallaby ran. Needs adding to
   `build_flat_metrics_wallaby.py`.
3. **Best-of-K (oracle)** — truth-cheat upper bound. Already in the
   `oracle_*` columns.

(1) → (2) closes ~9.5pp at ≤1e-4. (2) → (3) is the genuine
"truth-cheat" gap.

## Outstanding follow-up (per local-claude's caveat)

> The investigation doc also mentioned cells where the candidate set
> itself regressed (oracle-best across all rows went from tight to
> loose) — that's separate from this fix and still worth a follow-up
> if it shows up in the next benchmark.

That refers to cases like bicycle_model_7_1em8 where wallaby's
result.csv had `post_polish_error` plateaued at 2e-2 across all 20
rows, vs 14's tight 2.6e-6. If the new env_n14 probe (14 stack +
282fe1a source) recovered to 1.65e-7 at rank 4, then this is also a
sort-only issue (the truth-near row exists, just buried). If env_n14
still showed plateau at 2e-2 even at rank 4+, that would be a real
candidate-set regression separate from the sort. The FINDINGS doc
implies the former — but worth confirming on a few additional cells
before signing off.

(Original investigation content preserved below for reference.)

---

## ORIGINAL (PRE-RESOLUTION) CONTENT

## Symptom

Apples-to-apples polish success at fine thresholds, vs the numbat-14
benchmark (which used essentially the same ODEPE pipeline minus the
282fe1a changes, on the same data bytes as 06):

| Threshold | wallaby polish | 14 polish | delta |
|---|---|---|---|
| ≤0.1% | 59.6% | 63.7% | −4.1pp |
| ≤1e-4 | 48.3% | 51.9% | −3.6pp |
| ≤1e-9 | 14.8% | 15.2% | −0.4pp |

Of 54 cells where wallaby regressed past the ≤1e-4 threshold vs 06,
**47 are >1.5× worse in wallaby than in 14** (and 0 are better). 14 used
the same K=20 + `skip _detect_branches at output` pipeline as wallaby —
so the regression is from one of:

- soft-wall regularization (new default `polish_softwall_lambda=1e-2`)
- S2 sort (new `rank_strategy=:sat_neg1_err`)
- Identifiable-subspace clustering (new `cluster_method=:identifiable_subspace`)
- The Pkg.update (OrdinaryDiffEq 6.x → 7.0.0, MTK 11.26.0 → 11.26.3,
  Symbolics 7.22.0 → 7.24.0, SciMLBase 3.10.0 → 3.13.0, LinearSolve
  3.76.0 → 3.80.0, plus assorted minor bumps; full list in wallaby's
  MANIFEST.toml `[lineage]` block)

## What's been ruled out

### Soft-wall regularization (`polish_softwall_lambda`)

Probe `probe_softwall_zero_2026-05-18/` re-ran the 47 worst regression
cells with `polish_softwall_lambda = 0.0` and `polish_softwall_epsilon = 0.0`,
everything else (including data bytes) identical to wallaby. 47/47 cells
finished cleanly (mean 668s/cell). Result:

- Recovered to 14-level (≤1.5× of 14's oracle): **1 / 47**
- Improved (probe < 0.7× wallaby): 3 / 47
- **No change** (within ±30%): **40 / 47**
- Got worse: 3 / 47

This is a clean negative. Soft-wall is not the cause. (Makes sense in
retrospect: truth values for these cells are mid-range in [1e-5, 10], so
soft-wall is structurally inactive at the basin — `lambda=0` only
removes always-zero penalty rows.)

Probe directory and per-cell results retained at
`probe_softwall_zero_2026-05-18/` for follow-up.

## Concrete evidence pointing at OrdinaryDiffEq 7.0.0

The catastrophic case bicycle_model_7_1em8:

| | 06 | 14 | wallaby |
|---|---|---|---|
| Oracle | 5.6e-6 | 5.6e-6 | 4.1e-3 (700×) |
| `post_polish_error` of oracle row | n/a | **2.7e-6** | **2.1e-2** |
| `post_polish_error` of rank-1-by-err row | n/a | 2.6e-7 | 4.3e-4 |
| Polish notes | n/a | (none) | `[]` |
| `was_terminal_fallback` | n/a | False | False |

wallaby's LM polish stopped at residual 2e-2 vs 14's 3e-6 on the same
cell. That's four orders of magnitude looser. No timeout flag, no
fallback flag — LM's internal convergence test thinks it's done.

If the ODE integrator's effective noise floor went from ~1e-12 (where
14's polish could drive LM to residual e-6) to ~1e-3 (where wallaby's LM
hits a plateau at residual e-2), this is exactly what we'd see. The
plateau is set by the integrator, not by LM.

## Script-level parameter diff: 14 vs wallaby

`diff` of one per-cell polish script (`aircraft_pitch_0_0`) between
numbat-14 and wallaby:

```
2,3c2,3
< ### Date: 2026-05-14 22:22:54
< ### Generated by: src/generate_scripts.py benchmark_numbat_2026-05-14 -s odepe_v2_polish -r odepe_v2_polish_run
---
> ### Date: 2026-05-17 21:42:26
> ### Generated by: src/generate_scripts.py benchmark_wallaby_2026-05-17 -s odepe_v2_polish -r odepe_v2_polish_run
```

**The scripts are byte-identical except for the timestamp.** Same template,
same hardcoded opts (`abstol=1e-12`, `reltol=1e-12`, `polish_maxtime=3600`,
`polish_divergence_factor=10.0`, `polish_stagnation_window=50`,
`polish_ode_maxiters=20000`, `polish_method=PolishLSOBoundedLog`, etc.).

The only differences between 14 and wallaby are therefore:

1. **ODEPE source** pulled to 282fe1a, which changes
   defaults for opts that the script does NOT set explicitly:
   - `polish_softwall_lambda = 1e-2` (was 0 effectively in 14)
   - `polish_softwall_epsilon = 0.10` (new)
   - `rank_strategy = :sat_neg1_err` (was `:err_only` or similar in 14)
   - `cluster_method = :identifiable_subspace` (was MAD-based in 14)
   - `branch_top_k = 20` (was 100 in 14)

2. **`Pkg.update`** of `environments/julia_odepe`:
   - OrdinaryDiffEq: 6.x → 7.0.0 (major)
   - MTK 11.26.0 → 11.26.3, Symbolics 7.22.0 → 7.24.0, SciMLBase 3.10.0 → 3.13.0,
     DiffEqBase 7.3.0 → 7.5.0, LinearSolve 3.76.0 → 3.80.0, plus minor bumps

This narrows the hypothesis space considerably — script opts are not a confound.

## Parameter inventory (sanity check)

ODEPE configuration that polish uses, as of wallaby:

### Default ODE solver

`AutoVern9(Rodas5P())` — Verner 9th-order non-stiff with Rodas5P
auto-switch for stiff regions. Comes from
`src/types/estimation_options.jl` field
`ode_solver::Any = AutoVern9(Rodas5P())`.

The polish residual function calls this via
`ModelingToolkit.solve(prob_opt, ctx.solver; saveat=t_vec, abstol, reltol, maxiters, unstable_check=...)`
in `src/core/polish_residual.jl:139`.

### Tolerances

- Defaults in `EstimationOptions`: `abstol = 1e-14`, `reltol = 1e-14`
- **Scripts override to** `abstol = 1e-12, reltol = 1e-12` (the v2
  template `templates/julia_template_for_estimation_odepe_v2.jl`
  hardcodes these).
- LSO LM tolerances: `polish_lso_x_tol = polish_lso_f_tol = polish_lso_g_tol = -1.0`
  → inherits from `reltol` / `abstol`. So in practice LM is checking
  convergence at 1e-12.

These should be tight enough. Worth checking if OrdinaryDiffEq 7.0.0
changed how `abstol`/`reltol` are interpreted in stiff solvers.

### Polish controls

- `polish_method = PolishLSOBoundedLog` (bounded LSO LM in per-variable
  log space, `LeastSquaresOptim.jl`)
- `polish_maxiters = 5000` (in script; default in opts is 100, override
  via template)
- `polish_maxtime = 3600.0` (per-candidate wall-clock cap; with K=20 →
  total polish ≤ 20hr per cell)
- `polish_divergence_factor = 10.0` (stop if loss > 10× initial)
- `polish_stagnation_window = 50` (stop if no improvement in 50 iters)
- `polish_ode_maxiters = 20000` (ODE solver step cap inside polish loss;
  default in opts is 5000, template overrides to 20000)

### Soft-wall (282fe1a default, since-ruled-out as cause)

- `polish_softwall_lambda = 1e-2`
- `polish_softwall_epsilon = 0.10`
- Implementation in `src/core/polish_residual.jl:84-184`. Appends one
  penalty row per parameter, zero when parameter is in central
  (1 − ε) fraction of the halfrange in transformed internal coords.
  For bounds `[1e-5, 10]` and ε=0.10, penalty activates only outside
  log-internal-coord band ≈ [3e-5, 5].

### `unstable_check` callback (worth scrutiny)

`src/core/polish_residual.jl:148` passes
`unstable_check = (dt, u, p, ti) -> time() > deadline_ref[]` to the ODE
solver. This lets the integrator bail mid-step when the polish deadline
passes. Causes the solver to return `ReturnCode.Unstable`, which the
polish residual then sentinel-fills.

Worth confirming `unstable_check` semantics didn't change in
OrdinaryDiffEq 7.0.0. If the check fires more aggressively (e.g., on
every step instead of every chunk), it could be causing premature
solver bailouts that look like high residuals to LM.

### Other relevant Pkg.update version changes (vs wallaby-pre-update)

From wallaby MANIFEST.toml `[lineage]` block:

- **OrdinaryDiffEq: 6.x → 7.0.0** (major)
- ModelingToolkit: 11.26.0 → 11.26.3
- Symbolics: 7.22.0 → 7.24.0
- SciMLBase: 3.10.0 → 3.13.0
- DiffEqBase: 7.3.0 → 7.5.0
- LinearSolve: 3.76.0 → 3.80.0
- NonlinearSolve: 4.19.0 → 4.19.1
- Enzyme: 0.13.146 → 0.13.147
- HomotopyContinuation: 2.18.2 (unchanged in this update)
- LeastSquaresOptim: 0.8.9 (unchanged)
- GaussianProcesses: 0.12.6 from `orebas/GaussianProcesses.jl#optim2-compat`

The OrdinaryDiffEq major bump is the only "should worry about defaults"
candidate. The rest are minor/patch bumps unlikely to change polish
convergence behavior.

## Smoking-gun check (results)

Cross-cell verification on 3 cells (aircraft_pitch_0_0,
bicycle_model_7_1em8, sirt_treatment_0_1em6): all hardcoded opts in
script.jl are byte-identical (same values shown below):

```
polish_method = PolishLSOBoundedLog
polish_maxiters = 5000
polish_maxtime = 3600.0
polish_ode_maxiters = 20000
polish_divergence_factor = 10.0
polish_stagnation_window = 50
abstol = 1e-12
reltol = 1e-12
```

No misconfiguration. No off-by-one. No accidentally-tightened tolerance.
The opts are sensible and match what 14 used.

**Conclusion:** opts are not the smoking gun. The regression must come
from one of:

1. **OrdinaryDiffEq 7.0.0 major bump** (most likely — see post_polish_error
   plateau pattern in bicycle_model_7_1em8).
2. ODEPE 282fe1a default changes (softwall ruled out by probe;
   S2 sort + IS clustering as remaining candidates among the
   ODEPE-side defaults).
3. Some subtle MTK/Symbolics/SciMLBase interaction with the new
   OrdinaryDiffEq, since they bumped together.

## Hypotheses to test

In rough order of cheap-to-expensive:

1. **OrdinaryDiffEq 7.0.0 default tolerance behavior changed** — pin
   OrdinaryDiffEq back to whatever 14 used (probably 6.x latest), re-run
   one of the catastrophic-regression cells (e.g.
   `bicycle_model_7_1em8`), see if `post_polish_error` recovers to e-6.
   Cheap probe: ~10min per cell.
2. **`unstable_check` semantics changed** — temporarily comment out the
   `unstable_check` callback in `src/core/polish_residual.jl:148`,
   re-run a regression cell. If polish recovers, that's the
   smoking gun. (Risk: polish could run unbounded if the deadline race
   relied on the callback. Use a short `polish_maxtime` in the probe to
   safeguard.)
3. **AutoVern9 auto-switch threshold changed** — replace the default
   solver with plain `Rodas5P()` (force-stiff) or plain `Vern9()`
   (force-non-stiff) on a regression cell. Either fixing it strongly
   suggests the auto-switch logic moved.
4. **Different ODE problem construction** — MTK 11.26.0 → 11.26.3 could
   have changed how `ODEProblem` is built (e.g. different default
   `build_initializeprob` semantics). Less likely to be load-bearing
   given the minor version bump, but worth a glance.
5. **S2 sort / IS clustering downstream-feeding-LM** — if 1-4 all
   come back negative, check whether wallaby is feeding LM different
   candidate starting points than 14. Look at `polish_source_hc_idx`
   distribution per cell.

## Cells to use for probing

The list at `probe_softwall_zero_2026-05-18/cells.txt` is good — 47
cells representing the worst polish regressions. For a tighter probe,
start with these 5 that are the most catastrophic (>50× regression vs 14):

1. `bicycle_model_7_1em8` — 14=5.6e-6, wallaby=4.1e-3
2. `crauste_2_0` (nopolish-regression) — 14 = e-6, wallaby ≥ e-3
3. `vanderpol_5_1em4` — 14=1.5e-5, wallaby=3.8e-3
4. `vanderpol_9_1em4` — 14=9.3e-5, wallaby=7.6e-3
5. `seir_0_1em6` — 14=8.4e-5, wallaby=5.1e-3

If the OrdinaryDiffEq pin recovers any of these, we have our answer.

## Files

- Probe setup: `probe_softwall_zero_2026-05-18/`
  - `README.md` — probe description
  - `cells.txt` — list of 47 cells
  - `run_probe.s` — SLURM script
  - `filetree/<cell>/` — per-cell symlinked data + modified script.jl + results
- Probe analysis: `/tmp/probe_analyze.py` (worth promoting to
  `results/wallaby_analysis/probe_analyze.py` if anyone re-runs it)
- This document: `results/wallaby_analysis/INVESTIGATION_polish_regression_root_cause.md`

## What we'll do if we don't chase this further

Document the regression in the paper:

- 06 vs wallaby gap is concentrated in fine-threshold polish success
  (1-4pp at ≤0.1%, decaying to 0 at ≤1e-9 for nopolish, ~3pp for polish).
- 06's published numbers used OrdinaryDiffEq 6.x; wallaby reports use 7.0.0.
- This is a stack-update sensitivity, not an algorithmic change.
- Soft-wall ruled out by `probe_softwall_zero_2026-05-18`.
- OrdinaryDiffEq 6.x → 7.0.0 is the working hypothesis for the residual.
