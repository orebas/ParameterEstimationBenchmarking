#!/usr/bin/env python3
"""
Winner-provenance extractor for the final_v2 benchmark, POLISH arm only.

One tidy row per cell -> winner_provenance.csv, recording where the WINNING
solution came from (interpolator, shooting timepoint, single/multi/aggregate,
rescue/fallback) + top-1 recovery vs ground truth.

Winners only BY DESIGN: one observation per cell. The full candidate pool and the
selection/return mechanism are a separate follow-up.

Provenance source (recorded per row as `provenance_source`):
  - "metadata": odepe_metadata.json["best"]  (preferred; richest)
  - "pool": ~1/3 of cells have a 0-byte metadata.json, so we recover the winner's
    provenance by exact-matching the result.csv winner into pool.csv (dist 0.0) and
    reading the SAME provenance columns. Avoids silently dropping whole systems
    (flexible_arm, most of hiv/cstr) and the upward recovery bias that would cause.
  - "none": no result.csv at all (1 cell).

Structural unidentifiability is derived empirically (>=50% of a system's
metadata winners flag a var -> structural), mirroring build_manifest.py, so recovery
lines up with the paper (instances' own non_identifiable field is empty).

Read-only over the benchmark; writes only winner_provenance.csv next to itself.
"""
import csv
import glob
import json
import math
import os
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
B = "/home/orebas/ParameterEstimationBenchmark-local/benchmark_final_v2_2026-06-12"
FILETREE = os.path.join(B, "filetree")
ARM = "odepe_v2_polish_run"
OUT = os.path.join(HERE, "winner_provenance.csv")

NOISE_VAL = {"0": 0.0, "1em8": 1e-8, "1em6": 1e-6, "1em4": 1e-4, "1em2": 1e-2}
EPS = 1e-12
BETA = 3.0        # exponential shooting warp (compute_shooting_indices default)
N_SHOOT = 20      # n_shooting_points

INTERP_FAMILY = {
    "aaad": "AAA-rational", "aaad_gpr": "AAA-rational", "s2_aaa_mle": "AAA-rational",
    "agp_robust": "GP-robust", "agp_robust_rq": "GP-robust",
    "s3_adapt_se": "S3-composite", "s3_adapt_rq": "S3-composite",
    "chebyshev_aicc": "Chebyshev", "chebyshev_bic": "Chebyshev",
}
CONFIGURED_INTERPOLATORS = sorted(INTERP_FAMILY)
RESULT_META_COLS = {"post_polish_error", "err", "branch_size", "polish_source_hc_idx"}


def norm_var(name):
    s = str(name)
    return s[:-3] if s.endswith("(t)") else s


