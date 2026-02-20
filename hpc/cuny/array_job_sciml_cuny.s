#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=06:00:00
#SBATCH --mem=8GB
#SBATCH --job-name=array_job_sciml
#SBATCH --partition=partnsf
#SBATCH --output=output/array_job_sciml_%A_%a.out
#SBATCH --error=output/array_job_sciml_%A_%a.err
#SBATCH --array=0-9

# CUNY HPC — SciML benchmark
# Mirrors hpc/array_job_sciml.s but with CUNY-specific environment.
#
# Usage (from $SCRATCH):
#   sbatch ParameterEstimationBenchmarking/hpc/cuny/array_job_sciml_cuny.s <data_dir> <run_name>

export SCRATCH="/scratch/oren-qc-13"

module purge
export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 sciml $SLURM_ARRAY_TASK_ID
