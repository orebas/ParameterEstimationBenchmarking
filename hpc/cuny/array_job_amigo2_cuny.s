#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00
#SBATCH --mem=8GB
#SBATCH --job-name=array_job_amigo2
#SBATCH --partition=partnsf
#SBATCH --output=output/array_job_amigo2_%A_%a.out
#SBATCH --error=output/array_job_amigo2_%A_%a.err
#SBATCH --array=0-49

# CUNY HPC — AMIGO2 (MATLAB) benchmark
# Mirrors hpc/array_job_amigo2.s but with CUNY-specific environment.
#
# Usage (from $SCRATCH):
#   sbatch ParameterEstimationBenchmarking/hpc/cuny/array_job_amigo2_cuny.s <data_dir> <run_name>

module purge
module load Utils/Matlab/R2024b
export PATH="$HOME/julia-1.12.5/bin:$PATH"

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 amigo2 $SLURM_ARRAY_TASK_ID
