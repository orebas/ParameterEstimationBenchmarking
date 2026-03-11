#!/bin/bash
# Bilby benchmark monitor — runs unattended, submits batches, records failures.
# Usage: nohup bash hpc/cuny/bilby_monitor.sh >> bilby_monitor.log 2>&1 &

set -uo pipefail
cd /pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking

BENCHMARK=benchmark_bilby_2026_03_09
THROTTLE=80
LOGFILE=bilby_monitor.log
FAILURES_FILE=bilby_failures.txt
BATCH_STATE_FILE=bilby_batch_state.txt

# Track which batches have been submitted
# Batch 1 already submitted as jobs 43694,43695,43814,43815
if [[ ! -f "$BATCH_STATE_FILE" ]]; then
    cat > "$BATCH_STATE_FILE" <<'BEOF'
1:submitted:43694,43695,43814,43815
2:pending
3:pending
4:pending
BEOF
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

get_partition_pct() {
    local info
    info=$(sinfo -p partnsf -h -o "%C" 2>/dev/null)
    if [[ -z "$info" ]]; then echo 100; return; fi
    local used total
    used=$(echo "$info" | cut -d'/' -f1)
    total=$(echo "$info" | cut -d'/' -f4)
    echo $((used * 100 / total))
}

get_job_status() {
    local jobid=$1
    local comp fail run pend
    comp=$(sacct -j "$jobid" --format=State -n 2>&1 | grep -v '\.batch\|\.extern' | grep -c COMPLETED)
    fail=$(sacct -j "$jobid" --format=State -n 2>&1 | grep -v '\.batch\|\.extern' | grep -cE 'FAILED|TIMEOUT|CANCELLED|OUT_OF_ME')
    run=$(sacct -j "$jobid" --format=State -n 2>&1 | grep -v '\.batch\|\.extern' | grep -c RUNNING)
    pend=$(sacct -j "$jobid" --format=State -n 2>&1 | grep -v '\.batch\|\.extern' | grep -c PENDING)
    echo "$comp $fail $run $pend"
}

record_failures() {
    local jobid=$1 run_name=$2
    local failures
    failures=$(sacct -j "$jobid" --format=JobID%20,State%12,ExitCode -n 2>&1 | grep -v '\.batch\|\.extern' | grep -E 'FAILED|TIMEOUT|CANCELLED|OUT_OF_ME')
    if [[ -n "$failures" ]]; then
        echo "# $run_name (job $jobid)" >> "$FAILURES_FILE"
        echo "$failures" >> "$FAILURES_FILE"
    fi
}

is_batch_done() {
    local batch_num=$1
    local line
    line=$(grep "^${batch_num}:" "$BATCH_STATE_FILE")
    if [[ "$line" == *":done"* ]]; then return 0; fi
    if [[ "$line" == *":submitted:"* ]]; then
        local jobids
        jobids=$(echo "$line" | cut -d: -f3)
        local all_done=true
        IFS=',' read -ra IDS <<< "$jobids"
        for jid in "${IDS[@]}"; do
            local status
            status=$(get_job_status "$jid")
            local run pend
            run=$(echo "$status" | awk '{print $3}')
            pend=$(echo "$status" | awk '{print $4}')
            if [[ "$run" -gt 0 || "$pend" -gt 0 ]]; then
                all_done=false
                break
            fi
        done
        if $all_done; then
            # Record failures
            local names=("odepe_polish" "odepe_nopolish" "sciml_run" "amigo2_run")
            local idx=0
            for jid in "${IDS[@]}"; do
                record_failures "$jid" "${names[$idx]}_batch${batch_num}"
                idx=$((idx + 1))
            done
            sed -i "s/^${batch_num}:submitted:.*/${batch_num}:done:${jobids}/" "$BATCH_STATE_FILE"
            return 0
        fi
        return 1
    fi
    return 1
}

submit_batch() {
    local batch_num=$1
    log "Submitting batch $batch_num..."
    local job_ids=""
    for pair in "odepe_polish odepe" "odepe_nopolish odepe" "sciml_run sciml" "amigo2_run amigo2"; do
        local run_name=$(echo "$pair" | cut -d' ' -f1)
        local estimator=$(echo "$pair" | cut -d' ' -f2)
        local output
        output=$(bash hpc/cuny/submit_batched.sh "$BENCHMARK" "$run_name" "$estimator" "$batch_num" --throttle "$THROTTLE" 2>&1)
        local jid
        jid=$(echo "$output" | grep -oP '^\d+$' | tail -1)
        log "  $run_name: job $jid"
        if [[ -n "$job_ids" ]]; then job_ids="${job_ids},"; fi
        job_ids="${job_ids}${jid}"
    done
    sed -i "s/^${batch_num}:pending/${batch_num}:submitted:${job_ids}/" "$BATCH_STATE_FILE"
    log "Batch $batch_num submitted: $job_ids"
}

next_pending_batch() {
    grep ':pending' "$BATCH_STATE_FILE" | head -1 | cut -d: -f1
}

# Main loop
log "=== Bilby monitor started ==="
while true; do
    log "--- Check-in ---"
    pct=$(get_partition_pct)
    log "Partition usage: ${pct}%"

    # Status of all submitted batches
    for batch_num in 1 2 3 4; do
        line=$(grep "^${batch_num}:" "$BATCH_STATE_FILE")
        if [[ "$line" == *":submitted:"* ]]; then
            jobids=$(echo "$line" | cut -d: -f3)
            IFS=',' read -ra IDS <<< "$jobids"
            names=("odepe_polish" "odepe_nopolish" "sciml_run" "amigo2_run")
            log "Batch $batch_num:"
            idx=0
            for jid in "${IDS[@]}"; do
                status=$(get_job_status "$jid")
                log "  ${names[$idx]} ($jid): comp=$(echo $status|awk '{print $1}') fail=$(echo $status|awk '{print $2}') run=$(echo $status|awk '{print $3}') pend=$(echo $status|awk '{print $4}')"
                idx=$((idx + 1))
            done
            is_batch_done "$batch_num" && log "  -> Batch $batch_num COMPLETE"
        elif [[ "$line" == *":done:"* ]]; then
            log "Batch $batch_num: done"
        else
            log "Batch $batch_num: pending"
        fi
    done

    # Result file counts
    for run in odepe_polish odepe_nopolish sciml_run amigo2_run; do
        count=$(find "$BENCHMARK/filetree/$run" -name "result.csv" 2>/dev/null | wc -l)
        log "Results $run: $count/920"
    done

    # Submit next batch if partition below 50%
    next=$(next_pending_batch)
    if [[ -n "$next" ]]; then
        if [[ "$pct" -lt 50 ]]; then
            log "Partition at ${pct}% (<50%), submitting batch $next"
            submit_batch "$next"
        else
            log "Partition at ${pct}% (>=50%), waiting to submit batch $next"
        fi
    else
        # All batches submitted — check if all done
        all_done=true
        for b in 1 2 3 4; do
            is_batch_done "$b" || all_done=false
        done
        if $all_done; then
            log "=== ALL BATCHES COMPLETE ==="
            # Final failure summary
            if [[ -f "$FAILURES_FILE" && -s "$FAILURES_FILE" ]]; then
                log "Failures recorded in $FAILURES_FILE:"
                cat "$FAILURES_FILE" | while read -r line; do log "  $line"; done
            else
                log "No failures recorded!"
            fi
            log "=== Monitor exiting ==="
            exit 0
        fi
    fi

    log "Sleeping 30 minutes..."
    sleep 1800
done
