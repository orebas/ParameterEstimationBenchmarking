#!/bin/bash -e
#SBATCH --job-name=julia_setup
#SBATCH --partition=partnsf
#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=4
#SBATCH --mem=32GB --time=04:00:00
#SBATCH --output=output/julia_setup_%j.out
#SBATCH --error=output/julia_setup_%j.err

# Julia env setup for CUNY HPC.
# Repos already cloned + compat-stripped on login node.
# This script only does the Julia Pkg operations (heavy, needs compute node).

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"

cd /scratch/oren-qc-13/ParameterEstimationBenchmarking/environments

echo "=== Setting up julia_odepe environment ==="
rm -rf julia_odepe
julia -e '
using Pkg
Pkg.activate("julia_odepe")

# Dev the compat-stripped dependencies first
Pkg.develop(path="SIAN-Julia/")
Pkg.develop(path="StructuralIdentifiability.jl/")

# Dev ODEPE (depends on SIAN + SI)
Pkg.develop(path="ODEParameterEstimation/")

# Add remaining direct dependencies needed by the templates
Pkg.add([
    "MKL",
    "OrdinaryDiffEq",
    "BenchmarkTools",
    "OrderedCollections",
    "CSV",
    "GaussianProcesses",
    "Optim",
    "LineSearches",
    "Symbolics",
    "Distributions",
    "Statistics",
    "JSON",
])

Pkg.resolve()
Pkg.instantiate()

println("\n=== julia_odepe manifest (key packages) ===")
Pkg.status(mode=Pkg.PKGMODE_MANIFEST)
'

echo ""
echo "=== Setting up julia_sciml environment ==="
rm -rf julia_sciml
julia -e '
using Pkg
Pkg.activate("julia_sciml")

Pkg.add([
    "MKL",
    "CSV",
    "Distributions",
    "ForwardDiff",
    "ModelingToolkit",
    "Optimization",
    "OptimizationOptimJL",
    "OptimizationPolyalgorithms",
    "OrdinaryDiffEq",
    "SciMLSensitivity",
    "StaticArrays",
])

Pkg.resolve()
Pkg.instantiate()

println("\n=== julia_sciml manifest (key packages) ===")
Pkg.status(mode=Pkg.PKGMODE_MANIFEST)
'

echo ""
echo "=== Setup complete ==="
echo "julia_odepe: MTK v11 + ODEPE (dev) + SIAN (dev, compat stripped) + SI (dev, compat stripped)"
echo "julia_sciml: MTK v11 + SciML optimization stack"
