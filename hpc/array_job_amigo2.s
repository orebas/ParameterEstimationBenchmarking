#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00
#SBATCH --mem=8GB
#SBATCH --job-name=array_job_amigo2
#SBATCH --output=output/array_job_amigo2_%A_%a.out
#SBATCH --error=output/array_job_amigo2_%A_%a.err
#SBATCH --array=0-49

module purge
module load matlab/2025a

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 amigo2 $SLURM_ARRAY_TASK_ID

