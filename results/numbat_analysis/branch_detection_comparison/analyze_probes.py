#!/usr/bin/env python3
"""Analyze the 10 no_clustering probes.

For each probe, compute oracle-best (argmin max_rel_err over rows) and compare
to the original benchmark's per-cell oracle-best.

Outputs:
  probe_results.csv
  probe_summary.md
"""
import csv
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH = REPO / "benchmark_numbat_2026-05-12"
OLD_BENCH = REPO / "benchmark_numbat_2026-05-06"
HERE = REPO / "results/numbat_analysis/branch_detection_comparison"

PROBES = [
    # (cell, run_short, original_new_oracle, old_oracle)
    ("flexible_arm_0_1em8", "polish", 0.378, 4.78e-6),
    ("daisy_mamil4_8_1em8", "polish", 0.149, 6.19e-3),
    ("seir_3_0", "polish", 9.19e-2, 3.61e-13),
    ("hiv_8_0", "nopolish", 1.41e-2, 9.20e-6),
    ("biohydrogenation_2_0", "nopolish", 1.10e-2, 1.21e-5),
    ("vanderpol_6_1em2", "polish", 1.63e-2, 2.82e-4),
    ("quadrotor_9_1em4", "polish", 1.47e-2, 2.75e-4),
    ("fitzhugh_nagumo_4_1em6", "polish", 2.35e-2, 1.59e-3),
    ("dc_motor_4_1em4", "nopolish", 1.72e-2, 9.42e-4),
    ("fitzhugh_nagumo_0_1em4", "polish", 4.20e-1, 1.46e-2),
]


def normalize(c):
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
            out[sn] = {normalize(v) for v in unid}
    return out


def compute_per_row_oracle(result_csv, truth_id_vars):
    with open(result_csv) as f:
        r = csv.DictReader(f)
        rows = list(r)
        fields = r.fieldnames or []
    norm = {normalize(c): c for c in fields}
    errs = []
    for row in rows:
        vals = []
        for v, tv in truth_id_vars.items():
            if v not in norm:
                continue
            try:
                ev = float(row[norm[v]])
            except (ValueError, TypeError, KeyError):
                continue
            if abs(tv) > 1e-15:
                vals.append(abs(ev - tv) / abs(tv))
            else:
                vals.append(abs(ev - tv))
        errs.append(max(vals) if vals else float("inf"))
    return errs, len(rows)


