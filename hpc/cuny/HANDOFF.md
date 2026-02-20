# CUNY HPC Benchmark Handoff

This document is written for the Claude Code instance running on the CUNY HPC
cluster (Arrow). It contains everything needed to set up and run the
`ParameterEstimationBenchmarking` benchmark suite. All cluster values were
verified via SSH session on 2026-02-19.

## 1. Cluster Facts

| Property | Value |
|----------|-------|
| Cluster name | Arrow |
| Scheduler | SLURM |
| Login node | MHN (via bastion `chizen.csi.cuny.edu`) |
| Architecture | x86_64, AMD EPYC |
| Module system | Lmod (`module avail`, `module spider`) |
| Account | `gbassikqc` |
| Default QOS | `qosnsf` |
| Default partition | `partnsf` (marked with `*`) |

### Partitions (from `sinfo`)

```
PARTITION  AVAIL  TIMELIMIT   NODES(A/I/O/T)
debug        up   infinite       10/23/3/36
partnsf*     up 5-00:00:00        5/19/0/24
partcfd      up   infinite          0/3/0/3
partphys     up   infinite          2/0/0/2
partchem     up   infinite          3/0/0/3
partsym      up   infinite          1/0/0/1
partasrc     up   infinite          1/0/0/1
```

**Important:** There are NO dedicated MATLAB partitions. All jobs use `partnsf`.

### Storage

| Path | Quota | Purge |
|------|-------|-------|
| `/global/u/<userid>` (home, `$HOME`) | 50 GB | Never (backed up) |
| `/scratch/<userid>` (`$SCRATCH`) | No quota | 2 weeks idle or 70% full |

### `partnsf` Resources

- 24 nodes, 1896 CPUs total, ~8 TB RAM, 26 GPUs
- Max wall time: 5 days (120 hours)

## 2. Software Available

### Key Modules

| Category | Module | Notes |
|----------|--------|-------|
| MATLAB | `Utils/Matlab/R2024b` | Only version. Network license broken — uses online licensing. See `MATLAB_WORKAROUNDS.md` |
| Python | `Python/3.13.7_gnu` (D) | Also: 3.10.12, 3.11.4, 3.11.5 |
| GNU compiler | `GNU/15.2.0` (D) | Also: 9.3.0 through 14.2.0 |
| Julia (module) | `DevEnv/Julia/1.9.1` | **Too old — do NOT use** |
| CUDA | `Sys/CUDA/12.1.1` | |
| Git | `Utils/git/2.51.1` | **No HTTPS support** — use `curl` for downloads |
| MPI | `OpenMPI/5.0.0_gnu` (D) | |

(D) = default version

### Julia — Manual Install Required

The cluster module `DevEnv/Julia/1.9.1` is too old. Install Julia 1.12.5 manually:

```bash
cd ~
curl -fsSL https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-1.12.5-linux-x86_64.tar.gz | tar xz
```

This creates `~/julia-1.12.5/bin/julia`. All job scripts add it to PATH:
```bash
export PATH="$HOME/julia-1.12.5/bin:$PATH"
```

Install to `$HOME` (not scratch) so it persists across purges.

## 3. The Benchmark Pipeline

This repo is `orebas/ParameterEstimationBenchmarking` (forked from
`sumiya11/no-matlab-no-worry`), default branch: `master`.

### Pipeline Overview

```
generate_data.py → generate_scripts.py → estimate.py → collect_results.py
```

1. **`src/generate_data.py`** — Creates synthetic ODE data for all systems in
   `config/systems.json`. Writes instance files under a data directory.

2. **`src/generate_scripts.py`** — Uses Chevron/Mustache templates to generate
   Julia/MATLAB estimation scripts from `templates/`.

3. **`src/estimate.py`** — The main entry point called by SLURM jobs:
   ```bash
   python src/estimate.py <data_dir> <run_name> <estimator> <instance_idx>
   ```
   Estimators: `odepe`, `sciml`, `amigo2`, `pe`

4. **`src/collect_results.py`** — Aggregates individual results into summary CSVs.

### Julia Environments

Three separate Julia environments under `environments/`:

| Directory | Purpose | Key Packages |
|-----------|---------|-------------|
| `julia_pe/` | Shared PE utilities | ParameterEstimation.jl |
| `julia_odepe/` | ODEPE estimator | ODEParameterEstimation.jl |
| `julia_sciml/` | SciML estimator | DiffEqFlux, Optimization |

