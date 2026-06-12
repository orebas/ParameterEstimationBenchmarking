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

## Cloud findings (validated 2026-06-12 — 1-box test)
- **Coordinator MUST be a public box** (local is WSL2-NATed). A `ccx13`/fsn1 box ran it fine.
  Launch it with `setsid env PYTHONUNBUFFERED=1 python3 coordinator.py ... </dev/null &` — plain
  `ssh host "nohup ... &"` silently no-ops; `setsid </dev/null` fully detaches.
- **Provisioning**: `cax11`/`cpx11` are intermittently capacity-out / US-only; use `ccx`-class
  (the tiers already do) and fall back across locations on `resource_unavailable`.
- **Results deposit (KEY)**: the `odepe-bench` container has `rsync` + `python3` but **NO ssh
  client**. So a cloud worker CANNOT rsync-over-ssh from inside the container. Architecture:
  - worker.py in-container runs with `--results-rsync ""` (no in-container rsync) and POSTs
    `/done` over HTTP (python3 + outbound HTTP both work in-container).
  - results land in the in-container bench → `sync_to_work` copies to the mounted `/work`.
  - a **box-level** loop (outside the container, where ssh exists) rsyncs `/work` → the
    coordinator sink, using the fleet **deploy key** (`/tmp/odepe_deploy`, authorized in the
    coordinator's `authorized_keys`). The local worker, by contrast, rsyncs directly (it has ssh).

## Worker-box build (next — design settled, ~250 lines)
1. NEW `cloud/hetzner/run-worker-box.sh` (mirror run-on-box.sh's mounts): `docker run <mounts>
   $IMAGE run --worker-mode --coordinator $COORD --engines $ENGINES --results-rsync "" --arms
   $ARMS --config /shard/config.json --systems /shard/systems.json --odepe-ref main` **plus** a
   background `while rsync -az /work/.../filetree/ <deploykey> root@$COORD:/srv/results/; sleep 120; done`.
2. NEW `cloud/hetzner/worker_fleet.py` (reuse `fleet.stage_overlay/push_overlay/provision/destroy`):
   provision N `ccx33`/`ccx43` boxes → push overlay → scp deploy key to `/root/.ssh/id_ed25519` +
   full config/systems + run-worker-box.sh → launch it → monitor `/status` → destroy on drain.
3. Box → engines: ccx33 (8 vcpu) → `8:1` or `2:4`; ccx43 (16) → `8:1,2:4`.

## Validated 2026-06-12
- **Local** (`repro/benchmark_v2_dryrun_2026_06_12/`): coordinator + 1 worker (8:1,2:2) drained a
  6-cell benchmark; warm engines at both thread counts (~18x reuse), claim/run/done/drain, polish+
  nopolish emit pool.csv/jls (aaa none), AAAD at 1em4.
- **1-box cloud test**: coordinator on a public `ccx13`; the local worker claimed over HTTP, ran,
  and **rsync-deposited all 6 cells (result.csv + 4 pool.jls) to the cloud box `/srv/results`**;
  queue drained 6/6. Deploy-key auth proven. (Coordinator box torn down after.)
