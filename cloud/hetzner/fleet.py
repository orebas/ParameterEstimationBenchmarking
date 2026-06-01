#!/usr/bin/env python3
"""
Heterogeneous Hetzner fleet orchestrator for the PEB+ODEPE benchmark.

Each shard runs on its own throwaway box: provision -> push reduced config ->
docker-run run-benchmark.sh (the same image validated on a single box) -> rsync
results+logs home -> destroy. A ThreadPoolExecutor of size --max-boxes is the
box-pool: it never holds more than --max-boxes servers at once, so it respects
the Hetzner per-project vCPU/server ceiling and degrades gracefully (same work,
more wall) when the ceiling is low. No per-cell timeouts; a generous 12h per-box
wait bounds a genuinely-hung box (reap.sh is the real safety net).

Sharding: each box gets a REDUCED systems.json (its systems only) and a REDUCED
config.json (its noise levels only). cell_seed is deterministic from
(system, idx, noise) so every box generates bit-identical data with no
cross-box dependency; results merge by concatenating per-box result.csv.

Examples:
  # validate the whole plan at $0 (no cloud):
  ./fleet.py --tiers normal,hard,receptor --dry-run
  # 1-box lifecycle smoke (within an 8-vCPU cap): 1 shard, 1 noise, 1 trial:
  ./fleet.py --tiers normal --run-id smoke --max-boxes 1 \
             --max-shards-per-tier 1 --noises 0 --num-tests 1
  # full main run (when the cap is lifted), reserving slots for receptor:
  ./fleet.py --tiers normal,hard --run-id main-2026-06-05 --max-boxes 40
  ./fleet.py --tiers receptor    --run-id recv-2026-06-05 --max-boxes 10  # separate/background
"""
import argparse, json, subprocess, sys, time, itertools
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = Path(__file__).resolve().parent          # cloud/hetzner
PEB = HERE.parent.parent                          # ParameterEstimationBenchmark-local
RESULTS = HERE / "results"
STAGING = HERE / "staging"
SSH_KEY_FILE = str(Path.home() / ".ssh" / "id_ed25519")
SSH_KEY_NAME = "orebas@yahoo.com"                 # name in `hcloud ssh-key list`
IMAGE = "ghcr.io/orebas/odepe-bench:latest"
SSH_OPTS = ["-i", SSH_KEY_FILE, "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=10"]
DONE_TIMEOUT_S = 12 * 3600                         # generous hung-box bound (NOT a cell timeout)

# ── provider (set in main): "hetzner" | "do" ────────────────────────────────
PROVIDER = "hetzner"
DO_REGION = "nyc1"
DO_SSH_KEY = ""          # DigitalOcean ssh-key id/fingerprint (`doctl compute ssh-key list`)
DO_SIZES = {"ccx33": "s-8vcpu-32gb-amd", "ccx43": "s-8vcpu-32gb-amd"}   # 8c/32G == ccx33 tier (conc 5)
DO_RATES = {"ccx33": 0.25, "ccx43": 0.25}          # s-8vcpu-32gb-amd USD/hr
LOCAL_MEM_CAP = "22g"    # docker --memory cap for --provider local (cgroup-kills a cell, never the WSL2 VM)


