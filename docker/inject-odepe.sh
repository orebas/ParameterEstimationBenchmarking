#!/bin/bash
# Point /opt/odepe at the desired ODEParameterEstimation source (the code under
# test), then warm the precompile cache SERIALLY so the cell pool that follows
# only ever reads the cache (no thundering-herd precompile / OOM).
#
#   inject-odepe.sh --ref <git-ref>   checkout a ref in the baked clone (fetches if needed)
#   inject-odepe.sh --mounted         /opt/odepe is bind-mounted from the host; just warm
#   inject-odepe.sh                    warm the current /opt/odepe as-is
#
# Exits non-zero (loudly) if instantiate fails — that means the injected ODEPE ref
# needs a dependency the frozen Manifest lacks; re-run with run-benchmark
# --allow-resolve (which re-resolves and snapshots a new Manifest into the results).
set -euo pipefail

: "${PEB_ROOT:=/opt/peb}"
: "${ODEPE_DIR:=/opt/odepe}"
ENV_PROJ="$PEB_ROOT/environments/julia_odepe"

REF=""
ALLOW_RESOLVE="${ALLOW_RESOLVE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)     REF="$2"; shift 2 ;;
    --mounted) shift ;;                 # nothing to checkout; warm as-is
    --allow-resolve) ALLOW_RESOLVE=1; shift ;;
    *) shift ;;
  esac
done

if [ -n "$REF" ]; then
  echo "[inject-odepe] checking out ODEPE ref: $REF"
  git -C "$ODEPE_DIR" fetch --quiet --tags origin "$REF" 2>/dev/null \
    || git -C "$ODEPE_DIR" fetch --quiet --tags origin || true
  git -C "$ODEPE_DIR" checkout --quiet "$REF" \
    || git -C "$ODEPE_DIR" checkout --quiet "origin/$REF"
fi
echo "[inject-odepe] ODEPE @ $(git -C "$ODEPE_DIR" describe --tags --always 2>/dev/null || echo '(bind-mounted)')"

echo "[inject-odepe] warming precompile cache (serial)…"
JL_SETUP='using Pkg; Pkg.instantiate()'
if [ "$ALLOW_RESOLVE" = "1" ]; then
  echo "[inject-odepe] --allow-resolve: re-resolving (snapshots a new Manifest)"
  JL_SETUP='using Pkg; Pkg.resolve(); Pkg.instantiate(); cp("'"$ENV_PROJ"'/Manifest.toml", get(ENV,"RESOLVED_MANIFEST_OUT","/work/results/Manifest.resolved.toml"); force=true)'
fi
julia --startup-file=no --project="$ENV_PROJ" -e "
  $JL_SETUP
  using ODEParameterEstimation, MKL, ModelingToolkit, OrdinaryDiffEq,
        GaussianProcesses, Optim, LineSearches, CSV, JSON, OrderedCollections
  using Symbolics: Num
  println(\"[inject-odepe] warmup OK\")"
