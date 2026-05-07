#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --time=10:00:00
#SBATCH --mem=16GB
#SBATCH --job-name=array_job_odepe_v2_nopolish
#SBATCH --output=output/array_job_odepe_v2_nopolish_%A_%a.out
#SBATCH --error=output/array_job_odepe_v2_nopolish_%A_%a.err
#SBATCH --array=0-9

# Same as array_job_odepe_v2_polish.s but ODEPE_POLISH=false in template.
# Faster on average (no log-space LM polish step) but typically lower accuracy.

export JULIA_NUM_THREADS=4

module purge

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 odepe_v2_nopolish $SLURM_ARRAY_TASK_ID
