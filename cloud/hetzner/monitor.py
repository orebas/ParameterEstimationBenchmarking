#!/usr/bin/env python3
"""
Live fleet monitor — polls cloud control plane + ssh's each box to show progress,
timing, cost. For each fleet box: cells completed, aggregate files, DONE/FAILED,
active Julia workers, box age, $ so far, and last log line. Surfaces the oldest
in-flight box = the critical path (the wall driver).

Usage:
  ./monitor.py                 # poll every 30s until Ctrl-C
  ./monitor.py --provider do --run-id main-2026-06-05 --once
  ./monitor.py --run-id main-2026-06-05 --interval 20
  ./monitor.py --once          # single snapshot
"""
import argparse, json, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

SSH_KEY_FILE = str(Path.home() / ".ssh" / "id_ed25519")
SSH_OPTS = ["-i", SSH_KEY_FILE, "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=8",
            "-o", "BatchMode=yes"]
HCLOUD_RATES = {"ccx33": 0.1186, "ccx43": 0.2372}
DO_FALLBACK_RATES = {"s-8vcpu-32gb-amd": 0.25}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def public_ipv4_from_do(droplet):
    for net in droplet.get("networks", {}).get("v4", []):
        if net.get("type") == "public":
            return net.get("ip_address", "")
    return ""


def normalize_hcloud_box(server):
    bt = server["server_type"]["name"]
    return {
        "name": server["name"],
        "type": bt,
        "ip": server["public_net"]["ipv4"]["ip"],
        "created": server.get("created", ""),
        "hourly_rate": HCLOUD_RATES.get(bt, 0.0),
    }


def normalize_do_box(droplet):
    size = droplet.get("size") or {}
    bt = droplet.get("size_slug") or size.get("slug") or "?"
    return {
        "name": droplet["name"],
        "type": bt,
        "ip": public_ipv4_from_do(droplet),
        "created": droplet.get("created_at", ""),
        "hourly_rate": float(size.get("price_hourly") or DO_FALLBACK_RATES.get(bt, 0.0)),
    }


def list_hcloud_boxes(run_id):
    sel = "fleet=odepe" + (f",run={run_id}" if run_id else "")
    r = run(["hcloud", "server", "list", "--selector", sel, "-o", "json"])
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip()
        raise RuntimeError(f"hcloud list failed: {msg}")
    return [normalize_hcloud_box(server) for server in json.loads(r.stdout)]


def list_do_boxes(run_id):
    cmd = ["doctl", "compute", "droplet", "list", "--tag-name", "odepefleet", "--output", "json"]
    r = run(cmd)
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip()
        raise RuntimeError(f"doctl droplet list failed: {msg}")
    droplets = json.loads(r.stdout)
    if run_id:
        run_tag = f"run-{run_id}".replace(".", "-")
        droplets = [d for d in droplets if run_tag in d.get("tags", [])]
    return [normalize_do_box(droplet) for droplet in droplets]


def list_boxes(provider, run_id):
    if provider == "do":
        return list_do_boxes(run_id)
    return list_hcloud_boxes(run_id)


def age_min(created_iso):
    try:
        t = datetime.fromisoformat(created_iso.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - t).total_seconds() / 60
    except Exception:
        return 0.0


def short_name(name):
    if len(name) <= 34:
        return name
    parts = name.split("-")
    if len(parts) >= 4:
        return "-".join(parts[-4:])
    return name[-34:]


def box_probe(ip):
    # cell result.csv count | aggregate result.csv count | stdout count | DONE | FAILED |
    # Julia worker count | load average | Julia RSS GiB | last log line
    cmd = r"""
cells=$(find /work -path '*/filetree/*/*/result.csv' -type f 2>/dev/null | wc -l | tr -d ' ')
agg=$(find /work -maxdepth 2 -name result.csv -type f 2>/dev/null | wc -l | tr -d ' ')
stdout=$(find /work -name stdout.txt -type f 2>/dev/null | wc -l | tr -d ' ')
done=$(test -f /work/DONE && echo DONE || echo ....)
failed=$(test -f /work/FAILED && echo FAIL || echo ....)
julia=$(ps -C julia --no-headers 2>/dev/null | wc -l | tr -d ' ')
load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
rss=$(ps -C julia -o rss= 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s/1024/1024}')
tail=$(tail -n1 /root/box.log 2>/dev/null | tr -d '\r' | cut -c1-70)
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$cells" "$agg" "$stdout" "$done" "$failed" "$julia" "$load" "$rss" "$tail"
"""
    r = run(["ssh", *SSH_OPTS, f"root@{ip}", cmd])
    if r.returncode != 0:
        return ["?", "?", "?", "boot", "?", "?", "?", "?", "(ssh not ready)"]
    return (r.stdout.strip().split("|") + ["?"] * 9)[:9]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider", default="hetzner", choices=["hetzner", "do"])
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args()
    while True:
        try:
            bx = list_boxes(a.provider, a.run_id)
        except RuntimeError as e:
            sys.exit(str(e))
        print("\n" + "=" * 86)
        print(f"{time.strftime('%H:%M:%S')}   {a.provider}: {len(bx)} boxes"
              + (f"  run-id={a.run_id}" if a.run_id else ""))
        tot_cells, tot_aggs, tot_stdout, tot_workers, tot_cost, oldest = 0, 0, 0, 0, 0.0, (0.0, "")
        rows = []
        for b in bx:
            name = b["name"]
            bt = b["type"]
            ip = b["ip"]
            am = age_min(b.get("created", ""))
            cells, aggs, stdout, done, failed, workers, load, rss, tail = box_probe(ip)
            cost = am / 60 * b.get("hourly_rate", 0.0)
            tot_cost += cost
            for val, total_name in (
                (cells, "cells"),
                (aggs, "aggs"),
                (stdout, "stdout"),
                (workers, "workers"),
            ):
                try:
                    if total_name == "cells":
                        tot_cells += int(val)
                    elif total_name == "aggs":
                        tot_aggs += int(val)
                    elif total_name == "stdout":
                        tot_stdout += int(val)
                    elif total_name == "workers":
                        tot_workers += int(val)
                except ValueError:
                    pass
            if am > oldest[0] and done != "DONE":
                oldest = (am, name)
            status = failed if failed == "FAIL" else done
            rows.append((short_name(name), bt, cells, aggs, stdout, status, workers, load, rss, am, tail))
        for name, bt, cells, aggs, stdout, status, workers, load, rss, am, tail in sorted(rows):
            print(f"  {name:42s} {bt:17s} cells={cells:>3s} agg={aggs:>1s} "
                  f"out={stdout:>3s} {status:4s} julia={workers:>2s} "
                  f"load={load:14s} rss={rss:>4s}G {am:5.0f}m | {tail}")
        print(f"  ---- cells: {tot_cells}   aggs: {tot_aggs}   stdout: {tot_stdout}   "
              f"julia workers: {tot_workers}   "
              f"$ so far: ${tot_cost:.2f}   "
              f"critical path: {oldest[1][:38]} ({oldest[0]:.0f}m)")
        if a.once or not bx:
            break
        time.sleep(a.interval)


if __name__ == "__main__":
    main()
