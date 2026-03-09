#!/bin/bash
#
# Launch all 10 workers in parallel (2 noise types × 5 noise levels)
# With 12 cores, all 10 run concurrently. Each worker does 2 obs × 8 methods.
#
# Usage: bash 06_launch_parallel.sh
#
# After all workers finish, run: julia 06_merge.jl

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER="$SCRIPT_DIR/06_worker.jl"
LOGDIR="$SCRIPT_DIR/06_logs"

mkdir -p "$LOGDIR"

# Limit BLAS threads per worker so they don't fight over cores
# With 10 workers on 12 cores, give each ~1 BLAS thread
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1

echo "Launching 10 workers (2 noise types × 5 noise levels)..."
echo "Logs in: $LOGDIR/"
echo ""

PIDS=()

for noise_type in multiplicative additive; do
    for noise_idx in 1 2 3 4 5; do
        nt_short="mult"
        [[ "$noise_type" == "additive" ]] && nt_short="add"
        noise_names=("0" "1e-8" "1e-6" "1e-4" "1e-2")
        nn="${noise_names[$((noise_idx-1))]}"
        logfile="$LOGDIR/worker_${nt_short}_n${nn}.log"

        echo "  Starting: $noise_type level=$nn (index $noise_idx) → $logfile"
        julia "$WORKER" "$noise_type" "$noise_idx" > "$logfile" 2>&1 &
        PIDS+=($!)
    done
done

echo ""
echo "All 10 workers launched. PIDs: ${PIDS[*]}"
echo ""
echo "Waiting for all to finish..."

FAILED=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        echo "  Worker PID $pid FAILED"
        FAILED=$((FAILED + 1))
    fi
done

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "WARNING: $FAILED worker(s) failed! Check logs in $LOGDIR/"
else
    echo ""
    echo "All workers completed successfully!"
fi

echo ""
echo "Now run the merge script:"
echo "  julia $SCRIPT_DIR/06_merge.jl"
