#!/bin/bash -e
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --time=18:00:00
#SBATCH --mem=16GB
#SBATCH --job-name=probe_softwall_zero
#SBATCH --partition=partnsf
#SBATCH --account=gbassikqc
#SBATCH --output=output/probe_softwall_zero_%A_%a.out
#SBATCH --error=output/probe_softwall_zero_%A_%a.err

export SCRATCH="/scratch/oren-qc-13"
export JULIA_NUM_THREADS=${SLURM_CPUS_PER_TASK:-8}
sleep $((SLURM_ARRAY_TASK_ID % 20 * 3))
export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"

cd $SCRATCH/ParameterEstimationBenchmarking

PROBE_DIR=probe_softwall_zero_2026-05-18
# SLURM_ARRAY_TASK_ID is 1-indexed via the cells.txt line number
LINE=$((SLURM_ARRAY_TASK_ID + 1))  # 0-indexed array → 1-indexed line
CELL=$(sed -n "${LINE}p" $PROBE_DIR/cells.txt)
if [ -z "$CELL" ]; then
    echo "ERROR: no cell at line $LINE"
    exit 1
fi
CELL_DIR=$PROBE_DIR/filetree/$CELL
if [ ! -d "$CELL_DIR" ]; then
    echo "ERROR: cell dir missing: $CELL_DIR"
    exit 1
fi

cd $CELL_DIR
echo "=== Cell: $CELL ==="
echo "=== Started: $(date) ==="
t_start=$(date +%s)
julia --startup-file=no script.jl > stdout.txt 2> stderr.txt
t_end=$(date +%s)
echo "=== Done: $(date), wall=$((t_end - t_start))s ==="
echo $((t_end - t_start)) > wall_time_seconds.txt
