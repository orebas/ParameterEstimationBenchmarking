#!/bin/bash -e
#SBATCH --job-name=test_dg
#SBATCH --partition=partnsf
#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=1
#SBATCH --mem=8GB --time=00:30:00
#SBATCH --output=output/test_dg_%j.out
#SBATCH --error=output/test_dg_%j.err

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"

cd /scratch/oren-qc-13/ParameterEstimationBenchmarking

# Run one data generation script directly to see the full error
julia benchmark_2026_02/filetree/data_generation/aircraft_pitch_0.jl 2>&1
