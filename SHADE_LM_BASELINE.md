# SHADE+LM Baseline — Integration Guide

This note documents the SHADE+LM hybrid baseline that was moved into
ODEParameterEstimation on 2026-05-06, and the harness work still needed
before it can run as a `software` in the next big benchmark.

## Why this baseline

The next benchmark adds a third entry alongside ODEPE and AMIGO2. The
prior bilby head-to-head (`benchmark_bilby_2026_03_09`, noise=1e-8,
instance 0, 23 systems) established SHADE+LM as the strongest of the
PragmaticPE strategies (56.5% success vs DE+LM's 52.2%, ISRES+LM's
52.2%, MS-LBFGS's 47.8%, TikTak's 47.8%, eSS port's 39.1%). It's a
hybrid global+local optimizer: SHADE (Success-History Adaptive
Differential Evolution, derivative-free metaheuristic) explores the
bounded box, then top-K SHADE candidates are handed to a Levenberg-
Marquardt local refiner.

The version we're running going forward is **not** the original
PragmaticPE one. It's a re-implementation inside ODEPE that reuses
ODEPE's polish primitives (per-variable `:auto` coordinate transforms,
ForwardDiff Jacobian, revert guard, λ regularization knob, the 2026-05
trust-region tuning). This means the baseline benefits from ODEPE's
empirically validated polish defaults and stays in sync with the ODEPE
pipeline as it evolves.

## What was done (ODEPE side)

New file:

- `~/.julia/dev/ODEParameterEstimation/src/baselines/shade_lm.jl`
  - Public entry: `shade_lm_estimate(PEP::ParameterEstimationProblem;
    opts::EstimationOptions = EstimationOptions()) -> ParameterEstimationResult`
  - Internal: `_run_shade_phase`, `_safe_loss_closure`,
    `_finite_shade_bounds`. The SHADE phase returns a fixed-shape
    `(positions, fvals, n_evals, elapsed)` NamedTuple — that's the
    modularity hook. A future TikTak/DE/ISRES global phase matching the
    same shape drops in by changing one line.

Modified:

- `src/types/estimation_options.jl` — six new fields added to
  `EstimationOptions`:
  - `shade_total_max_evals::Int = 200_000`
  - `shade_total_max_time::Float64 = 600.0`
  - `shade_global_eval_fraction::Float64 = 0.7`
  - `shade_n_local_starts::Int = 5`
  - `shade_population::Int = 0` (0 = auto: `max(50, 10 * n_total)`)
  - `shade_seed::Union{Nothing, UInt} = nothing`
  - All wired into `print_options` and `validate_options`.
- `src/ODEParameterEstimation.jl` — `import Metaheuristics`
  (qualified to avoid colliding with Optim's `optimize`/`minimum`/
  `minimizer`); `include("baselines/shade_lm.jl")`; `export shade_lm_estimate`.
- `Project.toml` — unchanged. `Metaheuristics` was already a declared
  dep, used by `src/examples/benchmarks/benchmark_mega_fixed.jl`.

New test:

- `test/test_shade_lm.jl` — 3 testsets on the `simple()` model
  (2-state, 2-param, both states observed, fully identifiable). Covers
  default `PolishLSOBoundedLog` polish, `PolishFastLMBoundedLog` swap,
  and signed-bounds `:shifted_log` path. Wired into `test/runtests.jl`.
  All 15 tests pass; runtime ~36 s.

PragmaticPE at `~/julia/amigo2-port/PragmaticPE/` is **left alone** as
the original reference implementation. The other four strategies (DE,
MS, TikTak, ISRES) and the eSS port stay where they are.

## How to call it from a script today

```julia
using ODEParameterEstimation

PEP = sample_problem_data(
    fitzhugh_nagumo(),
    EstimationOptions(
        datasize = 21,
        time_interval = [0.0, 0.03],
        noise_level = 0.0,
        opt_lb = fill(1e-5, 5),
        opt_ub = fill(10.0, 5),
    ),
)

result = shade_lm_estimate(PEP; opts = EstimationOptions(
    opt_lb = fill(1e-5, 5),
    opt_ub = fill(10.0, 5),
    shade_total_max_evals = 200_000,
    shade_total_max_time = 600.0,
    shade_n_local_starts = 5,
    polish_method = PolishLSOBoundedLog,    # default; swap to
                                            # PolishFastLMBoundedLog for ~1.8x speed
))

@show result.err
@show result.provenance.primary_method   # :shade_lm
```

Critical: explicit `opt_lb`/`opt_ub` matter. Without them, the
package-default `compute_default_bounds` returns `±1e9 * data_scale`
(sensible for the multishot pipeline because algebraic seeds land near
truth), but useless for a derivative-free metaheuristic on any
realistic budget. Bilby uses `[1e-5, 10]` per parameter; the chevron
template must pass these explicitly.

## What is NOT yet wired into this harness

The benchmark pipeline (this repo) does not yet know about
`odepe_shade` as a software name. Running
`python3 src/estimate.py <bench_dir> odepe_shade <idx>` will fail
with an unknown-software error.

This was deferred deliberately so the ODEPE-side change could be
reviewed and merged on its own. The remaining work is mechanical and
small.

## Pre-benchmark TODO

Six concrete changes, all in this repo. Numbered in execution order.

### 1. Create the chevron template

`templates/julia_template_for_estimation_odepe_shade.jl`. Mirror
`templates/julia_template_for_estimation_odepe_multipoint.jl` but
replace the multishot call at the bottom with:

