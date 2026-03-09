# Biohydrogenation Interpolator Benchmark — Handoff Guide

## What This Does

Tests **11 interpolators + 1 combined run** on the biohydrogenation model (the model that had 0% success in the quokka benchmark). Uses the **scaled equations** from the quokka pipeline — the unscaled model is numerically unstable.

## Quick Start

```bash
# Run from any directory — uses global Julia environment (NOT --project=.)
julia /path/to/benchmarks/biohydro_interpolator_benchmark.jl
```

The script is self-contained. It builds the model from scratch, generates data, and runs all interpolators at 3 noise levels.

**Expected runtime:** ~45 min per noise level on a single core (~2.5 hours total).

## What It Tests

| # | Enum | Short Name | Type |
|---|------|------------|------|
| 1 | `InterpolatorAAAD` | AAAD | Pure barycentric (baseline) |
| 2 | `InterpolatorAAADGPR` | AAAD_GPR | AAA + GP refinement |
| 3 | `InterpolatorS2AAAMLE` | S2_AAA_MLE | AAA on raw data → MLE refinement |
| 4 | `InterpolatorAGPRobust` | GP_SE | GP with SE kernel |
| 5 | `InterpolatorAGPRobustRQ` | GP_RQ | GP with RQ kernel |
| 6 | `InterpolatorAGPRobustSEpRQ` | GP_SEpRQ | GP with SE+RQ sum kernel |
| 7 | `InterpolatorAGPRobustSExRQ` | GP_SExRQ | GP with SE×RQ product kernel |
| 8 | `InterpolatorS3SE` | S3_SE | GP(SE) → AAA → MLE |
| 9 | `InterpolatorS3RQ` | S3_RQ | GP(RQ) → AAA → MLE |
| 10 | `InterpolatorS3SEpRQ` | S3_SEpRQ | GP(SE+RQ) → AAA → MLE |
| 11 | `InterpolatorS3SExRQ` | S3_SExRQ | GP(SE×RQ) → AAA → MLE |
| 12 | ALL_COMBINED | — | All 11 in one `interpolators` call |

**Noise levels:** 0, 1e-8, 1e-6 (additive: `y + mean(y) * σ * randn`)

## Model Spec (Scaled Biohydrogenation)

```julia
D(x4) ~ (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4))
D(x5) ~ ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5
D(x6) ~ ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5
D(x7) ~ (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10)

y1 ~ 8.0*x4     # scaled measurement
y2 ~ 0.5*x5     # scaled measurement
```

- **True params:** k5=0.688, k6=0.87, k7=0.299, k8=0.561, k9=0.574, k10=0.558
- **True ICs:** x4=0.278, x5=0.862, x6=0.458, x7=0.777
- **Time:** [0.0, 10.0], 1501 points
- **Polishing:** OFF

## Key API Details

### Multi-Interpolator Pipeline

The ODEPE multi-interpolator feature runs the expensive SIAN/identifiability analysis **once**, then loops over interpolators doing only interpolation + HC solve per interpolator.

```julia
# Single interpolator
opts = EstimationOptions(interpolators = [InterpolatorAAAD], ...)

# Multi-interpolator (shares SIAN analysis)
opts = EstimationOptions(interpolators = [InterpolatorAAAD, InterpolatorS3SE, ...], ...)
```

### Return Structure

```julia
res = analyze_parameter_estimation_problem(pep, opts)
results_vec = res[1][1]  # Vector{ParameterEstimationResult}
# Each result has: .parameters, .states, .err, .interpolator_source
```

### Building the Model

Use `create_ordered_ode_system()` — do NOT use the built-in `biohydrogenation()` which has unscaled equations.

```julia
model, mq = create_ordered_ode_system("biohydrogenation", states, params, equations, measurements)
```

## Adapting for HPC / Cluster

To parallelize across noise levels, split the `NOISE_LEVELS` array and run separate Julia processes. Each noise level is independent.

To run a single interpolator at a single noise level (for SLURM array jobs):

```julia
INTERP_IDX = parse(Int, ENV["SLURM_ARRAY_TASK_ID"])  # 1-12
NOISE_IDX = parse(Int, ENV["NOISE_IDX"])               # 1-3

interp = INTERPOLATORS[INTERP_IDX]
noise = NOISE_LEVELS[NOISE_IDX]
# ... build pep, run single estimation
```

## Expected Results (noise=0, from local run)

| Interpolator | #Sol | Best Err | Time |
|---|---|---|---|
| AAAD | 54 | 2.64e-13 | 102s |
| AAAD_GPR | 43 | 3.13e-07 | 52s |
| S2_AAA_MLE | 54 | 2.64e-12 | 24s |
| GP_SE | 42 | 5.15e-06 | 79s |
| GP_RQ | 47 | 2.05e-06 | 212s |
| GP_SEpRQ | 43 | 2.77e-06 | 272s |
| GP_SExRQ | 46 | 1.42e-06 | 280s |
| S3_SE | 44 | 1.30e-09 | 83s |
| S3_RQ | 34 | 8.68e-05 | 255s |
| S3_SEpRQ | 45 | 5.93e-09 | 268s |
| S3_SExRQ | 44 | 2.44e-09 | 274s |
| ALL_COMBINED | 502 | 2.64e-13 | 606s |

ALL_COMBINED confirmed sources from all 11 interpolators.

## Dependencies

- Julia 1.12+ with global environment containing:
  - ODEParameterEstimation (from `~/.julia/dev/ODEParameterEstimation/`, commit `87cbf74` or later)
  - ModelingToolkit 11, Symbolics 7, SIAN 1.8.0
- **Do NOT use `--project=.`** — the project env is stale
