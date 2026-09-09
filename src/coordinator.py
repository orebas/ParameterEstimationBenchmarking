#!/usr/bin/env python3
"""Shared dynamic work-queue coordinator for the final ODEPE benchmark.

A tiny stdlib-only HTTP service backed by SQLite. It owns the manifest of every
benchmark CELL (arm x system x rep x noise) and hands cells out to pull-workers
running on Hetzner / DigitalOcean / local boxes. The work queue is what keeps
every core on every provider busy until the single slowest cell finishes.

Design notes:
  * Cell data is bit-identically regenerable from (system, rep, noise) via
    shared.cell_seed, so the coordinator stores no data -- only the manifest +
    each cell's status. Workers regenerate / already-have the filetree locally.
  * The coordinator never KILLS a running cell. A claim carries a short lease
    that the worker renews by heartbeat; the lease only re-queues a cell whose
    worker DIED (no heartbeat for lease_seconds). A legitimately-long cell on a
    live worker is never re-queued. The >5h "is this stuck?" watchdog is human
    (see /status, which sorts in-flight cells by elapsed time).
  * Priority = longest-expected-first (hard 8-core cells before easy 2-core),
    so makespan ~= the slowest single cell.

Endpoints:
  GET  /claim?worker=W&free_cores=N&kind=julia|matlab  -> one cell as JSON, or {}
  POST /done        {cell_pk, status:"ok"|"fail", secs}
  POST /heartbeat   {worker}                       -> renews that worker's leases
  POST /requeue     {cell_id} or {cell_pk}         -> force a cell back to PENDING
  GET  /status                                     -> progress + in-flight by elapsed
  GET  /health                                     -> {"ok": true}

Usage:
  python3 src/coordinator.py --huge-json <bench>/huge_json.json \
      --arms odepe_v2_polish,odepe_v2_nopolish,odepe_v2_aaa_nopolish,odepe_shade,amigo2 \
      --hard-systems biohydrogenation,crauste,cstr,daisy_mamil4,hiv,repressilator,seir,sirt_treatment,slow_fast \
      --local-only-arms amigo2 --hard-cores 8 --easy-cores 2 \
      --port 8080 --db queue.db
"""
import argparse
import json
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LOCK = threading.Lock()       # serialize all DB ops (low QPS; keeps claim atomic)
DB = None                     # sqlite3.Connection (check_same_thread=False)
CFG = None                    # argparse.Namespace


# ----------------------------------------------------------------------------- manifest
def parse_cell_id(instance):
    """(system, rep_idx, noise) from an instance dict. System names contain
    underscores, so peel the bare name (instance['name']) off the front."""
    cid = instance["id"]
    name = instance["name"]
    suffix = cid[len(name) + 1:] if cid.startswith(name + "_") else cid
    rep_str, noise = suffix.rsplit("_", 1)
    return name, int(rep_str), noise


def build_manifest(conn, cfg):
    instances = json.load(open(cfg.huge_json))["instances"]
    arms = [a.strip() for a in cfg.arms.split(",") if a.strip()]
    hard = set(s.strip() for s in cfg.hard_systems.split(",") if s.strip())
    local_only_arms = set(a.strip() for a in cfg.local_only_arms.split(",") if a.strip())
    rows = []
    for arm in arms:
        run = f"{arm}_run"
        lo = 1 if arm in local_only_arms else 0
        for inst in instances:
            system, rep, noise = parse_cell_id(inst)
            # amigo2 (local-only, single-threaded MATLAB) never needs hard cores —
            # giving it hard_cores makes it unclaimable by the low-free-cores MATLAB slot.
            cores = cfg.easy_cores if (lo or system not in hard) else cfg.hard_cores
            rows.append((arm, run, arm, int(inst["index"]), inst["id"],
                         system, noise, cores, lo, "PENDING", None, 0.0,
                         None, None, None, 0))
    conn.executemany(
        "INSERT INTO cells(arm,run,software,idx,cell_id,system,noise,cores,"
        "local_only,status,worker,lease_expiry,started,finished,secs,attempts) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    conn.commit()
    return len(rows)


def export_cells_csv(conn, path):
    """Stable cell_id <-> (arm, system, rep, noise, cores) map, written once at
    run start. Lets you find + re-queue any individual cell by hand later."""
    import csv
    rows = conn.execute(
        "SELECT pk, arm, cell_id, system, noise, cores, local_only FROM cells "
        "ORDER BY arm, system, cell_id").fetchall()
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["pk", "arm", "cell_id", "system", "noise", "cores", "local_only"])
        for r in rows:
            w.writerow([r["pk"], r["arm"], r["cell_id"], r["system"], r["noise"],
                        r["cores"], r["local_only"]])
    print(f"[coordinator] wrote cells map: {path} ({len(rows)} rows)")


