#!/bin/bash -e
#
# Single-cell probe SLURM script. Generic — takes a probe dir as $1.
# Probe dir must contain a self-contained script.jl + data.csv (or symlink).
# Output: stdout.txt, stderr.txt, result.csv, odepe_metadata.json in probe dir.
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --time=24:00:00
#SBATCH --mem=16GB
#SBATCH --job-name=probe_one_cell
#SBATCH --partition=partnsf
#SBATCH --account=gbassikqc
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}
export JULIA_CPU_TARGET="generic"

PROBE_DIR="$1"
if [ -z "$PROBE_DIR" ] || [ ! -d "$PROBE_DIR" ]; then
  echo "Usage: sbatch probe_one_cell.s <probe_dir>" >&2
  exit 1
fi

cd "$PROBE_DIR"
{
  echo "### Probe start: $(date)"
  echo "### probe_dir: $(pwd)"
  echo "### SLURM_JOB_ID: $SLURM_JOB_ID"
  echo "### SLURM_NODELIST: $SLURM_JOB_NODELIST"
  echo "### JULIA_NUM_THREADS: $JULIA_NUM_THREADS"
} > stdout.txt

julia --startup-file=no \
  --project=/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe \
  script.jl >> stdout.txt 2> stderr.txt

echo "### Probe end: $(date) (exit $?)" >> stdout.txt
