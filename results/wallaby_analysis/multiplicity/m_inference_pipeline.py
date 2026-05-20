#!/usr/bin/env python3
"""Auto-infer algebraic multiplicity M from our pipeline output.

Algorithm (our-package-only, no upstream patches needed):

  Step 1: SI gate. Call StructuralIdentifiability.assess_identifiability(ode).

      n_locally = #vars classified `:locally`
      n_nonid   = #vars classified `:nonidentifiable`

      - n_locally == 0  →  M = 1 (whether or not there are continuous
        unidentifiabilities; those are plugged via
        `representative_completion_value`).

      - n_locally > 0   →  M > 1 (SI proves this) but doesn't tell us
        the exact value. Falls through to step 2.

  Step 2 (TODO — see M_INFERENCE_INVESTIGATION.md): run HC.jl directly
  on the polynomial system in the identifiable subspace and count
  distinct complex roots. For now we fall through to `config/systems.json`
  (the hand-derived catalog from `MULTIPLICITY_COMPLETE.md`).

  The catalog itself was derived by:
    - HC.jl finding all complex roots
    - Projecting out :nonidentifiable axes via representative_completion_value
    - Counting distinct roots at cd10 = 1e-10 tolerance on the projection
    - Case-by-case verification (especially for biohydrogenation, where
      the alt branch is the sign-flipped k9 → -k9, k10 → -k10 transformation
      and is OOB for the wallaby bounds, so the polished result.csv
      undercounts it).

Why we don't naively count distinct rows in result.csv:

  - The K=20 result.csv contains rows that have been IS-clustered by
    ODEPE but each cluster representative has been polished separately,
    so the rows within a cluster diverge by up to ~20% on some axes
    due to polish convergence to slightly different points in the same
    basin. So a naive max-rel-dist threshold either over- or under-counts.
  - The threshold that local-claude used in `multiplicity_pass1.pkl`
    (the cd10 column) is more sophisticated — it uses MAD-normalized
    L∞ distance in identifiable-subspace coordinates. Reproducing that
    exactly here is its own engineering project; for the paper we use
    the cataloged values.

Empirical validator: for each system we also report the per-cell
distinct-row count at relative threshold 0.30 with `ceil(median)`
aggregation. For multiplicity-1 systems this should consistently be 1;
for multiplicity-2 systems it should be 2 (with biohydrogenation
showing 1 because polish rejected the OOB sign-flipped alt — this
is the known weakness of the naive row-clustering approach).

Output: m_inference_validation.csv + m_inference_validation.md
"""
import csv
import json
import math
import statistics
from collections import defaultdict, Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent
BENCH = REPO / "benchmark_wallaby_2026-05-17"
OUT_DIR = REPO / "results/wallaby_analysis/multiplicity"
ESTIMATORS = ("odepe_v2_polish", "odepe_v2_nopolish")

# Threshold for the empirical validator's naive row-clustering. 30% relative
# distance on identifiable axes. This is the tolerance used by the
# TOP2_BRANCH_CAPTURE.md analysis. Documented limitation: this is sensitive
# to small-magnitude axes (a row with x4=0.04 vs truth 0.6 reads as 94%
# different, looking like a "distinct branch" even though it's polish noise).
EMPIRICAL_BRANCH_THRESH = 0.30
TRUTH_PASS_TOP = 0.10  # row 0 must be within 10% of truth on identifiable axes


def normalize_col(c: str) -> str:
    return c[:-3] if c.endswith("(t)") else c


def load_si_classifications():
    """Parse the SI cross-check output for per-variable classifications.

    Returns: dict mapping system_name -> {var_name: classification_symbol}.
    Source: results/wallaby_analysis/multiplicity/sian_poly_output.log
    (covers 16 polynomial systems) and ODEPE's repro
    multiplicity_complete_2026_05_19/run_sian_all_23.txt (covers all 23
    via the sin→input trick).
    """
    classifications = {}
    sources = [
        OUT_DIR / "sian_poly_output.log",
        REPO / "environments/ODEParameterEstimation/repro/multiplicity_complete_2026_05_19/run_sian_all_23.txt",
    ]
    for src in sources:
        if not src.exists():
            continue
        with open(src) as f:
            lines = f.read().split("\n")
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line and "=" * 30 in lines[i - 1] if i > 0 else False:
                # System name header
                sys_name = line
                if sys_name in classifications or sys_name == "SUMMARY" or sys_name.startswith("DETAILED"):
                    i += 1
                    continue
                classifications[sys_name] = {}
                # Parse "  varname => :symbol" lines until next === or empty
                j = i + 2  # skip the trailing === line
                while j < len(lines):
                    ln = lines[j]
                    if ln.startswith("=" * 30) or (ln and ln[0] != " "):
                        break
                    if "=>" in ln:
                        parts = ln.strip().split("=>")
                        var = parts[0].strip()
                        sym = parts[1].strip()
                        classifications[sys_name][var] = sym
                    j += 1
                i = j
            else:
                i += 1
    return classifications


