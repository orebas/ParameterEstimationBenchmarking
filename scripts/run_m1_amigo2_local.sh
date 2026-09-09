#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BENCH="${BENCH:-benchmark_m1_main_2026-06-08}"
RUN="${RUN:-amigo2_run}"
SOFTWARE="${SOFTWARE:-amigo2}"
CONCURRENCY="${CONCURRENCY:-4}"
SENTINEL="${SENTINEL:-===END===}"

if [[ ! -d "$BENCH" ]]; then
  echo "benchmark directory not found: $BENCH" >&2
  exit 2
fi

if [[ ! -d "$BENCH/filetree/$RUN" ]]; then
  echo "run directory not found: $BENCH/filetree/$RUN" >&2
  exit 2
fi

if ! command -v matlab >/dev/null 2>&1; then
  echo "matlab not found on PATH" >&2
  exit 2
fi

pending_file="$(mktemp)"
trap 'rm -f "$pending_file"' EXIT

python3 - "$BENCH" "$RUN" "$SENTINEL" > "$pending_file" <<'PY'
import json
import sys
from pathlib import Path

bench = Path(sys.argv[1])
run = sys.argv[2]
sentinel = sys.argv[3]

cfg = json.loads((bench / "config" / "config.json").read_text())
instances = json.loads((bench / "huge_json.json").read_text())["instances"]
root = bench / cfg["FILETREE"] / run

for inst in instances:
    idx = inst["index"]
    cell = root / inst["id"]
    stdout = cell / "stdout.txt"
    if stdout.exists() and sentinel in stdout.read_text(errors="replace"):
        continue
    print(idx)
PY

pending_count="$(wc -l < "$pending_file" | tr -d ' ')"
total_count="$(python3 - "$BENCH" <<'PY'
import json
import sys
from pathlib import Path
print(len(json.loads((Path(sys.argv[1]) / "huge_json.json").read_text())["instances"]))
PY
)"

echo "[amigo2-local] $(date) benchmark=$BENCH run=$RUN software=$SOFTWARE concurrency=$CONCURRENCY"
echo "[amigo2-local] pending=$pending_count total=$total_count"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[amigo2-local] DRY_RUN=1; first pending indices:"
  sed -n '1,20p' "$pending_file"
  exit 0
fi

if [[ "$pending_count" == "0" ]]; then
  echo "[amigo2-local] nothing to do"
  exit 0
fi

export BENCH RUN SOFTWARE

cat "$pending_file" | xargs -r -P "$CONCURRENCY" -I{} bash -c '
idx="$1"
start="$(date +%s)"
echo "[amigo2-local] $(date) START index=${idx}"
python3 src/estimate.py "$BENCH" "$RUN" "$SOFTWARE" "$idx"
rc=$?
end="$(date +%s)"
echo "[amigo2-local] $(date) END index=${idx} rc=${rc} elapsed=$((end-start))s"
exit "$rc"
' _ {}

echo "[amigo2-local] $(date) all pending AMIGO2 cells processed"