### Python venv

The benchmark expects `environments/venv/` with pandas, chevron, etc.
Job scripts activate it with:
```bash
source ParameterEstimationBenchmarking/environments/venv/bin/activate
```

### How `estimate.py` Calls Julia

It generates a Julia script from a Mustache template, then runs bare `julia`
(must be in `$PATH`). The `--project=` flag points to the appropriate
environment directory.

### Calling Convention (NYU Pattern)

All SLURM scripts follow the same pattern:
```bash
cd $SCRATCH
source ParameterEstimationBenchmarking/environments/venv/bin/activate
python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 <estimator> $SLURM_ARRAY_TASK_ID
```

Arguments `$1` = data directory (relative to repo), `$2` = run name.
Each array task runs one instance.

## 4. NYU → CUNY Differences

| Feature | NYU (Greene) | CUNY (Arrow) |
|---------|-------------|-------------|
| Partition | (none specified / varies) | `--partition=partnsf` |
| Julia | `module load julia/X.Y.Z` (assumed) | `export PATH="$HOME/julia-1.12.5/bin:$PATH"` |
| MATLAB | `module load matlab/2025a` | `module load Utils/Matlab/R2024b` |
| Git HTTPS | Works | **Broken** — use `curl` for tarballs |
| Test partition | (none) | `--partition=debug` |
| Login | Direct SSH | Two-hop via `chizen.csi.cuny.edu` |
| Repo name on disk | `no-matlab-no-worry` | `ParameterEstimationBenchmarking` |
| `$SCRATCH` | Available | Available (same convention) |
| Output dir | `output/` (relative to `$SCRATCH`) | Same |

The CUNY scripts in `hpc/cuny/` are exact mirrors of the NYU scripts in `hpc/`
with only partition + module lines changed.

## 5. Step-by-Step Setup

Follow these steps IN ORDER on the CUNY cluster.

### Step 1: Install Julia

```bash
cd ~
curl -fsSL https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-1.12.5-linux-x86_64.tar.gz | tar xz
export PATH="$HOME/julia-1.12.5/bin:$PATH"
julia --version   # Should show 1.12.5
```

Add to `~/.bashrc` for persistence:
```bash
echo 'export PATH="$HOME/julia-1.12.5/bin:$PATH"' >> ~/.bashrc
```

### Step 2: Clone the Repo

```bash
cd $SCRATCH
# git HTTPS is broken on compute nodes, so use curl:
curl -fsSL https://github.com/orebas/ParameterEstimationBenchmarking/archive/refs/heads/master.tar.gz | tar xz
mv ParameterEstimationBenchmarking-master ParameterEstimationBenchmarking
```

Or if on the login node where git works:
```bash
cd $SCRATCH
git clone https://github.com/orebas/ParameterEstimationBenchmarking.git
```

### Step 3: Create Output Directory

```bash
mkdir -p $SCRATCH/output
```

### Step 4: Set Up Python Environment

```bash
cd $SCRATCH/ParameterEstimationBenchmarking
python3 -m venv environments/venv
source environments/venv/bin/activate
pip install pandas chevron numpy scipy
```

### Step 5: Set Up Julia Environments

```bash
export PATH="$HOME/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="$SCRATCH/.julia"
cd $SCRATCH/ParameterEstimationBenchmarking

for env in julia_pe julia_odepe julia_sciml; do
    echo "=== Setting up $env ==="
    julia --project=environments/$env -e '
        using Pkg
        Pkg.instantiate()
        Pkg.precompile()
    '
done
```

**This takes 30-60 minutes.** Consider running as a SLURM job on a compute
node rather than the login node.

### Step 6: Generate Benchmark Data

```bash
cd $SCRATCH
source ParameterEstimationBenchmarking/environments/venv/bin/activate
python ParameterEstimationBenchmarking/src/generate_data.py
python ParameterEstimationBenchmarking/src/generate_scripts.py
```

### Step 7: Run Connectivity Test

```bash
cd $SCRATCH
sbatch ParameterEstimationBenchmarking/hpc/cuny/test_connectivity.sh
# Wait, then check:
cat output/cuny_test_*.out
```

### Step 8: Single-Instance Test

```bash
cd $SCRATCH
sbatch --array=0 ParameterEstimationBenchmarking/hpc/cuny/array_job_odepe_cuny.s benchmark_2026_02 odepe_test
# Check:
cat output/array_job_odepe_*.out
```

