#!/usr/bin/env python3
"""Compute max-K-needed for oracle-best, split by (system, noise) and polish/nopolish.

Output: max_k_polish.csv, max_k_nopolish.csv with rows=systems, columns=noise.
Also writes a markdown summary at max_k_tables.md.
"""
import csv
import json
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH = REPO / "benchmark_numbat_2026-05-14"
OUT_DIR = REPO / "results/numbat_analysis/three_way"


def normalize(c: str) -> str:
    return c[:-3] if c.endswith("(t)") else c


def main():
    hj = json.load(open(BENCH / "huge_json.json"))
    inst_by_id = {c['id']: c for c in hj['instances']}

    nonid = {}
    for r in csv.DictReader(open(OUT_DIR / "accuracy_four_way.csv")):
        sn = r['system']
        if sn in nonid:
            continue
        nonid[sn] = set(v for v in (r['non_id_vars'] or '').split(';') if v)

    results = []
    for est in ('odepe_v2_polish', 'odepe_v2_nopolish'):
        run_dir = BENCH / "filetree" / f"{est}_run"
        if not run_dir.exists(): continue
        for cell_dir in run_dir.iterdir():
            cell_id = cell_dir.name
            res = cell_dir / "result.csv"
            if not res.exists(): continue
            if cell_id not in inst_by_id: continue
            inst = inst_by_id[cell_id]
            sn = inst['name']
            non_id = nonid.get(sn, set())
            truth = {**{v: val for v, val in (inst.get('state_values') or {}).items() if v not in non_id},
                     **{v: val for v, val in (inst.get('parameter_values') or {}).items() if v not in non_id}}
            with open(res) as f:
                r = csv.DictReader(f); fns = r.fieldnames; rows = list(r)
            if not rows: continue
            col_norm = {normalize(c): c for c in fns}

            def err_of(rr):
                try: return float(rr.get('err') or 'inf')
                except: return float('inf')

            rows_sorted = sorted(rows, key=err_of)

            def row_oracle(rr):
                vals = []
                for v, tv in truth.items():
                    if v not in col_norm: continue
                    try: ev = float(rr[col_norm[v]])
                    except: continue
                    vals.append(abs(ev - tv) / abs(tv) if abs(tv) > 1e-15 else abs(ev - tv))
                return max(vals) if vals else float('inf')

            oracles = [row_oracle(rr) for rr in rows_sorted]
            best_idx = oracles.index(min(oracles))
            results.append({
                'cell': cell_id, 'est': est, 'system': sn,
                'noise': cell_id.rsplit('_', 1)[1],
                'n_rows': len(rows), 'oracle_best_rank': best_idx + 1,
                'oracle_best': min(oracles),
            })

    # Write the flat per-cell csv
    flat_path = OUT_DIR / "oracle_best_rank_per_cell.csv"
    with open(flat_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(results[0].keys()))
        w.writeheader()
        w.writerows(results)
    print(f"wrote {flat_path}  ({len(results)} cells)")

    # Pivot tables
    noises = ['0', '1em8', '1em6', '1em4', '1em2']
    systems = sorted(set(r['system'] for r in results))

    for est_key, fname in [('odepe_v2_polish', 'max_k_polish.csv'),
                           ('odepe_v2_nopolish', 'max_k_nopolish.csv')]:
        out = OUT_DIR / fname
        with open(out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(['system'] + noises)
            for sn in systems:
                row = [sn]
                for nz in noises:
                    ranks = [r['oracle_best_rank'] for r in results if r['system'] == sn and r['est'] == est_key and r['noise'] == nz]
                    row.append(max(ranks) if ranks else '')
                w.writerow(row)
        print(f"wrote {out}")

    # Markdown
    md_lines = ["# Max K needed for oracle-best, by system × noise\n\n"]
    md_lines.append("For each cell in benchmark_numbat_2026-05-14, we sort result.csv rows by err ascending\n")
    md_lines.append("and find the rank (1-based) of the row that minimizes max-rel-err vs truth\n")
    md_lines.append("(excluding structurally unidentifiable axes). Each cell value below is the MAX\n")
    md_lines.append("such rank across the 10 instances in that (system, noise) bucket.\n\n")

    for est_label, est_key in [("## POLISH", 'odepe_v2_polish'),
                                ("## NOPOLISH", 'odepe_v2_nopolish')]:
        md_lines.append(f"{est_label}\n\n")
        md_lines.append("| system | " + " | ".join(noises) + " |\n")
        md_lines.append("|---|" + "|".join(["---:"] * len(noises)) + "|\n")
        for sn in systems:
            cells = [r['oracle_best_rank'] for r in results if r['system'] == sn and r['est'] == est_key]
            row = [sn]
            for nz in noises:
                ranks = [r['oracle_best_rank'] for r in results if r['system'] == sn and r['est'] == est_key and r['noise'] == nz]
                if not ranks:
                    row.append('—')
                else:
                    m = max(ranks)
                    row.append(f"**{m}**" if m >= 50 else str(m))
            md_lines.append("| " + " | ".join(row) + " |\n")
        md_lines.append("\n")

    md_lines.append("\n## How to read this\n\n")
    md_lines.append("- **K=1** means the err-sorted top-1 row is the truth-best (polish converged tightly).\n")
    md_lines.append("- **K=20** means the truth-near row is somewhere in the top-20; was the K cap in benchmark 13 (caused regressions).\n")
    md_lines.append("- **K=100** is the current cap in benchmark 14. Buckets with max_K=100 are at the cap (may have lost truth-near).\n")
    md_lines.append("- **K=200+** (we can't see past 100 since that's the cap): if the cap were higher we'd see this.\n\n")
    md_lines.append("Pattern: K grows with noise. Polish dramatically reduces K (gradient-descent collapses the residual ridge to a single point).\n")
    md_lines.append("Nopolish at low noise still needs large K because the data residual is near-flat in degenerate parameter subspaces.\n")

    md_path = OUT_DIR / "max_k_tables.md"
    md_path.write_text("".join(md_lines))
    print(f"wrote {md_path}")


if __name__ == "__main__":
    main()
