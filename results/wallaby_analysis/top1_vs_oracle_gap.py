#!/usr/bin/env python3
"""Top-1 vs oracle gap analysis: where does the algorithm's row-0 pick lose?

For each ODEPE polish/nopolish cell:
  - compute top-1 error (row 0)
  - compute oracle error (argmin over rows on identifiable axes)
  - record the rank of the truth-near row (0 = row 0, 1 = row 1, etc.)
  - flag whether the row-0 pick matches a known algebraic-branch
    transformation (for the 4 multiplicity-2 systems: daisy_mamil4,
    seir, slow_fast, biohydrogenation)

Output:
  - top1_vs_oracle_gap.csv: per-cell breakdown
  - top1_vs_oracle_gap.md:  summary tables grouped by system / noise /
    estimator + the algebraic-branch breakdown
"""
import csv
import json
import math
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
BENCH = REPO / "benchmark_wallaby_2026-05-17"
OUT_DIR = REPO / "results/wallaby_analysis"

ESTIMATORS = ("odepe_v2_polish", "odepe_v2_nopolish")
MULT2 = {"daisy_mamil4", "seir", "slow_fast", "biohydrogenation"}


def normalize_col(c: str) -> str:
    return c[:-3] if c.endswith("(t)") else c


def read_csv_dicts(path: Path):
    with open(path) as f:
        r = csv.DictReader(f)
        return list(r), r.fieldnames or []


def load_huge_json(bench: Path):
    j = json.load(open(bench / "huge_json.json"))
    return {c["id"]: c for c in j["instances"]}


def read_non_id_for_cell(cell_dir: Path) -> set:
    md = cell_dir / "odepe_metadata.json"
    if not md.exists():
        return set()
    try:
        d = json.load(open(md))
        unid = (d.get("best") or {}).get("all_unidentifiable") or []
        return {normalize_col(v) for v in unid}
    except Exception:
        return set()


def row_err(row, truth_id_vars, norm_fields):
    """Max relative error on identifiable axes for one row."""
    vals = []
    for v, tv in truth_id_vars.items():
        if v not in norm_fields:
            continue
        try:
            ev = float(row[norm_fields[v]])
        except (ValueError, TypeError, KeyError):
            continue
        if ev != ev:  # NaN
            continue
        if abs(tv) > 1e-15:
            vals.append(abs(ev - tv) / abs(tv))
        else:
            vals.append(abs(ev - tv))
    return max(vals) if vals else float("inf")


# ----------------------------------------------------------------------
# Algebraic-branch detection for the 4 multiplicity-2 systems.
#
# Each function returns True if the given row looks like the
# "alt branch" relative to truth (i.e., a swapped/sign-flipped version
# of the truth solution).
# ----------------------------------------------------------------------

def near(a, b, rel=0.15):
    """Within 15% relative."""
    if a is None or b is None:
        return False
    if abs(b) < 1e-12:
        return abs(a - b) < rel
    return abs(a - b) / abs(b) < rel


def get_val(row, norm_fields, var):
    if var not in norm_fields:
        return None
    try:
        v = float(row[norm_fields[var]])
    except (ValueError, TypeError, KeyError):
        return None
    if v != v:
        return None
    return v


