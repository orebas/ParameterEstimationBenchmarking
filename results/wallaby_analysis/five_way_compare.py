#!/usr/bin/env python3
"""Five-way compare: 06 (original) vs 12 (rejected) vs 13 (with patches) vs 14 (with fixA) vs wallaby (paper-clean).

Same metric as `numbat_analysis/three_way/four_way_compare.py`:
argmin-by-oracle over all rows of result.csv, excluding structurally
unidentifiable axes (sourced from each benchmark's odepe_metadata.json).

Outputs accuracy_five_way.csv + summary stats. The summary covers the
paper-relevant thresholds first (≤50%, ≤10%, ≤1%) and then includes
finer thresholds for diagnostics.
"""
import csv
import json
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
BENCH_06 = REPO / "benchmark_numbat_2026-05-06"
BENCH_12 = REPO / "benchmark_numbat_2026-05-12"
BENCH_13 = REPO / "benchmark_numbat_2026-05-13"
BENCH_14 = REPO / "benchmark_numbat_2026-05-14"
BENCH_WB = REPO / "benchmark_wallaby_2026-05-17"
OUT_DIR = REPO / "results/wallaby_analysis"

ESTIMATORS = ("odepe_v2_polish", "odepe_v2_nopolish")


def normalize_col(c: str) -> str:
    return c[:-3] if c.endswith("(t)") else c


def read_csv_dicts(path: Path):
    with open(path) as f:
        r = csv.DictReader(f)
        return list(r), r.fieldnames or []


def load_huge_json(bench: Path):
    j = json.load(open(bench / "huge_json.json"))
    return {c["id"]: c for c in j["instances"]}


def read_non_id_per_system(bench: Path) -> dict:
    out = {}
    for est in ESTIMATORS:
        rd = bench / "filetree" / f"{est}_run"
        if not rd.exists():
            continue
        for cell in rd.iterdir():
            md = cell / "odepe_metadata.json"
            if not md.exists():
                continue
            sn = cell.name.rsplit("_", 2)[0]
            if sn in out and out[sn]:
                continue
            try:
                d = json.load(open(md))
            except Exception:
                continue
            unid = d.get("best", {}).get("all_unidentifiable") or []
            new = {normalize_col(v) for v in unid}
            if sn not in out or (new and not out[sn]):
                out[sn] = new
    return out


def per_cell_oracle(result_csv: Path, truth_id_vars: dict):
    if not result_csv.exists():
        return None
    rows, fieldnames = read_csv_dicts(result_csv)
    if not rows:
        return None
    norm_fields = {normalize_col(c): c for c in fieldnames}

    def row_err(row):
        vals = []
        for v, tv in truth_id_vars.items():
            if v not in norm_fields:
                continue
            try:
                ev = float(row[norm_fields[v]])
            except (ValueError, TypeError, KeyError):
                continue
            # Skip NaN — float("NaN") > 0 is False so it'd silently degrade max_rel_err
            if ev != ev:
                continue
            if abs(tv) > 1e-15:
                vals.append(abs(ev - tv) / abs(tv))
            else:
                vals.append(abs(ev - tv))
        return max(vals) if vals else float("inf")

    errs = [row_err(r) for r in rows]
    best_i = min(range(len(errs)), key=lambda i: errs[i])
    return errs[best_i], len(rows)


def load_wall(p: Path):
    if not p.exists():
        return None
    try:
        return float(p.read_text().strip().split()[0])
    except Exception:
        return None


