#!/bin/bash
# Runs ON a fleet box (dispatched by fleet.py). Pulls the public image and runs
# ONE shard's full benchmark, then touches /work/DONE so the coordinator collects.
# Config via env (set by fleet.py):
#   NAME        benchmark name (== run-id; result dirs keyed by cell-id, so collisions are fine)
#   ARMS        comma list, e.g. odepe_v2_polish,odepe_v2_nopolish,odepe_shade
#   CONCURRENCY xargs -P width (cells in flight on this box)
#   THREADS     JULIA_NUM_THREADS per cell (receptor wants 8-16; normal 2)
#   HEAVY       comma list of memory-hungry systems -> 2-wide heavy lane (optional)
# Files staged by fleet.py in /root/shard/: systems.json, config.json, run-benchmark.sh
# The run-benchmark.sh override is mounted over the image's baked copy so the
# --threads flag is available without rebuilding the image.
set -euo pipefail

IMG="ghcr.io/orebas/odepe-bench:latest"
: "${NAME:=fleet}"; : "${ARMS:=odepe_v2_polish,odepe_v2_nopolish,odepe_shade}"
: "${CONCURRENCY:=4}"; : "${THREADS:=2}"; : "${HEAVY:=}"

echo "[box] $(date -u +%T) pulling $IMG ..."
docker pull "$IMG"
mkdir -p /work

echo "[box] $(date -u +%T) shard: name=$NAME arms=$ARMS conc=$CONCURRENCY threads=$THREADS heavy='$HEAVY'"
docker run --rm \
  -v /root/shard:/shard:ro \
  -v /root/shard/run-benchmark.sh:/opt/peb/docker/run-benchmark.sh:ro \
  -v /work:/work \
  "$IMG" run \
    --name "$NAME" \
    --config /shard/config.json \
    --systems /shard/systems.json \
    --arms "$ARMS" \
    --concurrency "$CONCURRENCY" \
    --threads "$THREADS" \
    --exclude-systems "" \
    --heavy-systems "$HEAVY" \
    --odepe-ref quoll-v1

touch /work/DONE
echo "[box] $(date -u +%T) DONE"
