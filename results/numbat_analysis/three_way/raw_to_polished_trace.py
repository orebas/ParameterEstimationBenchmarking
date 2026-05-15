#!/usr/bin/env python3
"""For each unrecovered cell, trace the best-by-oracle raw HC candidate through
the pipeline. Did it get polished? If not, why?

raw_candidates.csv has hc_idx column. polished_dump.csv has polish_source_hc_idx
column. So we can link each polished output back to its source raw.

For each unrecovered cell:
1. Compute oracle for every raw HC candidate
2. Identify the raw with the BEST (closest-to-truth) oracle
3. Was its hc_idx in the polish_source_hc_idx column of polished_dump.csv?
   YES: → polish converged to a non-truth basin (basin issue; column scaling)
   NO:  → dropped by err filter or pre-polish clustering
4. If NO: check err vs cutoff (100×min_err) to distinguish err filter vs clustering
"""
import csv, json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH_13 = REPO / "benchmark_numbat_2026-05-13"
PROBES = BENCH_13 / "probes"
SIM = REPO / "results/numbat_analysis/three_way/offline_fix_sim.csv"
ACCURACY = REPO / "results/numbat_analysis/three_way/accuracy_three_way.csv"
OUT = REPO / "results/numbat_analysis/three_way/raw_to_polished_trace.csv"

def normalize_col(c: str) -> str:
    if c.startswith("s::"): c = c[3:]
    if c.startswith("p::"): c = c[3:]
    return c[:-3] if c.endswith("(t)") else c

def load_truth():
    hj = json.load(open(BENCH_13 / "huge_json.json"))
    inst_by_id = {c["id"]: c for c in hj["instances"]}
    non_id_by_sys = {}
    for r in csv.DictReader(open(ACCURACY)):
        sn = r["system"]
        if sn in non_id_by_sys: continue
        non_id_by_sys[sn] = set(v for v in (r["non_id_vars"] or "").split(";") if v)
    truth = {}
    for cid, inst in inst_by_id.items():
        non_id = non_id_by_sys.get(inst["name"], set())
        d = {v: val for v, val in (inst.get("state_values") or {}).items() if v not in non_id}
        d.update({v: val for v, val in (inst.get("parameter_values") or {}).items() if v not in non_id})
        truth[cid] = d
    return truth

def row_oracle(row, truth, col_norm):
    vals = []
    for v, tv in truth.items():
        if v not in col_norm: continue
        try: ev = float(row[col_norm[v]])
        except: continue
        vals.append(abs(ev - tv) / abs(tv) if abs(tv) > 1e-15 else abs(ev - tv))
    return max(vals) if vals else float("inf")

