#!/usr/bin/env python3
"""Pull-worker for the shared dynamic work queue.

Runs on every box (Hetzner / DigitalOcean / local). Holds a FIXED pool of warm
"engine" slots and keeps every slot busy by pulling cells from the coordinator
until the whole queue drains. Two slot kinds:

  * Julia slots  -- each owns a persistent warm `warm_julia_worker.jl --server`
    process at a fixed JULIA_NUM_THREADS (e.g. 8 for hard cells, 2 for easy).
    The heavy ODEPE compile is paid ONCE per engine, then every claimed cell of
    that thread-count runs warm. Serves the ODEPE arms (kind=julia).
  * MATLAB slots -- run amigo2 cells via estimate.py (kind=matlab). Local only.

A slot loop: claim a fitting cell -> run it -> rsync the cell dir to the results
sink -> POST /done -> repeat. One heartbeat thread renews all of this box's
leases so a slow-but-alive cell is never re-queued; only a DEAD box's cells are.

Engine layout is given as --engines "8:1,2:4" (1 eight-thread + 4 two-thread
slots). Sum(threads*count) should be <= the box vCPUs.

Usage:
  python3 src/worker.py --coordinator http://COORD:8080 --bench /abs/bench \
      --worker $(hostname) --engines 8:1,2:4 --julia-project environments/julia_odepe \
      [--amigo2-slots 2] [--results-rsync user@coord:/srv/results] [--peb-root .]
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

SSH_OPTS = ("-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
            "-o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10")


# ----------------------------------------------------------------------------- HTTP
def http_get(url, timeout=30):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def http_post(url, obj, timeout=30):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def claim(cfg, kind, free_cores):
    q = urllib.parse.urlencode({"worker": cfg.worker, "free_cores": free_cores, "kind": kind})
    try:
        c = http_get(f"{cfg.coordinator}/claim?{q}")
        return c or None
    except Exception as e:
        print(f"[worker] claim error: {e}", flush=True)
        return None


def post_done(cfg, cell_pk, status, secs):
    try:
        http_post(f"{cfg.coordinator}/done",
                  {"cell_pk": cell_pk, "status": status, "secs": secs})
    except Exception as e:
        print(f"[worker] done error (cell {cell_pk}): {e}", flush=True)


def queue_remaining(cfg):
    try:
        return http_get(f"{cfg.coordinator}/status").get("remaining", 1)
    except Exception:
        return 1  # assume work remains on transient error -> keep waiting


# ----------------------------------------------------------------------------- warm Julia engine
class EngineDied(Exception):
    pass


class JuliaEngine:
    """One persistent warm Julia at a fixed thread count, fed one cell at a time."""

    def __init__(self, cfg, threads, log_path):
        self.cfg = cfg
        self.threads = threads
        self.log_path = log_path
        self.p = None

    def start(self):
        env = dict(os.environ, JULIA_NUM_THREADS=str(self.threads),
                   MKL_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1",
                   ODEPE_WARM_JULIA_NO_EXIT="1")
        cmd = ["julia", "--startup-file=no", f"--project={self.cfg.julia_project}",
               "src/warm_julia_worker.jl", "--server", self.cfg.bench]
        self.log = open(self.log_path, "w")
        self.p = subprocess.Popen(cmd, cwd=self.cfg.peb_root, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=self.log,
                                  text=True, bufsize=1)
        while True:
            line = self.p.stdout.readline()
            if line == "":
                raise EngineDied("engine failed to reach READY (see %s)" % self.log_path)
            if "WARM JULIA SERVER READY" in line:
                return

    def run(self, run, software, index):
        """Run one cell; block until it finishes. Returns the cell's exit status
        (0 ok). Raises EngineDied if the Julia process crashed."""
        self.p.stdin.write(f"{run}\t{software}\t{index}\n")
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if line == "":
                raise EngineDied("engine exited mid-cell")
            line = line.rstrip("\n")
            if line.startswith("CELL_DONE\t"):
                return int(line.split("\t")[2])
            if line.startswith("CELL_ERR"):
                return 2
            # stray output (warnings printed outside the cell redirect) -> ignore

    def close(self):
        try:
            if self.p and self.p.poll() is None:
                self.p.stdin.write("QUIT\n")
                self.p.stdin.flush()
                self.p.wait(timeout=20)
        except Exception:
            try:
                self.p.kill()
            except Exception:
                pass


# ----------------------------------------------------------------------------- result deposit
def deposit(cfg, run, cell_id):
    """rsync the finished cell directory to the results sink. No-op when running
    locally (results already live in the local filetree)."""
    if not cfg.results_rsync:
        return
    src = os.path.join(cfg.bench, "filetree", run, cell_id) + "/"
    dst = f"{cfg.results_rsync}/{run}/{cell_id}/"
    subprocess.run(["rsync", "-az", "--mkpath", "--timeout=120",
                    "-e", f"ssh {SSH_OPTS}", "--", src, dst],
                   check=False)


# ----------------------------------------------------------------------------- slots
def julia_slot(cfg, name, threads, stop):
    log_path = os.path.join(cfg.log_dir, f"engine_{name}.log")
    engine = JuliaEngine(cfg, threads, log_path)
    try:
        engine.start()
    except EngineDied as e:
        print(f"[{name}] FAILED to start: {e}", flush=True)
        return
    print(f"[{name}] warm engine up (threads={threads})", flush=True)
    while not stop.is_set():
        cell = claim(cfg, "julia", threads)
        if not cell:
            if queue_remaining(cfg) == 0:
                break
            time.sleep(cfg.idle_sleep)
            continue
        cid, pk = cell["cell_id"], cell["cell_pk"]
        t0 = time.time()
        try:
            status = engine.run(cell["run"], cell["software"], cell["index"])
        except EngineDied:
            secs = time.time() - t0
            print(f"[{name}] engine died on {cid}; marking fail + restarting", flush=True)
            deposit(cfg, cell["run"], cid)
            post_done(cfg, pk, "fail", secs)
            engine = JuliaEngine(cfg, threads, log_path)
            try:
                engine.start()
            except EngineDied as e:
                print(f"[{name}] could not restart engine: {e}", flush=True)
                return
            continue
        secs = round(time.time() - t0, 2)
        deposit(cfg, cell["run"], cid)
        post_done(cfg, pk, "ok" if status == 0 else "fail", secs)
        print(f"[{name}] {cid} -> {'ok' if status == 0 else 'fail'} ({secs}s)", flush=True)
    engine.close()
    print(f"[{name}] drained, exiting", flush=True)


def matlab_slot(cfg, name, stop):
    while not stop.is_set():
        cell = claim(cfg, "matlab", 2)
        if not cell:
            if queue_remaining(cfg) == 0:
                break
            time.sleep(cfg.idle_sleep)
            continue
        cid, pk = cell["cell_id"], cell["cell_pk"]
        t0 = time.time()
        rc = subprocess.run([sys.executable, "src/estimate.py", cfg.bench,
                             cell["run"], cell["software"], str(cell["index"])],
                            cwd=cfg.peb_root).returncode
        secs = round(time.time() - t0, 2)
        deposit(cfg, cell["run"], cid)
        post_done(cfg, pk, "ok" if rc == 0 else "fail", secs)
        print(f"[{name}] amigo2 {cid} -> {'ok' if rc == 0 else 'fail'} ({secs}s)", flush=True)
    print(f"[{name}] drained, exiting", flush=True)


def heartbeat_loop(cfg, stop):
    while not stop.wait(cfg.heartbeat_interval):
        try:
            http_post(f"{cfg.coordinator}/heartbeat", {"worker": cfg.worker})
        except Exception:
            pass


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coordinator", required=True, help="http://host:port")
    ap.add_argument("--bench", required=True, help="absolute path to the generated benchmark dir")
    ap.add_argument("--worker", required=True, help="unique box name (heartbeat key)")
    ap.add_argument("--engines", default="2:1",
                    help="warm Julia slots: 'threads:count,...' e.g. 8:1,2:4")
    ap.add_argument("--amigo2-slots", type=int, default=0, help="MATLAB slots (local only)")
    ap.add_argument("--julia-project", default="environments/julia_odepe")
    ap.add_argument("--peb-root", default=".", help="PEB repo root (cwd for julia/estimate)")
    ap.add_argument("--results-rsync", default="",
                    help="user@host:/path sink for finished cells ('' = local, no rsync)")
    ap.add_argument("--idle-sleep", type=float, default=8.0)
    ap.add_argument("--heartbeat-interval", type=float, default=60.0)
    ap.add_argument("--log-dir", default="/tmp")
    cfg = ap.parse_args()
    cfg.bench = os.path.abspath(cfg.bench)
    cfg.peb_root = os.path.abspath(cfg.peb_root)
    os.makedirs(cfg.log_dir, exist_ok=True)

    stop = threading.Event()
    threads = []
    for spec in cfg.engines.split(","):
        spec = spec.strip()
        if not spec:
            continue
        tc, _, cnt = spec.partition(":")
        for i in range(int(cnt or 1)):
            name = f"{cfg.worker}-j{tc}-{i}"
            t = threading.Thread(target=julia_slot, args=(cfg, name, int(tc), stop), daemon=True)
            t.start()
            threads.append(t)
    for i in range(cfg.amigo2_slots):
        name = f"{cfg.worker}-m-{i}"
        t = threading.Thread(target=matlab_slot, args=(cfg, name, stop), daemon=True)
        t.start()
        threads.append(t)

    hb = threading.Thread(target=heartbeat_loop, args=(cfg, stop), daemon=True)
    hb.start()
    print(f"[worker] {cfg.worker}: {len(threads)} slots up, coordinator={cfg.coordinator}", flush=True)

    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        pass
    stop.set()
    print(f"[worker] {cfg.worker}: all slots drained, done", flush=True)


if __name__ == "__main__":
    main()
