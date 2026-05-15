# Investigation: column-scaling in the polish loss landscape

**Status**: open, not yet started. This is a planning doc — read before
starting work.

**Companion docs (one package)**:
- `HANDOFF.md` — what was investigated in numbat 2026-05 and what was found
- This doc — open investigation 1: column scaling / ill-conditioning
- `INVESTIGATION_denoised_polish_target.md` — open investigation 2

---

## Why this is back on the radar

Numbat benchmark 14 (`benchmark_numbat_2026-05-14`) recovered 06-baseline
accuracy on most cells (succ@50% 85.8% vs 06's 86.4%, see `HANDOFF.md`).
But a stubborn ~10% of cells still fail to recover, and the diagnostic
work in `raw_to_polished_trace.csv` showed that 14 of 23 unrecovered
regression cells fall into a "POLISHED_BUT_WRONG_BASIN" bucket: the best
raw HC candidate **was** polished, but polish converged to a non-truth
minimum even when starting from a point near truth.

This is precisely the pathology that ODEPE's existing column-scaling
design doc was written to address:

> `environments/ODEParameterEstimation/docs/2026-05-01_variable_scaling_investigation.md`

That doc has the full algorithmic design (three implementation levels, scale
choices, HC.jl background). This PEB-level doc adds **numbat-empirical case
data**: concrete cells where the pathology manifests in result.csv, with
observed numbers. Use both docs together when starting work.

---

## The smoking-gun case: `brusselator_6_0`

This is the cleanest demonstrator. **Noise = 0**, so polish should converge
to truth precisely. It does not.

System:

```
dX/dt  = 0.5 - 0.5*X - 3.0*b*X + 16.0*a*Yc*X^2
dYc/dt = 6.0*b*X - 16.0*a*Yc*X^2
y1 = 2.0*X,  y2 = 2.0*Yc        (both states fully observed)
```

Truth: `X=0.380, Yc=0.164, a=0.818, b=0.651`. On paper, the easiest possible
inverse problem — direct observation of both state variables, no
unidentifiability, no noise.

`benchmark_numbat_2026-05-14/filetree/odepe_v2_polish_run/brusselator_6_0/result.csv`
top of err-sorted rows (excerpted):

| rank | err | oracle_max | X | a | b |
|---|---|---|---|---|---|
| 1 | **1.46e+02** | 2.22e-01 | 0.368 | 0.769 | 0.651 |
| 2 | 3.35e+09 | 1.57e+04 | **5959.12** | 0.848 | 0.487 |
| 3 | 8.16e+09 | 1.57e+04 | **5959.12** | 0.003 | 0.408 |
| ... 56 more rows mostly with X≈5959 (integration blowup) ... |
| 60 | 1.59e+10 | 1.15e-01 | 0.377 | 0.912 | 0.669 |
| 100 | 1.50e+15 | 1.44e+01 | 0.000 | 10.000 | 10.000 |

**Read**:

- The err at rank-1 is 146 for **noise=0** data. A well-converged polish
  on noise-free data should be at err ≈ 1e-13. The polish loss landscape
  is broken — there's nowhere to descend to a "real" minimum.
- Most rows have `X = 5959.12` (massively blown up — likely the ODE
  integration explodes during polish's forward-model evaluation, returning
  a corrupted state).
- The "truth-best" row (oracle 0.115) is at rank 60. It's still not
  truth — `a=0.912` vs truth 0.818, `b=0.669` vs truth 0.651. It's just
  the least-wrong of the 100 returned rows.

Raising `branch_top_k` doesn't help here. No row is anywhere near truth.

## What's going on

Brusselator at certain `(a, b)` regimes has Hopf bifurcations and stiff
limit cycles. The 16·a·Yc·X² term is super-linear in X, so when the polish
step takes a gradient step that puts X slightly too large, the next ODE
integration of the forward model amplifies it dramatically. The stiff
solver (default `Rodas5P` in this stack) either hits `polish_ode_maxiters
= 20000` mid-integration or returns numerically corrupted state. That
corrupted state's contribution to the polish residual is huge, so the
gradient descent at that polish step gets confused and wanders away from
the truth basin.

In one sentence: **the polish gradient is operating in a parameter space
where the ODE forward model has Jacobian condition numbers in the 1e6–1e10
range**, exactly the conditioning problem the ODEPE doc cites for
biohydrogenation and daisy_mamil4.

## Other cells in the same bucket

From `raw_to_polished_trace.csv` (in this directory), the 14 cells
diagnosed `POLISHED_BUT_WRONG_BASIN`:

| Cell | o06 baseline | o14 | best raw oracle | observation |
|---|---|---|---|---|
| `brusselator_5_0` | 0.59 | 14.0 | 29 | similar to brusselator_6_0 |
| `brusselator_6_1em6` | 1.0 | 14.4 | 8000 | also `noise-near-zero` instability |
| `biohydrogenation_6_1em6` | 0.73 | 7.34 | 0.389 | polish moves AWAY from a 0.4 raw |
| `biohydrogenation_8_1em4` | 0.85 | 17.5 | 0.85 | polish wanders from a truth-matching raw |
| `daisy_mamil4_8_1em8` | 6.19e-3 | 7.52e-2 | 0.31 | classic conditioning case |
| `fitzhugh_nagumo_4_1em6` | 1.59e-3 | 2.35e-2 | 1.59e-3 | polish stalls at the raw value |
| `slow_fast_7_1em4` | 1.10e-3 | 2.45e-3 | 1.10e-3 | similar — polish doesn't tighten |
| `aircraft_pitch_8_1em4` | 2.16e-5 | 9.43e-5 | 6.72e-3 | polish improves raw but not to 06 |
| `boost_converter_{3,5}_1em4` | ~1e-4 | ~1e-3 | ~1e-3 | similar |
| `forced_lotka_volterra_{2,3,4}_*` | low | ~7e-3 to 0.77 | varies | various noise levels |
| `quadrotor_1_1em4` | 1.64e-4 | 4.01e-4 | 3.57e-4 | minor — close to recovery |
| `seir_{4,6}_*` | 1.0, 0.02 | 69, 0.21 | 33, 0.21 | systemic failure on hard cells |

A signature pattern in many of these: **the best raw oracle is ALREADY
close to truth**, but polish moves AWAY from it. That is, polish's
gradient step is making things worse, not better. The polish basin of
attraction does not contain truth from these starting points.

## Concrete recommended test cells

Use these 5 cells as the column-scaling regression suite. Each has
verified pre-conditions and quantitative baselines:

1. **`brusselator_6_0`** — the cleanest demonstrator. Noise = 0, fully
   observable states, polish currently fails catastrophically (err 146 at
   rank 1). Truth: X=0.380, Yc=0.164, a=0.818, b=0.651.
2. **`brusselator_5_0`** — sibling failure case, different parameter regime.
3. **`biohydrogenation_9_0`** — at noise=0 this cell was STILL running at
   13+ hours wall time when the 14 rerun's main launch wrapped up. Almost
   certainly the same conditioning pathology applied to a different system.
4. **`daisy_mamil4_8_1em8`** — the practical-identifiability case from the
   12-era deep dives. Has well-defined Jacobian condition numbers
   documented in the ODEPE doc (cond(J) ≈ 2e6 at this noise). 06 recovered
   it (oracle 6.19e-3); 14 doesn't (oracle 7.52e-2).
5. **`aircraft_pitch_8_1em4`** — a "polish stalls just shy of truth" case,
   less dramatic than brusselator. Truth ~2e-5, polish lands at ~1e-4.

The pre-conditions and observed numbers for each are in
`accuracy_four_way.csv` (search by cell ID).

## Diagnostic to run BEFORE implementation

The ODEPE doc's verification section step 1 is:

> Run the diagnostic on biohydrogenation_0_0 in scaled coordinates,
> compare cond(J) before vs after.

Recommend doing this diagnostic on the 5 test cells above FIRST, before
any implementation. Specifically:

- For each test cell, evaluate the polish-loss Jacobian condition number
  at (a) truth, (b) the raw HC starting point, (c) the polished output.
  All three numbers in the same CSV row.
- The numbers from ODEPE's TODO say cond(J) 1e6–1e10. Confirm on numbat 14
  data. Look for the systematic shape: condition is bad → polish wanders.

If cond(J) is NOT large for some of these cells, the failure mode is
something else (could be `branch_err_factor` filter for some, could be
HC.jl missing the truth basin for others). Triage accordingly.

Output: a small Python or Julia script + CSV under
`results/numbat_analysis/three_way/` (e.g., `cond_J_diagnostic.csv`).

Reuse the polish-residual machinery in
`environments/ODEParameterEstimation/src/core/polish_residual.jl`. The
ForwardDiff Jacobian is already computed inside the LSO polish path; can
either grab it during a debug run or compute it standalone.

## Implementation pick

Per the ODEPE design doc, recommend **Level A: variable-substitution
wrapper**. Per that doc:

- Smallest diff (50–100 lines)
- Fully transparent to HC.jl and the polish step
- Easy to A/B test with a flag in `EstimationOptions`

Scale choice: start with **option 1 (bound-based)**, `s_i = upper_bound_i`,
using the existing `opt_ub` in `EstimationOptions`. Cheapest. The diagnostic
will tell us whether option 2 (column-norm-based) is needed.

Level B (full pipeline scaling) is out of scope for the first cut. Level C
(reformulating the algebraic problem) is open research and out of scope.

## Evaluation protocol

1. **Per-cell diagnostic confirmation** — cond(J) drops by 1-3 orders of
   magnitude on the 5 test cells under Level A scaling.
2. **Probe re-run** — re-run the 5 test cells (same data, same script,
   only `apply_variable_scaling` flag flipped on) and compare oracles.
   Use the SLURM probe pattern already established in
   `hpc/cuny/probe_one_cell.s` (single cell) or
   `hpc/cuny/array_probe_regressions.s` (array of cells with shared
   probe script template).
3. **No regression check** — pick 30-50 random cells from numbat 14 where
   14 currently MATCHES 06. Run with the flag on; confirm no regression
   on those.
4. **If 1+2+3 are all green**: discuss with user whether to flip the
   default. Per the existing ODEPE doc's "What to NOT do" section:
   > Do not silently change defaults on first iteration. Add the option,
   > default it off, prove it helps on a benchmark subset, *then* discuss
   > flipping the default.

## What could go wrong

- **Substitution not invariant under SI**. The symbolic-identifiability
  step may produce different equations under scaled coordinates. The ODEPE
  doc flags this in Level A's "Cons" — verify the SI-derived templates
  match before vs after substitution.
- **Polish-step bounds plumbing**. `opt_lb` and `opt_ub` must be scaled
  to match the new coordinates. Same for divergence/stagnation
  thresholds. Easy to miss one.
- **Conditioning improves but truth-near isn't in the polished list**.
  If the issue is HC.jl missing the truth basin entirely (rather than
  polish wandering from it), column scaling won't help. The diagnostic
  will tell us; if so, this investigation isn't the right tool.
- **Bound-based scaling underperforms**. If `s_i = upper_bound_i` doesn't
  drop cond(J) enough on biohydrogenation/daisy_mamil4, fall back to
  option 2 (column-norm-based). Requires more plumbing but is what
  serious solvers do.

## References

- `environments/ODEParameterEstimation/docs/2026-05-01_variable_scaling_investigation.md` — the existing 3-level design doc, including the cond(J) numbers (1e6–1e10) and the choice between Levels A/B/C
- `environments/ODEParameterEstimation/TODO` — top entry: "investigate / implement variable (column) rescaling for the polynomial system"
- `HANDOFF.md` § "ODE-solver-induced polish failures (column scaling)" — the brusselator deep dive in narrative form
- `raw_to_polished_trace.csv` — per-cell diagnoses identifying the 14 POLISHED_BUT_WRONG_BASIN cells
- `accuracy_four_way.csv` — full per-cell comparison across 06/12/13/14

## Files likely to be modified

Per the ODEPE design doc, Level A touches:

- `src/core/parameter_estimation.jl` — top-level driver; accept new option, apply substitution at I/O boundary
- `src/core/parameter_estimation_helpers.jl` — unsubstitution path
- `src/types/estimation_options.jl` — new option field (e.g. `variable_scaling::Symbol = :none`, valid values `:none, :bounds, :norm_J`)
- `src/types/core_types.jl` — possibly a scaled-coordinate `ParameterEstimationProblem` variant
- New: a small test/diagnostic at `test/diagnostics/cond_J.jl` or similar to assert cond(J) bound on biohydrogenation under known scaling