def load_json(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None


def load_wall(cell_dir):
    try:
        return float(open(os.path.join(cell_dir, "wall_time_seconds.txt")).read().split()[0])
    except Exception:
        return ""


def load_result(cell_dir):
    try:
        rows = list(csv.reader(open(os.path.join(cell_dir, "result.csv"))))
    except FileNotFoundError:
        return None, None
    if len(rows) < 2:
        return (rows[0] if rows else None), None
    return rows[0], rows[1]


def split_noise(cell_id):
    parts = cell_id.rsplit("_", 2)
    return (parts[0], parts[1], parts[2]) if len(parts) == 3 else (cell_id, "", "")


def shooting_grid(count):
    """compute_shooting_indices(20, count, warp=true, beta=3): 1-based data-grid indices."""
    if not count or count < 2:
        return []
    denom = math.exp(BETA) - 1.0
    return sorted({1 + round((math.exp(BETA * (i / (N_SHOOT - 1))) - 1.0) / denom * (count - 1))
                   for i in range(N_SHOOT)})


def shoot_features(idx, inst):
    """(norm_pos in [0,1], t, rank-of-20) for a 1-based shooting index."""
    t = inst.get("time", {}) or {}
    count, start, end = t.get("count"), t.get("start"), t.get("end")
    if idx is None or not count or start is None or end is None:
        return "", "", ""
    norm = float(idx) / float(count)
    tval = start + norm * (end - start)
    grid = shooting_grid(count)
    rank = (1 + min(range(len(grid)), key=lambda k: abs(grid[k] - idx))) if grid else ""
    return round(norm, 4), round(tval, 4), rank


def recovery(rh, rr, inst, structural):
    """Top-1 max abs-rel error over identifiable params+states; (max_rel, n_scored)."""
    if rr is None:
        return "", 0
    col = {norm_var(n): i for i, n in enumerate(rh)}
    truth = {}
    truth.update(inst.get("parameter_values", {}) or {})
    truth.update(inst.get("state_values", {}) or {})
    worst, n = None, 0
    for vname, tval in truth.items():
        v = norm_var(vname)
        if v in structural or v not in col:
            continue
        try:
            est = float(rr[col[v]])
        except (ValueError, IndexError):
            continue
        if not math.isfinite(est):
            continue
        rel = abs(est - float(tval)) / max(abs(float(tval)), EPS)
        worst = rel if worst is None else max(worst, rel)
        n += 1
    return (worst if worst is not None else ""), n


def prov_from_metadata(best):
    mti = best.get("multipoint_time_indices")
    return {
        "provenance_source": "metadata",
        "interpolator_source": best.get("interpolator_source"),
        "source_type": best.get("source_type"),
        "source_shooting_index": best.get("source_shooting_index"),
        "rescue_path": best.get("rescue_path") or "none",
        "primary_method": best.get("primary_method"),
        "was_terminal_fallback": bool(best.get("was_terminal_fallback")),
        "aggregation_strategy": best.get("aggregation_strategy"),
        "multipoint_n_times": len(mti) if isinstance(mti, list) else "",
        "practical_identifiability_status": best.get("practical_identifiability_status"),
        "n_unident": len(best.get("all_unidentifiable", []) or []),
        "n_structural_fix": len(best.get("structural_fix_set", {}) or {}),
        "n_representative": len(best.get("representative_assignments", {}) or {}),
        "n_eqs_dropped": len(best.get("equations_dropped_by_rank_trimming", []) or []),
    }


def prov_from_pool(cell_dir, rd):
    """Recover winner provenance by exact-matching the result.csv winner into pool.csv."""
    try:
        pool = list(csv.reader(open(os.path.join(cell_dir, "pool.csv"))))
    except FileNotFoundError:
        return None
    if len(pool) < 2:
        return None
    pi = {n: i for i, n in enumerate(pool[0])}
    params = [k for k in rd if k not in RESULT_META_COLS and not k.endswith("(t)") and "p_" + k in pi]
    if not params:
        return None
    best = None
    for row in pool[1:]:
        try:
            d = sum(abs(float(row[pi["p_" + p]]) - float(rd[p])) for p in params)
        except Exception:
            continue
        if best is None or d < best[0]:
            best = (d, row)
    if best is None or best[0] > 1e-4:
        return None
    row = best[1]

    def g(k):
        return row[pi[k]] if (k in pi and row[pi[k]] not in ("", "NA")) else None
    rescue = g("rescue_path") or "none"
    primary = g("primary_method")
    ssi = g("source_shooting_index")
    return {
        "provenance_source": "pool",
        "interpolator_source": g("interpolator_source"),
        "source_type": g("source_type"),
        "source_shooting_index": int(float(ssi)) if ssi else None,
        "rescue_path": rescue,
        "primary_method": primary,
        "was_terminal_fallback": (rescue == "direct_opt_fallback") or (primary == "direct_opt"),
        "aggregation_strategy": g("aggregation_strategy"),
        "multipoint_n_times": "",
        "practical_identifiability_status": "",
        "n_unident": "", "n_structural_fix": "", "n_representative": "", "n_eqs_dropped": "",
    }


BLANK_PROV = {k: "" for k in (
    "interpolator_source", "source_type", "source_shooting_index", "rescue_path",
    "primary_method", "was_terminal_fallback", "aggregation_strategy", "multipoint_n_times",
    "practical_identifiability_status", "n_unident", "n_structural_fix", "n_representative",
    "n_eqs_dropped")}


def winner_kind(prov):
    if prov.get("was_terminal_fallback") in (True, "True"):
        return "direct_opt_fallback"
    return prov.get("source_type") or "(unknown)"


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return ""


FIELDS = [
    "cell_id", "system", "rep", "noise_mnem", "noise_val", "provenance_source",
    "status", "raw_count", "best_count", "besterror", "winner_err", "branch_size",
    "winner_kind", "primary_method", "interpolator_source", "interpolator_family",
    "source_type", "rescue_path", "was_terminal_fallback",
    "source_shooting_index", "shoot_norm", "shoot_t", "shoot_rank20",
    "multipoint_n_times", "aggregation_strategy", "practical_identifiability_status",
    "n_structural_fix", "n_representative", "n_eqs_dropped", "n_unident",
    "wall_time_s", "n_scored", "max_rel_err", "recovered_1pct", "recovered_10pct",
]


def main():
    insts = {i["id"]: i for i in load_json(f"{B}/huge_json.json")["instances"]}
    cells = sorted(c for c in glob.glob(os.path.join(FILETREE, ARM, "*")) if os.path.isdir(c))

    # PASS 1: per-system structural unidentifiable consensus (>=50% of *metadata* winners)
    flag = defaultdict(lambda: defaultdict(int))
    total = defaultdict(int)
    for cd in cells:
        inst = insts.get(os.path.basename(cd))
        md = load_json(os.path.join(cd, "odepe_metadata.json"))
        if inst and md and isinstance(md.get("best"), dict):
            total[inst["name"]] += 1
            for v in md["best"].get("all_unidentifiable", []) or []:
                flag[inst["name"]][norm_var(v)] += 1
    structural = {s: {v for v, c in fv.items() if c >= 0.5 * total[s]} for s, fv in flag.items()}
    print("structural consensus:", {s: sorted(v) for s, v in structural.items() if v})

    # PASS 2: one winner row per cell (metadata -> pool fallback -> none)
    rows, src_count = [], defaultdict(int)
    for cd in cells:
        cell = os.path.basename(cd)
        inst = insts.get(cell)
        if not inst:
            continue
        system, rep, noise = split_noise(cell)
        system = inst.get("name", system)
        rh, rr = load_result(cd)
        rd = dict(zip(rh, rr)) if rr else {}
        md = load_json(os.path.join(cd, "odepe_metadata.json"))

        if md and isinstance(md.get("best"), dict) and md["best"]:
            prov = prov_from_metadata(md["best"])
            cell_lvl = {"status": md.get("status"), "raw_count": md.get("raw_count"),
                        "best_count": md.get("best_count"), "besterror": md.get("besterror")}
        else:
            prov = prov_from_pool(cd, rd) if rr else None
            cell_lvl = {"status": "", "raw_count": "", "best_count": "", "besterror": ""}
            if prov is None:
                prov = {"provenance_source": "none", **BLANK_PROV}
        src_count[prov["provenance_source"]] += 1

        ssi = prov.get("source_shooting_index")
        ssi = int(ssi) if isinstance(ssi, (int, float)) and ssi != "" else (
            int(float(ssi)) if isinstance(ssi, str) and ssi else None)
        norm, tval, rank = shoot_features(ssi, inst)
        interp = prov.get("interpolator_source")
        max_rel, n_scored = recovery(rh, rr, inst, structural.get(system, set()))

        rows.append({
            "cell_id": cell, "system": system, "rep": rep,
            "noise_mnem": noise, "noise_val": NOISE_VAL.get(noise, ""),
            "provenance_source": prov["provenance_source"],
            "status": cell_lvl["status"], "raw_count": cell_lvl["raw_count"],
            "best_count": cell_lvl["best_count"], "besterror": cell_lvl["besterror"],
            "winner_err": num(rd.get("err")), "branch_size": num(rd.get("branch_size")),
            "winner_kind": winner_kind(prov), "primary_method": prov.get("primary_method"),
            "interpolator_source": interp if interp else "(null)",
            "interpolator_family": INTERP_FAMILY.get(interp, "(none: aggregate/fallback)"),
            "source_type": prov.get("source_type"), "rescue_path": prov.get("rescue_path"),
            "was_terminal_fallback": prov.get("was_terminal_fallback"),
            "source_shooting_index": ssi if ssi is not None else "",
            "shoot_norm": norm, "shoot_t": tval, "shoot_rank20": rank,
            "multipoint_n_times": prov.get("multipoint_n_times"),
            "aggregation_strategy": prov.get("aggregation_strategy"),
            "practical_identifiability_status": prov.get("practical_identifiability_status"),
            "n_structural_fix": prov.get("n_structural_fix"),
            "n_representative": prov.get("n_representative"),
            "n_eqs_dropped": prov.get("n_eqs_dropped"), "n_unident": prov.get("n_unident"),
            "wall_time_s": load_wall(cd), "n_scored": n_scored,
            "max_rel_err": ("%.6g" % max_rel) if max_rel != "" else "",
            "recovered_1pct": (1 if (max_rel != "" and max_rel < 0.01) else 0) if max_rel != "" else "",
            "recovered_10pct": (1 if (max_rel != "" and max_rel < 0.10) else 0) if max_rel != "" else "",
        })

    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    print("wrote", OUT, "rows:", len(rows))
    print("provenance_source:", dict(src_count))


if __name__ == "__main__":
    main()
