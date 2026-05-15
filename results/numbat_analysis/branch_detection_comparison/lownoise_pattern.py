#!/usr/bin/env python3
"""Investigation D Phase A: classify low-noise regression cells.

For each cell that regressed at noise=0 or noise=1em8 (where data is essentially
noise-free and accuracy SHOULD be machine-eps), look inside result.csv:
  - How many rows did branch detection return?
  - What's the oracle err per row?
  - Was the truth-near candidate in the list but at a non-row-0 position
    (= clustering picked a less-truthy cluster representative)?
  - Or was the truth-near candidate absent from the list entirely
    (= solver/HC failed to find it, or pre-polish filter dropped it)?

Inputs:
  accuracy_per_cell.csv  (for the cell list)
  benchmark_numbat_2026-05-12/huge_json.json  (ground truth)
  benchmark_numbat_2026-05-12/filetree/<run>/<cell>/result.csv  (per-cell)
  benchmark_numbat_2026-05-12/filetree/<run>/<cell>/odepe_metadata.json  (raw_count etc.)

Outputs:
  lownoise_pattern.csv
  lownoise_pattern.md
"""
import csv
import json
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent
HERE = Path(__file__).resolve().parent
BENCH = REPO / "benchmark_numbat_2026-05-12"
PER_CELL = HERE / "accuracy_per_cell.csv"
HUGE_JSON = BENCH / "huge_json.json"
OUT_CSV = HERE / "lownoise_pattern.csv"
OUT_MD = HERE / "lownoise_pattern.md"

# Classification thresholds
TRUTH_NEAR = 0.01   # row with oracle err < 1% is "truth-near"
TRUTH_FAR = 0.1     # row with oracle err >= 10% is "truth-far"


def to_float(s):
    try:
        return float(s) if s not in ("", None) else None
    except (TypeError, ValueError):
        return None


def normalize_col(c):
    return c[:-3] if c.endswith("(t)") else c


def read_non_id(bench):
    out = {}
    for est in ("odepe_v2_polish", "odepe_v2_nopolish"):
        rd = bench / "filetree" / f"{est}_run"
        if not rd.exists():
            continue
        for cell in rd.iterdir():
            md = cell / "odepe_metadata.json"
            if not md.exists():
                continue
            sn = cell.name.rsplit("_", 2)[0]
            if sn in out:
                continue
            try:
                d = json.load(open(md))
            except Exception:
                continue
            unid = d.get("best", {}).get("all_unidentifiable") or []
            out[sn] = {normalize_col(v) for v in unid}
    return out


def per_row_oracle(result_csv, truth_id_vars):
    """Compute max_rel_err for each row of result.csv. Returns list (sorted by file order)."""
    with open(result_csv) as f:
        r = csv.DictReader(f)
        rows = list(r)
        fields = r.fieldnames or []
    norm_fields = {normalize_col(c): c for c in fields}
    errs = []
    branch_sizes = []
    for row in rows:
        vals = []
        for var, tv in truth_id_vars.items():
            if var not in norm_fields:
                continue
            try:
                ev = float(row[norm_fields[var]])
            except (ValueError, TypeError, KeyError):
                continue
            if abs(tv) > 1e-15:
                vals.append(abs(ev - tv) / abs(tv))
            else:
                vals.append(abs(ev - tv))
        errs.append(max(vals) if vals else float("inf"))
        try:
            branch_sizes.append(int(float(row.get("branch_size", "1"))))
        except (ValueError, TypeError):
            branch_sizes.append(None)
    return errs, branch_sizes, len(rows)


