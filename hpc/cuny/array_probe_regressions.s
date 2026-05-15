#!/bin/bash -e
#
# Array probe wrapper: drains the per-line probe_dirs.txt by SLURM_ARRAY_TASK_ID.
# Each task picks one probe dir and runs its script.jl, dumping all opt-in
# instrumentation files (raw_candidates.csv, polished_dump.csv) plus result.csv.
#
# Usage:
#   sbatch --array=0-N%50 hpc/cuny/array_probe_regressions.s
# where N = (lines in probe_dirs.txt) - 1.
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --time=36:00:00
#SBATCH --mem=16GB
#SBATCH --job-name=probe_regr
#SBATCH --partition=partnsf
#SBATCH --account=gbassikqc
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}
export JULIA_CPU_TARGET="generic"

PROBE_LIST="/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/results/numbat_analysis/three_way/probe_dirs.txt"

# Random initial stagger to spread depot load across tasks
sleep $((SLURM_ARRAY_TASK_ID % 20 * 3))

# Pick the probe dir for this task
PROBE_DIR=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$PROBE_LIST")
if [ -z "$PROBE_DIR" ] || [ ! -d "$PROBE_DIR" ]; then
  echo "Bad probe_dir for task $SLURM_ARRAY_TASK_ID: '$PROBE_DIR'" >&2
  exit 1
fi

cd "$PROBE_DIR"
{
  echo "### Probe start: $(date)"
  echo "### probe_dir: $(pwd)"
  echo "### SLURM_JOB_ID: $SLURM_JOB_ID"
  echo "### SLURM_ARRAY_TASK_ID: $SLURM_ARRAY_TASK_ID"
  echo "### SLURM_NODELIST: $SLURM_JOB_NODELIST"
  echo "### JULIA_NUM_THREADS: $JULIA_NUM_THREADS"
} > stdout.txt

t0=$(date +%s)
set +e
julia --startup-file=no \
  --project=/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe \
  script.jl >> stdout.txt 2> stderr.txt
rc=$?
t1=$(date +%s)
set -e

echo "### Probe end: $(date) (exit $rc)" >> stdout.txt
echo $((t1 - t0)) > wall_time_seconds.txt
