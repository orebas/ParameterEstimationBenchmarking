#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --time=00:30:00
#SBATCH --mem=4GB
#SBATCH --job-name=array_estim_pe
#SBATCH --output=output/array_estim_pe_%A_%a.out
#SBATCH --error=output/array_estim_pe_%A_%a.err
#SBATCH --mail-type=ALL
#SBATCH --mail-user=ad7760@nyu.edu
#SBATCH --array=0-9

module purge

cd $SCRATCH

source venv/bin/activate

python no-matlab-no-worry/src/estimate.py no-matlab-no-worry/2025_05_11_18_49 pe $SLURM_ARRAY_TASK_ID

