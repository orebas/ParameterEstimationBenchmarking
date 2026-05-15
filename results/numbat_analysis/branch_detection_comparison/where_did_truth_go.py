#!/usr/bin/env python3
"""For each polish probe cell, trace where the truth-recovering candidate went.

Procedure per cell:
  1. From the `no_clustering` probe's result.csv, identify the polished row with
     the lowest oracle err (max_rel_err vs truth). That's the "truth-near polish"
     produced by the legacy (no-err-filter) pipeline.
  2. In the `deep_dump` probe, find the closest raw HC candidate in identifiable
     parameter space — this is the raw that *would* have polished to truth if
     polish had been applied to it.
  3. Report: did that raw survive the deep_dump err filter? Did it get polished?
     What was its raw err vs the err-filter cap?

Output: trace_table.csv + trace_table.md
"""
import csv
import json
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH = REPO / "benchmark_numbat_2026-05-12"
HERE = REPO / "results/numbat_analysis/branch_detection_comparison"

POLISH_PROBES = [
    "flexible_arm_0_1em8",
    "daisy_mamil4_8_1em8",
    "seir_3_0",
    "vanderpol_6_1em2",
    "quadrotor_9_1em4",
    "fitzhugh_nagumo_4_1em6",
    "fitzhugh_nagumo_0_1em4",
]
BRANCH_ERR_FACTOR = 100.0


def normalize(c):
    return c[:-3] if c.endswith("(t)") else c


def read_non_id(bench):
    out = {}
    for est in ("odepe_v2_polish", "odepe_v2_nopolish"):
        rd = bench / "filetree" / f"{est}_run"
        if not rd.exists(): continue
        for cell in rd.iterdir():
            md = cell / "odepe_metadata.json"
            if not md.exists(): continue
            sn = cell.name.rsplit("_", 2)[0]
            if sn in out: continue
            try:
                d = json.load(open(md))
                out[sn] = {normalize(v) for v in (d.get("best", {}).get("all_unidentifiable") or [])}
            except Exception:
                pass
    return out


def oracle_err(row, truth):
    """row: dict of normalized-name → float. truth: dict of name → value."""
    vals = []
    for v, tv in truth.items():
        ev = row.get(v)
        if ev is None: continue
        if abs(tv) > 1e-15:
            vals.append(abs(ev - tv) / abs(tv))
        else:
            vals.append(abs(ev - tv))
    return max(vals) if vals else np.inf


def _strip_prefix(name):
    """Strip s:: or p:: column prefix used in raw_candidates / polished_results dumps."""
    if name.startswith("s::") or name.startswith("p::"):
        return name[3:]
    return name


def read_csv_normalized(path):
    """Return list of dicts with normalized keys. Handles both result.csv (bare
    variable names like 'x1(t)') and polished_results.csv ('s::x1(t)' prefixed)."""
    with open(path) as f:
        rdr = csv.DictReader(f)
        rows = list(rdr)
        fields = rdr.fieldnames or []
    out = []
    for r in rows:
        d = {}
        for col in fields:
            key = normalize(_strip_prefix(col))
            try:
                d[key] = float(r[col])
            except (ValueError, TypeError, KeyError):
                pass
        # Pass-through metadata cols
        for col in fields:
            if col in ("polish_source_hc_idx", "hc_idx", "branch_size"):
                try:
                    d[col] = int(float(r[col]))
                except (ValueError, TypeError):
                    pass
        out.append(d)
    return out


def read_raw_candidates(path):
    """Return list of dicts: {hc_idx, err, <state_names>, <param_names>, all_unidentifiable_set}."""
    with open(path) as f:
        rdr = csv.DictReader(f)
        rows = list(rdr)
        fields = rdr.fieldnames or []
    out = []
    for r in rows:
        d = {}
        for col in fields:
            if col.startswith("s::") or col.startswith("p::"):
                key = normalize(col[3:])
                try:
                    d[key] = float(r[col])
                except (ValueError, TypeError):
                    d[key] = np.nan
            elif col == "hc_idx":
                d["hc_idx"] = int(r[col])
            elif col == "err":
                try:
                    d["err"] = float(r[col]) if r[col].strip() else np.inf
                except ValueError:
                    d["err"] = np.inf
        out.append(d)
    return out


