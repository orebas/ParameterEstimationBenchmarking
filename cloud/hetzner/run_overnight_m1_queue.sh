#!/usr/bin/env bash
set -u

cd /home/orebas/ParameterEstimationBenchmark-local/cloud/hetzner

log() {
  printf '[overnight %(%Y-%m-%d %H:%M:%S %Z)T] %s\n' -1 "$*"
}

DO_SSH_KEY=56766580
RUN_DATE=2026-06-08
MAX_BOXES=15
COMMON_ARGS=(
  --provider do
  --do-region nyc1
  --do-ssh-key "$DO_SSH_KEY"
  --tiers-file tiers_m1.json
  --config ../../config/config_m1_main_10rep.json
  --systems ../../config/systems_m1_broad.json
  --date "$RUN_DATE"
  --max-boxes "$MAX_BOXES"
  --num-tests 10
  --warm-julia
  --warm-julia-batch 2
)

wait_for_tmux_session_to_end() {
  local session="$1"
  while tmux has-session -t "$session" 2>/dev/null; do
    log "waiting for tmux session '$session' to finish before starting the next fleet"
    sleep 300
  done
}

run_tier() {
  local tier="$1"
  local run_id="$2"
  log "starting tier=$tier run_id=$run_id"
  ./fleet.py "${COMMON_ARGS[@]}" --tiers "$tier" --run-id "$run_id"
  local rc=$?
  log "finished tier=$tier run_id=$run_id rc=$rc"
  return "$rc"
}

log "overnight queue armed"
wait_for_tmux_session_to_end m1_normal_do
wait_for_tmux_session_to_end m1_main_hard_do

run_tier m1_low_aaa_hard m1_low_aaa_hard_do_warm_2026_06_09
run_tier m1_ablation_hard m1_ablation_hard_do_warm_2026_06_09

log "overnight queue finished"