```julia
opts = EstimationOptions(
    interpolators = [InterpolatorAGPRobust],   # not used by SHADE+LM but harmless
    polish_method = PolishLSOBoundedLog,
    polish_lso_delta = 10.0,
    opt_lb = fill({{lower_bound}}, length(states) + length(parameters)),
    opt_ub = fill({{upper_bound}}, length(states) + length(parameters)),
    shade_total_max_evals = 200_000,
    shade_total_max_time = 600.0,
    shade_n_local_starts = 5,
    abstol = 1e-14,
    reltol = 1e-14,
)

@time result = ODEParameterEstimation.shade_lm_estimate(pep; opts = opts)

# Write CSV in the same column shape as existing odepe templates.
```

The chevron variables (`{{#parameters}}`, `{{#states}}`,
`{{#components}}`, etc.) and the result-CSV writing pattern come
directly from the multipoint template — no new chevron variables
needed.

### 2. Register in `src/generate_scripts.py`

Three dict entries to add:

```python
# TEMPLATE_ESTIMATION
"odepe_shade": "templates/julia_template_for_estimation_odepe_shade.jl",

# SOFTWARE_COMMENT
"odepe_shade": "#",

# FILE_EXT
"odepe_shade": "jl",
```

### 3. Register in `src/shared.py`

```python
# AVAILABLE_SOFTWARE — add 'odepe_shade'
# JULIA_ENVIRONMENTS — point at the existing julia_odepe env:
"odepe_shade": "Symbol(:environments, /, :julia_odepe)",
```

### 4. Update `src/collect_results.py`

The Julia branch around line 100 currently checks
`if software in ("odepe", "pe", "sciml"): ...`. Add `"odepe_shade"`
to that tuple so result.csv is parsed (not stdout).

### 5. Confirm the Julia env

`environments/julia_odepe/Project.toml` does not currently list
`Metaheuristics` directly. It will be available transitively through
ODEPE (which now declares it), but if Julia's environment resolver
picks an inconsistent version, declare it explicitly:

```toml
Metaheuristics = "bcdb8e00-2c21-11e9-3065-2b553b22f898"
```

Pin to `3.4.x` if reproducibility across re-resolves matters.

After editing, run `Pkg.instantiate()` once inside that environment.

### 6. Bounds policy

The chevron template above uses `fill({{lower_bound}}, n)` and
`fill({{upper_bound}}, n)`. Bilby's config sets these to `1e-5` and
`10` respectively. Confirm in `config/systems.json` for the next
benchmark that uniform per-system bounds are still appropriate, or
extend the template to take per-variable bounds if you want them.

## Verification before the full run

The plan from `NEXT_BENCHMARK_RECOMMENDATIONS.md` already calls for a
preflight on `crauste`, `hiv`, `brusselator`, `cstr`, `daisy_mamil4`,
`aircraft_pitch` at noise levels `0`, `1e-8`, `1e-4`, `1e-2`. Add
`odepe_shade` to that preflight matrix. Specific checks to confirm
before the full run:

1. `python3 src/estimate.py <bench_dir> odepe_shade 0` runs to
   completion on at least one system at zero noise and writes a
   non-empty `filetree/odepe_shade/<id>/result.csv` with finite
   parameter columns inside the bounds box.
2. `python3 src/collect_results.py <bench_dir> odepe_shade` parses the
   above without `[WARN] Results for odepe_shade / <id> not found`.
3. On a known-easy system (e.g. `harmonic_oscillator_0_1em8`),
   max relative parameter error < 1%. If not, the wiring is wrong;
   the algorithm itself was validated on `simple()` zero-noise.
4. On the bilby `lotka_volterra_0_1em8` instance (which the prior
   PragmaticPE SHADE+LM solved to 0% error), the new ODEPE-side
   version should land within the same ballpark. If it's
   substantially worse, the polish defaults moved in a way the
   baseline benefits from but the test didn't catch — file an
   investigation before the full run.

## Behavior changes vs. the prior PragmaticPE SHADE+LM

The new version uses ODEPE's polish primitives. Concrete differences:

- **ForwardDiff Jacobian** instead of central finite differences.
  Faster per LM iteration, more accurate gradients. May expose
  ill-conditioning that FD masked.
- **Per-variable coordinate transforms** (`:log`/`:shifted_log`/
  `:linear`) via `:auto` policy, rather than blanket `log()`.
  Handles signed bounds correctly (PragmaticPE silently broke on those).
- **Trust-region radius `Δ = 10`** instead of LSO's default `Δ = 1`.
  From the 2026-05 polish bake-off — modest improvement.
- **`polish_ode_maxiters = 5000`** instead of `1_000_000`. Fast-fail
  on hopeless parameter regions. Speeds up the LM phase considerably
  on adversarial seeds.
- **Residual sentinel `1e6`** for failed ODE solves, not `1e8`.
- **Revert guard** at the polish level — already there in PragmaticPE,
  but ODEPE's also tracks the best iterate seen during scalar polish
  paths.

Net: the ODEPE-side baseline should match or beat PragmaticPE's bilby
numbers, but with a different statistical signature. The preflight
above is the gating signal.

## Modularity hooks (for future sessions)

If you decide later to add TikTak, DE, ISRES, or multistart-LBFGS as
additional baselines:

- The local solver is **already free**. Pass a different `polish_method`
  (`PolishFastLMBoundedLog`, `PolishLBFGS`, `PolishBFGS`,
  `PolishNewtonTrust`, `PolishLevenberg`) via `EstimationOptions`. No
  code changes.
- The global solver swap requires writing one new function matching the
  `_run_shade_phase` contract (returns
  `(positions, fvals, n_evals, elapsed)`) and changing one line in
  `shade_lm_estimate`. Each new global backend ends up at maybe 50
  lines, plus a parallel chevron template here.
