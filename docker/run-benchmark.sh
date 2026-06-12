#!/bin/bash
# Full in-container benchmark run (Julia arms only; amigo2 runs on CUNY):
#   inject ODEPE @ ref -> warm cache -> init -> generate_data -> generate_scripts
#   -> estimate (memory-aware pool, light + heavy lanes) -> collect_results.
# Outputs persist to /work (bind-mount it). Defaults target the smoke config.
#
#   run-benchmark.sh --name quoll --config config/config_quoll_broad.json \
#       --systems config/systems_quoll_broad.json --odepe-ref quoll-v1 \
#       --arms odepe_v2_polish,odepe_v2_nopolish,odepe_shade --concurrency 16
#
# Fleet/SLURM worker mode (benchmark dir already prepared, run ONE cell):
#   run-benchmark.sh --single-cell --dir <bench> --run <arm>_run --arm <arm> --index N
set -euo pipefail
: "${PEB_ROOT:=/opt/peb}"
: "${WORK:=/work}"
cd "$PEB_ROOT"

# ── defaults ────────────────────────────────────────────────────────────────
NAME="bench"; DATE="$(date +%Y-%m-%d)"
CONFIG="config/config_quoll_smoke.json"
SYSTEMS="config/systems_quoll_smoke.json"
ARMS="odepe_v2_polish,odepe_v2_nopolish,odepe_shade"
ODEPE_REF=""; CONCURRENCY=""; INDICES="all"; THREADS=2
EXCLUDE_SYSTEMS="receptor_subtype_binding_branch"
HEAVY_SYSTEMS="biohydrogenation,latent_subpopulation_branch,latent_subpopulation_observed_control"
PER_CELL_GB=6; HEAVY_GB=10; ALLOW_RESOLVE=0; PRIOR=""
SINGLE_CELL=0; S_DIR=""; S_RUN=""; S_ARM=""; S_IDX=""
WARM_JULIA=0; WARM_JULIA_BATCH=4
SYNC_INTERVAL_S="${SYNC_INTERVAL_S:-300}"; SYNC_PID=""
# Shared dynamic work-queue worker mode (replaces the static light/heavy lanes):
WORKER_MODE=0; COORDINATOR=""; ENGINES="2:1"; WORKER_NAME=""; AMIGO2_SLOTS=0; RESULTS_RSYNC=""

while [ $# -gt 0 ]; do case "$1" in
  --name) NAME="$2"; shift 2;;
  --date) DATE="$2"; shift 2;;
  --config) CONFIG="$2"; shift 2;;
  --systems) SYSTEMS="$2"; shift 2;;
  --arms) ARMS="$2"; shift 2;;
  --odepe-ref) ODEPE_REF="$2"; shift 2;;
  --concurrency) CONCURRENCY="$2"; shift 2;;
  --threads) THREADS="$2"; shift 2;;
  --indices) INDICES="$2"; shift 2;;
  --exclude-systems) EXCLUDE_SYSTEMS="$2"; shift 2;;
  --heavy-systems) HEAVY_SYSTEMS="$2"; shift 2;;
  --prior) PRIOR="$2"; shift 2;;
  --warm-julia) WARM_JULIA=1; shift;;
  --warm-julia-batch) WARM_JULIA_BATCH="$2"; shift 2;;
  --allow-resolve) ALLOW_RESOLVE=1; shift;;
  --worker-mode) WORKER_MODE=1; shift;;
  --coordinator) COORDINATOR="$2"; shift 2;;
  --engines) ENGINES="$2"; shift 2;;
  --worker-name) WORKER_NAME="$2"; shift 2;;
  --amigo2-slots) AMIGO2_SLOTS="$2"; shift 2;;
  --results-rsync) RESULTS_RSYNC="$2"; shift 2;;
  --single-cell) SINGLE_CELL=1; shift;;
  --dir) S_DIR="$2"; shift 2;;
  --run) S_RUN="$2"; shift 2;;
  --arm) S_ARM="$2"; shift 2;;
  --index) S_IDX="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

