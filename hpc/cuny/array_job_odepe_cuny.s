#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --time=06:00:00
#SBATCH --mem=16GB
#SBATCH --job-name=array_job_odepe
#SBATCH --partition=partnsf
#SBATCH --output=output/array_job_odepe_%A_%a.out
#SBATCH --error=output/array_job_odepe_%A_%a.err
#SBATCH --array=0-9

# CUNY HPC — ODEPE benchmark
# Mirrors hpc/array_job_odepe.s but with CUNY-specific environment.
#
# Usage (from $SCRATCH):
#   sbatch ParameterEstimationBenchmarking/hpc/cuny/array_job_odepe_cuny.s <data_dir> <run_name>

export JULIA_NUM_THREADS=4

module purge
export PATH="$HOME/julia-1.12.5/bin:$PATH"

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 odepe $SLURM_ARRAY_TASK_ID
