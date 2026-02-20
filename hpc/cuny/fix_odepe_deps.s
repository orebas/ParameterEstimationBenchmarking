#!/bin/bash -e
#SBATCH --job-name=fix_deps
#SBATCH --partition=partnsf
#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=1
#SBATCH --mem=8GB --time=00:30:00
#SBATCH --output=output/fix_deps_%j.out
#SBATCH --error=output/fix_deps_%j.err

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"

cd /scratch/oren-qc-13/ParameterEstimationBenchmarking/environments

# Add ModelingToolkit as direct dep to julia_odepe (already in Manifest, just need Project.toml entry)
julia -e '
using Pkg
Pkg.activate("julia_odepe")
Pkg.add("ModelingToolkit")
Pkg.resolve()
println("ModelingToolkit added to julia_odepe")
Pkg.status()
'

# Quick test: can we load the key packages?
echo "=== Testing imports ==="
julia -e '
using Pkg; Pkg.activate("julia_odepe")
using ModelingToolkit, OrdinaryDiffEq
using ODEParameterEstimation, Distributions, OrderedCollections
println("All imports successful!")
println("MTK version: ", pkgversion(ModelingToolkit))
'
