#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00
#SBATCH --mem=8GB
#SBATCH --job-name=array_job_odepe
#SBATCH --output=output/array_job_odepe_%A_%a.out
#SBATCH --error=output/array_job_odepe_%A_%a.err
#SBATCH --mail-type=ALL
#SBATCH --mail-user=ad7760@nyu.edu
#SBATCH --array=0-9

module purge

cd $SCRATCH

source venv/bin/activate

python no-matlab-no-worry/src/estimate.py no-matlab-no-worry/$1 odepe $SLURM_ARRAY_TASK_ID

