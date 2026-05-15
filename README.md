# Parameter Estimation Benchmarking

A benchmarking harness for comparing ODE parameter estimation methods across a suite of dynamical systems from control theory, biology, chemistry, epidemiology, and other domains.

## Overview

This repository generates synthetic ODE data, runs multiple parameter estimation methods on each system under varying noise levels, and collects/summarizes the results. It supports the following estimation backends:

- **ODEPE** — ODE Parameter Estimation via Gaussian Process Regression
- ODEPE runs now also write an optional `odepe_metadata.json` next to `result.csv` for debugging/provenance; collectors still use `result.csv` as the compatibility artifact.
- **SciML** — Scientific Machine Learning (Julia/DiffEqFlux)
- **AMIGO2** — Advanced Model Identification using Global Optimization (MATLAB)
- **PE** — ParameterEstimation.jl (Julia)

## Benchmark Systems

| System | Domain | Parameters |
|---|---|---|
| Aircraft Pitch | Control | 4 |
| Bicycle Model | Control | 4 |
| Biohydrogenation | Biology | 6 |
| Boost Converter | Control | 3 |
| Brusselator | Chemistry | 2 |
| Crauste | Immunology | 12 |
| CSTR | Chemistry | 5 |
| DAISY Mamil3 | Compartmental | 5 |
| DAISY Mamil4 | Compartmental | 7 |
| DC Motor | Control | 3 |
| FitzHugh-Nagumo | Neuroscience | 3 |
| Flexible Arm | Control | 6 |
| Forced Lotka-Volterra | Ecology | 4 |
| Harmonic Oscillator | Mechanics | 2 |
| HIV | Immunology | 10 |
| Lotka-Volterra | Ecology | 3 |
| Mass-Spring-Damper | Control | 4 |
| Quadrotor | Control | 2 |
| Repressilator | Synth. Biology | 3 |
| SEIR | Epidemiology | 3 |
| SIRT Treatment | Epidemiology | 5 |
| Slow-Fast | Dynamical Sys. | 2 |
| Two-Compartment PK | Pharmacology | 5 |
| Van der Pol | Dynamical Sys. | 2 |

## Requirements

- **Python** 3.9+
- **Julia** 1.11+
- **MATLAB** (for AMIGO2 backend only)
- Python packages: see `environments/requirements.txt`
- Julia packages: instantiated via `environments/julia_*/Project.toml`

## Quick Start

```bash
# Clone the repository
git clone https://github.com/orebas/ParameterEstimationBenchmarking
cd ParameterEstimationBenchmarking

# Install Python dependencies
pip install -r environments/requirements.txt

# Generate synthetic data
python src/generate_data.py config/config.json config/systems.json

# Generate estimation scripts (e.g., for ODEPE)
python src/generate_scripts.py <data_dir> odepe

# Run estimation
python src/estimate.py <data_dir> <run_dir> odepe <array_indices>

# Collect results
python src/collect_results.py <data_dir>

# Summarize
python src/summarize_results.py <data_dir>
```

## Directory Structure

```
config/              Configuration files (systems, benchmark parameters)
environments/        Python requirements and Julia project environments
hpc/                 SLURM job scripts for HPC clusters
src/                 Core Python pipeline (data gen, script gen, estimation, collection)
templates/           Julia/MATLAB template files for each estimation backend
```

## Running the Full Benchmark on HPC (SLURM)

The benchmark runs **4 estimators** across all 24 systems, 5 noise levels, and 10 trials each = **4800 total jobs**.

| Run | Estimator | HPC script | Time | Mem |
|-----|-----------|------------|------|-----|
| `amigo2_run` | AMIGO2 (eSS+nl2sol) | `hpc/array_job_amigo2.s` | 4h | 8GB |
| `sciml_run` | SciML (BFGS, 200k iters) | `hpc/array_job_sciml.s` | 3h | 8GB |
| `odepe_nopolish` | ODEPE (algebraic only) | `hpc/array_job_odepe.s` | 6h | 16GB |
| `odepe_polish` | ODEPE (algebraic + BFGS) | `hpc/array_job_odepe.s` | 6h | 16GB |