def is_alt_branch_daisy_mamil4(row, truth, norm_fields) -> bool:
    """daisy_mamil4 alt branch: channel swap. y3 = 1.2*x3 + 1.6*x4 is the
    observed combination, so the alt branch satisfies
        1.2 * x3_row ≈ 1.6 * x4_truth
        1.6 * x4_row ≈ 1.2 * x3_truth
    i.e., the contribution of x3 to y3 in the alt branch matches the
    contribution of x4 to y3 at truth, and vice versa. Detect via this
    relation (more robust than literal k_swap match — the rates don't
    exchange 1-to-1, only the observable combination does).
    Also require x3_row not ~= x3_truth so we don't false-positive on
    the truth branch.
    """
    tx3 = truth.get("x3(t)") or truth.get("x3")
    tx4 = truth.get("x4(t)") or truth.get("x4")
    rx3 = get_val(row, norm_fields, "x3")
    rx4 = get_val(row, norm_fields, "x4")
    if None in (tx3, tx4, rx3, rx4):
        return False
    truth_y3 = 1.2 * tx3 + 1.6 * tx4
    row_y3 = 1.2 * rx3 + 1.6 * rx4
    # y3 should be preserved (both branches give same y3 by construction)
    if not near(row_y3, truth_y3, rel=0.10):
        return False
    # Swap relation: row's "x3 contribution" ~ truth's "x4 contribution"
    swap_check_1 = near(1.2 * rx3, 1.6 * tx4, rel=0.15)
    swap_check_2 = near(1.6 * rx4, 1.2 * tx3, rel=0.15)
    # And the row must not be the truth (require non-trivial swap)
    not_truth = not near(rx3, tx3, rel=0.10)
    return swap_check_1 and swap_check_2 and not_truth


def is_alt_branch_seir(row, truth, norm_fields) -> bool:
    """seir alt branch: a*nu = const, with (a, nu) hyperbola swap.
    Detect by: a_row * nu_row ≈ a_truth * nu_truth, but a_row != a_truth.
    """
    ta = truth.get("a"); tnu = truth.get("nu")
    ra = get_val(row, norm_fields, "a"); rnu = get_val(row, norm_fields, "nu")
    if None in (ta, tnu, ra, rnu):
        return False
    if ta <= 0 or tnu <= 0 or ra <= 0 or rnu <= 0:
        return False
    prod_t = ta * tnu
    prod_r = ra * rnu
    return near(prod_r, prod_t, rel=0.10) and not near(ra, ta, rel=0.10)


def is_alt_branch_slow_fast(row, truth, norm_fields) -> bool:
    """slow_fast alt branch: k1 ↔ k2 swap. Detect by row.k1 ~ k * truth.k2 for some k,
    with k1*k2 preserved. xA may go negative (OOB) but doesn't have to in
    row 0 (row 0 is bound-clipped).
    """
    tk1 = truth.get("k1"); tk2 = truth.get("k2")
    rk1 = get_val(row, norm_fields, "k1"); rk2 = get_val(row, norm_fields, "k2")
    if None in (tk1, tk2, rk1, rk2):
        return False
    if tk1 <= 0 or tk2 <= 0:
        return False
    prod_t = tk1 * tk2
    prod_r = rk1 * rk2
    # Ratio reversal: truth.k1/truth.k2 vs row.k1/row.k2 should be flipped
    truth_ratio = tk1 / tk2
    row_ratio = rk1 / max(rk2, 1e-15)
    return (near(prod_r, prod_t, rel=0.10) and
            (truth_ratio - 1) * (row_ratio - 1) < 0 and  # opposite sides of 1
            not near(rk1, tk1, rel=0.20))


def is_alt_branch_biohydrogenation(row, truth, norm_fields) -> bool:
    """biohydrogenation alt branch: k9 -> -k9, k10 -> -k10 (sign flip).
    Detect by row.k9 < 0 OR row.k10 < 0 (truth values are positive).
    """
    rk9 = get_val(row, norm_fields, "k9")
    rk10 = get_val(row, norm_fields, "k10")
    if rk9 is None and rk10 is None:
        return False
    if rk9 is not None and rk9 < -1e-6:
        return True
    if rk10 is not None and rk10 < -1e-6:
        return True
    return False


ALT_BRANCH_DETECTORS = {
    "daisy_mamil4": is_alt_branch_daisy_mamil4,
    "seir": is_alt_branch_seir,
    "slow_fast": is_alt_branch_slow_fast,
    "biohydrogenation": is_alt_branch_biohydrogenation,
}