def init_db(cfg):
    conn = sqlite3.connect(cfg.db, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS cells(
        pk INTEGER PRIMARY KEY AUTOINCREMENT,
        arm TEXT, run TEXT, software TEXT, idx INTEGER, cell_id TEXT,
        system TEXT, noise TEXT, cores INTEGER, local_only INTEGER,
        status TEXT, worker TEXT, lease_expiry REAL,
        started REAL, finished REAL, secs REAL, attempts INTEGER)""")
    conn.execute("CREATE INDEX IF NOT EXISTS i_status ON cells(status, cores)")
    conn.commit()
    n = conn.execute("SELECT COUNT(*) c FROM cells").fetchone()["c"]
    if n == 0:
        added = build_manifest(conn, cfg)
        print(f"[coordinator] built manifest: {added} cells "
              f"({len(cfg.arms.split(','))} arms)")
    else:
        print(f"[coordinator] resuming existing manifest: {n} cells in {cfg.db}")
    return conn


# ----------------------------------------------------------------------------- queue ops
def reap_expired(now):
    """Re-queue cells whose worker died (lease lapsed). Recovery only -- never
    touches a cell whose worker is still heartbeating."""
    cur = DB.execute(
        "UPDATE cells SET status='PENDING', worker=NULL, lease_expiry=0 "
        "WHERE status='CLAIMED' AND lease_expiry < ?", (now,))
    if cur.rowcount:
        print(f"[coordinator] re-queued {cur.rowcount} cell(s) from dead leases")
    DB.commit()


def claim(worker, free_cores, kind, now):
    """kind='julia' serves the ODEPE arms (local_only=0); kind='matlab' serves
    the amigo2 arm (local_only=1, run only on local workers). Routing by runtime
    keeps a Julia engine from ever being handed a MATLAB cell."""
    lo = 1 if kind == "matlab" else 0
    with LOCK:
        reap_expired(now)
        # Highest-priority cell that fits: hard (more cores) first, then fewest
        # attempts (don't starve retries), then stable pk. Respect core budget.
        sql = ("SELECT * FROM cells WHERE status='PENDING' AND cores<=? AND local_only=? "
               "ORDER BY cores DESC, attempts ASC, pk ASC LIMIT 1")
        row = DB.execute(sql, (free_cores, lo)).fetchone()
        if row is None:
            return None
        DB.execute(
            "UPDATE cells SET status='CLAIMED', worker=?, lease_expiry=?, "
            "started=COALESCE(started,?), attempts=attempts+1 WHERE pk=?",
            (worker, now + CFG.lease_seconds, now, row["pk"]))
        DB.commit()
        return {"cell_pk": row["pk"], "arm": row["arm"], "run": row["run"],
                "software": row["software"], "index": row["idx"],
                "cell_id": row["cell_id"], "system": row["system"],
                "noise": row["noise"], "cores": row["cores"]}


def mark_done(cell_pk, status, secs, now):
    st = "DONE" if status == "ok" else "FAILED"
    with LOCK:
        DB.execute("UPDATE cells SET status=?, finished=?, secs=? WHERE pk=?",
                   (st, now, secs, cell_pk))
        DB.commit()


def heartbeat(worker, now):
    with LOCK:
        cur = DB.execute(
            "UPDATE cells SET lease_expiry=? WHERE worker=? AND status='CLAIMED'",
            (now + CFG.lease_seconds, worker))
        DB.commit()
        return cur.rowcount


def requeue(cell_id=None, cell_pk=None, arm=None):
    """Force a cell back to PENDING. By pk (exact one), or by cell_id optionally
    narrowed to a single arm (cell_id alone matches that cell across ALL arms)."""
    with LOCK:
        if cell_pk is not None:
            cur = DB.execute("UPDATE cells SET status='PENDING', worker=NULL, "
                             "lease_expiry=0 WHERE pk=?", (cell_pk,))
        elif arm:
            cur = DB.execute("UPDATE cells SET status='PENDING', worker=NULL, "
                             "lease_expiry=0 WHERE cell_id=? AND arm=?", (cell_id, arm))
        else:
            cur = DB.execute("UPDATE cells SET status='PENDING', worker=NULL, "
                             "lease_expiry=0 WHERE cell_id=?", (cell_id,))
        DB.commit()
        return cur.rowcount


def status(now):
    counts = {r["status"]: r["c"] for r in
              DB.execute("SELECT status, COUNT(*) c FROM cells GROUP BY status")}
    total = sum(counts.values())
    done = counts.get("DONE", 0) + counts.get("FAILED", 0)
    per_arm = [dict(r) for r in DB.execute(
        "SELECT arm, COUNT(*) total, "
        "SUM(status IN ('DONE','FAILED')) done, SUM(status='FAILED') failed "
        "FROM cells GROUP BY arm ORDER BY arm")]
    inflight = [{"cell_id": r["cell_id"], "arm": r["arm"], "worker": r["worker"],
                 "cores": r["cores"],
                 "elapsed_min": round((now - r["started"]) / 60, 1) if r["started"] else None}
                for r in DB.execute(
                    "SELECT * FROM cells WHERE status='CLAIMED' "
                    "ORDER BY started ASC LIMIT 40")]
    over5h = [c for c in inflight if c["elapsed_min"] and c["elapsed_min"] > 300]
    return {"total": total, "done": done, "remaining": total - done,
            "counts": counts, "per_arm": per_arm,
            "inflight_oldest": inflight[:15],
            "WATCHDOG_over_5h": over5h}


# ----------------------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def log_message(self, *a):  # quiet; we print our own lines
        pass

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        now = time.time()
        if u.path == "/claim":
            cell = claim(q.get("worker", ["?"])[0],
                         int(q.get("free_cores", ["0"])[0]),
                         q.get("kind", ["julia"])[0],
                         now)
            self._send(cell or {})
        elif u.path == "/status":
            self._send(status(now))
        elif u.path == "/health":
            self._send({"ok": True})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        b = self._body()
        now = time.time()
        if u.path == "/done":
            mark_done(int(b["cell_pk"]), b.get("status", "ok"),
                      b.get("secs"), now)
            self._send({"ok": True})
        elif u.path == "/heartbeat":
            n = heartbeat(b.get("worker", "?"), now)
            self._send({"ok": True, "renewed": n})
        elif u.path == "/requeue":
            n = requeue(b.get("cell_id"), b.get("cell_pk"), b.get("arm"))
            self._send({"ok": True, "requeued": n})
        else:
            self._send({"error": "not found"}, 404)


def main():
    global DB, CFG
    ap = argparse.ArgumentParser()
    ap.add_argument("--huge-json", required=True,
                    help="<bench>/huge_json.json -- enumerates the cells")
    ap.add_argument("--arms", required=True, help="comma list of software/arms")
    ap.add_argument("--hard-systems", required=True,
                    help="comma list of 8-core systems (from tiers_m1.json)")
    ap.add_argument("--local-only-arms", default="amigo2",
                    help="comma list of arms pinned to local workers (MATLAB)")
    ap.add_argument("--hard-cores", type=int, default=8)
    ap.add_argument("--easy-cores", type=int, default=2)
    ap.add_argument("--lease-seconds", type=float, default=180.0,
                    help="dead-worker re-queue timeout; heartbeat renews it")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--db", default="queue.db")
    ap.add_argument("--cells-csv", default="",
                    help="write the cell_id<->attributes map here at startup")
    CFG = ap.parse_args()
    DB = init_db(CFG)
    if CFG.cells_csv:
        export_cells_csv(DB, CFG.cells_csv)
    # request_queue_size default (5) is too small for ~50 workers bursting
    # claims+heartbeats; raise the listen backlog so connections aren't dropped.
    class Coord(ThreadingHTTPServer):
        request_queue_size = 256
        daemon_threads = True
    srv = Coord(("0.0.0.0", CFG.port), Handler)
    print(f"[coordinator] listening on :{CFG.port}  db={CFG.db}  "
          f"lease={CFG.lease_seconds}s")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[coordinator] shutting down")


if __name__ == "__main__":
    main()