# ── fleet/SLURM worker: just run the one cell (dir already prepared) ─────────
if [ "$SINGLE_CELL" = "1" ]; then
  [ -n "$S_DIR" ] && [ -n "$S_RUN" ] && [ -n "$S_ARM" ] && [ -n "$S_IDX" ] \
    || { echo "cell mode needs --dir --run --arm --index" >&2; exit 2; }
  exec env JULIA_NUM_THREADS="${JULIA_NUM_THREADS:-2}" MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
       python3 src/estimate.py "$S_DIR" "$S_RUN" "$S_ARM" "$S_IDX"
fi

# ── concurrency (memory-aware) ──────────────────────────────────────────────
MEM_GB=$(awk '/MemTotal/{printf "%d",$2/1024/1024}' /proc/meminfo)
if [ -z "$CONCURRENCY" ]; then
  CONCURRENCY=$(( MEM_GB / PER_CELL_GB )); CORES=$(nproc)
  [ "$CONCURRENCY" -gt "$CORES" ] && CONCURRENCY=$CORES
fi
[ "${CONCURRENCY:-0}" -lt 1 ] && CONCURRENCY=1
HEAVY_CONC=$(( MEM_GB / HEAVY_GB )); [ "$HEAVY_CONC" -lt 1 ] && HEAVY_CONC=1; [ "$HEAVY_CONC" -gt 2 ] && HEAVY_CONC=2

BENCH="benchmark_${NAME}_${DATE}"
echo "=== run-benchmark: $BENCH | arms=$ARMS | concurrency=$CONCURRENCY (heavy $HEAVY_CONC) | threads/cell=$THREADS | warm_julia=$WARM_JULIA batch=$WARM_JULIA_BATCH | mem=${MEM_GB}G ==="

sync_to_work() {
  [ -n "${BENCH:-}" ] && [ -d "$PEB_ROOT/$BENCH" ] || return 0
  mkdir -p "$WORK"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --ignore-errors "$PEB_ROOT/$BENCH/" "$WORK/$BENCH/" >/tmp/peb-work-sync.log 2>&1 || true
  else
    mkdir -p "$WORK/$BENCH"
    cp -a "$PEB_ROOT/$BENCH/." "$WORK/$BENCH/" >/tmp/peb-work-sync.log 2>&1 || true
  fi
}

cleanup_sync() {
  local rc=$?
  if [ -n "$SYNC_PID" ]; then
    kill "$SYNC_PID" >/dev/null 2>&1 || true
    wait "$SYNC_PID" >/dev/null 2>&1 || true
  fi
  sync_to_work
  return "$rc"
}
trap cleanup_sync EXIT

# ── inject ODEPE + warm the precompile cache SERIALLY (before any pool) ──────
INJ=(); [ -n "$ODEPE_REF" ] && INJ+=(--ref "$ODEPE_REF"); [ "$ALLOW_RESOLVE" = "1" ] && INJ+=(--allow-resolve)
"$PEB_ROOT/docker/inject-odepe.sh" ${INJ[@]+"${INJ[@]}"}

# init_benchmark creates the dir at $PEB_ROOT/$BENCH (repo-root-relative, hardcoded).
# We do NOT symlink it into /work — init's --force can't rmtree a symlink. Instead the
# pipeline runs in /opt/peb and we copy results to /work at the end.

# ── pipeline ────────────────────────────────────────────────────────────────
IFS=',' read -r -a ARM_ARR <<< "$ARMS"
python3 src/init_benchmark.py --name "$NAME" --date "$DATE" \
    --software "${ARM_ARR[@]}" --config "$CONFIG" --systems "$SYSTEMS" --force
FROZEN_SYS="$BENCH/config/systems.json"

# drop excluded systems (default: receptor_subtype_binding_branch — 6h timeouts) BEFORE data-gen
if [ -n "$EXCLUDE_SYSTEMS" ]; then
  python3 - "$FROZEN_SYS" "$EXCLUDE_SYSTEMS" <<'PY'
