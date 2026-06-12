#!/bin/bash
# Runs ON a worker box (shipped + launched by worker_fleet.py). Launches the
# odepe-bench container in --worker-mode (pulls cells from the coordinator) PLUS a
# box-level loop that rsyncs /work -> the coordinator results sink. The container
# has rsync but NO ssh, so the deposit must happen at the box level (the box has
# ssh + the fleet deploy key at /root/.ssh/id_ed25519).
#
# env (exported by worker_fleet.py over ssh):
#   COORDINATOR   http://<coord-ip>:8080
#   ENGINES       warm-engine spec, e.g. 8:1,2:4
#   ARMS          comma list of ODEPE arms (no amigo2 on cloud)
#   RESULTS_SINK  root@<coord-ip>:/srv/results
#   NAME DATE IMAGE ODEPE_REF AMIGO2_SLOTS WNAME
set -uo pipefail
: "${COORDINATOR:?need COORDINATOR}" "${ENGINES:?need ENGINES}" "${RESULTS_SINK:?need RESULTS_SINK}"
NAME="${NAME:-wq}"; DATE="${DATE:-2026-06-12}"
IMAGE="${IMAGE:-ghcr.io/orebas/odepe-bench:latest}"
ARMS="${ARMS:-odepe_v2_polish,odepe_v2_nopolish,odepe_v2_aaa_nopolish,odepe_shade}"
ODEPE_REF="${ODEPE_REF:-}"; AMIGO2_SLOTS="${AMIGO2_SLOTS:-0}"
WNAME="${WNAME:-$(hostname)}"
SSHOPTS="-i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
BENCH="benchmark_${NAME}_${DATE}"

echo "[wbox] $(date -u +%T) pulling $IMAGE"; docker pull "$IMAGE"
mkdir -p /work

# Container mounts (mirror run-on-box.sh: overlay overrides the baked image).
M=(-v /root/shard:/shard:ro -v /work:/work)
if [ -d /root/overlay ]; then
  for d in src templates config docker; do
    [ -d "/root/overlay/$d" ] && M+=(-v "/root/overlay/$d:/opt/peb/$d:ro")
  done
  [ -d /root/overlay/environments/julia_odepe ] && \
    M+=(-v /root/overlay/environments/julia_odepe:/opt/peb/environments/julia_odepe:ro)
  for p in Groebner SIAN-Julia StructuralIdentifiability.jl; do
    [ -d "/root/overlay/environments/$p" ] && M+=(-v "/root/overlay/environments/$p:/opt/peb/environments/$p:ro")
  done
  [ -d /root/overlay/environments/ODEParameterEstimation ] && M+=(
    -v /root/overlay/environments/ODEParameterEstimation:/opt/peb/environments/ODEParameterEstimation:ro
    -v /root/overlay/environments/ODEParameterEstimation:/opt/odepe:ro)
fi
OREF=(); [ -n "$ODEPE_REF" ] && OREF=(--odepe-ref "$ODEPE_REF")

# Box-level results sync: the container drops results into the mounted /work (via
# the harness's sync_to_work); push them to the coordinator sink with the deploy key.
( while true; do
    [ -d "/work/$BENCH/filetree" ] && \
      rsync -az --timeout=120 -e "ssh $SSHOPTS" "/work/$BENCH/filetree/" "$RESULTS_SINK/" 2>/dev/null
    sleep 90
  done ) &
SYNC_PID=$!

echo "[wbox] $(date -u +%T) worker-mode: coord=$COORDINATOR engines=$ENGINES arms=$ARMS name=$WNAME"
docker run --rm --network host "${M[@]}" -e SYNC_INTERVAL_S=60 \
  "$IMAGE" run --name "$NAME" --date "$DATE" \
    --config /shard/config.json --systems /shard/systems.json --arms "$ARMS" "${OREF[@]}" \
    --worker-mode --coordinator "$COORDINATOR" --engines "$ENGINES" \
    --amigo2-slots "$AMIGO2_SLOTS" --results-rsync "" --worker-name "$WNAME"
RC=$?
kill "$SYNC_PID" 2>/dev/null
# Final deposit, THEN signal worker_fleet that all results are on the sink (so it
# won't destroy this box mid-rsync and lose the last cells).
[ -d "/work/$BENCH/filetree" ] && rsync -az -e "ssh $SSHOPTS" "/work/$BENCH/filetree/" "$RESULTS_SINK/" 2>/dev/null
touch /work/WORKER_DONE
echo "[wbox] $(date -u +%T) done rc=$RC (final deposit complete)"