def main():
    truth_by_id = load_truth()
    sim_rows = list(csv.DictReader(open(SIM)))

    unrec = []
    for r in sim_rows:
        try:
            o06 = float(r["o06"]) if r["o06"] else None
            fixA = float(r["fixA_K100"])
            if o06 and fixA > 2 * max(o06, 1e-10):
                unrec.append(r)
        except: pass

    out_rows = []
    for sim in unrec:
        cell = sim["cell"]; run = sim["run"]
        probe = PROBES / f"{run}__{cell}" / "dump"
        raw_csv = probe / "raw_candidates.csv"
        pol_csv = probe / "polished_dump.csv"
        if not raw_csv.exists() or not pol_csv.exists(): continue
        truth = truth_by_id.get(cell, {})
        if not truth: continue

        # raw
        with open(raw_csv) as f:
            raw_fns = csv.DictReader(f).fieldnames
        with open(raw_csv) as f:
            raws = list(csv.DictReader(f))
        # polished
        with open(pol_csv) as f:
            pol_fns = csv.DictReader(f).fieldnames
        with open(pol_csv) as f:
            pols = list(csv.DictReader(f))

        col_raw = {normalize_col(c): c for c in raw_fns}
        col_pol = {normalize_col(c): c for c in pol_fns}

        def err_of(r):
            try: return float(r.get("err") or "inf")
            except: return float("inf")

        # Compute oracle for each raw
        raw_oracles = [row_oracle(r, truth, col_raw) for r in raws]
        # Sort raws by oracle ascending, pick best 5
        raw_idx_by_oracle = sorted(range(len(raws)), key=lambda i: raw_oracles[i])
        best_raw_idxs = raw_idx_by_oracle[:5]

        # Pre-polish err filter cutoff
        raw_errs = [err_of(r) for r in raws]
        finite_errs = [e for e in raw_errs if e < 1e10]
        min_err = min(finite_errs) if finite_errs else float("inf")

        # Was each best raw polished? polished_dump's polish_source_hc_idx column references
        # the original `hc_idx` column from raw_candidates.csv
        polished_hc_idxs = set()
        for p in pols:
            try: polished_hc_idxs.add(int(p.get("polish_source_hc_idx", "-1")))
            except: pass

        # Also: did the polish produce a truth-near output? Best polished oracle (full list)
        pol_oracles = [row_oracle(p, truth, col_pol) for p in pols]
        best_pol_oracle = min(pol_oracles) if pol_oracles else float("inf")

        # For best raw idx, look at hc_idx column value
        def get_hc_idx(raw_row):
            try: return int(raw_row.get("hc_idx", "-1"))
            except: return -1

        o06 = float(sim["o06"])
        # Diagnose for top-5 raws
        for rank, idx in enumerate(best_raw_idxs):
            raw = raws[idx]
            hc_idx = get_hc_idx(raw)
            raw_o = raw_oracles[idx]
            raw_err = raw_errs[idx]
            was_polished = hc_idx in polished_hc_idxs
            err_ratio = raw_err / min_err if min_err > 0 else float("inf")
            passes_err_filter = err_ratio <= 100

            # If polished, find its polish output oracle
            polish_out_oracle = None
            if was_polished:
                for p in pols:
                    try: psh = int(p.get("polish_source_hc_idx", "-1"))
                    except: psh = -1
                    if psh == hc_idx:
                        po = row_oracle(p, truth, col_pol)
                        if polish_out_oracle is None or po < polish_out_oracle:
                            polish_out_oracle = po

            if was_polished:
                if polish_out_oracle is not None and polish_out_oracle < 2 * max(o06, 1e-10):
                    diag = "POLISHED_RECOVERED"
                else:
                    diag = "POLISHED_BUT_WRONG_BASIN"
            else:
                if not passes_err_filter:
                    diag = "DROPPED_BY_ERR_FILTER"
                else:
                    diag = "DROPPED_BY_PRE_POLISH_CLUSTERING"

            out_rows.append({
                "cell": cell, "run": run, "system": sim["system"], "noise": sim["noise"],
                "raw_rank": rank+1,
                "hc_idx": hc_idx,
                "raw_oracle": raw_o,
                "raw_err": raw_err,
                "err_ratio_vs_min": err_ratio,
                "was_polished": was_polished,
                "polish_out_oracle": polish_out_oracle,
                "best_pol_oracle_anywhere": best_pol_oracle,
                "o06": o06,
                "diagnosis": diag,
            })

    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out_rows[0].keys()))
        w.writeheader()
        w.writerows(out_rows)
    print(f"wrote {OUT}  ({len(out_rows)} rows for {len(out_rows)//5} cells)")

    # Per-cell summary: take rank-1 best raw, see its diagnosis
    from collections import Counter, defaultdict
    by_cell = defaultdict(list)
    for r in out_rows:
        by_cell[(r["cell"], r["run"])].append(r)

    diag_top1 = Counter()
    diag_best_of_5 = Counter()
    for cell_run, rows in by_cell.items():
        rows.sort(key=lambda r: r["raw_rank"])
        diag_top1[rows[0]["diagnosis"]] += 1
        # Best-of-5: which diagnosis applies to the BEST raw that wasn't dropped?
        # (i.e., if rank-1 is dropped, look at rank-2, etc.)
        for r in rows:
            if r["was_polished"]:
                diag_best_of_5["BEST5_HAS_POLISHED:" + r["diagnosis"]] += 1
                break
        else:
            diag_best_of_5["BEST5_ALL_DROPPED:" + rows[0]["diagnosis"]] += 1

    print()
    print("=== Diagnosis for rank-1 (best-by-oracle) raw HC of each unrecovered cell ===")
    for d, n in diag_top1.most_common():
        print(f"  {d}: {n}")

    print()
    print("=== Best-of-top-5 raws — did at least one get polished? Top-1 diag if all dropped ===")
    for d, n in diag_best_of_5.most_common():
        print(f"  {d}: {n}")

    # NEW key question: how many cells would be recovered if we polished EVERY raw HC?
    # Approximation: for cells where rank-1 raw was "DROPPED_*", what's the rank-1's polish potential?
    # We can't know that without re-running. But we CAN check: across the entire raws list, is there
    # ANY raw that (after polishing) might be truth-near?
    # → that's exactly what fixA_K100 is, and we already know fixA misses these 23 cells.

    # So the question becomes: do the top-5 best raws ALL get dropped? If yes, polishing them would help.
    n_all_dropped = sum(1 for d, n in diag_best_of_5.items() if d.startswith("BEST5_ALL_DROPPED")
                       for _ in range(n))
    n_have_polished = sum(n for d, n in diag_best_of_5.items() if d.startswith("BEST5_HAS_POLISHED"))
    print()
    print(f"Cells where at least one of top-5 best raws got polished but polish landed in wrong basin:")
    print(f"  {n_have_polished}")
    print(f"Cells where NONE of top-5 best raws got polished (err filter + clustering dropped them all):")
    print(f"  {n_all_dropped}")

if __name__ == "__main__":
    main()