def analyze_cell(est, cell_id, inst, instances):
    sn = inst["name"]
    cell_dir = BENCH / "filetree" / f"{est}_run" / cell_id
    rc = cell_dir / "result.csv"
    if not rc.exists():
        return None

    rows, fieldnames = read_csv_dicts(rc)
    if not rows:
        return None
    norm_fields = {normalize_col(c): c for c in fieldnames}

    # Identifiable truth (project out unidentifiable axes)
    non_id = read_non_id_for_cell(cell_dir)
    truth_full = {}
    truth_full.update(inst.get("state_values") or {})
    truth_full.update(inst.get("parameter_values") or {})
    truth_id = {v: val for v, val in truth_full.items() if v not in non_id}

    # Per-row errors on identifiable axes
    errs = [row_err(r, truth_id, norm_fields) for r in rows]
    if not errs:
        return None
    top1_err = errs[0]
    oracle_rank = min(range(len(errs)), key=lambda i: errs[i])
    oracle_err = errs[oracle_rank]

    # Algebraic branch flag (for the 4 multiplicity-2 systems, on row 0)
    is_alt = False
    if sn in MULT2:
        detector = ALT_BRANCH_DETECTORS[sn]
        # Use full truth (not just identifiable) — branch transformations are
        # defined on the full state/param space.
        try:
            is_alt = detector(rows[0], truth_full, norm_fields)
        except Exception:
            is_alt = False

    return {
        "system": sn,
        "estimator": est,
        "noise_label": cell_id.rsplit("_", 1)[1],
        "cell_id": cell_id,
        "n_rows": len(rows),
        "top1_err": top1_err,
        "oracle_err": oracle_err,
        "oracle_rank": oracle_rank,
        "gap_ratio": (top1_err / oracle_err) if oracle_err > 0 else float("inf"),
        "is_mult2": sn in MULT2,
        "row0_is_alt_branch": is_alt,
    }


