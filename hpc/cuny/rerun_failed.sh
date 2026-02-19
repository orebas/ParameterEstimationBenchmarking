#!/bin/bash
# Rerun failed instances from a CUNY HPC benchmark run.
#
# Scans results to find missing instances and generates rerun sbatch commands.
#
# Usage (from $SCRATCH):
#   bash ParameterEstimationBenchmarking/hpc/cuny/rerun_failed.sh <benchmark_name> <run_name> <estimator>
#
# Example:
#   bash ParameterEstimationBenchmarking/hpc/cuny/rerun_failed.sh benchmark_2026_02 odepe_nopolish odepe

set -euo pipefail

BENCHMARK_NAME=${1:?Usage: rerun_failed.sh <benchmark_name> <run_name> <estimator>}
RUN_NAME=${2:?Usage: rerun_failed.sh <benchmark_name> <run_name> <estimator>}
ESTIMATOR=${3:?Usage: rerun_failed.sh <benchmark_name> <run_name> <estimator>}

REPO_DIR="$SCRATCH/ParameterEstimationBenchmarking"
RESULTS_DIR="$REPO_DIR/results/$BENCHMARK_NAME/$RUN_NAME"

echo "Scanning results for: $BENCHMARK_NAME / $RUN_NAME ($ESTIMATOR)"
echo "Results dir: $RESULTS_DIR"
echo ""

if [ ! -d "$RESULTS_DIR" ]; then
    echo "ERROR: Results directory does not exist: $RESULTS_DIR"
    echo "Has the benchmark been run at least once?"
    exit 1
fi

# Count total instances from data directory
DATA_DIR="$REPO_DIR/$BENCHMARK_NAME"
if [ -d "$DATA_DIR" ]; then
    TOTAL_INSTANCES=$(find "$DATA_DIR" -name "*.json" -type f | wc -l)
    echo "Total instances found in data: $TOTAL_INSTANCES"
else
    echo "WARNING: Data dir not found at $DATA_DIR, assuming 1200"
    TOTAL_INSTANCES=1200
fi

# Find missing instances
MISSING=()
for IDX in $(seq 0 $((TOTAL_INSTANCES - 1))); do
    if ! ls "$RESULTS_DIR"/*"_${IDX}."* >/dev/null 2>&1 && \
       ! ls "$RESULTS_DIR"/*"_${IDX}_"* >/dev/null 2>&1; then
        MISSING+=("$IDX")
    fi
done

NUM_MISSING=${#MISSING[@]}
echo "Found $NUM_MISSING missing instances out of $TOTAL_INSTANCES"

if [ "$NUM_MISSING" -eq 0 ]; then
    echo "All instances have results. Nothing to rerun."
    exit 0
fi

echo ""
echo "Missing instances: ${MISSING[*]:0:20}$([ "$NUM_MISSING" -gt 20 ] && echo " ... and $((NUM_MISSING - 20)) more")"
echo ""

# Generate rerun script
RERUN_SCRIPT="$SCRATCH/rerun_${BENCHMARK_NAME}_${RUN_NAME}.sh"
MISSING_LIST="$SCRATCH/missing_${BENCHMARK_NAME}_${RUN_NAME}.txt"
printf '%s\n' "${MISSING[@]}" > "$MISSING_LIST"

{
    echo "#!/bin/bash -e"
    echo "#SBATCH --job-name=rerun_${ESTIMATOR}"
    echo "#SBATCH --partition=partnsf"
    echo "#SBATCH --nodes=1"
    echo "#SBATCH --ntasks-per-node=1"
    if [ "$ESTIMATOR" = "odepe" ]; then
        echo "#SBATCH --cpus-per-task=4"
        echo "#SBATCH --mem=16GB"
        echo "#SBATCH --time=06:00:00"
    else
        echo "#SBATCH --cpus-per-task=1"
        echo "#SBATCH --mem=8GB"
        echo "#SBATCH --time=04:00:00"
    fi
    echo "#SBATCH --output=output/rerun_${ESTIMATOR}_%A_%a.out"
    echo "#SBATCH --error=output/rerun_${ESTIMATOR}_%A_%a.err"
    echo "#SBATCH --array=0-$((NUM_MISSING - 1))"
    echo ""
    echo "module purge"
    if [ "$ESTIMATOR" = "amigo2" ]; then
        echo "module load Utils/Matlab/R2024b"
    fi
    echo "export PATH=\"\$HOME/julia-1.12.5/bin:\$PATH\""
    if [ "$ESTIMATOR" = "odepe" ]; then
        echo "export JULIA_NUM_THREADS=4"
    fi
    echo ""
    echo "cd \$SCRATCH"
    echo "source ParameterEstimationBenchmarking/environments/venv/bin/activate"
    echo ""
    echo "# Read instance index from missing list"
    echo "IDX=\$(sed -n \"\$((SLURM_ARRAY_TASK_ID + 1))p\" $MISSING_LIST)"
    echo "python ParameterEstimationBenchmarking/src/estimate.py ParameterEstimationBenchmarking/$BENCHMARK_NAME $RUN_NAME $ESTIMATOR \$IDX"
} > "$RERUN_SCRIPT"
chmod +x "$RERUN_SCRIPT"

echo "Missing instance list: $MISSING_LIST"
echo "Rerun script: $RERUN_SCRIPT"
echo ""
echo "Submit with:"
echo "  cd \$SCRATCH && sbatch $RERUN_SCRIPT"
