#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --time=10:00:00
#SBATCH --mem=16GB
#SBATCH --job-name=array_job_odepe_v2_polish
#SBATCH --output=output/array_job_odepe_v2_polish_%A_%a.out
#SBATCH --error=output/array_job_odepe_v2_polish_%A_%a.err
#SBATCH --array=0-9

# Numbat-era ODEPE estimator with multipoint + synthesize_aggregate_candidates
# + PolishLSOBoundedLog. Per-cell sidecars: result.csv, odepe_metadata.json
# (provenance), wall_time_seconds.txt, ===END=== sentinel in stdout.
#
# Submit (preflight subset, instance 0 only — every 10th index of 1150):
#   ./hpc/submit.sh --array=0-1140:10%50 hpc/array_job_odepe_v2_polish.s \
#       benchmark_numbat_2026-05-06 odepe_v2_polish_run
#
# Submit (full numbat — 1150 cells with 50-way concurrency cap):
#   ./hpc/submit.sh --array=0-1149%50 hpc/array_job_odepe_v2_polish.s \
#       benchmark_numbat_2026-05-06 odepe_v2_polish_run

export JULIA_NUM_THREADS=4

module purge

cd $SCRATCH

source ParameterEstimationBenchmarking/environments/venv/bin/activate

python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$1 $2 odepe_v2_polish $SLURM_ARRAY_TASK_ID