def main():
    # Load comparable cells, filter to regressions at low noise.
    with open(PER_CELL) as f:
        rows = list(csv.DictReader(f))

    instances = {c["id"]: c for c in json.load(open(HUGE_JSON))["instances"]}
    non_id = read_non_id(BENCH)

    # Low-noise regression cells: noise label in {0, 1em8}, new much worse than old, and old was OK
    targets = []
    for r in rows:
        if r.get("status_new") != "ok":
            continue
        if r["noise_label"] not in ("0", "1em8"):
            continue
        new_oracle = to_float(r.get("new_oracle_max"))
        old_oracle = to_float(r.get("old_oracle_max"))
        if new_oracle is None or old_oracle is None:
            continue
        if old_oracle > 0.1:  # old was already bad; skip
            continue
        if new_oracle <= old_oracle * 10:  # not a regression
            continue
        if new_oracle < 0.01:  # new is still ok-ish
            continue
        targets.append(r)

    print(f"Found {len(targets)} low-noise regression cells")

    out_rows = []
    classification_counter = Counter()
    for r in targets:
        cell_id = r["id"]
        est = r["run"]
        inst = instances[cell_id]
        sys_name = inst["name"]
        non_id_set = non_id.get(sys_name, set())

        truth_id_vars = {}
        for v, val in (inst.get("state_values") or {}).items():
            if v not in non_id_set:
                truth_id_vars[v] = val
        for v, val in (inst.get("parameter_values") or {}).items():
            if v not in non_id_set:
                truth_id_vars[v] = val

        cell_dir = BENCH / "filetree" / f"{est}_run" / cell_id
        result_csv = cell_dir / "result.csv"
        if not result_csv.exists():
            continue
        errs, branch_sizes, n_rows = per_row_oracle(result_csv, truth_id_vars)

        # Metadata
        md_path = cell_dir / "odepe_metadata.json"
        raw_count = best_count = None
        all_unid = []
        if md_path.exists():
            try:
                m = json.load(open(md_path))
                raw_count = m.get("raw_count")
                best_count = m.get("best_count")
                all_unid = m.get("best", {}).get("all_unidentifiable") or []
            except Exception:
                pass

        # Classify
        min_err = min(errs) if errs else float("inf")
        min_err_idx = errs.index(min_err) if errs else None
        row0_err = errs[0] if errs else float("inf")

        any_truth_near = any(e < TRUTH_NEAR for e in errs)
        any_truth_intermediate = any(TRUTH_NEAR <= e < TRUTH_FAR for e in errs)

        if any_truth_near and min_err_idx != 0:
            classification = "truth_near_in_list_but_not_row0"   # clustering picked wrong rep
        elif any_truth_near and min_err_idx == 0:
            classification = "truth_near_at_row0_but_audit_classifies_regression"  # shouldn't happen
        elif any_truth_intermediate:
            classification = "intermediate_only_truth_near_absent"
        else:
            classification = "no_truth_near_candidate_in_list"  # solver/HC issue

        classification_counter[classification] += 1

        out_rows.append({
            "id": cell_id,
            "run": est,
            "system": sys_name,
            "noise_label": r["noise_label"],
            "new_oracle_best": min_err,
            "new_oracle_row0": row0_err,
            "old_oracle_best": to_float(r["old_oracle_max"]),
            "n_rows": n_rows,
            "raw_count": raw_count,
            "best_count": best_count,
            "min_err_row_idx": min_err_idx,
            "any_truth_near": int(any_truth_near),
            "classification": classification,
            "all_errs": ";".join(f"{e:.3e}" for e in errs[:20]),  # first 20 rows
            "branch_sizes": ";".join(str(b) for b in branch_sizes[:20]),
            "non_id_count": len(all_unid),
        })

    keys = list(out_rows[0].keys()) if out_rows else []
    with open(OUT_CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(out_rows)
    print(f"Wrote {OUT_CSV} ({len(out_rows)} rows)")

    # Markdown summary
    md = []
    md.append("# Investigation D Phase A — low-noise regression pattern")
    md.append("")
    md.append(f"**Cells analyzed**: {len(out_rows)} (low-noise regressions where new is >10× worse than old, old < 0.1, new > 0.01)")
    md.append("")
    md.append("## Classification summary")
    md.append("")
    md.append("| classification | count | meaning |")
    md.append("|----------------|------:|---------|")
    meanings = {
        "truth_near_in_list_but_not_row0": "Branch detection KEPT a truth-near candidate but ranked it below row 0. Clustering or branch-detection picking issue.",
        "truth_near_at_row0_but_audit_classifies_regression": "Row 0 IS truth-near but audit flagged regression (unexpected — investigate)",
        "intermediate_only_truth_near_absent": "Result.csv has candidates within 10% of truth but none within 1%. Polish or solver didn't refine far enough.",
        "no_truth_near_candidate_in_list": "Result.csv has NO candidate within 10% of truth. Solver/HC/pre-polish-filter failed to find truth basin.",
    }
    for c, n in classification_counter.most_common():
        md.append(f"| {c} | {n} | {meanings[c]} |")
    md.append("")
    md.append("## Cell-level detail")
    md.append("")
    md.append("| cell | run | new_best | new_row0 | old_best | n_rows | raw_count | best_idx | class |")
    md.append("|------|-----|---------:|---------:|---------:|-------:|----------:|---------:|-------|")
    for r in sorted(out_rows, key=lambda x: -x["new_oracle_best"]):
        md.append(f"| {r['id']} | {r['run'].replace('odepe_v2_','v2_')} | "
                  f"{r['new_oracle_best']:.2e} | {r['new_oracle_row0']:.2e} | "
                  f"{r['old_oracle_best']:.2e} | {r['n_rows']} | {r['raw_count']} | "
                  f"{r['min_err_row_idx']} | {r['classification'][:20]} |")
    md.append("")
    md.append("## Interpretation")
    md.append("")
    md.append("- If `truth_near_in_list_but_not_row0` dominates: branch detection / clustering is dropping the best candidate from row 0. Fix: tighter eps, or different cluster-rep selection. Can probably recover by re-analyzing the result.csv offline.")
    md.append("- If `no_truth_near_candidate_in_list` dominates: solver/HC is the problem. The pre-polish filter (or process_raw_solution under Rodas5P) is rejecting candidates that the old stack found. Cannot recover offline; need a probe re-run.")
    md.append("- Mix: probably both effects. Probe a representative of each class.")

    OUT_MD.write_text("\n".join(md))
    print(f"Wrote {OUT_MD}")
    print()
    print("=== Classification ===")
    for c, n in classification_counter.most_common():
        print(f"  {c}: {n}")


if __name__ == "__main__":
    main()