### Step 1: Generate synthetic data (once)

```bash
python3 src/generate_data.py config/config.json config/systems.json -d benchmark_2026_02
```

### Step 2: Generate estimation scripts

```bash
# AMIGO2 and SciML
python3 src/generate_scripts.py benchmark_2026_02 -s amigo2 -r amigo2_run
python3 src/generate_scripts.py benchmark_2026_02 -s sciml -r sciml_run

# ODEPE no-polish run (disable polish in config, generate, then re-enable)
python3 -c "
import json
with open('benchmark_2026_02/config/config.json') as f: cfg = json.load(f)
cfg['ODEPE_POLISH'] = 'false'
with open('benchmark_2026_02/config/config.json', 'w') as f: json.dump(cfg, f, indent=2)
"
python3 src/generate_scripts.py benchmark_2026_02 -s odepe -r odepe_nopolish

# ODEPE polish run (re-enable polish)
python3 -c "
import json
with open('benchmark_2026_02/config/config.json') as f: cfg = json.load(f)
cfg['ODEPE_POLISH'] = 'true'
with open('benchmark_2026_02/config/config.json', 'w') as f: json.dump(cfg, f, indent=2)
"
python3 src/generate_scripts.py benchmark_2026_02 -s odepe -r odepe_polish
```

### Step 3: Submit HPC jobs (array 0–1199 for all 1200 instances)

```bash
./hpc/submit.sh --array=0-1199 hpc/array_job_amigo2.s benchmark_2026_02 amigo2_run
./hpc/submit.sh --array=0-1199 hpc/array_job_sciml.s benchmark_2026_02 sciml_run
./hpc/submit.sh --array=0-1199 hpc/array_job_odepe.s benchmark_2026_02 odepe_nopolish
./hpc/submit.sh --array=0-1199 hpc/array_job_odepe.s benchmark_2026_02 odepe_polish
```

The `submit.sh` wrapper prompts for your email on first run (saved to `hpc/user_config.sh`, git-ignored).

### Step 4: Collect results (after all jobs complete)

```bash
python3 src/collect_results.py benchmark_2026_02 amigo2_run sciml_run odepe_nopolish odepe_polish
```

**Note:** By default, `.julia` is located in `$HOME`. If `$HOME` has limited quota, set `export JULIA_DEPOT_PATH=$SCRATCH` before running Julia.

## Recent research notes (numbat 2026-05 investigation)

A three-doc package summarizing what we learned during the May 2026 numbat
reruns and the resulting open questions. Read these together when picking
up clustering / polish / output-filtering work:

- [`results/numbat_analysis/three_way/HANDOFF.md`](results/numbat_analysis/three_way/HANDOFF.md)
  — full writeup of the investigation: pipeline overview, the 5 key
  findings (polish concurrency bug, `_detect_branches` over-clustering,
  practical non-identifiability, ODE-solver-induced polish failures, err
  filter), headline 4-way benchmark comparison, repro recipes for every
  analysis script, and a per-system "hardest cases" map.
- [`results/numbat_analysis/three_way/INVESTIGATION_column_scaling.md`](results/numbat_analysis/three_way/INVESTIGATION_column_scaling.md)
  — open investigation 1. Numbat-empirical extension of the ODEPE-side
  design doc at
  [`environments/ODEParameterEstimation/docs/2026-05-01_variable_scaling_investigation.md`](environments/ODEParameterEstimation/docs/2026-05-01_variable_scaling_investigation.md).
  Concrete failing cells (brusselator_6_0 et al.), diagnostic-first plan,
  Level A implementation recommendation, evaluation protocol.
- [`results/numbat_analysis/three_way/INVESTIGATION_denoised_polish_target.md`](results/numbat_analysis/three_way/INVESTIGATION_denoised_polish_target.md)
  — open investigation 2 (speculative). Proposal to polish against a
  GP-smoothed or blended target instead of raw noisy data. Includes a
  candid risks section; recommended to attempt after column scaling pans
  out (or doesn't).

## Citation

If you use this benchmark suite in your research, please cite:

```bibtex
@article{TODO,
  title  = {TODO},
  author = {TODO},
  year   = {2026}
}
```

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
