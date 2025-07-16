#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=01:00:00
#SBATCH --mem=4GB
#SBATCH --job-name=array_job_amigo2
#SBATCH --output=output/array_job_amigo2_%A_%a.out
#SBATCH --error=output/array_job_amigo2_%A_%a.err
#SBATCH --mail-type=ALL
#SBATCH --mail-user=ad7760@nyu.edu
#SBATCH --array=0-49

module purge
# module load matlab/2024a
module load matlab/2025a
module load anaconda3/2024.02
# module load gcc/10.2.0
# module load gmp/gcc/6.2.1

# export gcc=/usr/bin/gcc

# export MATLAB_PREFDIR=$(mktemp -d $SLURM_JOBTMP/matlab-XXXX)
# export MATLAB_LOG_DIR=$SLURM_JOBTMP

cd $SCRATCH

source activate env/
source venv/bin/activate

python no-matlab-no-worry/src/estimate.py no-matlab-no-worry/EXAMPLE amigo2 $SLURM_ARRAY_TASK_ID