def main():
    instances = load_huge_json(BENCH)
    rows_out = []
    for est in ESTIMATORS:
        for cell_id, inst in sorted(instances.items()):
            r = analyze_cell(est, cell_id, inst, instances)
            if r:
                rows_out.append(r)

    out_csv = OUT_DIR / "top1_vs_oracle_gap.csv"
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows_out[0].keys()))
        w.writeheader()
        w.writerows(rows_out)
    print(f"wrote {out_csv}  ({len(rows_out)} rows)")

    # Build summary
    # A "significant gap" cell is one where:
    #   top1_err > 10% (fails @10%) AND oracle_err < 1% (a truth-near row exists)
    # That's the population the user cares about: where the rank-1 sort is
    # losing a recoverable win.
    sig_gap = [r for r in rows_out if r["top1_err"] > 0.10 and r["oracle_err"] < 0.01]
    # Also: "moderate gap" — top1 > oracle by ≥3× (sort-order loss without the
    # strict pass/fail framing)
    mod_gap = [r for r in rows_out if r["gap_ratio"] >= 3.0 and r["oracle_err"] < 0.10]

    by_sys = defaultdict(lambda: defaultdict(int))
    for r in sig_gap:
        by_sys[r["system"]][r["estimator"]] += 1
    by_noise = defaultdict(lambda: defaultdict(int))
    for r in sig_gap:
        by_noise[r["noise_label"]][r["estimator"]] += 1
    by_oracle_rank = defaultdict(int)
    for r in sig_gap:
        by_oracle_rank[r["oracle_rank"]] += 1

    # Algebraic branch breakdown for multiplicity-2 systems
    mult2_breakdown = defaultdict(lambda: {"n_cells": 0, "n_sig_gap": 0, "n_row0_alt": 0,
                                            "n_sig_gap_alt": 0, "n_sig_gap_non_alt": 0})
    for r in rows_out:
        if not r["is_mult2"]:
            continue
        key = (r["system"], r["estimator"])
        mult2_breakdown[key]["n_cells"] += 1
        if r["top1_err"] > 0.10 and r["oracle_err"] < 0.01:
            mult2_breakdown[key]["n_sig_gap"] += 1
            if r["row0_is_alt_branch"]:
                mult2_breakdown[key]["n_sig_gap_alt"] += 1
            else:
                mult2_breakdown[key]["n_sig_gap_non_alt"] += 1
        if r["row0_is_alt_branch"]:
            mult2_breakdown[key]["n_row0_alt"] += 1

    out_md = OUT_DIR / "top1_vs_oracle_gap.md"
    lines = []
    lines.append("# Top-1 vs oracle gap analysis")
    lines.append("")
    lines.append(f"Per-cell breakdown of the {len(rows_out)} ODEPE polish + nopolish cells.")
    lines.append("")
    lines.append("**Significant gap** = top-1 fails @10% (max-rel-err > 0.10) while")
    lines.append("the oracle row passes @1% (max-rel-err < 0.01). These are cells where")
    lines.append("the algorithm clearly had a truth-near row in the K=20 set but its")
    lines.append("row-0 sort surfaced something far worse.")
    lines.append("")
    lines.append(f"- **Total significant-gap cells:** {len(sig_gap)} / {len(rows_out)} ({100*len(sig_gap)/len(rows_out):.1f}%)")
    lines.append(f"- **Cells with gap_ratio ≥ 3× and oracle < 10%:** {len(mod_gap)} / {len(rows_out)} ({100*len(mod_gap)/len(rows_out):.1f}%)")
    lines.append("")

    lines.append("## Where does the oracle row live in result.csv? (rank distribution)")
    lines.append("")
    lines.append("Among the significant-gap cells:")
    lines.append("")
    lines.append("| Oracle rank | Count | % of sig-gap |")
    lines.append("|---:|---:|---:|")
    total_sig = max(len(sig_gap), 1)
    for rank in sorted(by_oracle_rank.keys()):
        cnt = by_oracle_rank[rank]
        lines.append(f"| {rank} | {cnt} | {100*cnt/total_sig:.1f}% |")
    lines.append("")
    if by_oracle_rank:
        rank_within_top3 = sum(c for r, c in by_oracle_rank.items() if r <= 2)
        rank_within_top10 = sum(c for r, c in by_oracle_rank.items() if r <= 9)
        lines.append(f"- Oracle row within rows 0-2: **{rank_within_top3}/{total_sig}** ({100*rank_within_top3/total_sig:.1f}%)")
        lines.append(f"- Oracle row within rows 0-9: **{rank_within_top10}/{total_sig}** ({100*rank_within_top10/total_sig:.1f}%)")
    lines.append("")

    lines.append("## Per-system significant-gap counts")
    lines.append("")
    lines.append("(50 cells per system per estimator = 100 per system row)")
    lines.append("")
    lines.append("| System | Mult? | polish gaps | nopolish gaps | Total |")
    lines.append("|---|:---:|---:|---:|---:|")
    for sn in sorted(by_sys.keys(), key=lambda s: -sum(by_sys[s].values())):
        polish = by_sys[sn].get("odepe_v2_polish", 0)
        nopolish = by_sys[sn].get("odepe_v2_nopolish", 0)
        mult_tag = "**2**" if sn in MULT2 else "1"
        lines.append(f"| {sn} | {mult_tag} | {polish} | {nopolish} | {polish + nopolish} |")
    lines.append("")

    lines.append("## Per-noise significant-gap counts")
    lines.append("")
    lines.append("| Noise | polish gaps | nopolish gaps | Total |")
    lines.append("|---|---:|---:|---:|")
    for nz in sorted(by_noise.keys()):
        polish = by_noise[nz].get("odepe_v2_polish", 0)
        nopolish = by_noise[nz].get("odepe_v2_nopolish", 0)
        lines.append(f"| {nz} | {polish} | {nopolish} | {polish + nopolish} |")
    lines.append("")

    lines.append("## Algebraic-branch breakdown (the 4 multiplicity-2 systems)")
    lines.append("")
    lines.append("For each multiplicity-2 system, of the cells where row 0 is")
    lines.append("significantly worse than oracle, how often was row 0 the")
    lines.append("**alt algebraic branch** (the sign-flipped or swapped solution)?")
    lines.append("")
    lines.append("Branch detection rules:")
    lines.append("- **daisy_mamil4**: row 0 has (k13, k31, x3) ↔ (k14, k41, x4) swapped from truth")
    lines.append("- **seir**: row 0 satisfies a·nu = truth's a·nu, but a is far from truth")
    lines.append("- **slow_fast**: row 0 has k1, k2 swapped (k1*k2 preserved, ratio flipped)")
    lines.append("- **biohydrogenation**: row 0 has k9 or k10 negative (sign-flipped from truth)")
    lines.append("")
    lines.append("| System | Estimator | Cells | Row-0=alt-branch | Sig-gap | Sig-gap & alt | Sig-gap & not-alt |")
    lines.append("|---|---|---:|---:|---:|---:|---:|")
    for (sn, est) in sorted(mult2_breakdown.keys()):
        d = mult2_breakdown[(sn, est)]
        lines.append(
            f"| {sn} | {est} | {d['n_cells']} | {d['n_row0_alt']} "
            f"| {d['n_sig_gap']} | {d['n_sig_gap_alt']} | {d['n_sig_gap_non_alt']} |"
        )
    lines.append("")

    # Most extreme cells (by gap ratio, oracle < 1%)
    lines.append("## Top 15 most extreme gap cells (largest top1/oracle ratio, oracle < 1%)")
    lines.append("")
    extreme = sorted(
        [r for r in rows_out if r["oracle_err"] < 0.01 and math.isfinite(r["gap_ratio"])],
        key=lambda r: -r["gap_ratio"],
    )[:15]
    lines.append("| Cell | Estimator | top1_err | oracle_err | gap_ratio | oracle_rank | row0_alt |")
    lines.append("|---|---|---:|---:|---:|---:|:---:|")
    for r in extreme:
        alt_tag = "✓" if r["row0_is_alt_branch"] else ""
        lines.append(
            f"| `{r['cell_id']}` | {r['estimator']} | {r['top1_err']:.2e} "
            f"| {r['oracle_err']:.2e} | ×{r['gap_ratio']:.0f} | rank {r['oracle_rank']} | {alt_tag} |"
        )
    lines.append("")

    lines.append("## Headline answer")
    lines.append("")
    lines.append("Drivers of the top-1 vs oracle gap, in priority order:")
    lines.append("")
    # Compute aggregates for the answer
    n_total_gap = len(sig_gap)
    n_mult2_gap = sum(1 for r in sig_gap if r["is_mult2"])
    n_alt_branch_gap = sum(1 for r in sig_gap if r["row0_is_alt_branch"])
    n_polish_gap = sum(1 for r in sig_gap if r["estimator"] == "odepe_v2_polish")
    n_nopolish_gap = sum(1 for r in sig_gap if r["estimator"] == "odepe_v2_nopolish")
    lines.append(f"1. Of {n_total_gap} significant-gap cells:")
    lines.append(f"   - {n_polish_gap} are in polish, {n_nopolish_gap} are in nopolish")
    lines.append(f"   - {n_mult2_gap} are in the 4 multiplicity-2 systems")
    lines.append(f"   - {n_alt_branch_gap} have row 0 = the alt algebraic branch")
    lines.append("")

    out_md.write_text("\n".join(lines))
    print(f"wrote {out_md}")
    print()
    print(f"=== Quick summary ===")
    print(f"Total cells: {len(rows_out)}")
    print(f"Significant-gap cells: {len(sig_gap)} ({100*len(sig_gap)/len(rows_out):.1f}%)")
    print(f"  polish:   {n_polish_gap}")
    print(f"  nopolish: {n_nopolish_gap}")
    print(f"In multiplicity-2 systems: {n_mult2_gap}")
    print(f"Row 0 = alt algebraic branch: {n_alt_branch_gap}")


if __name__ == "__main__":
    main()