import json,sys
f,exc=sys.argv[1],set(sys.argv[2].split(","))
d=json.load(open(f)); n0=len(d["systems"])
d["systems"]=[s for s in d["systems"] if s["name"] not in exc]
json.dump(d,open(f,"w"),indent=2)
print(f"  excluded {n0-len(d['systems'])} system(s): {sorted(exc)}",file=sys.stderr)
PY
fi

python3 src/generate_data.py "$BENCH/config/config.json" "$FROZEN_SYS" -d "$BENCH"
for arm in "${ARM_ARR[@]}"; do
  python3 src/generate_scripts.py "$BENCH" -s "$arm" -r "${arm}_run"
done

if [ "$WARM_JULIA" = "1" ]; then
  # Some public images may still have templates that call exit(1) after a
  # caught analysis failure. A persistent Julia worker must keep serving later
  # cells, so generated scripts are patched to honor ODEPE_WARM_JULIA_NO_EXIT.
  python3 - "$BENCH" "${ARM_ARR[@]}" <<'PY'
import sys
from pathlib import Path

bench = Path(sys.argv[1])
for arm in sys.argv[2:]:
    for path in (bench / "filetree" / f"{arm}_run").glob("*/script.jl"):
        text = path.read_text()
        old = "if analysis_failed\n    exit(1)\nend\n"
        new = """if analysis_failed
    if get(ENV, "ODEPE_WARM_JULIA_NO_EXIT", "0") != "1"
        exit(1)
    end
end
"""
        if old in text:
            path.write_text(text.replace(old, new))
PY
fi

if [ -n "$PRIOR" ] && [ -d "$PRIOR/$BENCH/filetree" ]; then
  echo "=== resume: copying prior cell outputs from $PRIOR/$BENCH ==="
  mkdir -p "$BENCH/filetree"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$PRIOR/$BENCH/filetree/" "$BENCH/filetree/"
  else
    cp -a "$PRIOR/$BENCH/filetree/." "$BENCH/filetree/"
  fi
fi

sync_to_work
( while true; do sleep "$SYNC_INTERVAL_S"; sync_to_work; done ) &
SYNC_PID=$!

# ── worker mode: pull cells from the coordinator instead of the static lanes ──
# The filetree for $ARMS is already generated above (deterministic on every box);
# worker.py claims (arm,index) cells, runs them warm, rsyncs each finished cell to
# the results sink, and exits when the whole queue drains. No collect step (the
# coordinator owns status; analysis reads the rsync'd cells).
if [ "$WORKER_MODE" = "1" ]; then
  [ -n "$COORDINATOR" ] || { echo "worker mode needs --coordinator URL" >&2; exit 2; }
  WNAME="${WORKER_NAME:-$(hostname)}"
  echo "=== worker mode: coordinator=$COORDINATOR engines=$ENGINES name=$WNAME amigo2_slots=$AMIGO2_SLOTS ==="
  python3 src/worker.py --coordinator "$COORDINATOR" --bench "$PEB_ROOT/$BENCH" \
    --worker "$WNAME" --engines "$ENGINES" --amigo2-slots "$AMIGO2_SLOTS" \
    --julia-project "$PEB_ROOT/environments/julia_odepe" --peb-root "$PEB_ROOT" \
    --results-rsync "$RESULTS_RSYNC" --log-dir "$WORK"
  [ -n "$SYNC_PID" ] && kill "$SYNC_PID" 2>/dev/null
  sync_to_work
  echo "=== worker drained, exiting ==="
  exit 0
fi

