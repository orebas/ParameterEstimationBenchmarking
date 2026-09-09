#!/usr/bin/env python3
"""T1/T2 assertion: a single benchmark cell ran correctly. Exit 0 = pass, 1 = fail.

Usage: assert_cell.py <cell_dir> [--besterror-max 1e-3] [--require-besterror]

Checks the cell's output files (per collect_results.py's contract):
  result.csv (>=2 rows), stdout.txt ends ===END===, wall_time_seconds.txt parses,
  and for ODEPE arms odepe_metadata.json status==ok + besterror under threshold.
"""
import sys, os, json, csv, argparse

ap = argparse.ArgumentParser()
ap.add_argument("cell_dir")
ap.add_argument("--besterror-max", type=float, default=1e-3)
ap.add_argument("--require-besterror", action="store_true",
                help="fail if odepe_metadata.json / besterror is absent (ODEPE arms)")
a = ap.parse_args()

d = a.cell_dir
fails = []

rc = os.path.join(d, "result.csv")
if not os.path.exists(rc):
    fails.append("no result.csv")
else:
    with open(rc) as f:
        rows = [r for r in csv.reader(f) if r]
    if len(rows) < 2:
        fails.append(f"result.csv has {len(rows)} row(s) (<2)")

so = os.path.join(d, "stdout.txt")
if not os.path.exists(so):
    fails.append("no stdout.txt")
elif "===END===" not in open(so, errors="replace").read()[-400:]:
    fails.append("stdout.txt missing ===END=== sentinel")

wt = os.path.join(d, "wall_time_seconds.txt")
if os.path.exists(wt):
    try:
        float(open(wt).read().split()[0])
    except Exception as e:
        fails.append(f"wall_time unparseable: {e}")

be = None
md = os.path.join(d, "odepe_metadata.json")
if os.path.exists(md):
    m = json.load(open(md))
    if m.get("status") != "ok":
        fails.append(f"status={m.get('status')!r} (!=ok)")
    be = m.get("besterror")
    if be is not None and be > a.besterror_max:
        fails.append(f"besterror {be:.3e} > {a.besterror_max:.0e}")
    elif be is None and a.require_besterror:
        fails.append("besterror missing from odepe_metadata.json")
elif a.require_besterror:
    fails.append("no odepe_metadata.json")

if fails:
    print(f"FAIL {d}:")
    for x in fails:
        print("  -", x)
    sys.exit(1)
print(f"PASS {d}  (besterror={be})")