def log(msg):
    print(f"[fleet {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# ── shard computation ────────────────────────────────────────────────────────
def compute_shards(tiers_cfg, tier_names, noises_all, overrides):
    noises = overrides.get("noises") or noises_all
    cap = overrides.get("max_shards_per_tier")
    exclude = set(overrides.get("exclude") or [])
    shards = []
    for tier in tier_names:
        t = tiers_cfg[tier]
        keys = t["shard_by"]
        sys_names = [s for s in t["systems"] if s not in exclude]
        dimvals = {"system": sys_names, "arm": t["arms"], "noise": noises}
        combos = list(itertools.product(*[dimvals[k] for k in keys]))
        if cap:
            combos = combos[:cap]
        for combo in combos:
            sel = dict(zip(keys, combo))
            label = tier + "__" + "_".join(f"{k}-{sel[k]}" for k in keys)
            shards.append({
                "tier": tier, "label": label.replace("/", "_"),
                "systems": [sel["system"]] if "system" in sel else list(t["systems"]),
                "arms":    [sel["arm"]]    if "arm"    in sel else list(t["arms"]),
                "noises":  [sel["noise"]]  if "noise"  in sel else list(noises),
                "box_type": t["box_type"], "concurrency": t["concurrency"],
                "threads": t["threads"], "heavy": t.get("heavy", ""),
            })
    return shards


def cells(shard, num_tests):
    return len(shard["systems"]) * len(shard["arms"]) * len(shard["noises"]) * num_tests


def already_done(label, run_id):
    """A shard is done if its result.csv was rsync'd home — lets a restart resume."""
    return any((RESULTS / run_id / label).glob("benchmark_*/result.csv"))


def stage_shard(shard, base_config, base_systems, num_tests, run_id):
    d = STAGING / run_id / shard["label"]
    d.mkdir(parents=True, exist_ok=True)
    sysf = {"systems": [s for s in base_systems["systems"] if s["name"] in shard["systems"]]}
    (d / "systems.json").write_text(json.dumps(sysf, indent=2))
    cfg = dict(base_config)
    cfg["NOISE_LEVEL"] = {k: base_config["NOISE_LEVEL"][k] for k in shard["noises"]}
    if num_tests:
        cfg["NUM_TESTS"] = num_tests
    (d / "config.json").write_text(json.dumps(cfg, indent=2))
    return d


# ── box lifecycle ────────────────────────────────────────────────────────────
def provision(name, box_type, location, run_id):
    if PROVIDER == "do":
        size = DO_SIZES.get(box_type, box_type)
        last = ""
        backoff = [30, 60, 120]             # gentle backstop; destroy() waits out the cap so this rarely fires
        for attempt in range(len(backoff) + 1):
            r = run(["doctl", "compute", "droplet", "create", name,
                     "--region", DO_REGION, "--size", size, "--image", "ubuntu-24-04-x64",
                     "--ssh-keys", DO_SSH_KEY,
                     "--user-data-file", str(HERE / "cloud-init-docker.yaml"),
                     "--tag-names", f"odepefleet,run-{run_id}".replace(".", "-"),
                     "--wait", "--output", "json"])
            if r.returncode == 0:
                d = json.loads(r.stdout)[0]
                for net in d.get("networks", {}).get("v4", []):
                    if net.get("type") == "public":
                        return net["ip_address"]
                raise RuntimeError("DO: no public IPv4 on droplet")
            last = (r.stderr.strip() or r.stdout.strip())[:200]
            if attempt < len(backoff):
                time.sleep(backoff[attempt])   # 30s, 60s, 120s — not a tight loop
        raise RuntimeError(f"DO provision failed after {len(backoff) + 1} tries: {last}")
    r = run(["hcloud", "server", "create", "--name", name, "--type", box_type,
             "--image", "ubuntu-24.04", "--location", location,
             "--ssh-key", SSH_KEY_NAME,
             "--user-data-from-file", str(HERE / "cloud-init-docker.yaml"),
             "--label", f"run={run_id}", "--label", "fleet=odepe", "-o", "json"])
    if r.returncode != 0:
        raise RuntimeError(f"provision failed: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)["server"]["public_net"]["ipv4"]["ip"]


def ssh(ip, cmd, timeout=None):
    return run(["ssh", *SSH_OPTS, f"root@{ip}", cmd], timeout=timeout)


def wait_for(ip, test_cmd, what, timeout_s, interval):
    start = time.time()
    while time.time() - start < timeout_s:
        if ssh(ip, test_cmd).returncode == 0:
            return
        time.sleep(interval)
    raise TimeoutError(f"timeout ({timeout_s}s) waiting for {what}")


def destroy(name):
    if PROVIDER == "do":
        run(["doctl", "compute", "droplet", "delete", name, "--force"])
        # Wait out the deletion before this worker frees up, so the cap slot is actually released
        # before the next provision. This is what prevents repeatedly attempting to exceed the
        # droplet limit — i.e. keeps us a well-behaved API citizen, not a retry-storming one.
        time.sleep(45)
    else:
        run(["hcloud", "server", "delete", name])


def run_shard(shard, run_id, base_config, base_systems, num_tests, location):
    label = shard["label"]
    if already_done(label, run_id):          # another worker (e.g. the other cloud) finished it
        log(f"⤳ skip {label} (already collected)")
        return {"label": label, "tier": shard["tier"], "ok": True, "minutes": 0.0,
                "box_type": shard["box_type"], "cells": cells(shard, num_tests), "skipped": True}
    if PROVIDER == "local":
        return run_shard_local(shard, run_id, base_config, base_systems, num_tests)
    name = f"odepe-{run_id}-{label}".lower().replace("_", "-").replace(".", "-")[:63]
    t0 = time.time()
    ip = None
    try:
        d = stage_shard(shard, base_config, base_systems, num_tests, run_id)
        log(f"+ provision {name} ({shard['box_type']}, {cells(shard, num_tests)} cells)")
        ip = provision(name, shard["box_type"], location, run_id)
        wait_for(ip, "test -f /tmp/cloud-init-done", f"cloud-init@{name}", 360, 8)
        # push reduced config + the runner override (run-benchmark.sh w/ --threads)
        push = run(["scp", *SSH_OPTS, str(d / "systems.json"), str(d / "config.json"),
                    str(HERE / "run-on-box.sh"), str(PEB / "docker" / "run-benchmark.sh"),
                    f"root@{ip}:/root/"])
        if push.returncode != 0:
            raise RuntimeError(f"scp failed: {push.stderr.strip()[:200]}")
        ssh(ip, "mkdir -p /root/shard && mv /root/systems.json /root/config.json "
                "/root/run-benchmark.sh /root/shard/ && chmod +x /root/run-on-box.sh")
        arms = ",".join(shard["arms"])
        env = (f"NAME={run_id} ARMS={arms} CONCURRENCY={shard['concurrency']} "
               f"THREADS={shard['threads']} HEAVY='{shard['heavy']}'")
        # background it + poll DONE so a network blip can't kill a multi-hour run
        ssh(ip, f"nohup env {env} bash /root/run-on-box.sh >/root/box.log 2>&1 & echo launched")
        log(f"  running {name}: arms={arms} conc={shard['concurrency']} threads={shard['threads']}")
        wait_for(ip, "test -f /work/DONE", f"shard@{name}", DONE_TIMEOUT_S, 30)
        dest = RESULTS / run_id / label
        dest.mkdir(parents=True, exist_ok=True)
        run(["rsync", "-az", "-e", "ssh " + " ".join(SSH_OPTS),
             f"root@{ip}:/work/", str(dest) + "/"])
        ok = any(dest.glob("benchmark_*/result.csv"))
        dt = (time.time() - t0) / 60
        log(f"✓ DONE {name} in {dt:.1f}min -> results/{run_id}/{label}  ok={ok}")
        return {"label": label, "tier": shard["tier"], "ok": ok, "minutes": dt,
                "box_type": shard["box_type"], "cells": cells(shard, num_tests)}
    except Exception as e:
        log(f"✗ FAIL {name}: {e}")
        return {"label": label, "tier": shard["tier"], "ok": False, "error": str(e),
                "box_type": shard["box_type"], "minutes": (time.time() - t0) / 60,
                "cells": cells(shard, num_tests)}
    finally:
        if ip is not None:
            destroy(name)


def run_shard_local(shard, run_id, base_config, base_systems, num_tests):
    """Run a shard in a local docker container, memory-capped to spare the WSL2 VM. No cloud."""
    label = shard["label"]
    t0 = time.time()
    try:
        d = stage_shard(shard, base_config, base_systems, num_tests, run_id)
        work = STAGING / run_id / f"_localwork_{label}"
        work.mkdir(parents=True, exist_ok=True)
        arms = ",".join(shard["arms"])
        log(f"+ local docker {label} ({cells(shard, num_tests)} cells, conc={shard['concurrency']}, mem<={LOCAL_MEM_CAP})")
        run(["docker", "run", "--rm", f"--memory={LOCAL_MEM_CAP}",
             "-v", f"{d}:/shard:ro",
             "-v", f"{PEB}/docker/run-benchmark.sh:/opt/peb/docker/run-benchmark.sh:ro",
             "-v", f"{work}:/work",
             IMAGE, "run", "--name", run_id,
             "--config", "/shard/config.json", "--systems", "/shard/systems.json",
             "--arms", arms, "--concurrency", str(shard["concurrency"]),
             "--threads", str(shard["threads"]), "--exclude-systems", "",
             "--heavy-systems", shard["heavy"], "--odepe-ref", "quoll-v1"], timeout=None)
        dest = RESULTS / run_id / label
        dest.mkdir(parents=True, exist_ok=True)
        for bench in work.glob("benchmark_*"):
            run(["cp", "-a", str(bench), str(dest) + "/"])
        run(["rm", "-rf", str(work)])
        ok = any(dest.glob("benchmark_*/result.csv"))
        dt = (time.time() - t0) / 60
        log(f"{'✓' if ok else '✗'} DONE(local) {label} in {dt:.1f}min ok={ok}")
        return {"label": label, "tier": shard["tier"], "ok": ok, "minutes": dt,
                "box_type": "local", "cells": cells(shard, num_tests)}
    except Exception as e:
        log(f"✗ FAIL(local) {label}: {e}")
        return {"label": label, "tier": shard["tier"], "ok": False, "error": str(e),
                "box_type": "local", "minutes": (time.time() - t0) / 60, "cells": cells(shard, num_tests)}


# ── plan / cost reporting ────────────────────────────────────────────────────
def print_plan(shards, num_tests, rates):
    log(f"PLAN: {len(shards)} shards / boxes")
    by_tier = {}
    for s in shards:
        by_tier.setdefault(s["tier"], []).append(s)
    grand_cells = 0
    for tier, ss in by_tier.items():
        c = sum(cells(s, num_tests) for s in ss)
        grand_cells += c
        bt = ss[0]["box_type"]
        log(f"  {tier:9s}: {len(ss):3d} boxes ({bt}) | {c:5d} cells "
            f"| conc={ss[0]['concurrency']} threads={ss[0]['threads']}")
    peak_rate = sum(rates.get(s["box_type"], 0) for s in shards)
    log(f"  TOTAL: {len(shards)} boxes | {grand_cells} cells "
        f"| ${peak_rate:.2f}/hr at full concurrency")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tiers", default="normal,hard,receptor")
    ap.add_argument("--run-id", default="run")
    ap.add_argument("--max-boxes", type=int, default=4)
    ap.add_argument("--location", default="fsn1")
    ap.add_argument("--provider", default="hetzner", choices=["hetzner", "do", "local"])
    ap.add_argument("--do-region", default="nyc1")
    ap.add_argument("--do-ssh-key", default="",
                    help="DigitalOcean ssh-key id/fingerprint (doctl compute ssh-key list)")
    ap.add_argument("--concurrency", type=int, default=0, help="override per-box concurrency (0=tier default)")
    ap.add_argument("--threads", type=int, default=0, help="override per-cell threads (0=tier default)")
    ap.add_argument("--shard-slice", default="", help="i/n: only shards where index%%n==i (split workers)")
    ap.add_argument("--reverse", action="store_true", help="process shards back-to-front (converge w/ a forward worker)")
    ap.add_argument("--middle-out", action="store_true", help="process shards center-outward (3rd worker fills the gap)")
    ap.add_argument("--config", default=str(PEB / "config" / "config_quoll_broad.json"))
    ap.add_argument("--systems", default=str(PEB / "config" / "systems_quoll_broad.json"))
    ap.add_argument("--tiers-file", default=str(HERE / "tiers.json"))
    ap.add_argument("--dry-run", action="store_true", help="compute+stage shards, print plan, no cloud")
    # smoke / scope overrides
    ap.add_argument("--num-tests", type=int, default=0, help="override NUM_TESTS (0=config default)")
    ap.add_argument("--noises", default="", help="comma list of noise mnemonics (default: all)")
    ap.add_argument("--max-shards-per-tier", type=int, default=0)
    ap.add_argument("--exclude", default="", help="comma list of systems to drop (e.g. too-slow ones)")
    args = ap.parse_args()

    global PROVIDER, DO_REGION, DO_SSH_KEY
    PROVIDER, DO_REGION, DO_SSH_KEY = args.provider, args.do_region, args.do_ssh_key
    if PROVIDER == "do" and not DO_SSH_KEY and not args.dry_run:
        sys.exit("--do-ssh-key required for --provider do (from: doctl compute ssh-key list)")

    tiers_cfg_all = json.loads(Path(args.tiers_file).read_text())
    tiers_cfg = tiers_cfg_all["tiers"]
    rates = {} if PROVIDER == "local" else (DO_RATES if PROVIDER == "do" else tiers_cfg_all["_rates_usd_per_hr"])
    base_config = json.loads(Path(args.config).read_text())
    base_systems = json.loads(Path(args.systems).read_text())
    noises_all = list(base_config["NOISE_LEVEL"].keys())
    num_tests = args.num_tests or base_config["NUM_TESTS"]
    tier_names = [t.strip() for t in args.tiers.split(",") if t.strip()]
    overrides = {
        "noises": [n.strip() for n in args.noises.split(",") if n.strip()] or None,
        "max_shards_per_tier": args.max_shards_per_tier or None,
        "exclude": [s.strip() for s in args.exclude.split(",") if s.strip()] or None,
    }
    shards = compute_shards(tiers_cfg, tier_names, noises_all, overrides)
    for s in shards:
        if args.concurrency:
            s["concurrency"] = args.concurrency
        if args.threads:
            s["threads"] = args.threads
    if args.shard_slice:
        i, n = (int(x) for x in args.shard_slice.split("/"))
        shards = [s for k, s in enumerate(shards) if k % n == i]
    if args.reverse:
        shards = list(reversed(shards))
    if args.middle_out:
        c = (len(shards) - 1) / 2
        shards = [s for _, s in sorted(enumerate(shards), key=lambda kv: abs(kv[0] - c))]
    print_plan(shards, num_tests, rates)

    if args.dry_run:
        for s in shards:
            stage_shard(s, base_config, base_systems, num_tests, args.run_id)
        log(f"DRY-RUN: staged {len(shards)} shard configs under staging/{args.run_id}/ — no cloud touched.")
        return

    RESULTS.mkdir(parents=True, exist_ok=True)
    pending = [s for s in shards if not already_done(s["label"], args.run_id)]
    if len(pending) < len(shards):
        log(f"resume: {len(shards) - len(pending)} shards already collected, {len(pending)} to go")
    shards = pending
    if not shards:
        log("nothing to do — all shards already collected.")
        return
    log(f"launching {len(shards)} shards, pool={args.max_boxes} boxes, run-id={args.run_id}")
    results = []
    with ThreadPoolExecutor(max_workers=args.max_boxes) as ex:
        futs = {ex.submit(run_shard, s, args.run_id, base_config, base_systems,
                          num_tests, args.location): s for s in shards}
        for fut in as_completed(futs):
            results.append(fut.result())
            done = len(results)
            log(f"progress: {done}/{len(shards)} shards finished")

    ok = [r for r in results if r.get("ok")]
    bad = [r for r in results if not r.get("ok")]
    cost = sum(r["minutes"] / 60 * rates.get(r["box_type"], 0) for r in results)
    log("=" * 60)
    log(f"SUMMARY run-id={args.run_id}: {len(ok)}/{len(results)} shards ok, "
        f"{sum(r['cells'] for r in ok)} cells, ~${cost:.2f}, "
        f"slowest {max((r['minutes'] for r in results), default=0):.0f}min")
    if bad:
        log(f"FAILED shards: {[r['label'] for r in bad]}")
    (RESULTS / args.run_id / "_summary.json").write_text(json.dumps(results, indent=2))
    log(f"per-shard results under results/{args.run_id}/ ; merge with collect step.")


if __name__ == "__main__":
    main()