### Step 9: Full Benchmark

```bash
cd $SCRATCH

# Use submit.sh wrapper (handles email notifications) or sbatch directly:
sbatch --array=0-99 ParameterEstimationBenchmarking/hpc/cuny/array_job_odepe_cuny.s benchmark_2026_02 odepe_nopolish
sbatch --array=0-99 ParameterEstimationBenchmarking/hpc/cuny/array_job_odepe_cuny.s benchmark_2026_02 odepe_polish
sbatch --array=0-99 ParameterEstimationBenchmarking/hpc/cuny/array_job_sciml_cuny.s benchmark_2026_02 sciml_run
sbatch --array=0-49 ParameterEstimationBenchmarking/hpc/cuny/array_job_amigo2_cuny.s benchmark_2026_02 amigo2_run
```

Adjust `--array` range to match the number of instances generated.
The `run_in_slurm.py` manager can also handle batching automatically:
```bash
cd $SCRATCH
python ParameterEstimationBenchmarking/hpc/run_in_slurm.py benchmark_2026_02 --max-cpus=1800
```
(May need edits to point at `hpc/cuny/` scripts instead of `hpc/` scripts.)

### Step 10: Collect Results

```bash
cd $SCRATCH
source ParameterEstimationBenchmarking/environments/venv/bin/activate
python ParameterEstimationBenchmarking/src/collect_results.py benchmark_2026_02
```

## 6. Key Gotchas

### JULIA_DEPOT_PATH
Julia's package cache can grow to 10+ GB. With a 50 GB home quota, set:
```bash
export JULIA_DEPOT_PATH="$SCRATCH/.julia"
```
Add to `~/.bashrc`. **Risk:** scratch purge deletes packages — re-run Step 5.

### Scratch Purge
Files idle for 2 weeks get purged. Keep jobs running to refresh timestamps.
Back up results off-cluster.

### Git HTTPS is Broken
`Utils/git/2.51.1` lacks HTTPS support (`remote-https` not found). Use:
- `curl` + tarball extraction (shown in Step 2)
- SSH git if you have keys configured
- Login node where system git may work

### MKL
If Julia templates `using MKL` fails, try `module load Libs/MKL/2024.2` or
remove MKL usage from templates.

### estimate.py Paths
The first argument to `estimate.py` is a path relative to `$SCRATCH`, NOT
relative to the repo. That's why scripts pass
`ParameterEstimationBenchmarking/$1` — prepending the repo name.

### AMIGO2 / MATLAB Configuration
Set `PATH_TO_AMIGO2` in `config/config.json` before running AMIGO2 benchmarks.

**MATLAB requires two workarounds on this cluster.** See `MATLAB_WORKAROUNDS.md`
for full details. In brief:
1. The network license server is down. Online licensing is used instead
   (`-licmode onlinelicensing` added to `src/estimate.py`). Requires one-time
   interactive activation with a MathWorks account.
2. Most compute nodes are missing X11 libraries that MATLAB R2024b needs even
   in headless mode. 38 libraries are bundled in `$SCRATCH/.matlab_libs/` and
   loaded via `LD_LIBRARY_PATH` in the SLURM script.

## 7. Monitoring

```bash
squeue -u $USER                    # check running jobs
sacct -j <JOBID> --format=JobID,State,Elapsed,MaxRSS,ExitCode
cat $SCRATCH/output/*.out          # job output
scancel <JOBID>                    # cancel one job
scancel -u $USER                   # cancel all
sinfo -p partnsf                   # partition status
```

## 8. Files in `hpc/cuny/`

| File | Purpose |
|------|---------|
| `array_job_odepe_cuny.s` | SLURM job for ODEPE (4 CPU, 16 GB, 6 hr) |
| `array_job_sciml_cuny.s` | SLURM job for SciML (1 CPU, 8 GB, 3 hr) |
| `array_job_amigo2_cuny.s` | SLURM job for AMIGO2/MATLAB (1 CPU, 8 GB, 4 hr) |
| `test_connectivity.sh` | Connectivity test (debug partition, 30 min) |
| `setup_cuny.sh` | Environment discovery (run on login node) |
| `rerun_failed.sh` | Generate rerun scripts for failed instances |
| `MATLAB_WORKAROUNDS.md` | MATLAB licensing & missing X11 lib fixes |
| `HANDOFF.md` | This file |

These mirror the NYU scripts in `hpc/` with CUNY-specific partition and module settings.
