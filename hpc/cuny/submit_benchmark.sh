#!/bin/bash
# Submit a CUNY HPC benchmark array job with throttling.
#
# Wraps the existing array_job_{estimator}_cuny.s scripts, overriding the
# hardcoded --array directive via the sbatch CLI (CLI flags override #SBATCH).
#
# Usage (from $SCRATCH):
#   bash ParameterEstimationBenchmarking/hpc/cuny/submit_benchmark.sh \
#       <benchmark_dir> <run_name> <estimator> [options]
#
# Options:
#   --array RANGE     Array range (default: 0-1199)
#   --throttle N      Max concurrent tasks (default: 50)
#   --after JOBID     Submit with afterany dependency on JOBID
#   --dry-run         Print the sbatch command without submitting
#
# Examples:
#   # Submit all 1200 instances, max 50 concurrent:
#   bash .../submit_benchmark.sh benchmark_2026_02 odepe_polish odepe
#
#   # Submit specific range:
#   bash .../submit_benchmark.sh benchmark_2026_02 sciml_run sciml --array 0-99
#
#   # Chain after a previous job:
#   bash .../submit_benchmark.sh benchmark_2026_02 odepe_polish odepe --after 12345
#
# Returns the submitted job ID to stdout (for chaining).

set -euo pipefail

# ── Parse positional args ───────────────────────────────────────────
BENCHMARK_DIR=${1:?Usage: submit_benchmark.sh <benchmark_dir> <run_name> <estimator> [options]}
RUN_NAME=${2:?Usage: submit_benchmark.sh <benchmark_dir> <run_name> <estimator> [options]}
ESTIMATOR=${3:?Usage: submit_benchmark.sh <benchmark_dir> <run_name> <estimator> [options]}
shift 3

# ── Defaults ────────────────────────────────────────────────────────
ARRAY_RANGE="0-1199"
THROTTLE=50
AFTER_JOBID=""
DRY_RUN=false

# ── Parse optional flags ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --array)    ARRAY_RANGE="$2"; shift 2 ;;
        --throttle) THROTTLE="$2"; shift 2 ;;
        --after)    AFTER_JOBID="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Validate estimator ─────────────────────────────────────────────
case $ESTIMATOR in
    odepe|sciml|amigo2) ;;
    *) echo "ERROR: Unknown estimator '$ESTIMATOR'. Must be odepe, sciml, or amigo2." >&2; exit 1 ;;
esac

# ── Paths ───────────────────────────────────────────────────────────
SCRATCH="${SCRATCH:-/scratch/oren-qc-13}"
REPO_DIR="$SCRATCH/ParameterEstimationBenchmarking"
SCRIPT="$REPO_DIR/hpc/cuny/array_job_${ESTIMATOR}_cuny.s"
FILETREE_DIR="$REPO_DIR/$BENCHMARK_DIR/filetree/$RUN_NAME"

# ── Validate ────────────────────────────────────────────────────────
if [[ ! -f "$SCRIPT" ]]; then
    echo "ERROR: Array job script not found: $SCRIPT" >&2
    exit 1
fi

if [[ ! -d "$FILETREE_DIR" ]]; then
    echo "ERROR: Filetree directory does not exist: $FILETREE_DIR" >&2
    echo "Has generate_scripts.py been run for this run?" >&2
    exit 1
fi

# Ensure output directory exists
mkdir -p "$SCRATCH/output"

# ── Build sbatch command ────────────────────────────────────────────
SBATCH_CMD=(sbatch)
SBATCH_CMD+=(--array="${ARRAY_RANGE}%${THROTTLE}")

if [[ -n "$AFTER_JOBID" ]]; then
    SBATCH_CMD+=(--dependency="afterany:${AFTER_JOBID}")
fi

SBATCH_CMD+=("$SCRIPT" "$BENCHMARK_DIR" "$RUN_NAME")

# ── Print info to stderr (keep stdout clean for job ID capture) ─────
echo "Benchmark: $BENCHMARK_DIR" >&2
echo "Run:       $RUN_NAME" >&2
echo "Estimator: $ESTIMATOR" >&2
echo "Array:     ${ARRAY_RANGE}%${THROTTLE}" >&2
if [[ -n "$AFTER_JOBID" ]]; then
    echo "After job: $AFTER_JOBID" >&2
fi
echo "" >&2
echo "Command:" >&2
echo "  ${SBATCH_CMD[*]}" >&2
echo "" >&2

# ── Submit or dry-run ───────────────────────────────────────────────
if $DRY_RUN; then
    echo "(dry-run) Would submit: ${SBATCH_CMD[*]}" >&2
    echo "DRY_RUN"
    exit 0
fi

OUTPUT=$("${SBATCH_CMD[@]}" 2>&1)

# sbatch prints "Submitted batch job 12345" — extract the job ID
JOB_ID=$(echo "$OUTPUT" | grep -oP '\d+$')

if [[ -z "$JOB_ID" ]]; then
    echo "ERROR: Failed to parse job ID from sbatch output:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

echo "Submitted job: $JOB_ID" >&2
echo "$JOB_ID"
