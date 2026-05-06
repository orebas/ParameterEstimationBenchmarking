# Next Benchmark Recommendations

This note is a planning guide for the next ODEPE benchmark run, based mainly on
the Bilby benchmark (`benchmark_bilby_2026_03_09`) and the follow-up multipoint
investigation. The goal is to make the next run interpretable: if performance
changes, the benchmark should tell us which change caused it.

## Main Recommendation

Do not run a single "new ODEPE" benchmark and compare it directly to old Bilby
tables. Run a small set of deliberately separated ODEPE variants on frozen data:

| Run | Purpose |
|---|---|
| `odepe_old_reference` | Last known-good ODEPE commit/template/settings. This anchors the comparison. |
| `odepe_new_core` | Current ODEPE with settings as close as possible to the reference. |
| `odepe_new_multipoint` | Current ODEPE with multipoint enabled. Keep the interpolator list controlled. |
| `odepe_new_polish` | Current ODEPE with polishing enabled, only if polish impact is part of the question. |
| `amigo2_run` | External reference, not the only success target. |

The Bilby multipoint investigation showed why this matters: the apparent
"multipoint regression" was actually caused by a changed interpolator portfolio.
The old 12-interpolator set passed the Crauste A/B test with or without
multipoint, while the reduced 7-interpolator set failed with or without
multipoint.

## Record These Run Factors

Every benchmark directory should contain a small run manifest with:

- ODEPE git SHA and repository state.
- Benchmarking repository git SHA and dirty diff summary.
- Julia version and `Manifest.toml` hash.
- Python environment or requirements hash.
- Template file name and hash for each run.
- Full interpolator list in order.
- `polish_solutions`, `polish_solver_solutions`, polish method, polish limits.
- `use_multipoint`, `multipoint_n_points`, and `multipoint_max_pairs`.
- `shooting_points`, `shooting_warp`, and `shooting_warp_beta`.
- `use_parameter_homotopy` and solver backend.
- SLURM CPU count, memory, wall time, and array throttle.
- Data directory and data-generation config hash.

This is not bookkeeping for its own sake. It prevents accidental comparisons
between algorithm changes, interpolator changes, environment changes, and data
changes.

## Suggested Preflight Before Full HPC Run

Run a small preflight before launching the full 920-instance or larger matrix.

Suggested models:

- `crauste`
- `hiv`
- `brusselator`
- `cstr`
- `daisy_mamil4`
- `aircraft_pitch`

Suggested noises:

- `0`
- `1e-8`
- `1e-4`
- `1e-2`

Suggested replicas:

- 2 or 3 per model/noise combination.

Launch the full benchmark only after the preflight confirms that the expected
reference cases still behave as expected. In particular, Crauste should be used
as an interpolator-diversity sentinel.

## Model Tiers

Report model tiers separately. A single headline success rate is too easy to
misread because easy models can hide meaningful regressions.

### Sanity Models

These should usually pass and are useful for checking that the pipeline is not
broken:

- `harmonic_oscillator`
- `vanderpol`
- `mass_spring_damper`
- `bicycle_model`
- `dc_motor`
- `lotka_volterra`

### Differential Models

These are useful for distinguishing algorithmic behavior:

- `crauste`
- `hiv`
- `brusselator`
- `daisy_mamil4`
- `aircraft_pitch`
- `seir`
- `biohydrogenation`
- `forced_lotka_volterra`

### Pathological or Special-Handling Models

These should not be allowed to dominate the main score without context:

- `cstr`

CSTR is useful as a stress case, but the current Bilby setup appears to be a
poor experimental design for ordinary success-rate scoring.

## CSTR Recommendation

Keep the CSTR ODE unchanged, but change the data-generation policy. The current
Bilby CSTR examples often have a very fast initial transient followed by a long
weakly forced temperature trajectory. Because the only measurement is
`y1 = 700*Temp`, this makes the hidden concentration and reaction-rate dynamics
hard to infer.

The CSTR equations in Bilby are:

```text
C' = (1 - C) / (2*tau) - 1.999863916554819*r_eff*C

Temp' = (Tin - Temp) / (2*tau)
      + 0.0285694845222117*dH_rhoCP*r_eff*C
      - 2*UA_VrhoCP*Temp
      + 0.8571428571428571*UA_VrhoCP
      + 0.05714285714285714*UA_VrhoCP*sin(0.5*t)

r_eff' = 12.5*r_eff/(Temp^2) * Temp'

y1 = 700*Temp
```

### What Went Wrong In Bilby

In the eight noiseless Bilby CSTR replicas:

- `C` fell below `1e-3` permanently by `t <= 0.2` in 6 of 8 replicas.
- Some replicas depleted `C` by about `t = 0.0267`, only a couple samples into
  the run.
- `r_eff` often changed by many orders of magnitude because of the
  `r_eff / Temp^2` term.
- The late-half temperature signal was only about 12 to 23 units in `y1`, while
  1% additive noise had standard deviation around 2 to 4 units.
- Local output sensitivity was dominated by `Tin`, `Temp0`, `tau`, and `UA`.
  `dH_rhoCP`, `C0`, and `r_eff0` were much less visible in `y1`.
- Several sensitivity directions were strongly confounded, especially `Tin`
  versus `Temp0`.

This means current CSTR failures are not clean evidence of a bad estimator. They
are at least partly evidence of a weak single-output experiment.

