#!/bin/bash
# Rerun failed instances from a CUNY HPC benchmark run.
#
# Detects failures by checking for ===END=== in stdout.txt (the authoritative
# success marker written by estimate.py).
#
# Usage (from $SCRATCH):
#   bash ParameterEstimationBenchmarking/hpc/cuny/rerun_failed.sh \
#       <benchmark_dir> <run_name> <estimator> [--mem MEM] [--time TIME] [--dry-run]
#
# Examples:
#   # Find failures and generate rerun script:
#   bash .../rerun_failed.sh benchmark_2026_02 odepe_polish odepe
#
#   # Retry OOM failures with more memory:
#   bash .../rerun_failed.sh benchmark_2026_02 odepe_polish odepe --mem 32GB
#
#   # Just see what failed without generating a script:
#   bash .../rerun_failed.sh benchmark_2026_02 sciml_run sciml --dry-run

set -euo pipefail

# ── Parse positional args ───────────────────────────────────────────
BENCHMARK_DIR=${1:?Usage: rerun_failed.sh <benchmark_dir> <run_name> <estimator> [--mem MEM] [--time TIME] [--dry-run]}
RUN_NAME=${2:?Usage: rerun_failed.sh <benchmark_dir> <run_name> <estimator> [--mem MEM] [--time TIME] [--dry-run]}
ESTIMATOR=${3:?Usage: rerun_failed.sh <benchmark_dir> <run_name> <estimator> [--mem MEM] [--time TIME] [--dry-run]}
shift 3

# ── Defaults ────────────────────────────────────────────────────────
DRY_RUN=false
MEM_OVERRIDE=""
TIME_OVERRIDE=""
THROTTLE=50

# ── Parse optional flags ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)  DRY_RUN=true; shift ;;
        --mem)      MEM_OVERRIDE="$2"; shift 2 ;;
        --time)     TIME_OVERRIDE="$2"; shift 2 ;;
        --throttle) THROTTLE="$2"; shift 2 ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Validate estimator ─────────────────────────────────────────────
case $ESTIMATOR in
    odepe|sciml|amigo2) ;;
    *) echo "ERROR: Unknown estimator '$ESTIMATOR'. Must be odepe, sciml, or amigo2."; exit 1 ;;
esac

# ── Paths ───────────────────────────────────────────────────────────
SCRATCH="${SCRATCH:-/scratch/oren-qc-13}"
REPO_DIR="$SCRATCH/ParameterEstimationBenchmarking"
FILETREE_DIR="$REPO_DIR/$BENCHMARK_DIR/filetree/$RUN_NAME"

echo "Scanning: $BENCHMARK_DIR / $RUN_NAME ($ESTIMATOR)"
echo "Filetree: $FILETREE_DIR"
echo ""

if [[ ! -d "$FILETREE_DIR" ]]; then
    echo "ERROR: Filetree directory does not exist: $FILETREE_DIR"
    echo "Has generate_scripts.py been run for this run?"
    exit 1
fi

# ── Load instance list from huge_json.json ──────────────────────────
# We need the ordered instance IDs to map array indices to directory names.
HUGE_JSON="$REPO_DIR/$BENCHMARK_DIR/huge_json.json"
if [[ ! -f "$HUGE_JSON" ]]; then
    echo "ERROR: huge_json.json not found at $HUGE_JSON"
    exit 1
fi

# Extract ordered instance IDs (one per line, in array order)
INSTANCE_IDS=()
while IFS= read -r id; do
    INSTANCE_IDS+=("$id")
