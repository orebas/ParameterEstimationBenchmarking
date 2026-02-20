#!/bin/bash -e
#SBATCH --job-name=julia_reprecompile
#SBATCH --partition=partnsf
#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=4
#SBATCH --mem=32GB --time=04:00:00
#SBATCH --output=output/julia_reprecompile_%j.out
#SBATCH --error=output/julia_reprecompile_%j.err

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"
export JULIA_NUM_THREADS=4

echo "Node: $(hostname) | Date: $(date) | JULIA_CPU_TARGET: $JULIA_CPU_TARGET"

# Clear ALL compiled caches (leaves packages/registries/artifacts intact)
echo "=== Clearing compiled cache ==="
rm -rf /scratch/oren-qc-13/.julia/compiled/v1.12
echo "Done."

ENV_DIR="/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments"

echo "=== Precompiling julia_odepe ==="
julia --project="$ENV_DIR/julia_odepe" -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

echo "=== Precompiling julia_sciml ==="
julia --project="$ENV_DIR/julia_sciml" -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

echo "=== Smoke test: ODEPE imports ==="
julia --project="$ENV_DIR/julia_odepe" -e '
    using MKL, ODEParameterEstimation, ModelingToolkit, OrdinaryDiffEq
    println("ODEPE imports OK on ", gethostname())
'

echo "=== Smoke test: SciML imports ==="
julia --project="$ENV_DIR/julia_sciml" -e '
    using MKL, ModelingToolkit, OrdinaryDiffEq, Optimization
    using OptimizationPolyalgorithms, OptimizationOptimJL
    using SciMLSensitivity, ForwardDiff
    println("SciML imports OK on ", gethostname())
'

echo "=== Reprecompilation complete ==="