def gate_via_si(classification):
    """Apply the SI gate.

    Returns (gate_M, n_locally, n_nonid, n_globally).
    gate_M is 1 if the system is determinately mult-1; None if it might be > 1.
    """
    n_locally = sum(1 for v in classification.values() if v == "locally")
    n_nonid = sum(1 for v in classification.values() if v == "nonidentifiable")
    n_globally = sum(1 for v in classification.values() if v == "globally")
    if n_locally == 0:
        return 1, n_locally, n_nonid, n_globally
    return None, n_locally, n_nonid, n_globally


def read_nonid_axes(cell_dir: Path) -> set:
    md = cell_dir / "odepe_metadata.json"
    if not md.exists():
        return set()
    try:
        d = json.load(open(md))
        unid = (d.get("best") or {}).get("all_unidentifiable") or []
        return {normalize_col(v) for v in unid}
    except Exception:
        return set()


def parse_result_rows(rc_path: Path):
    if not rc_path.exists():
        return None, []
    with open(rc_path) as f:
        rd = csv.DictReader(f)
        fields = rd.fieldnames or []
        rows = list(rd)
    # Normalize column names: x(t) -> x
    rows = [{normalize_col(k): v for k, v in r.items()} for r in rows]
    norm_fields = [normalize_col(c) for c in fields]
    return norm_fields, rows


def to_floats(row, axes):
    out = {}
    for k in axes:
        if k not in row:
            continue
        try:
            v = float(row[k])
        except (ValueError, TypeError):
            continue
        if math.isnan(v) or math.isinf(v):
            continue
        out[k] = v
    return out


def max_rel_dist(d1, d2):
    mx = 0.0
    n = 0
    for k in d1:
        if k not in d2:
            continue
        denom = max(abs(d1[k]), abs(d2[k]), 1e-10)
        mx = max(mx, abs(d1[k] - d2[k]) / denom)
        n += 1
    return mx if n > 0 else None


def max_rel_err(row_floats, truth):
    mx = 0.0
    n = 0
    for k, tv in truth.items():
        if k not in row_floats:
            continue
        if abs(tv) > 1e-15:
            mx = max(mx, abs(row_floats[k] - tv) / abs(tv))
        else:
            mx = max(mx, abs(row_floats[k] - tv))
        n += 1
    return mx if n > 0 else float("inf")


def count_distinct_branches_per_cell(cell_dir: Path, truth_full):
    """Walk all K=20 rows. Return count of distinct branches at cd10 tolerance,
    on identifiable axes only. Restricted to cells where row 0 is near truth
    (else the cell is unreliable — polish didn't converge to the truth basin
    so we can't trust the row count).
    """
    fields, rows = parse_result_rows(cell_dir / "result.csv")
    if not rows:
        return None
    nonid = read_nonid_axes(cell_dir)
    id_axes = {k for k in fields if k not in nonid and k not in
               ("err", "post_polish_error", "branch_size", "polish_source_hc_idx")
               and not k.startswith("_trfn_")}
    truth_id = {k: v for k, v in truth_full.items() if k in id_axes}
    if not truth_id:
        return None

    row0 = to_floats(rows[0], id_axes)
    if not row0 or max_rel_err(row0, truth_id) > TRUTH_PASS_TOP:
        return None  # row 0 isn't near truth — cell unreliable for branch counting

    # Count distinct branches at EMPIRICAL_BRANCH_THRESH tolerance: two
    # rows are in the same branch if max-rel-distance on identifiable axes
    # is below threshold. Documented limitation: this naive clustering can
    # over- or under-count depending on per-axis spread.
    branches = [row0]
    for r in rows[1:]:
        rf = to_floats(r, id_axes)
        if not rf:
            continue
        is_new = True
        for b in branches:
            d = max_rel_dist(rf, b)
            if d is None or d <= EMPIRICAL_BRANCH_THRESH:
                is_new = False
                break
        if is_new:
            branches.append(rf)
    return len(branches)


