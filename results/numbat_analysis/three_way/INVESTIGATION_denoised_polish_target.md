# Investigation: polish against a denoised target

**Status**: open, not yet started, **speculative**. This is a planning doc
for a new idea that came up while looking at the numbat 2026-05
investigation. Read before starting work — and read the "What could go wrong"
section carefully, because the idea is not a slam-dunk.

**Companion docs (one package)**:
- `HANDOFF.md` — what was investigated in numbat 2026-05 and what was found
- `INVESTIGATION_column_scaling.md` — open investigation 1
- This doc — open investigation 2: polish against a denoised target

---

## The idea, in one sentence

Instead of polishing against the raw observation vector `y_data`, polish
against a smoothed/denoised proxy `y_smooth`. The polish minimum then
reflects the underlying smooth signal rather than the specific
noise-realization in `y_data`.

## Mechanically

Current polish residual (`environments/ODEParameterEstimation/src/core/polish_residual.jl:127-130`):

```julia
data_true = ctx.data_targets[j]    # raw y_data per observable
# ... residual_vector[k] = y_pred[k] - data_true[k]
```

where `ctx.data_targets` is constructed at
`environments/ODEParameterEstimation/src/core/parameter_estimation.jl:2096`:

```julia
data_targets = Vector{Float64}[
    Float64.(PEP.data_sample[eq.rhs])
    for eq in PEP.measured_quantities
]
```

That's the raw noisy data. The proposed change: substitute a denoised
version of each `data_targets[j]` before polish runs. Polish's gradient
descent then optimizes against the denoised vector.

## Why it might help

At noise level σ on a time series of length n, the empirical-residual loss
landscape has a minimum that is shifted from the true model parameters by
a quantity that scales with σ²/n in expectation. On well-identified cells
this shift is tiny. **On near-non-identifiable cells the shift can be
LARGE in the degenerate subspace.** That's the bias-amplification mechanism.

In numbat 2026-05-14, the cells in `raw_to_polished_trace.csv` diagnosed
as `POLISHED_BUT_WRONG_BASIN` show this signature: the best raw HC
candidate started near truth, polish actively moved AWAY from truth, and
polish converged to a basin that has lower data residual than the truth
basin does (by design — polish is minimizing data residual). The fact
that the "best-fit-to-data" point isn't truth is what we mean by
noise-realization bias.

Polishing against a smoothed target shifts that bias:
- More of the residual minimum's location is determined by the underlying
  smooth signal
- Less is determined by the specific noise realization at each timepoint

In statistical-estimation terms: polish-against-raw is MLE under iid
Gaussian noise. Polish-against-smoothed is biased (toward the smoother)
but lower-variance.

## Why it might hurt

Three concrete risks:

1. **Bias from over-smoothing.** If `y_smooth` smooths away real features
   of the underlying ODE trajectory (e.g. fast transients in stiff
   systems, high-frequency content in oscillators), polish converges to
   "best-fit to smoothed signal," which can be further from truth than
   "best-fit to noisy signal." Stiff-system cells (brusselator,
   biohydrogenation) are particularly at risk.

2. **At low noise this is strictly worse.** noise=0 cells: polish-against-raw
   is exact MLE; polish-against-smoothed adds GP-fit error to the
   residual. Easy to break working cells.

3. **GP fit error becomes a polish residual.** When the GP fit happens to
   be a poor model of the underlying signal (mis-specified kernel,
   numerical issues, sparse data near transients), polish's residual now
   carries that error as a "target" and converges to mimicking GP-fit
   artifacts.

The cleaner statistical fix is per-timepoint noise-variance weighting in
the residual — i.e., MLE under a non-iid noise model. That requires noise
variance estimation we don't have. The denoised-target trick is a cheaper
proxy with no MLE interpretation.

## Variants to consider

The implementation has one major axis: which denoiser?

### (a) GP fit as target

