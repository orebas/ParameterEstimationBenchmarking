#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=06:00:00
#SBATCH --mem=8GB
#SBATCH --job-name=array_job_odepe_shade
#SBATCH --partition=partnsf
#SBATCH --account=gbassikqc
#SBATCH --output=output/array_job_odepe_shade_%A_%a.out
#SBATCH --error=output/array_job_odepe_shade_%A_%a.err
#SBATCH --array=0-9

# CUNY HPC — SHADE+LM benchmark
# Mirrors hpc/array_job_odepe_shade.s but with CUNY-specific environment.
#
# Usage (from $SCRATCH):
#   sbatch ParameterEstimationBenchmarking/hpc/cuny/array_job_odepe_shade_cuny.s <data_dir> <run_name>

export SCRATCH="/scratch/oren-qc-13"

# Stagger startup to avoid NFS contention across concurrent array jobs
sleep $((SLURM_ARRAY_TASK_ID % 20 * 3))

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 odepe_shade $SLURM_ARRAY_TASK_ID
