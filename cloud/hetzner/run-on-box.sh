#!/bin/bash
# Runs ON a fleet box (dispatched by fleet.py). Pulls the public image and runs
# ONE shard's full benchmark, then touches /work/DONE so the coordinator collects.
# Config via env (set by fleet.py):
#   NAME        benchmark name (== run-id; result dirs keyed by cell-id, so collisions are fine)
#   DATE        stable benchmark date (keeps resume/pulls in one benchmark_* tree)
#   ARMS        comma list, e.g. odepe_v2_polish,odepe_v2_nopolish,odepe_shade
#   CONCURRENCY xargs -P width (cells in flight on this box)
#   THREADS     JULIA_NUM_THREADS per cell (receptor wants 8-16; normal 2)
#   HEAVY       comma list of memory-hungry systems -> 2-wide heavy lane (optional)
#   PRIOR       optional in-container path with previous /work contents for resume
#   WARM_JULIA  1 to batch multiple cells through each Julia process
#   WARM_JULIA_BATCH number of cells per warm Julia process
#   ODEPE_REF   optional ODEPE git ref; empty means use staged/mounted source
# Files staged by fleet.py in /root/shard/: systems.json, config.json, run-benchmark.sh
# The run-benchmark.sh override is mounted over the image's baked copy so the
# --threads flag is available without rebuilding the image.
set -euo pipefail

: "${IMAGE:=ghcr.io/orebas/odepe-bench:latest}"
IMG="$IMAGE"
: "${NAME:=fleet}"; : "${ARMS:=odepe_v2_polish,odepe_v2_nopolish,odepe_shade}"
: "${DATE:=$(date +%Y-%m-%d)}"; : "${CONCURRENCY:=4}"; : "${THREADS:=2}"; : "${HEAVY:=}"; : "${PRIOR:=}"
: "${WARM_JULIA:=0}"; : "${WARM_JULIA_BATCH:=4}"
: "${ODEPE_REF:=}"

mark_done() {
  local rc=$?
  mkdir -p /work
  if [ "$rc" -eq 0 ]; then
    touch /work/DONE
    echo "[box] $(date -u +%T) DONE"
  else
    echo "$rc" >/work/FAILED
    touch /work/DONE
    echo "[box] $(date -u +%T) FAILED rc=$rc"
  fi
  cp -f /root/box.log /work/box.log 2>/dev/null || true
}
trap mark_done EXIT

echo "[box] $(date -u +%T) pulling $IMG ..."
docker pull "$IMG"
mkdir -p /work

echo "[box] $(date -u +%T) shard: name=$NAME date=$DATE arms=$ARMS conc=$CONCURRENCY threads=$THREADS warm_julia=$WARM_JULIA batch=$WARM_JULIA_BATCH odepe_ref='${ODEPE_REF:-staged}' heavy='$HEAVY' prior='${PRIOR:-}'"
DOCKER_MOUNTS=(-v /root/shard:/shard:ro
  -v /work:/work)
if [ -d /root/overlay ]; then
  for dir in src templates config docker; do
    if [ -d "/root/overlay/$dir" ]; then
      DOCKER_MOUNTS+=(-v "/root/overlay/$dir:/opt/peb/$dir:ro")
    fi
  done
  if [ -d /root/overlay/environments/julia_odepe ]; then
    DOCKER_MOUNTS+=(-v /root/overlay/environments/julia_odepe:/opt/peb/environments/julia_odepe:ro)
  fi
  for pkg in Groebner SIAN-Julia StructuralIdentifiability.jl; do
    if [ -d "/root/overlay/environments/$pkg" ]; then
      DOCKER_MOUNTS+=(-v "/root/overlay/environments/$pkg:/opt/peb/environments/$pkg:ro")
    fi
  done
  if [ -d /root/overlay/environments/ODEParameterEstimation ]; then
    DOCKER_MOUNTS+=(-v /root/overlay/environments/ODEParameterEstimation:/opt/odepe:ro)
  fi
else
  DOCKER_MOUNTS+=(-v /root/shard/run-benchmark.sh:/opt/peb/docker/run-benchmark.sh:ro)
  if [ -f /root/shard/warm_julia_worker.jl ]; then
    DOCKER_MOUNTS+=(-v /root/shard/warm_julia_worker.jl:/opt/peb/src/warm_julia_worker.jl:ro)
  fi
fi
PRIOR_ARGS=()
if [ -n "$PRIOR" ] && [ -d /root/prior ]; then
  DOCKER_MOUNTS+=(-v /root/prior:/prior:ro)
  PRIOR_ARGS=(--prior "$PRIOR")
fi
WARM_ARGS=()
if [ "$WARM_JULIA" = "1" ]; then
  WARM_ARGS=(--warm-julia --warm-julia-batch "$WARM_JULIA_BATCH")
fi
ODEPE_ARGS=()
if [ -n "$ODEPE_REF" ]; then
  ODEPE_ARGS=(--odepe-ref "$ODEPE_REF")
fi
docker run --rm \
  "${DOCKER_MOUNTS[@]}" \
  "$IMG" run \
    --name "$NAME" \
    --date "$DATE" \
    --config /shard/config.json \
    --systems /shard/systems.json \
    --arms "$ARMS" \
    --concurrency "$CONCURRENCY" \
    --threads "$THREADS" \
    --exclude-systems "" \
    --heavy-systems "$HEAVY" \
    "${WARM_ARGS[@]}" \
    "${PRIOR_ARGS[@]}" \
    "${ODEPE_ARGS[@]}"