ODEPE already computes GP fits during the interpolator step (the
`InterpolatorAGPRobust*` and `InterpolatorAdapt*` families — see
`environments/ODEParameterEstimation/src/types/estimation_options.jl:24–55`).
The GP regression already produces a smooth predicted-mean function on
the data timepoints. Cheap to access — just re-evaluate the existing GP
fit at the data timepoints and use as target.

**Pros**: reuses existing machinery; no new dependencies.

**Cons**: which GP fit? ODEPE runs a portfolio of interpolators per cell
and picks one. The "best" interpolator for derivatives may not be the
right denoiser. Choice of kernel (SE, RQ, Matern, etc.) determines the
smoothness prior.

### (b) Moving-average / Savitzky-Golay smoothing

Simpler. No GP at all. Compute Savitzky-Golay (polynomial-fit) smoothing
on each observable, use as target. Window size is a knob — start with
something like ≤ 5% of the data length.

**Pros**: no new dependencies; no GP-kernel choice; behavior is easy to
predict.

**Cons**: doesn't capture longer-range structure; pathological at
boundaries; sensitive to outliers.

### (c) Blend: `α * y_data + (1-α) * y_smooth`

Probably the right starting variant. Sets up an A/B knob `α ∈ [0, 1]`
where `α = 1` is current behavior (polish against raw) and `α = 0` is
pure-smoothed. Run experiments at `α = 0.7` (mostly raw, slight bias
toward smooth) and `α = 0.5` (even mix).

**Pros**: backwards-compatible default `α = 1`; degrades gracefully if
the experiment doesn't pan out; explicit knob to dial bias/variance.

