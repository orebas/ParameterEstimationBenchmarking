#!/usr/bin/env python3
"""
Merge a fleet run's per-box results into one result.csv + a recovery/timing summary.
fleet.py rsyncs each shard's filetree to results/<run-id>/<label>/benchmark_*/; this
concatenates their result.csv (deterministic cell_seed -> disjoint, mergeable rows) and
reads fleet's _summary.json for the slowest-shard critical path (the min-wall headline).

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
    csvs = sorted(base.glob("*/benchmark_*/result.csv"))
    if not csvs:
        print(f"no result.csv under {base}/*/benchmark_*/ — nothing collected yet.")
        return

    header, rows = None, []
    for f in csvs:
        r = list(csv.reader(open(f)))
        if not r:
            continue
        if header is None:
            header = r[0]
        rows.extend(r[1:])
    out = base / "result_merged.csv"
    with open(out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(rows)
    print(f"merged {len(csvs)} per-box result.csv -> {out}  ({len(rows)} data rows)")

    # best-effort recovery summary (schema-agnostic: find name + error columns)
    cols = {c.lower(): i for i, c in enumerate(header)}
    name_i = next((cols[k] for k in ("name", "system", "model") if k in cols), None)
    err_i = next((cols[k] for k in ("besterror", "best_error", "error", "err") if k in cols), None)
    if name_i is not None and err_i is not None:
        best = defaultdict(lambda: float("inf"))
        for row in rows:
            try:
                best[row[name_i]] = min(best[row[name_i]], float(row[err_i]))
            except (ValueError, IndexError):
                pass
        nrec = sum(1 for e in best.values() if e < a.recover_threshold)
        print(f"\n=== best error per system ({nrec}/{len(best)} recovered "
              f"< {a.recover_threshold:g}) ===")
        for name in sorted(best):
            e = best[name]
            print(f"  {'OK ' if e < a.recover_threshold else '***'} {name:44s} {e:.3e}")
    else:
        print("(could not auto-detect name/error columns; merged CSV is still complete)")

    summ = base / "_summary.json"
    if summ.exists():
        s = json.loads(summ.read_text())
        if s:
            slow = max(s, key=lambda r: r.get("minutes", 0))
            cost = sum(r.get("minutes", 0) / 60 *
                       {"ccx33": 0.1186, "ccx43": 0.2372}.get(r.get("box_type"), 0) for r in s)
            print(f"\n=== timing / cost ===\n  shards={len(s)}  total box-min={sum(r.get('minutes',0) for r in s):.0f}"
                  f"  ~${cost:.2f}\n  critical path (slowest shard) = {slow.get('minutes',0):.0f}min "
                  f"({slow.get('label')})")


if __name__ == "__main__":
    main()
