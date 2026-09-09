#!/usr/bin/env python3
"""
Merge a fleet run's per-box results + build a recovery/timing summary.

fleet.py rsyncs each shard's filetree to results/<run-id>/<label>/benchmark_*/.
PEB's collect leaves result.csv's `result`/`has_result` columns empty (it doesn't
re-extract the estimate), so the trustworthy recovery signal is each cell's
odepe_metadata.json `besterror` (the same metric the quoll analysis used). This
concatenates result.csv for provenance AND writes recovery.csv from the metadata.

Usage:
  ./collect.py --run-id main-2026-06-05
"""
import argparse, csv, json
from pathlib import Path
from collections import defaultdict

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--recover-threshold", type=float, default=1e-3)
    a = ap.parse_args()
    base = RESULTS / a.run_id

    # 1. merge per-box result.csv (provenance; map id->system name).
    csvs = sorted(base.glob("*/benchmark_*/result.csv"))
    header, rows = None, []
    for f in csvs:
        r = list(csv.reader(open(f)))
        if not r:
            continue
        if header is None:
            header = r[0]
        rows.extend(r[1:])
    id2name = {}
    if header:
        cols = {c.lower(): i for i, c in enumerate(header)}
        out = base / "result_merged.csv"
        with open(out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(header)
            w.writerows(rows)
        print(f"merged {len(csvs)} per-box result.csv -> {out}  ({len(rows)} rows)")
        if "id" in cols and "name" in cols:
            for row in rows:
                try:
                    id2name[row[cols["id"]]] = row[cols["name"]]
                except IndexError:
                    pass

    # 2. recovery from per-cell odepe_metadata.json (besterror = recovery quality).
    rec = []  # (cell_id, system, besterror, status)
    for mf in base.glob("*/benchmark_*/filetree/*/*/odepe_metadata.json"):
        cell_id = mf.parent.name
        try:
            m = json.loads(mf.read_text())
        except Exception:
            continue
        system = id2name.get(cell_id) or cell_id.rsplit("_", 2)[0]
        rec.append((cell_id, system, m.get("besterror"), m.get("status", "?")))
    if not rec:
        print("(no odepe_metadata.json yet — nothing to summarize)")
    else:
        recf = base / "recovery.csv"
        with open(recf, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["cell_id", "system", "besterror", "status"])
            w.writerows(rec)
        best = defaultdict(lambda: float("inf"))
        for _, system, be, _st in rec:
            try:
                best[system] = min(best[system], float(be))
            except (TypeError, ValueError):
                pass
        nrec = sum(1 for e in best.values() if e < a.recover_threshold)
        print(f"\n=== recovery: best error per system "
              f"({nrec}/{len(best)} < {a.recover_threshold:g}), {len(rec)} cells ===")
        for system in sorted(best):
            e = best[system]
            print(f"  {'OK ' if e < a.recover_threshold else '***'} {system:44s} {e:.3e}")
        print(f"  -> {recf}")

    # 3. timing / cost from fleet's _summary.json.
    summ = base / "_summary.json"
    if summ.exists():
        s = json.loads(summ.read_text())
        if s:
            slow = max(s, key=lambda r: r.get("minutes", 0))
            cost = sum(r.get("minutes", 0) / 60 *
                       {"ccx33": 0.1186, "ccx43": 0.2372}.get(r.get("box_type"), 0) for r in s)
            print(f"\n=== timing / cost ===\n  shards={len(s)}  "
                  f"box-min={sum(r.get('minutes', 0) for r in s):.0f}  ~${cost:.2f}\n"
                  f"  critical path (slowest shard) = {slow.get('minutes', 0):.0f}min "
                  f"({slow.get('label')})")


if __name__ == "__main__":
    main()