**Cons**: still has to choose a denoiser for `y_smooth` (so the variant
above's choices apply).

**Recommend variant (c) with GP fit from (a) as the denoiser.**

## Concrete implementation sketch

Single new opt-in option on `EstimationOptions`:

```julia
# Polish target denoising
polish_target_denoiser::Symbol = :none      # :none (default) | :gp | :savgol
polish_target_blend_alpha::Float64 = 1.0    # 1.0 = pure raw (default); 0.0 = pure denoised
```

In `parameter_estimation.jl` around line 2096 (where `data_targets` is
built), if the option is set:

```julia
y_raw = Float64.(PEP.data_sample[eq.rhs])
y_smooth = compute_denoised_target(y_raw, PEP.data_sample["t"], opts.polish_target_denoiser, opts)
α = opts.polish_target_blend_alpha
data_targets_j = α .* y_raw .+ (1.0 - α) .* y_smooth
```

For the `:gp` denoiser: re-evaluate the GP fit already computed by the
interpolator step at the observation timepoints. The fit object should
already be available in `PEP` or computable from
`opts.interpolators[1]` + the data.

For `:savgol`: a small new helper, ~30 lines, depending on a polynomial
order and window size (could also be options).

Default option keeps polish behavior unchanged. Opt-in only.

**Files likely touched**:
- `src/types/estimation_options.jl` — two new fields
- `src/core/parameter_estimation.jl` — `data_targets` construction (line ~2096)
- new `src/core/denoised_targets.jl` (or similar) — small helper containing the GP and SavGol denoisers
- `templates/julia_template_for_estimation_odepe_v2.jl` — optionally surface the new options

## Concrete cells to evaluate on

Use the existing probe infrastructure
(`results/numbat_analysis/three_way/make_regression_probes.py`,
`hpc/cuny/array_probe_regressions.s`) to run side-by-side comparisons.

**High-noise target cells** (should benefit):
- `forced_lotka_volterra_*_1em2` — 7 of 10 instances regressed in 13
- `lotka_volterra_*_1em2` — 4 regressed
- `fitzhugh_nagumo_4_1em6` — has `POLISHED_BUT_WRONG_BASIN` diagnosis
- `daisy_mamil4_8_1em8` — practical-identifiability case

**Low-noise control cells** (should NOT regress; if they do, the bias is
real and too big):
- `lotka_volterra_*_0`
- `harmonic_oscillator_*_0`
- `aircraft_pitch_0_0`
- `daisy_mamil3_*_0`

## Evaluation protocol

1. Implement variant (c) with `:gp` denoiser. Default `α = 1.0` (no-op).
2. Run two SLURM probe sweeps on the same probe set (~50 cells from the
   target + control lists above):
   - Sweep A: `α = 1.0` (control — should reproduce current 14 result.csv exactly)
   - Sweep B: `α = 0.5` or `α = 0.7` (the experiment)
3. Per-cell oracle comparison. Bucket cells into:
   - **Improved**: oracle_B < oracle_A / 2 (denoised polish helped)
   - **Unchanged**: |oracle_B - oracle_A| / oracle_A < 0.5
   - **Regressed**: oracle_B > oracle_A * 2
4. **Decision rule**:
   - If improved > 2× regressed: try wider α sweep, then propose flipping default to opt-in for high-noise.
   - If improved ≈ regressed: decline to ship. Document negative result.
   - If regressed >> improved: the bias is too big. Decline. Document.
5. **In any case**, do a separate sanity check on the control cells: if
   any of them regress significantly at `α = 0.5`, the denoiser is biased
   in a way that hurts well-posed problems. That kills the idea.

## Author's honest assessment

I think this is **worth trying but not a slam-dunk.** The core tension:

- For polish to descend cleanly to truth, the loss landscape needs a
  minimum that coincides with (or is close to) truth.
- Polish-against-raw has the right minimum in expectation but is biased
  on any specific noise realization.
- Polish-against-smooth has a deterministic minimum, but it's biased
  toward the smoother's prior (smoothness assumptions, kernel, etc.).

It's a bias/variance tradeoff. Whether it helps net-net depends on which
bias dominates on a given cell. The numbat data suggests that for
`POLISHED_BUT_WRONG_BASIN` cells, the noise-realization bias is the
dominant problem — but **the column-scaling hypothesis explains the SAME
cells equally well**. So if column scaling pans out, this idea may be
redundant.

**Recommend doing this AFTER the column-scaling investigation produces
preliminary results**, not in parallel. If column scaling closes the gap,
denoised-target is unmotivated. If column scaling doesn't help on cells
like `fitzhugh_nagumo_4_1em6` (a non-stiff system where conditioning
shouldn't be the issue), denoised-target gets its chance.

## What could go wrong

- **GP fit unstable on small datasets** — some cells have only 750 data
  points. GP regression overhead and numerical stability may degrade.
  Mitigation: precompute the GP fit once per cell, cache it; fall back
  to Savitzky-Golay if GP fit fails.
- **Polish gradient depends on GP fit through-line, not just values** —
  if the GP fit has artifacts (over-smoothing near transients), polish
  inherits them. The α blend bounds this but doesn't eliminate it.
- **The whole experiment is moot if column scaling fixes the same cells.**
  See the assessment above.
- **Performance.** GP re-evaluation at every polish step is expensive.
  Implementation should compute `y_smooth` ONCE (pre-polish), not
  per-iteration. Should be cheap if done right.
- **GP kernel choice matters and we don't have a principled selection.**
  ODEPE's existing interpolator portfolio picks per-cell; we could
  inherit that choice or fix to one (SE or Matern52 are sane defaults).

## References

- `HANDOFF.md` § "Practical non-identifiability" — the daisy_mamil4 and
  hiv worked examples that motivate this idea
- `raw_to_polished_trace.csv` — the 14 `POLISHED_BUT_WRONG_BASIN` cells
  that this would target
- `INVESTIGATION_column_scaling.md` — the alternative hypothesis for the
  same cells; investigate that first
- `environments/ODEParameterEstimation/src/core/polish_residual.jl` — the
  residual closure currently using `ctx.data_targets`
- `environments/ODEParameterEstimation/src/core/parameter_estimation.jl:2096` — where `data_targets` is constructed
- `environments/ODEParameterEstimation/src/types/estimation_options.jl:24–55` — existing interpolator portfolio (the source of the GP fit)
