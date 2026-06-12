# Shared dynamic work-queue benchmark — runbook

The final benchmark runs as a **central coordinator + pull-workers** instead of static
per-box shards. Every core on every provider (Hetzner / DigitalOcean / local) pulls cells
from one queue until the single slowest cell finishes. Built 2026-06-12.

## Pieces (all new/changed, in this repo)
- `src/coordinator.py` — SQLite + HTTP queue. Owns the cell manifest, hands out cells
  (hard 8-core first, core-fit, `kind=julia|matlab` routing), heartbeat leases (dead-worker
  recovery only), `/status` with a `WATCHDOG_over_5h` bucket, `/requeue` for manual rerun.
- `src/worker.py` — pull-worker. A fixed pool of warm Julia engines (`8:1,2:4` = one 8-thread
  + four 2-thread). Each slot: claim → run warm → rsync the finished cell to the sink → POST
  /done. One heartbeat thread per box. MATLAB (amigo2) slots run via `estimate.py` (local only).
- `src/warm_julia_worker.jl --server <bench>` — persistent warm-Julia mode: one cell per stdin
  line (`<run>\t<software>\t<index>`), prints `CELL_DONE\t<index>\t<status>`. ODEPE compiles
  ONCE per engine.
- `docker/run-benchmark.sh --worker-mode --coordinator <url> --engines 8:1,2:4 ...` — after the
  normal on-box generate step, runs `worker.py` instead of the static lanes.
- `templates/.../odepe_v2.jl` — AAA arm forces `auto_filter_interpolators=false`; polish/nopolish
  dump the full candidate pool (`pool.csv`/`pool.jls`).

## Topology
- **Coordinator box**: a tiny always-public Hetzner box (e.g. `cpx11`/`ccx13`). The local machine
  is WSL2-NATed and unreachable from cloud workers, so the coordinator MUST be public. It also
  doubles as the **results sink** (workers `rsync` finished cells to it over ssh).
- **Worker boxes**: Hetzner (ccx33=8 vcpu → `--engines 8:1` or `2:4`; ccx43=16 vcpu →
  `8:1,2:4`), DO droplets, and the local machine.
- Hard 9-system set + the `heavy` memory subset come from `cloud/hetzner/tiers_m1.json`.

## Launch sequence
### 1. Push the code (DONE — origin/main has err_only @ 96721a3). Cloud uses `--odepe-ref main`.

### 2. Generate the manifest source (huge_json) once, locally
```
python3 src/init_benchmark.py --name final_v2 --date 2026-06-12 \
  --software odepe_v2_polish odepe_v2_nopolish odepe_v2_aaa_nopolish odepe_shade amigo2 \
  --config config/config_m1_main_10rep.json --systems config/systems_m1_broad.json --force
```
This writes `benchmark_final_v2_2026-06-12/huge_json.json` (1250 instances) + MANIFEST.toml.

### 3. Coordinator box (public)
```
hcloud server create --name odepe-coord --type cpx11 --image ubuntu-24.04 \
  --ssh-key <key> --user-data-from-file cloud/hetzner/cloud-init-docker.yaml
COORD_IP=<ip>
# copy coordinator.py + huge_json.json + tiers_m1.json to the box; then:
HARD=$(python3 -c "import json;t=json.load(open('cloud/hetzner/tiers_m1.json'));import itertools;
print(','.join(sorted(set(s for v in t['tiers'].values() for s in v['systems'] if v['box_type']=='ccx43'))))")
python3 src/coordinator.py --huge-json huge_json.json \
  --arms odepe_v2_polish,odepe_v2_nopolish,odepe_v2_aaa_nopolish,odepe_shade,amigo2 \
  --hard-systems "$HARD" --local-only-arms amigo2 --port 8080 \
  --db queue.db --cells-csv cells.csv
# results sink: mkdir -p /srv/results  (workers rsync here)
```
Coordinator URL = `http://$COORD_IP:8080`.  Sink = `root@$COORD_IP:/srv/results`.

### 4. Workers
- **Local** (amigo2 + a share of julia cells):
```
python3 src/worker.py --coordinator http://$COORD_IP:8080 --bench $PWD/benchmark_final_v2_2026-06-12 \
  --worker local --engines 8:1,2:3 --amigo2-slots 2 \
  --results-rsync root@$COORD_IP:/srv/results
```
  (the local bench must be fully generated first: `generate_data.py` + `generate_scripts.py` per arm.)
- **Cloud** (via fleet.py provision + run-on-box.sh in worker mode — see "Cloud provisioning" below).

### 5. Monitor (human 5h watchdog)
```
watch -n 30 'curl -s http://$COORD_IP:8080/status | python3 -m json.tool'
```
`WATCHDOG_over_5h` lists any cell elapsed >5h → read its engine log, decide (requeue / wait / flag).
`POST /requeue {"cell_id":"cstr_3_1em2","arm":"odepe_v2_polish"}` to rerun one cell.

### 6. Teardown
When `/status` `remaining`==0: pull `/srv/results` from the coordinator box, run analysis, then
`hcloud server delete` the workers + coordinator (or `reap.sh`).

## Cloud provisioning (TODO — validate live, 1 box first)
The existing `fleet.py provision()/push_overlay()/destroy()` are reused unchanged. The remaining
wiring (to do live against one real box, then scale):
1. `run-on-box.sh`: add a worker-mode branch that passes `--worker-mode --coordinator $COORD
   --engines $ENGINES --results-rsync $SINK` into the `docker run $IMAGE run ...` invocation
   (the container already has Julia + the julia_odepe env; worker.py runs inside it after generate).
2. A thin `worker_fleet.py` (reuses fleet.py helpers): provision N identical worker boxes →
   push overlay → launch run-on-box.sh worker-mode → monitor coordinator `/status` → destroy.
3. Box → engines: ccx33 → `8:1` (hard) or `2:4` (easy) or hybrid; ccx43 → `8:1,2:4`.
4. `--odepe-ref main` so the container checks out err_only.

## Validated locally (2026-06-12)
`repro/benchmark_v2_dryrun_2026_06_12/` — coordinator + 1 worker (8:1,2:2 engines) drained a
6-cell benchmark: warm engines start at both thread counts, claim/run/done/drain work, polish+
nopolish emit pool.csv/jls, aaa emits none, AAAD used at 1em4. (See dryrun.log.)