done < <(python3 -c "
import json, sys
with open('$HUGE_JSON') as f:
    data = json.load(f)
for inst in data['instances']:
    print(inst['id'])
")

TOTAL=${#INSTANCE_IDS[@]}
echo "Total instances: $TOTAL"
echo ""

# ── Scan for failures ───────────────────────────────────────────────
FAILED_INDICES=()
SUCCEEDED=0
MISSING=0
INCOMPLETE=0

for IDX in $(seq 0 $((TOTAL - 1))); do
    INST_ID="${INSTANCE_IDS[$IDX]}"
    STDOUT_FILE="$FILETREE_DIR/$INST_ID/stdout.txt"

    if [[ ! -f "$STDOUT_FILE" ]] || [[ ! -s "$STDOUT_FILE" ]]; then
        # Missing or empty stdout.txt → not yet run
        FAILED_INDICES+=("$IDX")
        MISSING=$((MISSING + 1))
    elif ! tail -1 "$STDOUT_FILE" | grep -q '===END==='; then
        # stdout.txt exists but no ===END=== at end → crashed/OOM/timeout
        FAILED_INDICES+=("$IDX")
        INCOMPLETE=$((INCOMPLETE + 1))
    else
        SUCCEEDED=$((SUCCEEDED + 1))
    fi
done

NUM_FAILED=${#FAILED_INDICES[@]}

echo "Results:"
echo "  Succeeded:  $SUCCEEDED"
echo "  Not yet run: $MISSING"
echo "  Incomplete:  $INCOMPLETE (crashed/OOM/timeout)"
echo "  Total failed: $NUM_FAILED"
echo ""

if [[ $NUM_FAILED -eq 0 ]]; then
    echo "All $TOTAL instances succeeded. Nothing to rerun."
    exit 0
fi

# Show first few failures
if [[ $NUM_FAILED -le 20 ]]; then
    echo "Failed indices: ${FAILED_INDICES[*]}"
else
    echo "Failed indices (first 20): ${FAILED_INDICES[*]:0:20} ... and $((NUM_FAILED - 20)) more"
fi

# Show a few instance IDs for the failures
echo ""
echo "First few failed instances:"
for i in $(seq 0 $((${#FAILED_INDICES[@]} < 5 ? ${#FAILED_INDICES[@]} - 1 : 4))); do
    IDX=${FAILED_INDICES[$i]}
    echo "  [$IDX] ${INSTANCE_IDS[$IDX]}"
done
if [[ $NUM_FAILED -gt 5 ]]; then
    echo "  ... ($((NUM_FAILED - 5)) more)"
fi
echo ""

# ── Dry-run: stop here ──────────────────────────────────────────────
if $DRY_RUN; then
    echo "(dry-run) No rerun script generated."
    exit 0
fi

# ── Generate mapping file and rerun script ──────────────────────────
RERUN_DIR="$SCRATCH/reruns"
mkdir -p "$RERUN_DIR"

MAPPING_FILE="$RERUN_DIR/mapping_${BENCHMARK_DIR}_${RUN_NAME}.txt"
RERUN_SCRIPT="$RERUN_DIR/rerun_${BENCHMARK_DIR}_${RUN_NAME}.sh"

# Write mapping: line N = original array index for rerun task N
printf '%s\n' "${FAILED_INDICES[@]}" > "$MAPPING_FILE"

# ── Determine resource defaults per estimator ──────────────────────
case $ESTIMATOR in
    odepe)
        DEFAULT_CPUS=4
        DEFAULT_MEM="16GB"
        DEFAULT_TIME="06:00:00"
        ;;
    sciml)
        DEFAULT_CPUS=1
        DEFAULT_MEM="8GB"
        DEFAULT_TIME="03:00:00"
        ;;
    amigo2)
        DEFAULT_CPUS=1
        DEFAULT_MEM="8GB"
        DEFAULT_TIME="04:00:00"
        ;;
esac

FINAL_MEM="${MEM_OVERRIDE:-$DEFAULT_MEM}"
FINAL_TIME="${TIME_OVERRIDE:-$DEFAULT_TIME}"

# ── Write the SLURM rerun script ───────────────────────────────────
cat > "$RERUN_SCRIPT" << SLURM_EOF
#!/bin/bash -e
#
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=$DEFAULT_CPUS
#SBATCH --time=$FINAL_TIME
#SBATCH --mem=$FINAL_MEM
#SBATCH --job-name=rerun_${ESTIMATOR}_${RUN_NAME}
#SBATCH --partition=partnsf
#SBATCH --output=output/rerun_${ESTIMATOR}_${RUN_NAME}_%A_%a.out
#SBATCH --error=output/rerun_${ESTIMATOR}_${RUN_NAME}_%A_%a.err
#SBATCH --array=0-$((NUM_FAILED - 1))%${THROTTLE}

# CUNY HPC — Rerun failed instances for: $BENCHMARK_DIR / $RUN_NAME ($ESTIMATOR)
# Generated $(date '+%Y-%m-%d %H:%M:%S')
# Failed instances: $NUM_FAILED / $TOTAL

export SCRATCH="/scratch/oren-qc-13"

module purge
SLURM_EOF

# Add estimator-specific environment
if [[ "$ESTIMATOR" == "amigo2" ]]; then
    cat >> "$RERUN_SCRIPT" << 'SLURM_EOF'
module load Utils/Matlab/R2024b
export LD_LIBRARY_PATH="${SCRATCH}/.matlab_libs:${LD_LIBRARY_PATH}"
SLURM_EOF
fi

cat >> "$RERUN_SCRIPT" << 'SLURM_EOF'
export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"
export JULIA_CPU_TARGET="generic"
SLURM_EOF

if [[ "$ESTIMATOR" == "odepe" ]]; then
    echo 'export JULIA_NUM_THREADS=4' >> "$RERUN_SCRIPT"
fi

cat >> "$RERUN_SCRIPT" << SLURM_EOF

cd \$SCRATCH
source ParameterEstimationBenchmarking/environments/venv/bin/activate

# Read the original array index from the mapping file
IDX=\$(sed -n "\$((SLURM_ARRAY_TASK_ID + 1))p" "$MAPPING_FILE")

python ParameterEstimationBenchmarking/src/estimate.py \\
    ParameterEstimationBenchmarking/$BENCHMARK_DIR $RUN_NAME $ESTIMATOR \$IDX
SLURM_EOF

chmod +x "$RERUN_SCRIPT"

echo "Generated rerun script: $RERUN_SCRIPT"
echo "Instance mapping file:  $MAPPING_FILE"
echo ""
echo "Resource overrides applied:"
echo "  Memory: $FINAL_MEM$([ -n "$MEM_OVERRIDE" ] && echo ' (overridden)' || echo ' (default)')"
echo "  Time:   $FINAL_TIME$([ -n "$TIME_OVERRIDE" ] && echo ' (overridden)' || echo ' (default)')"
echo "  CPUs:   $DEFAULT_CPUS"
echo "  Throttle: $THROTTLE concurrent tasks"
echo ""
echo "Submit with:"
echo "  cd \$SCRATCH && sbatch $RERUN_SCRIPT"
