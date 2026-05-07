#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00
#SBATCH --mem=8GB
#SBATCH --job-name=array_job_odepe_shade
#SBATCH --output=output/array_job_odepe_shade_%A_%a.out
#SBATCH --error=output/array_job_odepe_shade_%A_%a.err
#SBATCH --array=0-9

module purge

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 odepe_shade $SLURM_ARRAY_TASK_ID
