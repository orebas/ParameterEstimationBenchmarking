#!/usr/bin/env python3
"""
Live fleet monitor — polls hcloud + ssh's each box to show progress, timing, cost.
For each fleet box: cells completed (result.csv count), box age, $ so far, last log
line. Surfaces the oldest in-flight box = the critical path (the wall driver).

Usage:
  ./monitor.py                 # poll every 30s until Ctrl-C
  ./monitor.py --run-id main-2026-06-05 --interval 20
  ./monitor.py --once          # single snapshot
"""
import argparse, json, subprocess, time
from datetime import datetime, timezone
from pathlib import Path

SSH_KEY_FILE = str(Path.home() / ".ssh" / "id_ed25519")
SSH_OPTS = ["-i", SSH_KEY_FILE, "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=8",
            "-o", "BatchMode=yes"]
RATES = {"ccx33": 0.1186, "ccx43": 0.2372}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def list_boxes(run_id):
    sel = "fleet=odepe" + (f",run={run_id}" if run_id else "")
    r = run(["hcloud", "server", "list", "--selector", sel, "-o", "json"])
    return json.loads(r.stdout) if r.returncode == 0 else []


def age_min(created_iso):
    try:
        t = datetime.fromisoformat(created_iso.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - t).total_seconds() / 60
    except Exception:
        return 0.0


def box_probe(ip):
    # cells done (result.csv) | DONE? | last log line
    cmd = ("c=$(find /work -name result.csv 2>/dev/null | wc -l); "
           "d=$(test -f /work/DONE && echo DONE || echo ....); "
           "t=$(tail -n1 /root/box.log 2>/dev/null | tr -d '\\r' | cut -c1-52); "
           'echo "$c|$d|$t"')
    r = run(["ssh", *SSH_OPTS, f"root@{ip}", cmd])
    return (r.stdout.strip().split("|") + ["?", "?", ""])[:3] if r.returncode == 0 \
        else ["?", "boot", "(ssh not ready)"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args()
    while True:
        bx = list_boxes(a.run_id)
        print("\n" + "=" * 86)
        print(f"{time.strftime('%H:%M:%S')}   fleet: {len(bx)} boxes"
              + (f"  run-id={a.run_id}" if a.run_id else ""))
        tot_cells, tot_cost, oldest = 0, 0.0, (0.0, "")
        rows = []
        for b in bx:
            name = b["name"]
            bt = b["server_type"]["name"]
            ip = b["public_net"]["ipv4"]["ip"]
            am = age_min(b.get("created", ""))
            cells, done, tail = box_probe(ip)
            cost = am / 60 * RATES.get(bt, 0)
            tot_cost += cost
            try:
                tot_cells += int(cells)
            except ValueError:
                pass
            if am > oldest[0] and done != "DONE":
                oldest = (am, name)
            rows.append((name[:42], bt, cells, done, am, tail))
        for name, bt, cells, done, am, tail in sorted(rows):
            print(f"  {name:42s} {bt:5s} cells={cells:>4s} {done:4s} {am:5.0f}m | {tail}")
        print(f"  ---- cells done (rsync pending): {tot_cells}   "
              f"$ so far: ${tot_cost:.2f}   "
              f"critical path: {oldest[1][:38]} ({oldest[0]:.0f}m)")
        if a.once or not bx:
            break
        time.sleep(a.interval)


if __name__ == "__main__":
    main()
