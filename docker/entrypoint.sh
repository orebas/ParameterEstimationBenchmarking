#!/bin/bash
# Dispatch for the odepe-bench container.
#
#   selftest            T0: assert the precompiled stack loads + the cache is warm
#   warmup [--ref R]    (re)point /opt/odepe and (re)populate the precompile cache
#   run    [opts]       full pipeline: inject ODEPE -> generate -> estimate -> collect
#   cell   [opts]       run ONE benchmark cell by index (fleet/SLURM workers)
#   shell               drop to bash
#
# All Julia is invoked with --startup-file=no and JULIA_PKG_PRECOMPILE_AUTO=0 so a
# cell can never trigger an implicit precompile mid-pool (avoids N-way thrash/OOM).
set -euo pipefail

: "${PEB_ROOT:=/opt/peb}"
: "${JULIA_DEPOT_PATH:=/opt/julia-depot}"
: "${JULIA_PKG_PRECOMPILE_AUTO:=0}"
export JULIA_DEPOT_PATH JULIA_PKG_PRECOMPILE_AUTO
ENV_PROJ="$PEB_ROOT/environments/julia_odepe"
cd "$PEB_ROOT"

cmd="${1:-selftest}"
shift || true

case "$cmd" in
  selftest)
    echo "[selftest] $(julia --version)  depot=$JULIA_DEPOT_PATH  cpu_target=${JULIA_CPU_TARGET:-default}"
    julia --startup-file=no --project="$ENV_PROJ" -e '
      using ODEParameterEstimation, MKL, ModelingToolkit, OrdinaryDiffEq,
            GaussianProcesses, Optim, LineSearches, CSV, JSON, OrderedCollections
      using Symbolics: Num
      println("OK ODEParameterEstimation loaded")'
    n=$(find "$JULIA_DEPOT_PATH/compiled" -name '*.ji' 2>/dev/null | wc -l)
    echo "[selftest] precompile cache: $n .ji files"
    if [ "$n" -le 0 ]; then echo "[selftest] FAIL: empty precompile cache"; exit 1; fi
    echo "[selftest] PASS"
    ;;
  warmup)
    exec "$PEB_ROOT/docker/inject-odepe.sh" "$@"
    ;;
  run)
    exec "$PEB_ROOT/docker/run-benchmark.sh" "$@"
    ;;
  cell)
    exec "$PEB_ROOT/docker/run-benchmark.sh" --single-cell "$@"
    ;;
  shell)
    exec bash "$@"
    ;;
  *)
    echo "unknown subcommand: '$cmd' (use: selftest | warmup | run | cell | shell)" >&2
    exit 2
    ;;
esac