# ── partition indices into light / heavy lanes (heavy = memory-hungry systems) ─
LIGHT_FILE=$(mktemp); HEAVY_FILE=$(mktemp)
LIGHT_FILE="$LIGHT_FILE" HEAVY_FILE="$HEAVY_FILE" python3 - "$BENCH" "$HEAVY_SYSTEMS" "$INDICES" <<'PY'
import json,sys,os
benchdir,heavy_csv,spec=sys.argv[1],sys.argv[2],sys.argv[3]
heavy=set(filter(None,heavy_csv.split(",")))
inst=json.load(open(f"{benchdir}/huge_json.json"))["instances"]
want=None
if spec!="all":
    want=set()
    for p in spec.split(","):
        if "-" in p: a,b=p.split("-"); want.update(range(int(a),int(b)+1))
        else: want.add(int(p))
light,hv=[],[]
for x in inst:
    i=x["index"]
    if want is not None and i not in want: continue
    (hv if x.get("name") in heavy else light).append(i)
open(os.environ["LIGHT_FILE"],"w").write("\n".join(map(str,light)))
open(os.environ["HEAVY_FILE"],"w").write("\n".join(map(str,hv)))
print(f"  {len(light)} light + {len(hv)} heavy cell-indices",file=sys.stderr)
PY

# ── estimate: per-arm, light lane (N-wide) then heavy lane (2-wide) ──────────
run_lane() {  # $1=arm  $2=indexfile  $3=concurrency
  local arm="$1" idxfile="$2" conc="$3"
  [ -s "$idxfile" ] || return 0
  local todo
  todo=$(mktemp)
  python3 - "$BENCH" "$arm" "$idxfile" > "$todo" <<'PY'
import json
import sys
from pathlib import Path

bench, arm, idxfile = sys.argv[1:]
instances = json.load(open(f"{bench}/huge_json.json"))["instances"]
id_by_index = {str(x["index"]): x["id"] for x in instances}
total = skipped = 0
for raw in open(idxfile):
    idx = raw.strip()
    if not idx:
        continue
    total += 1
    cell_id = id_by_index.get(idx)
    if cell_id is None:
        print(idx)
        continue
    result = Path(bench) / "filetree" / f"{arm}_run" / cell_id / "result.csv"
    if result.exists():
        skipped += 1
        continue
    print(idx)
print(f"  resume filter {arm}: skipped {skipped}/{total} completed cells", file=sys.stderr)
PY
  if [ ! -s "$todo" ]; then
    rm -f "$todo"
    return 0
  fi
  if [ "$WARM_JULIA" = "1" ]; then
    JULIA_NUM_THREADS="$THREADS" MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 ODEPE_WARM_JULIA_NO_EXIT=1 \
      xargs -a "$todo" -P "$conc" -n "$WARM_JULIA_BATCH" \
        julia --startup-file=no --project="$PEB_ROOT/environments/julia_odepe" src/warm_julia_worker.jl "$BENCH" "${arm}_run" "$arm"
  else
    JULIA_NUM_THREADS="$THREADS" MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
      xargs -a "$todo" -P "$conc" -I{} \
        python3 src/estimate.py "$BENCH" "${arm}_run" "$arm" {}
  fi
  rm -f "$todo"
  sync_to_work
}
for arm in "${ARM_ARR[@]}"; do
  echo "--- $arm: light lane (-P $CONCURRENCY) ---"; run_lane "$arm" "$LIGHT_FILE" "$CONCURRENCY"
  echo "--- $arm: heavy lane (-P $HEAVY_CONC) ---"; run_lane "$arm" "$HEAVY_FILE" "$HEAVY_CONC"
done

# ── collect ─────────────────────────────────────────────────────────────────
RUNS=$(printf '%s_run,' "${ARM_ARR[@]}"); RUNS="${RUNS%,}"
python3 src/collect_results.py "$BENCH" "$RUNS"

# Persist outputs to the mounted volume (the pipeline ran in /opt/peb).
mkdir -p "$WORK"
cp -a "$PEB_ROOT/$BENCH" "$WORK/" 2>/dev/null || rsync -a "$PEB_ROOT/$BENCH/" "$WORK/$BENCH/"
sync_to_work
echo "=== done -> $WORK/$BENCH (result.csv, result.json + per-cell outputs) ==="
