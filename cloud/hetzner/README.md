# Hetzner fleet — benchmark runner

Run the full PEB+ODEPE benchmark (3 Julia arms; no MATLAB) across throwaway
Hetzner boxes, one shard per box, then merge. Same `ghcr.io/orebas/odepe-bench`
image validated on a single box (lotka besterror 9.45e-12).

## Files
| file | role |
|------|------|
| `tiers.json` | tier config — the only file to tune (systems, box type, shard granularity, concurrency, threads). |
| `fleet.py` | orchestrator: shard → provision → push reduced config → run → rsync → destroy. Box-pool = `--max-boxes`. |
| `run-on-box.sh` | runs *on* each box: `docker pull` + `docker run … run …` + `touch /work/DONE`. |
| `monitor.py` | live: per-box cells-done, age, $ so far, critical path. |
| `collect.py` | merge per-box `result.csv` → `result_merged.csv` + recovery/timing summary. |
| `reap.sh` | teardown (`--all`, `--run <id>`) + 48h-only orphan safety sweep. |
| `cloud-init-docker.yaml` | box bootstrap (installs docker.io). |

## The vCPU ceiling is the throughput dial
Hetzner caps **vCPUs per project** (new accounts start ~8 = one ccx33; **ccx43 = 16 vCPU
can't run at all until the cap lifts**). The cap rises as the account ages + spends; request
more at **Console → account menu (top-right) → Limits → Request change** (1–3 business days;
blocked while "too new"). `--max-boxes` must keep `Σ box vCPU ≤ cap` — the pool then cycles
shards through the available slots. Cost ≈ core-hours (flat); more boxes only cut wall time.

## Launch sequence (when the cap is lifted)
```bash
cd ~/ParameterEstimationBenchmark-local/cloud/hetzner
export PATH="$HOME/.local/bin:$PATH"          # hcloud

# 0. preflight: context + current capacity
hcloud context active                          # -> odepe
hcloud server list                             # -> empty

# 1. validate the plan at $0 (no cloud)
./fleet.py --tiers normal,hard,receptor --dry-run

# 2. ONE-box lifecycle smoke (fits an 8-vCPU cap: 1x ccx33, ~$0.05)
./fleet.py --tiers normal --run-id smoke --max-boxes 1 \
           --max-shards-per-tier 1 --noises 0 --num-tests 1
./collect.py --run-id smoke                    # expect 1 cell, recovered

# 3. full main run (normal+hard). Set --max-boxes so Σ vCPU ≤ cap minus receptor's reserve.
#    e.g. cap=120 vCPU -> ~7 ccx33 + a few ccx43; tune --max-boxes to taste.
./fleet.py --tiers normal,hard --run-id main-$(date +%F) --max-boxes 40 &
#    receptor as a SEPARATE background fleet (no timeout, own slots):
./fleet.py --tiers receptor --run-id recv-$(date +%F) --max-boxes 10 &

# 4. watch (another terminal)
./monitor.py --run-id main-$(date +%F) --interval 20

# 5. collect + teardown
./collect.py --run-id main-$(date +%F)
./reap.sh                                       # safety sweep; ./reap.sh --all to force-destroy
```

## Pre-launch checklist
- **Image freshness:** the fleet mounts the repo's `docker/run-benchmark.sh` over the image's
  baked copy, so the `--threads` flag works without a rebuild. For a fully self-contained image,
  rebuild+repush (`docker build -f docker/Dockerfile -t odepe-bench . && docker push …`) and drop
  the mount in `run-on-box.sh`.
- **`--max-boxes` vs cap:** ccx33=8 vCPU, ccx43=16 vCPU. Keep the sum under the project cap.
- **Receptor is separate + un-timed** — give it its own `--run-id` + slot reserve; it trickles in
  over hours and must not gate the main run.
- **Guardrail:** `./reap.sh --all` is the panic button; the bare `./reap.sh` is cron-safe (48h only).

## Tuning wall time
`shard_by` in `tiers.json` is the granularity knob: more split dims → more boxes → lower wall
(same cost). Defaults: normal `[system,arm]` (63), hard `[system,noise]` (25), receptor
`[arm,noise]` (15) = 103 boxes / 3240 cells. To halve the hard tier's wall, add `arm`:
`["system","arm","noise"]` → 75 boxes.