### Minimal Fix: Rejection Sampling

Use CSTR-specific rejection sampling during data generation. Keep the ODE and
broad parameter ranges, but reject parameter/initial-condition draws whose
noiseless trajectories are not informative.

For each candidate CSTR draw:

1. Simulate the noiseless trajectory over the planned time window.
2. Compute:
   - `reaction(t) = 1.999863916554819 * r_eff(t) * C(t)`
   - `T_range_late = max(Temp(t)) - min(Temp(t))` over the second half of the
     time window
   - `r_eff_span = log10(max(r_eff) / min(r_eff))`
3. Accept only if all checks pass.

Recommended checks for `[0, 20]`:

```text
C is not permanently below 1e-3 before t = 5.
reaction(t) is not permanently below 5% of its peak before t = 10.
log10(max(r_eff) / min(r_eff)) < 8.
late-half Temp range > 0.015.
```

The last condition corresponds to a late-half range of more than 10.5 units in
`y1 = 700*Temp`.

This filter is deliberately simple and trajectory-based. It avoids changing the
ODE and avoids hand-picking replicas, while excluding experiments where the
reaction effectively dies immediately.

### Optional CSTR Tweaks

If rejection sampling alone is not enough:

- Keep the ODE unchanged but use a CSTR-specific time interval of `[0, 10]` or
  `[0, 12.5]`.
- If using `[0, 10]`, adjust the live-reaction threshold to `t = 5`.
- Constrain `Temp0` away from zero, for example `0.25 <= Temp0 <= 0.75`, because
  `r_eff'` contains `1 / Temp^2`.
- Consider measuring both `Temp` and `C` in a separate CSTR sensitivity
  benchmark. Do not mix that with the unchanged-Bilby comparison unless clearly
  labeled.

Preferred minimal option:

```text
Keep ODE unchanged.
Keep broad parameter/IC sampling.
Keep [0, 20].
Add the four rejection-sampling checks above.
Log accepted CSTR trajectory diagnostics.
```

## Interpolator Portfolio

The multipoint template should not drop the AAA rational interpolators unless
the experiment is explicitly testing that drop.

For the next multipoint run, use at least:

```julia
interpolators = [
    InterpolatorAGPRobust,
    InterpolatorS3AdaptSE,
    InterpolatorChebyshevBIC,
    InterpolatorS3AdaptSExRQ,
    InterpolatorAGPRobustSExRQ,
    InterpolatorChebyshevAICc,
    InterpolatorAAADGPR,
    InterpolatorAAAD,
    InterpolatorS2AAAMLE,
]
```

`InterpolatorAAAD` and `InterpolatorS2AAAMLE` were the key restored
interpolators in the Bilby Crauste investigation. They were also relatively
fast, so restoring them is a low-cost protection against losing useful
interpolator diversity.

## ODEPE Metadata To Save Per Instance

Standardize ODEPE sidecar metadata for every ODEPE variant, not just multipoint.
Recommended fields:

- `status`: `ok`, `no_result`, `error`, `timeout`, or similar.
- `raw_count`
- `best_count`
- Error metrics: min, mean, median, max, RMS, approximation error.
- Best-solution parameters and states.
- Best-solution provenance:
  - primary method
  - interpolator source
  - shooting index
  - multipoint or single-point source
  - rescue path
  - fix sets
  - template status before/after residual fixes
- Maximum relative error and the parameter/state responsible.
- Max derivative order used by the polynomial system.
- For multipoint: derivative orders used after rank trimming.
- Wall time and whether the job hit a SLURM or internal timeout.

This makes post-run diagnosis much faster. It also lets the summary distinguish
"no algebraic solution", "bad solution", "timeout", and "parser failed".

## Analysis Outputs To Add

In addition to existing success-ratio and error tables, generate:

- Per-model tier summaries.
- Old/new paired instance comparison tables.
- Regression and improvement tables by `(system, noise, replica)`.
- Worst-parameter frequency tables.
- Success by interpolator/provenance for ODEPE.
- Runtime versus success scatter summaries.
- Failure reason counts.
- CSTR live-dynamics diagnostics for accepted draws.
- Multipoint derivative-order reports for sentinel models.

For regression analysis, report paired deltas rather than only aggregate
percentages. The important question is often "which exact instances changed?"
rather than "did the overall mean move?"

## Suggested Full Workflow

1. Generate or freeze data.
2. For CSTR, apply live-dynamics rejection sampling during data generation.
3. Write a run manifest before rendering scripts.
4. Generate scripts for all planned variants.
5. Run the sentinel preflight.
6. Compare preflight against old reference behavior.
7. Launch the full benchmark.
8. Collect results into `result.json` and `result.csv`.
9. Generate standard summaries plus paired-delta summaries.
10. Archive the manifest, configs, templates, summary scripts, and key sidecars.

## Success Criteria

A good next benchmark should be able to answer:

- Did current ODEPE improve relative to the old reference on the same data?
- Are improvements caused by algorithm changes, interpolator changes, polishing,
  or multipoint?
- Which systems regressed, and on which noise levels?
- Are regressions concentrated in known pathological systems?
- Does multipoint actually reduce derivative order on the sentinel models?
- For CSTR, did the accepted data contain live reaction dynamics?

If the benchmark cannot answer these questions, it will be hard to interpret the
cluster spend.
