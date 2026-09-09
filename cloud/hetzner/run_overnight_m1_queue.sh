#!/usr/bin/env bash
set -u

cd /home/orebas/ParameterEstimationBenchmark-local/cloud/hetzner

log() {
  printf '[overnight %(%Y-%m-%d %H:%M:%S %Z)T] %s\n' -1 "$*"
}

DO_SSH_KEY=56766580
RUN_DATE=2026-06-08
PROVIDER=${PROVIDER:-hetzner}
MAX_BOXES=${MAX_BOXES:-14}
NUM_TESTS=${NUM_TESTS:-10}
WARM_JULIA_BATCH=${WARM_JULIA_BATCH:-2}
RUN_SUFFIX=${RUN_SUFFIX:-${PROVIDER}_warm_2026_06_10}
COMMON_ARGS=(
  --provider "$PROVIDER"
  --tiers-file tiers_m1.json
  --systems ../../config/systems_m1_broad.json
  --date "$RUN_DATE"
  --max-boxes "$MAX_BOXES"
  --num-tests "$NUM_TESTS"
  --warm-julia
  --warm-julia-batch "$WARM_JULIA_BATCH"
)
if [[ "$PROVIDER" == "do" ]]; then
  COMMON_ARGS+=(--do-region nyc1 --do-ssh-key "$DO_SSH_KEY")
fi
if [[ -n "${SHARD_SLICE:-}" ]]; then
  COMMON_ARGS+=(--shard-slice "$SHARD_SLICE")
fi
if [[ "${REVERSE:-0}" == "1" ]]; then
  COMMON_ARGS+=(--reverse)
fi
if [[ "${MIDDLE_OUT:-0}" == "1" ]]; then
  COMMON_ARGS+=(--middle-out)
fi

wait_for_tmux_session_to_end() {
  local session="$1"
  while tmux has-session -t "$session" 2>/dev/null; do
    log "waiting for tmux session '$session' to finish before starting the next fleet"
    sleep 300
  done
}

run_tiers() {
  local tiers="$1"
  local config="$2"
  local run_id="$3"
  shift 3
  log "starting tiers=$tiers config=$config run_id=$run_id extra=$*"
  ./fleet.py "${COMMON_ARGS[@]}" --config "$config" --tiers "$tiers" --run-id "$run_id" "$@"
  local rc=$?
  log "finished tiers=$tiers run_id=$run_id rc=$rc"
  return "$rc"
}

log "overnight queue armed"
wait_for_tmux_session_to_end m1_normal_do
wait_for_tmux_session_to_end m1_main_hard_do

run_tiers \
  m1_low_aaa_normal,m1_low_aaa_hard \
  ../../config/config_m1_low_noise_10rep.json \
  "m1_low_aaa_incremental_${RUN_SUFFIX}"

run_tiers \
  m1_low_aaa_new_noise_polish_normal,m1_low_aaa_new_noise_polish_hard \
  ../../config/config_m1_low_noise_10rep.json \
  "m1_low_aaa_newnoise_polish_${RUN_SUFFIX}" \
  --noises 1em12,1em10

run_tiers \
  m1_ablation_normal,m1_ablation_hard \
  ../../config/config_m1_polish_ablation_10rep.json \
  "m1_polish_ablation_incremental_${RUN_SUFFIX}"

log "overnight queue finished"