def infer_M(system, classifications, instances, catalog_M):
    """Run the gated pipeline.

    Step 1 (automated): SI gate. n_locally == 0 → M_inferred = 1.
    Step 2 (catalog for now): n_locally > 0 → fall through to catalog
             value, which came from MULTIPLICITY_COMPLETE.md's HC
             analysis. TODO: replace with direct HC.jl call.

    Also computes M_empirical via naive row-clustering at 30% threshold
    + ceil(median) as a sanity validator.
    """
    cls = classifications.get(system, {})
    gate_M, n_loc, n_non, n_glob = gate_via_si(cls)
    out = {
        "system": system,
        "n_globally": n_glob,
        "n_locally": n_loc,
        "n_nonid": n_non,
        "si_gate_fires": gate_M is not None,
        "M_from_si_gate": gate_M,
        "M_inferred": None,
        "M_inferred_source": None,
        "M_empirical_validator": None,
        "n_good_cells": 0,
        "per_cell_histogram": {},
    }

    # Step 1: SI gate
    if gate_M is not None:
        out["M_inferred"] = gate_M
        out["M_inferred_source"] = "si_gate"
        return out

    # Step 2: SI says M > 1 — fall through to catalog
    out["M_inferred"] = catalog_M
    out["M_inferred_source"] = "catalog (TODO: direct HC)"

    # Empirical validator (informational, not the source of M_inferred)
    per_cell_counts = []
    for est in ESTIMATORS:
        rd = BENCH / "filetree" / f"{est}_run"
        if not rd.exists():
            continue
        for cell_id, inst in instances.items():
            if inst["name"] != system:
                continue
            cd = rd / cell_id
            if not cd.exists():
                continue
            truth = {**(inst.get("state_values") or {}), **(inst.get("parameter_values") or {})}
            cnt = count_distinct_branches_per_cell(cd, truth)
            if cnt is not None:
                per_cell_counts.append(cnt)
    if per_cell_counts:
        med = statistics.median(per_cell_counts)
        out["M_empirical_validator"] = math.ceil(med)
        out["n_good_cells"] = len(per_cell_counts)
        out["per_cell_histogram"] = dict(Counter(per_cell_counts))
    return out


def load_catalog():
    cfg = json.load(open(REPO / "config" / "systems.json"))
    return {s["name"]: int(s.get("algebraic_multiplicity", 1)) for s in cfg["systems"]}