def main():
    instances = {c["id"]: c for c in json.load(open(BENCH / "huge_json.json"))["instances"]}
    non_id = read_non_id(BENCH)

    out_rows = []
    for cell, run_short, original_new, old_oracle in PROBES:
        run_full = f"odepe_v2_{run_short}"
        inst = instances[cell]
        sys_name = inst["name"]
        non_id_set = non_id.get(sys_name, set())
        truth = {}
        for v, val in (inst.get("state_values") or {}).items():
            if v not in non_id_set:
                truth[v] = val
        for v, val in (inst.get("parameter_values") or {}).items():
            if v not in non_id_set:
                truth[v] = val

        probe_csv = BENCH / "probes" / cell / "no_clustering" / "result.csv"
        if not probe_csv.exists():
            out_rows.append({"cell": cell, "run": run_short, "status": "no_result"})
            continue

        probe_errs, probe_n = compute_per_row_oracle(probe_csv, truth)
        probe_best = min(probe_errs) if probe_errs else float("inf")
        probe_best_idx = probe_errs.index(probe_best) if probe_errs else -1

        # Original new benchmark
        orig_csv = BENCH / "filetree" / f"{run_full}_run" / cell / "result.csv"
        orig_errs, orig_n = compute_per_row_oracle(orig_csv, truth)
        orig_best = min(orig_errs) if orig_errs else float("inf")
        orig_row0 = orig_errs[0] if orig_errs else float("inf")

        # Old benchmark
        old_csv = OLD_BENCH / "filetree" / f"{run_full}_run" / cell / "result.csv"
        if old_csv.exists():
            old_errs, old_n = compute_per_row_oracle(old_csv, truth)
            old_best = min(old_errs) if old_errs else float("inf")
        else:
            old_n, old_best = -1, float("inf")

        # Classification
        if probe_best < 0.01:
            verdict = "CLUSTERING_RECOVERED"
        elif probe_best < orig_best * 0.5:
            verdict = "PARTIAL_RECOVERY"
        elif probe_best > orig_best * 2:
            verdict = "WORSE_THAN_ORIG"
        else:
            verdict = "NO_RECOVERY"

        out_rows.append({
            "cell": cell,
            "run": run_short,
            "probe_n_rows": probe_n,
            "probe_oracle_best": probe_best,
            "probe_best_idx": probe_best_idx,
            "orig_n_rows": orig_n,
            "orig_oracle_best": orig_best,
            "orig_row0_oracle": orig_row0,
            "old_n_rows": old_n,
            "old_oracle_best": old_best,
            "verdict": verdict,
        })

    # Write CSV
    keys = ["cell", "run", "verdict", "probe_n_rows", "orig_n_rows", "old_n_rows",
            "probe_oracle_best", "orig_oracle_best", "orig_row0_oracle", "old_oracle_best",
            "probe_best_idx"]
    with open(HERE / "probe_results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        w.writerows(out_rows)
    print(f"Wrote {HERE / 'probe_results.csv'}")

    # Markdown summary
    md = []
    md.append("# No-clustering probe results")
    md.append("")
    md.append("**Setup**: 10 cells re-run with `branch_cluster_eps=1e-9` + `branch_detection=false`.")
    md.append("Every HC candidate becomes its own pre-polish cluster (all polished, no merging),")
    md.append("post-polish branch detection skipped (full polished list returned, oracle-sorted).")
    md.append("")
    md.append("**Verdict legend:**")
    md.append("- `CLUSTERING_RECOVERED`: probe oracle-best < 1% → disabling clustering recovers truth-near candidate. **User hypothesis confirmed.**")
    md.append("- `PARTIAL_RECOVERY`: probe is at least 2× better than original benchmark, but still >1% off truth.")
    md.append("- `NO_RECOVERY`: probe is similar to original (within 2×) — clustering was NOT the dominant issue.")
    md.append("- `WORSE_THAN_ORIG`: probe is >2× worse than original benchmark (unexpected; possibly a different basin).")
    md.append("")
    md.append("## Per-cell results")
    md.append("")
    md.append("| cell | run | verdict | probe rows | probe best | orig rows | orig best | old rows | old best |")
    md.append("|------|-----|---------|-----------:|-----------:|----------:|----------:|---------:|---------:|")
    for r in out_rows:
        if r.get("status") == "no_result":
            md.append(f"| {r['cell']} | {r['run']} | NO_RESULT | - | - | - | - | - | - |")
            continue
        md.append(f"| {r['cell']} | {r['run']} | **{r['verdict']}** | "
                  f"{r['probe_n_rows']} | {r['probe_oracle_best']:.2e} | "
                  f"{r['orig_n_rows']} | {r['orig_oracle_best']:.2e} | "
                  f"{r['old_n_rows']} | {r['old_oracle_best']:.2e} |")
    md.append("")

    # Summary
    counter = {}
    for r in out_rows:
        v = r.get("verdict", r.get("status", "?"))
        counter[v] = counter.get(v, 0) + 1

    md.append("## Verdict summary")
    md.append("")
    for v, n in sorted(counter.items(), key=lambda x: -x[1]):
        md.append(f"- {v}: **{n}** / {len(out_rows)}")
    md.append("")

    # Row-count blowup
    md.append("## Row-count blowup (clustering was doing real work)")
    md.append("")
    md.append("| cell | orig rows (clustered) | probe rows (raw) | compression factor (orig/probe) |")
    md.append("|------|-----:|-----:|-----:|")
    for r in out_rows:
        if r.get("status") == "no_result":
            continue
        compression = r["orig_n_rows"] / max(1, r["probe_n_rows"])
        md.append(f"| {r['cell']} | {r['orig_n_rows']} | {r['probe_n_rows']} | {1/compression:.0f}× |")
    md.append("")

    (HERE / "probe_summary.md").write_text("\n".join(md))
    print(f"Wrote {HERE / 'probe_summary.md'}")
    print()
    print("=== Verdict summary ===")
    for v, n in sorted(counter.items(), key=lambda x: -x[1]):
        print(f"  {v}: {n}")
    print()
    print("=== Per-cell ===")
    for r in out_rows:
        if r.get("status") == "no_result":
            print(f"  {r['cell']:32s} NO_RESULT")
            continue
        print(f"  {r['cell']:32s} {r['verdict']:22s}  probe={r['probe_oracle_best']:.2e} orig={r['orig_oracle_best']:.2e} old={r['old_oracle_best']:.2e}")


if __name__ == "__main__":
    main()
