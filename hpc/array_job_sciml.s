#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=03:00:00
#SBATCH --mem=8GB
#SBATCH --job-name=array_job_sciml
#SBATCH --output=output/array_job_sciml_%A_%a.out
#SBATCH --error=output/array_job_sciml_%A_%a.err
#SBATCH --array=0-9

module purge

cd $SCRATCH

source no-matlab-no-worry/environments/venv/bin/activate

python no-matlab-no-worry/src/estimate.py no-matlab-no-worry/$1 $2 sciml $SLURM_ARRAY_TASK_ID