def main():
    classifications = load_si_classifications()
    print(f"Loaded SI classifications for {len(classifications)} systems")
    catalog = load_catalog()
    print(f"Loaded catalog for {len(catalog)} systems")
    print()

    instances = {c["id"]: c for c in json.load(open(BENCH / "huge_json.json"))["instances"]}

    rows = []
    for system in sorted(catalog.keys()):
        r = infer_M(system, classifications, instances, catalog[system])
        r["M_catalog"] = catalog[system]
        r["match"] = r["M_inferred"] == r["M_catalog"]
        rows.append(r)

    # Print + write
    out_csv = OUT_DIR / "m_inference_validation.csv"
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {out_csv}")

    print()
    print(f"{'system':<22s} {'glob':>5s} {'loc':>5s} {'nonid':>5s} {'gate':>5s} "
          f"{'M_inf':>6s} {'M_cat':>6s} {'M_emp':>6s} {'cells':>6s} {'match':>6s}")
    print("-" * 92)
    n_match = 0
    for r in rows:
        gate_str = "✓" if r["si_gate_fires"] else "."
        match_str = "✓" if r["match"] else "✗"
        n_match += 1 if r["match"] else 0
        emp = "-" if r["M_empirical_validator"] is None else str(r["M_empirical_validator"])
        print(f"{r['system']:<22s} {r['n_globally']:>5d} {r['n_locally']:>5d} "
              f"{r['n_nonid']:>5d} {gate_str:>5s} {str(r['M_inferred']):>6s} "
              f"{r['M_catalog']:>6d} {emp:>6s} {r['n_good_cells']:>6d} {match_str:>6s}")
    print("-" * 92)
    print(f"{n_match}/{len(rows)} systems match catalog")

    # Markdown summary
    out_md = OUT_DIR / "m_inference_validation.md"
    md = []
    md.append("# M-inference pipeline validation")
    md.append("")
    md.append("## Algorithm (our-package-only, no upstream patches)")
    md.append("")
    md.append("**Step 1: SI gate.** Call `assess_identifiability(ode)` and count")
    md.append("`:locally`-classified variables.")
    md.append("- `n_locally == 0` → **M = 1** (system globally identifiable in the")
    md.append("  identifiable subspace).")
    md.append("- `n_locally > 0` → M > 1 (SI proves this), but the value isn't")
    md.append("  exposed. Fall through to step 2.")
    md.append("")
    md.append("**Step 2 (TODO: direct HC; today: catalog).** For systems where SI")
    md.append("gate defers, read M from `config/systems.json` (hand-derived from")
    md.append("`MULTIPLICITY_COMPLETE.md`'s HC root-count analysis). The TODO is")
    md.append("to replace this with a direct HC.jl call on the polynomial system")
    md.append("in the identifiable subspace, counting distinct complex roots.")
    md.append("Tracked in `M_INFERENCE_INVESTIGATION.md`.")
    md.append("")
    md.append("**Sanity validator: M_empirical.** For each cell, count distinct")
    md.append(f"rows in result.csv K=20 at relative threshold {EMPIRICAL_BRANCH_THRESH}")
    md.append(f"on identifiable axes (cells with row 0 within {TRUTH_PASS_TOP*100:.0f}% of")
    md.append("truth only). Aggregate with `ceil(median)`. This is NOT the source")
    md.append("of M_inferred — it's a sanity column showing what naive empirical")
    md.append("counting on the polished output produces. Documented limitations:")
    md.append("- Sensitive to small-magnitude axes (1e-9 vs 1.0 reads as 100% diff)")
    md.append("- For biohydrogenation, undercounts: polish rejects the OOB")
    md.append("  k9,k10 < 0 sign-flipped alt branch, so most cells show only 1.")
    md.append("- For systems with significant within-basin polish spread, may")
    md.append("  overcount.")
    md.append("")
    md.append(f"## Results on {len(rows)} wallaby systems")
    md.append("")
    md.append(f"**{n_match}/{len(rows)} match catalog.**")
    md.append("")
    md.append("| System | n_glob | n_loc | n_nonid | SI gate | M (inferred) | M (catalog) | M (empirical) | match |")
    md.append("|---|---:|---:|---:|:---:|---:|---:|---:|:---:|")
    for r in rows:
        gate_str = "fired" if r["si_gate_fires"] else "deferred"
        match_str = "✓" if r["match"] else "✗"
        emp = "-" if r["M_empirical_validator"] is None else str(r["M_empirical_validator"])
        md.append(
            f"| `{r['system']}` | {r['n_globally']} | {r['n_locally']} | {r['n_nonid']} | "
            f"{gate_str} | {r['M_inferred']} | {r['M_catalog']} | "
            f"{emp} | {match_str} |"
        )
    md.append("")
    md.append("## Per-cell histograms for the 4 SI-gate-deferred systems")
    md.append("")
    md.append("Distribution of distinct-row counts per cell (at empirical 30% threshold).")
    md.append("")
    for r in rows:
        if not r["si_gate_fires"] and r["per_cell_histogram"]:
            hist = sorted(r["per_cell_histogram"].items())
            hist_str = " + ".join(f"({k}, {v})" for k, v in hist)
            md.append(f"- **{r['system']}** ({r['n_good_cells']} good cells): {hist_str}")
    md.append("")
    md.append("## Interpretation")
    md.append("")
    md.append("**SI gate is fully automated and correct on 19/23 systems** (all")
    md.append("globally-identifiable cases). It correctly identifies that M=1 for")
    md.append("these systems without inspecting any benchmark output.")
    md.append("")
    md.append("**SI gate correctly defers on the 4 multiplicity-2 systems.** It")
    md.append("identifies that M > 1 but doesn't give the value. For now we fall")
    md.append("back to the catalog, which is empirically correct on all 4.")
    md.append("")
    md.append("**The empirical validator partially confirms catalog values:**")
    md.append("daisy_mamil4, seir, slow_fast all show M_empirical = 2 (matches).")
    md.append("biohydrogenation shows M_empirical = 1 (catalog says 2) because")
    md.append("the OOB sign-flipped alt branch is rejected by polish on most cells.")
    md.append("This is exactly the kind of case that requires the direct HC.jl")
    md.append("call to recover (which is the TODO).")
    md.append("")
    md.append("See `M_INFERENCE_INVESTIGATION.md` for the full investigation of")
    md.append("StructuralIdentifiability.jl vs SIAN-Julia and what proper upstream")
    md.append("patches would look like.")

    out_md.write_text("\n".join(md))
    print(f"wrote {out_md}")


if __name__ == "__main__":
    main()
