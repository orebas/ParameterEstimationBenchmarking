#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --time=36:00:00
#SBATCH --mem=16GB
#SBATCH --job-name=array_job_odepe_v2_polish
#SBATCH --partition=partnsf
#SBATCH --account=gbassikqc
#SBATCH --output=output/array_job_odepe_v2_polish_%A_%a.out
#SBATCH --error=output/array_job_odepe_v2_polish_%A_%a.err
#SBATCH --array=0-9

# CUNY HPC — Numbat ODEPE-v2 polish variant
# Mirrors hpc/array_job_odepe_v2_polish.s but with CUNY environment.

export SCRATCH="/scratch/oren-qc-13"
export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}

sleep $((SLURM_ARRAY_TASK_ID % 20 * 3))

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

# MaxArraySize=1001 workaround. Inject INDEX_OFFSET via --export=ALL,INDEX_OFFSET=1000.
REAL_INDEX=$((${INDEX_OFFSET:-0} + SLURM_ARRAY_TASK_ID))
python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 odepe_v2_polish $REAL_INDEX