def main():
    # Use wallaby as the canonical truth source; the deterministic md5 seeds
    # mean all 5 benchmarks have bit-identical (params, IC, data) for each cell.
    instances = load_huge_json(BENCH_WB)
    non_id = {}
    for bench in (BENCH_WB, BENCH_14, BENCH_13, BENCH_12, BENCH_06):
        per_bench = read_non_id_per_system(bench)
        for sn, vs in per_bench.items():
            if sn not in non_id or (vs and not non_id[sn]):
                non_id[sn] = vs

    rows_out = []
    for est in ESTIMATORS:
        for cell_id, inst in sorted(instances.items()):
            sn = inst["name"]
            non_id_set = non_id.get(sn, set())
            truth_id = {}
            for v, val in (inst.get("state_values") or {}).items():
                if v not in non_id_set:
                    truth_id[v] = val
            for v, val in (inst.get("parameter_values") or {}).items():
                if v not in non_id_set:
                    truth_id[v] = val

            def stats_for(bench: Path):
                cd = bench / "filetree" / f"{est}_run" / cell_id
                o = per_cell_oracle(cd / "result.csv", truth_id)
                w = load_wall(cd / "wall_time_seconds.txt")
                return (o[0] if o else None, o[1] if o else None, w)

            o06, n06, w06 = stats_for(BENCH_06)
            o12, n12, w12 = stats_for(BENCH_12)
            o13, n13, w13 = stats_for(BENCH_13)
            o14, n14, w14 = stats_for(BENCH_14)
            owb, nwb, wwb = stats_for(BENCH_WB)

            rows_out.append({
                "system": sn, "run": est, "noise_label": cell_id.rsplit("_", 1)[1], "id": cell_id,
                "non_id_vars": ";".join(sorted(non_id_set)),
                "o06": o06, "n06": n06, "w06": w06,
                "o12": o12, "n12": n12, "w12": w12,
                "o13": o13, "n13": n13, "w13": w13,
                "o14": o14, "n14": n14, "w14": w14,
                "owb": owb, "nwb": nwb, "wwb": wwb,
                "status_wb": "ok" if owb is not None else "incomplete",
            })

    out_path = OUT_DIR / "accuracy_five_way.csv"
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows_out[0].keys()))
        w.writeheader()
        w.writerows(rows_out)
    print(f"wrote {out_path}")

    n_incomplete = sum(1 for r in rows_out if r["status_wb"] != "ok")
    print(f"  rows: {len(rows_out)} (incomplete in wallaby: {n_incomplete})")

    def median(xs):
        xs = sorted(x for x in xs if x is not None and x == x)
        if not xs:
            return None
        n = len(xs)
        return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])

    def succ_at(metrics, thr):
        finite = [m for m in metrics if m is not None and m == m]
        return sum(1 for m in finite if m < thr) / len(finite) * 100 if finite else None

    def total(xs):
        xs = [x for x in xs if x is not None]
        return sum(xs) / 3600 if xs else None

    print()
    print(f"=== Headline (across {len(rows_out)} rows: polish + nopolish) ===")
    print(f"{'metric':<25s} {'06':>10s} {'12':>10s} {'13':>10s} {'14':>10s} {'wallaby':>10s}")
    o06s = median([r['o06'] for r in rows_out])
    o12s = median([r['o12'] for r in rows_out])
    o13s = median([r['o13'] for r in rows_out])
    o14s = median([r['o14'] for r in rows_out])
    owbs = median([r['owb'] for r in rows_out])
    print(f"{'median oracle':<25s} {o06s:>10.2e} {o12s:>10.2e} {o13s:>10.2e} {o14s:>10.2e} {owbs:>10.2e}")

    print()
    print("Paper-relevant coarse thresholds:")
    for thr_lbl, thr in [("succ @ 1%", 0.01), ("succ @ 10%", 0.10), ("succ @ 50%", 0.50)]:
        s06 = succ_at([r['o06'] for r in rows_out], thr) or 0
        s12 = succ_at([r['o12'] for r in rows_out], thr) or 0
        s13 = succ_at([r['o13'] for r in rows_out], thr) or 0
        s14 = succ_at([r['o14'] for r in rows_out], thr) or 0
        swb = succ_at([r['owb'] for r in rows_out], thr) or 0
        print(f"{thr_lbl:<25s} {s06:>9.1f}% {s12:>9.1f}% {s13:>9.1f}% {s14:>9.1f}% {swb:>9.1f}%")

    print()
    print("Fine-threshold diagnostics:")
    for thr_lbl, thr in [("succ @ 0.1%", 0.001), ("succ @ 0.01%", 0.0001), ("succ @ 0.001%", 0.00001)]:
        s06 = succ_at([r['o06'] for r in rows_out], thr) or 0
        s12 = succ_at([r['o12'] for r in rows_out], thr) or 0
        s13 = succ_at([r['o13'] for r in rows_out], thr) or 0
        s14 = succ_at([r['o14'] for r in rows_out], thr) or 0
        swb = succ_at([r['owb'] for r in rows_out], thr) or 0
        print(f"{thr_lbl:<25s} {s06:>9.1f}% {s12:>9.1f}% {s13:>9.1f}% {s14:>9.1f}% {swb:>9.1f}%")

    print()
    print(f"{'total CPU-hr':<25s} {(total([r['w06'] for r in rows_out]) or 0):>10.0f} {(total([r['w12'] for r in rows_out]) or 0):>10.0f} {(total([r['w13'] for r in rows_out]) or 0):>10.0f} {(total([r['w14'] for r in rows_out]) or 0):>10.0f} {(total([r['wwb'] for r in rows_out]) or 0):>10.0f}")

    n_med = median([r['nwb'] for r in rows_out if r['nwb']]) or 0
    print(f"\nwallaby median n_rows in result.csv: {n_med}")

    # Recovery vs 06 baseline at multiplicative thresholds
    print()
    print("=== Recovery vs 06 baseline ===")
    print(f"{'threshold':<18s} {'12':>14s} {'13':>14s} {'14':>14s} {'wallaby':>14s}")
    n_with_06 = sum(1 for r in rows_out if r['o06'] is not None)
    for thr_label, mult in [("within 2×", 2), ("within 3×", 3), ("within 5×", 5), ("within 10×", 10), ("within 20×", 20)]:
        def closeness(col):
            return sum(1 for r in rows_out if r[col] and r['o06'] and r[col] < mult * max(r['o06'], 1e-10))
        n12 = closeness('o12')
        n13 = closeness('o13')
        n14 = closeness('o14')
        nwb = closeness('owb')
        print(f"  {thr_label:<16s} {n12}/{n_with_06}={n12*100/n_with_06:>4.0f}% {n13}/{n_with_06}={n13*100/n_with_06:>4.0f}% {n14}/{n_with_06}={n14*100/n_with_06:>4.0f}% {nwb}/{n_with_06}={nwb*100/n_with_06:>4.0f}%")

    # By noise breakdown for the headline thresholds
    print()
    print(f"=== Success @ 50% by noise (paper headline) ===")
    by_noise = defaultdict(list)
    for r in rows_out:
        by_noise[r['noise_label']].append(r)
    print(f"{'noise':>6s}  {'06':>7s} {'12':>7s} {'13':>7s} {'14':>7s} {'wallaby':>9s}")
    for nz in sorted(by_noise.keys()):
        bucket = by_noise[nz]
        s06 = succ_at([r['o06'] for r in bucket], 0.5) or 0
        s12 = succ_at([r['o12'] for r in bucket], 0.5) or 0
        s13 = succ_at([r['o13'] for r in bucket], 0.5) or 0
        s14 = succ_at([r['o14'] for r in bucket], 0.5) or 0
        swb = succ_at([r['owb'] for r in bucket], 0.5) or 0
        print(f"  {nz:>6s}  {s06:>5.1f}% {s12:>5.1f}% {s13:>5.1f}% {s14:>5.1f}% {swb:>7.1f}%")

    print()
    print(f"=== Success @ 10% by noise ===")
    print(f"{'noise':>6s}  {'06':>7s} {'12':>7s} {'13':>7s} {'14':>7s} {'wallaby':>9s}")
    for nz in sorted(by_noise.keys()):
        bucket = by_noise[nz]
        s06 = succ_at([r['o06'] for r in bucket], 0.10) or 0
        s12 = succ_at([r['o12'] for r in bucket], 0.10) or 0
        s13 = succ_at([r['o13'] for r in bucket], 0.10) or 0
        s14 = succ_at([r['o14'] for r in bucket], 0.10) or 0
        swb = succ_at([r['owb'] for r in bucket], 0.10) or 0
        print(f"  {nz:>6s}  {s06:>5.1f}% {s12:>5.1f}% {s13:>5.1f}% {s14:>5.1f}% {swb:>7.1f}%")

    print()
    print(f"=== Success @ 1% by noise ===")
    print(f"{'noise':>6s}  {'06':>7s} {'12':>7s} {'13':>7s} {'14':>7s} {'wallaby':>9s}")
    for nz in sorted(by_noise.keys()):
        bucket = by_noise[nz]
        s06 = succ_at([r['o06'] for r in bucket], 0.01) or 0
        s12 = succ_at([r['o12'] for r in bucket], 0.01) or 0
        s13 = succ_at([r['o13'] for r in bucket], 0.01) or 0
        s14 = succ_at([r['o14'] for r in bucket], 0.01) or 0
        swb = succ_at([r['owb'] for r in bucket], 0.01) or 0
        print(f"  {nz:>6s}  {s06:>5.1f}% {s12:>5.1f}% {s13:>5.1f}% {s14:>5.1f}% {swb:>7.1f}%")

    # Per-estimator (polish vs nopolish) breakdown at paper thresholds
    print()
    print("=== Per-estimator @ 10% (paper threshold) ===")
    for est in ESTIMATORS:
        bucket = [r for r in rows_out if r["run"] == est]
        s06 = succ_at([r['o06'] for r in bucket], 0.10) or 0
        s14 = succ_at([r['o14'] for r in bucket], 0.10) or 0
        swb = succ_at([r['owb'] for r in bucket], 0.10) or 0
        print(f"  {est:<22s} 06={s06:>5.1f}%  14={s14:>5.1f}%  wallaby={swb:>5.1f}%  (delta wallaby-14={swb-s14:+.1f}pp)")


if __name__ == "__main__":
    main()
