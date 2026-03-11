#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --time=36:00:00
#SBATCH --mem=16GB
#SBATCH --job-name=array_job_odepe
#SBATCH --partition=partnsf
#SBATCH --account=gbassikqc
#SBATCH --output=output/array_job_odepe_%A_%a.out
#SBATCH --error=output/array_job_odepe_%A_%a.err
#SBATCH --array=0-9

# CUNY HPC — ODEPE benchmark
# Mirrors hpc/array_job_odepe.s but with CUNY-specific environment.
#
# Usage (from $SCRATCH):
#   sbatch ParameterEstimationBenchmarking/hpc/cuny/array_job_odepe_cuny.s <data_dir> <run_name>

export SCRATCH="/scratch/oren-qc-13"
export JULIA_NUM_THREADS=16

# Stagger startup to avoid NFS contention across concurrent array jobs
sleep $((SLURM_ARRAY_TASK_ID % 20 * 3))

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 odepe $SLURM_ARRAY_TASK_ID
