#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=01:00:00
#SBATCH --mem=4GB
#SBATCH --job-name=array_job_iqm
#SBATCH --output=output/array_job_iqm_%A_%a.out
#SBATCH --error=output/array_job_iqm_%A_%a.err
#SBATCH --array=0-49

module purge
module load matlab/2025a

cd $SCRATCH

source no-matlab-no-worry/environments/venv/bin/activate

python no-matlab-no-worry/src/estimate.py no-matlab-no-worry/$1 iqm $SLURM_ARRAY_TASK_ID

