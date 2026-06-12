#!/usr/bin/env python3
"""Provision worker boxes for the shared work queue and launch run-worker-box.sh.

Reuses fleet.py's provision/stage_overlay/push_overlay/ssh/destroy. Each box runs
the odepe-bench container in --worker-mode against an already-running coordinator;
the box rsyncs /work to the coordinator sink (the container has no ssh). Boxes are
destroyed when the coordinator queue drains.

Prereq: a coordinator box is already up (see WORKQUEUE_RUNBOOK.md), its
/srv/results sink exists, and the deploy key's PUBLIC half is in its authorized_keys.

  python3 cloud/hetzner/worker_fleet.py \
      --coordinator http://COORD_IP:8080 --results-sink root@COORD_IP:/srv/results \
      --deploy-key /tmp/odepe_deploy --config config/config_m1_main_10rep.json \
      --systems config/systems_m1_broad.json --name final_v2 --date 2026-06-12 \
      --n 1 --box-type ccx33 --engines 8:1,2:3 --odepe-ref main
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fleet  # noqa: E402  (reuse provision/stage_overlay/push_overlay/ssh/destroy)


def scp(src, ip, dst):
    subprocess.run(["scp", *fleet.SSH_OPTS, src, f"root@{ip}:{dst}"], check=True)


def setup_box(name, args, run_id):
    ip = None
    try:
        ip = fleet.provision(name, args.box_type, args.location, run_id)
        fleet.log(f"+ {name} @ {ip} ({args.box_type})")
        fleet.wait_for(ip, "test -f /tmp/cloud-init-done", f"cloud-init@{name}", 360, 8)
        fleet.push_overlay(ip, run_id)
        scp(args.deploy_key, ip, "/root/deploy_key")
        scp(args.config, ip, "/root/config.json")
        scp(args.systems, ip, "/root/systems.json")
        scp(os.path.join(HERE, "run-worker-box.sh"), ip, "/root/run-worker-box.sh")
        fleet.ssh(ip, "mkdir -p /root/shard /root/.ssh && "
                      "mv /root/config.json /root/systems.json /root/shard/ && "
                      "mv /root/deploy_key /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519 && "
                      "chmod +x /root/run-worker-box.sh")
        env = {
            "COORDINATOR": args.coordinator, "ENGINES": args.engines, "ARMS": args.arms,
            "RESULTS_SINK": args.results_sink, "NAME": args.name, "DATE": args.date,
            "ODEPE_REF": args.odepe_ref, "AMIGO2_SLOTS": str(args.amigo2_slots), "WNAME": name,
            "IMAGE": fleet.IMAGE,
        }
        envs = " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items())
        fleet.ssh(ip, f"nohup env {envs} bash /root/run-worker-box.sh >/root/wbox.log 2>&1 & echo launched")
        fleet.log(f"  {name}: worker launched (engines={args.engines})")
        return {"name": name, "ip": ip, "ok": True}
    except Exception as e:
        fleet.log(f"x {name} FAILED: {e}")
        return {"name": name, "ip": ip, "ok": False, "error": str(e)}


def queue_remaining(coordinator):
    try:
        with urllib.request.urlopen(f"{coordinator}/status", timeout=15) as r:
            return json.loads(r.read()).get("remaining", 1)
    except Exception:
        return 1  # transient error -> assume work remains


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coordinator", required=True, help="http://COORD_IP:8080")
    ap.add_argument("--results-sink", required=True, help="root@COORD_IP:/srv/results")
    ap.add_argument("--deploy-key", required=True, help="fleet deploy PRIVATE key path")
    ap.add_argument("--config", required=True)
    ap.add_argument("--systems", required=True)
    ap.add_argument("--arms", default="odepe_v2_polish,odepe_v2_nopolish,odepe_v2_aaa_nopolish,odepe_shade")
    ap.add_argument("--engines", default="8:1,2:4")
    ap.add_argument("--n", type=int, default=1, help="number of worker boxes")
    ap.add_argument("--box-type", default="ccx33")
    ap.add_argument("--location", default="fsn1")
    ap.add_argument("--provider", default="hetzner", choices=["hetzner", "do"])
    ap.add_argument("--name", default="wq", help="bench NAME -> benchmark_<name>_<date>")
    ap.add_argument("--date", default="2026-06-12")
    ap.add_argument("--odepe-ref", default="", help="git ref to inject (e.g. main); '' = use mounted")
    ap.add_argument("--amigo2-slots", type=int, default=0)
    ap.add_argument("--run-id", default="wq")
    ap.add_argument("--keep", action="store_true", help="do not destroy boxes when drained")
    ap.add_argument("--do-region", default="nyc1")
    ap.add_argument("--do-ssh-key", default="")
    args = ap.parse_args()

    fleet.PROVIDER = args.provider
    if args.provider == "do":
        fleet.DO_REGION, fleet.DO_SSH_KEY = args.do_region, args.do_ssh_key

    fleet.stage_overlay(args.run_id)
    fleet.log(f"staged overlay (run {args.run_id})")

    names = [f"odepe-wq-{args.name}-{i}".replace("_", "-") for i in range(args.n)]
    with ThreadPoolExecutor(max_workers=max(1, args.n)) as ex:
        boxes = list(ex.map(lambda nm: setup_box(nm, args, args.run_id), names))
    up = [b for b in boxes if b["ok"]]
    fleet.log(f"{len(up)}/{len(boxes)} worker boxes up")
    if not up:
        sys.exit(1)

    try:
        while queue_remaining(args.coordinator) > 0:
            time.sleep(60)
    except KeyboardInterrupt:
        pass
    fleet.log("queue drained")
    if not args.keep:
        for b in up:
            try:
                fleet.destroy(b["name"])
                fleet.log(f"destroyed {b['name']}")
            except Exception as e:
                fleet.log(f"destroy {b['name']} failed: {e}")


if __name__ == "__main__":
    main()