def main():
    instances = {c["id"]: c for c in json.load(open(BENCH / "huge_json.json"))["instances"]}
    non_id = read_non_id(BENCH)

    out_rows = []
    md = ["# Where did the truth-recovering candidate go?", "",
          "For each polish probe cell: find the truth-near polished output from "
          "`no_clustering` (legacy/no-err-filter), match it back to a raw HC in "
          "`deep_dump` (new pipeline), and report whether the err filter dropped it.",
          ""]
    md.append("| cell | nc_oracle | dd_best_overall | matched_raw_hc | match_dist | raw_err | err_cap | filter | polished | dd_polish_oracle_from_matched_raw |")
    md.append("|------|----------:|----------------:|----------------:|-----------:|--------:|--------:|:------:|:--------:|----------------------------------:|")

    for cell_id in POLISH_PROBES:
        nc_dir = BENCH / "probes" / cell_id / "no_clustering"
        dd_dir = BENCH / "probes" / cell_id / "deep_dump"
        if not (nc_dir / "result.csv").exists() or not (dd_dir / "raw_candidates.csv").exists():
            print(f"[skip] {cell_id}: missing files")
            continue

        inst = instances[cell_id]
        sys_name = inst["name"]
        non_id_set = non_id.get(sys_name, set())
        truth_full = {**(inst.get("state_values") or {}), **(inst.get("parameter_values") or {})}
        truth = {v: val for v, val in truth_full.items() if v not in non_id_set}
        id_var_names = list(truth.keys())

        # 1. Truth-near polished from no_clustering
        nc_rows = read_csv_normalized(nc_dir / "result.csv")
        nc_oracles = [(oracle_err(r, truth), i, r) for i, r in enumerate(nc_rows)]
        nc_oracles.sort(key=lambda x: x[0])
        nc_best_oracle, _, nc_best_row = nc_oracles[0]

        # Reference point in id-space (from the truth-near polished output)
        ref_id = np.array([nc_best_row.get(v, np.nan) for v in id_var_names])

        # 2. Find closest raw in deep_dump
        dd_raws = read_raw_candidates(dd_dir / "raw_candidates.csv")
        dd_polished = read_csv_normalized(dd_dir / "polished_results.csv")
        polished_hc_set = {p.get("polish_source_hc_idx") for p in dd_polished if p.get("polish_source_hc_idx") is not None}

        # Use uniform absolute distance (no MAD here — just want geometric proximity)
        best_match = None
        best_dist = np.inf
        for r in dd_raws:
            raw_id = np.array([r.get(v, np.nan) for v in id_var_names])
            if not np.all(np.isfinite(raw_id)):
                continue
            # Per-component relative distance, take max (matches solution_distance style)
            dists = []
            for j, v in enumerate(id_var_names):
                a, b = raw_id[j], ref_id[j]
                denom = max(abs(a) + abs(b), 1.0)
                dists.append(abs(a - b) / denom)
            d = max(dists) if dists else np.inf
            if d < best_dist:
                best_dist = d
                best_match = r

        # Err filter analysis
        finite_errs = [r["err"] for r in dd_raws if np.isfinite(r.get("err", np.inf))]
        min_err = min(finite_errs) if finite_errs else np.inf
        err_cap = BRANCH_ERR_FACTOR * max(min_err, 2.2e-16)

        # 3. deep_dump's best polish oracle (for context)
        dd_pol_oracles = [oracle_err(r, truth) for r in dd_polished]
        dd_best_oracle = min(dd_pol_oracles) if dd_pol_oracles else np.inf

        # Match status
        if best_match is None:
            md.append(f"| {cell_id} | {nc_best_oracle:.2e} | {dd_best_oracle:.2e} | - | - | - | {err_cap:.2e} | - | - | - |")
            continue
        m_hc = best_match["hc_idx"]
        m_err = best_match["err"]
        survived = m_err <= err_cap
        polished = m_hc in polished_hc_set
        survived_str = "✓" if survived else "✗"
        polished_str = "✓" if polished else "✗"
        # Look up the polished output specifically from this hc_idx
        dd_pol_from_match = "-"
        if polished:
            for p in dd_polished:
                if p.get("polish_source_hc_idx") == m_hc:
                    o = oracle_err(p, truth)
                    dd_pol_from_match = f"{o:.2e}"
                    break
        md.append(f"| {cell_id} | {nc_best_oracle:.2e} | {dd_best_oracle:.2e} | {m_hc} | {best_dist:.2e} | {m_err:.2e} | {err_cap:.2e} | {survived_str} | {polished_str} | {dd_pol_from_match} |")

        out_rows.append({
            "cell": cell_id,
            "nc_best_oracle": nc_best_oracle,
            "dd_best_polish_oracle": dd_best_oracle,
            "matched_raw_hc_idx": m_hc,
            "id_match_dist": best_dist,
            "raw_err": m_err,
            "err_cap": err_cap,
            "survived_err_filter": int(survived),
            "got_polished_in_dd": int(polished),
            "ref_id_values": ";".join(f"{v}={ref_id[j]:.4f}" for j, v in enumerate(id_var_names)),
        })

    out_csv = HERE / "trace_table.csv"
    keys = list(out_rows[0].keys()) if out_rows else []
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(out_rows)
    print(f"\nWrote {out_csv}")

    out_md = HERE / "trace_table.md"
    out_md.write_text("\n".join(md))
    print(f"Wrote {out_md}")
    print()
    print("=== Summary ===")
    print("\n".join(md))


if __name__ == "__main__":
    main()
