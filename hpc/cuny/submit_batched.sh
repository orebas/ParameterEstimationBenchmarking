#!/bin/bash
# Submit a benchmark in batches of 2 test instances per (system, noise) combo.
#
# The huge_json loop order is: noise → system → test (innermost, groups of 8).
# This script picks test indices [2*(B-1), 2*(B-1)+1] from each group of 8,
# giving 23 systems × 5 noise levels × 2 = 230 instances per batch.
#
# Usage:
#   bash submit_batched.sh <benchmark_dir> <run_name> <estimator> <batch(1-4)> [extra submit_benchmark.sh options]
#
# Example:
#   bash submit_batched.sh benchmark_bilby_2026_03_09 odepe_polish odepe 1
#   bash submit_batched.sh benchmark_bilby_2026_03_09 odepe_polish odepe 2 --after 12345

set -euo pipefail

BENCHMARK_DIR=${1:?Usage: submit_batched.sh <benchmark_dir> <run_name> <estimator> <batch(1-4)> [options]}
RUN_NAME=${2:?}
ESTIMATOR=${3:?}
BATCH=${4:?}
shift 4

if [[ "$BATCH" -lt 1 || "$BATCH" -gt 4 ]]; then
    echo "ERROR: batch must be 1-4, got $BATCH" >&2
    exit 1
fi

NUM_SYSTEMS=23
NUM_NOISE=5
NUM_TESTS=8
BLOCK_SIZE=$((NUM_SYSTEMS * NUM_TESTS))  # 184
TOTAL=$((BLOCK_SIZE * NUM_NOISE))         # 920

# Test indices for this batch: 2*(batch-1) and 2*(batch-1)+1
T0=$(( 2 * (BATCH - 1) ))
T1=$(( T0 + 1 ))

# Build comma-separated index list
INDICES=""
for noise_idx in $(seq 0 $((NUM_NOISE - 1))); do
    BASE=$((noise_idx * BLOCK_SIZE))
    for sys_idx in $(seq 0 $((NUM_SYSTEMS - 1))); do
        GROUP_BASE=$((BASE + sys_idx * NUM_TESTS))
        IDX0=$((GROUP_BASE + T0))
        IDX1=$((GROUP_BASE + T1))
        if [[ -n "$INDICES" ]]; then
            INDICES="${INDICES},"
        fi
        INDICES="${INDICES}${IDX0},${IDX1}"
    done
done

echo "Batch $BATCH: test indices $T0,$T1 from each group of $NUM_TESTS" >&2
echo "Total instances: $(echo "$INDICES" | tr ',' '\n' | wc -l)" >&2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/submit_benchmark.sh" "$BENCHMARK_DIR" "$RUN_NAME" "$ESTIMATOR" --array "$INDICES" "$@"
