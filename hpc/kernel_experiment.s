#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=01:00:00
#SBATCH --mem=5G
#SBATCH --output=output/kernel_%x_%A_%a.out
#SBATCH --error=output/kernel_%x_%A_%a.err
#SBATCH --partition=local

# Usage: sbatch --array=0-59 --job-name=gpr_se hpc/kernel_experiment.s odepe_kernel_se
#
# With 2 CPUs + 5GB per task on a 24-CPU / 40GB node, SLURM runs ~8 tasks concurrently.
# Each task runs one script.jl directly (bypasses estimate.jl TeeIO issues).

export JULIA_NUM_THREADS=2

KERNEL_TYPE=${1:?Usage: sbatch ... hpc/kernel_experiment.s <kernel_type>}
EXPERIMENT_DIR="/home/orebas/ParameterEstimationBenchmark-local/results/kernel_experiment"
IDX=$SLURM_ARRAY_TASK_ID

# Look up instance ID from huge_json.json
INSTANCE_ID=$(python3 -c "
import json
with open('${EXPERIMENT_DIR}/huge_json.json') as f:
    data = json.load(f)
print(data['instances'][${IDX}]['id'])
")

SCRIPT_DIR="${EXPERIMENT_DIR}/filetree/${KERNEL_TYPE}/${INSTANCE_ID}"
SCRIPT="${SCRIPT_DIR}/script.jl"

if [ ! -f "$SCRIPT" ]; then
    echo "ERROR: Script not found: $SCRIPT"
    exit 1
fi

echo "Running: ${KERNEL_TYPE} / ${INSTANCE_ID} (index ${IDX})"

cd "$SCRIPT_DIR"

# Run directly, capture stdout/stderr to files alongside result.csv
julia "$SCRIPT" > stdout.txt 2> stderr.txt
echo -e "\n\nTime: ${SECONDS}\n===END===" >> stdout.txt
