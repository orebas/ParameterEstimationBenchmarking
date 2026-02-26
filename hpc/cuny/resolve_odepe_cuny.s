#!/bin/bash -e
#SBATCH --job-name=resolve_odepe
#SBATCH --partition=partnsf
#SBATCH --account=gbassikqc
#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=4
#SBATCH --mem=32GB --time=02:00:00
#SBATCH --output=output/resolve_odepe_%j.out
#SBATCH --error=resolve_odepe_%j.err

# Resolve and precompile julia_odepe after updating ODEParameterEstimation source.
# Run this after `git pull` on environments/ODEParameterEstimation.

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"
export JULIA_NUM_THREADS=4

echo "Node: $(hostname) | Date: $(date)"

ENV_DIR="/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments"

# Clear compiled cache for clean precompilation
echo "=== Clearing compiled cache ==="
rm -rf /scratch/oren-qc-13/.julia/compiled/v1.12
echo "Done."

echo "=== Resolving + precompiling julia_odepe ==="
julia --project="$ENV_DIR/julia_odepe" -e '
    using Pkg
    Pkg.resolve()
    Pkg.instantiate()
    Pkg.precompile()
'

echo "=== Smoke test: ODEPE imports ==="
julia --project="$ENV_DIR/julia_odepe" -e '
    using MKL, ODEParameterEstimation, ModelingToolkit, OrdinaryDiffEq
    println("ODEPE version: ", pkgversion(ODEParameterEstimation))
    println("ODEPE imports OK on ", gethostname())
'

echo "=== Resolution complete ==="
