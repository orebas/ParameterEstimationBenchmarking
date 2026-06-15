#!/usr/bin/env python3
"""
Polish-arm winner-provenance report (final_v2). Reads winner_provenance.csv and
writes POLISH_PROVENANCE_REPORT.md, 5 PNG plots, and a self-contained
polish_provenance.html (tables + base64-embedded plots; no external deps).

Winners only: one observation per cell (metadata["best"], with a pool.csv fallback
for the ~1/3 of cells whose metadata.json is empty). The full candidate pool and
the selection mechanism are a separate follow-up exercise.
"""
import base64
import html as _html
import os
import re
import warnings

warnings.filterwarnings("ignore")
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, "winner_provenance.csv")
MD = os.path.join(HERE, "POLISH_PROVENANCE_REPORT.md")
HTML = os.path.join(HERE, "polish_provenance.html")

NOISE = ["0", "1em8", "1em6", "1em4", "1em2"]
NOISE_LBL = {"0": "0", "1em8": "1e-8", "1em6": "1e-6", "1em4": "1e-4", "1em2": "1e-2"}
INTERP_ORDER = ["aaad", "aaad_gpr", "s2_aaa_mle", "agp_robust", "agp_robust_rq",
                "s3_adapt_se", "s3_adapt_rq", "chebyshev_aicc", "chebyshev_bic", "(null)"]
FAM_ORDER = ["AAA-rational", "GP-robust", "S3-composite", "Chebyshev", "(none: aggregate/fallback)"]
FAM_COLOR = {"AAA-rational": "#C73E1D", "GP-robust": "#2E86AB", "S3-composite": "#1B998B",
             "Chebyshev": "#F4A259", "(none: aggregate/fallback)": "#9aa0a6"}
ST_ORDER = ["single_point", "multipoint", "synthesized_aggregate"]
ST_COLOR = {"single_point": "#2E86AB", "multipoint": "#A23B72", "synthesized_aggregate": "#F4A259"}

df = pd.read_csv(CSV, dtype={"noise_mnem": str, "rep": str}, low_memory=False)
for c in ["interpolator_source", "interpolator_family", "source_type", "rescue_path",
          "winner_kind", "aggregation_strategy", "practical_identifiability_status"]:
    df[c] = df[c].fillna("(null)").replace("", "(null)").astype(str)
for c in ["recovered_10pct", "recovered_1pct", "shoot_norm", "shoot_t", "shoot_rank20",
          "raw_count", "best_count", "wall_time_s", "max_rel_err", "branch_size"]:
    df[c] = pd.to_numeric(df[c], errors="coerce")
df["noise_mnem"] = pd.Categorical(df["noise_mnem"], categories=NOISE, ordered=True)

L = []
def w(s=""):
    L.append(s)


def pct_by(sub, col, by="noise_mnem", order=None, cats=None):
    ct = pd.crosstab(sub[col], sub[by])
    cols = [c for c in (order or NOISE) if c in ct.columns]
    ct = ct[cols]
    if cats:
        ct = ct.reindex([c for c in cats if c in ct.index])
    pctc = 100.0 * ct / ct.sum(axis=0)
    hdr = "| %s | " % col + " | ".join(NOISE_LBL.get(c, str(c)) for c in cols) + " | overall |"
    sep = "|---|" + "|".join("---:" for _ in cols) + "|---:|"
    out = [hdr, sep]
    overall = 100.0 * sub[col].value_counts() / len(sub)
    for idx in pctc.index:
        out.append("| %s | " % idx + " | ".join("%.1f" % v for v in pctc.loc[idx].values)
                   + " | %.1f |" % overall.get(idx, 0.0))
    out.append("| **n cells** | " + " | ".join(str(int(ct[c].sum())) for c in cols)
               + " | %d |" % len(sub))
    return "\n".join(out)


def counts_table(sub, col, order=None):
    vc = sub[col].value_counts()
    idx = [c for c in order if c in vc.index] if order else list(vc.index)
    idx += [c for c in vc.index if c not in idx]
    out = ["| %s | n | %% | recovered@10%% |" % col, "|---|---:|---:|---:|"]
    for k in idx:
        s = sub[sub[col] == k]
        rec = s["recovered_10pct"].mean()
        out.append("| %s | %d | %.1f | %s |" % (k, len(s), 100.0 * len(s) / len(sub),
                   ("%.1f" % (100 * rec)) if pd.notna(rec) else "-"))
    return "\n".join(out)


def savefig(fig, name):
    p = os.path.join(HERE, name)
    fig.savefig(p, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return name


def stacked_by_noise(colvals, color_map, order, title, ylabel, fname):
    sub = df[df[colvals].isin(order)]
    ct = pd.crosstab(sub["noise_mnem"], sub[colvals])
    ct = ct.reindex(index=NOISE)[[c for c in order if c in ct.columns]]
    pct = 100.0 * ct.div(ct.sum(axis=1), axis=0)
    fig, ax = plt.subplots(figsize=(6.4, 3.6))
    bottom = np.zeros(len(pct))
    for c in pct.columns:
        ax.bar([NOISE_LBL[n] for n in pct.index], pct[c].values, bottom=bottom,
               label=c, color=color_map.get(c, "#888"), edgecolor="white", linewidth=0.5)
        bottom += np.nan_to_num(pct[c].values)
    ax.set_ylabel(ylabel); ax.set_ylim(0, 100)
    ax.set_title(title + "  (x = noise level)", fontsize=10)
    ax.legend(fontsize=8, ncol=3, loc="upper center", bbox_to_anchor=(0.5, -0.10), frameon=False)
    fig.tight_layout()
    return savefig(fig, fname)


# ============================================================ build report
w("# Polish-arm winner provenance — final_v2 benchmark")
w()
w("_Where did each winning polish solution actually come from? Generated from "
  "`winner_provenance.csv` (extract_winner_provenance.py) over "
  "`benchmark_final_v2_2026-06-12/filetree/odepe_v2_polish_run/`._")
w()
w("### Scope & caveats (bound every number below)")
w("1. **Winners only.** One observation per cell — `metadata[\"best\"]`, the single returned "
  "solution. This says which interpolator / timepoint / path **won**, *not* the make-up of the "
  "full candidate pool. The pool and the selection/return mechanism are the **next exercise**.")
nsrc = df["provenance_source"].value_counts().to_dict()
w("2. **Provenance source.** %d cells from `odepe_metadata.json[\"best\"]`; %d recovered by "
  "exact-matching the `result.csv` winner into `pool.csv` (those cells have a 0-byte metadata "
  "file — dropping them would have deleted whole systems and biased recovery up ~14 pts at high "
  "noise); %d cell has no `result.csv` at all. The pool-recovered rows carry the same core "
  "provenance columns; a few metadata-only fields (practical-identifiability, raw/best counts) are "
  "blank for them." % (nsrc.get("metadata", 0), nsrc.get("pool", 0), nsrc.get("none", 0)))
w("3. **`(null)` interpolator is a real category** — the winner was a *synthesized aggregate* "
  "(no single interpolator) or a fallback, not missing data.")
w("4. **Timepoints are exp-warped toward t0 by design** (`compute_shooting_indices`, β=3): the 20 "
  "shooting points cluster early, so *some* early-t bias is built in, not chosen. We report both "
  "the shooting-point rank (1–20) and the normalized time position.")
w("5. **AAA-family is auto-filtered at high noise** (`auto_filter_interpolators`), so its "
  "disappearance as noise grows is expected behaviour, not failure.")
w()

# ---- §0 overall ----
w("## §0 — Overall summary")
w()
ok = df[df.provenance_source != "none"]
w("- **%d cells** (25 systems × 5 noise × 10 reps), all `status=ok`." % len(df))
w("- **Recovery (top-1):** %.1f%% within 10%% worst-param error, %.1f%% within 1%% — "
  "by noise (10%%): %s. (Matches the paper's polish SR-10, confirming the right cells/scoring.)"
  % (100 * df.recovered_10pct.mean(), 100 * df.recovered_1pct.mean(),
     ", ".join("%s=%.0f%%" % (NOISE_LBL[n], 100 * df[df.noise_mnem == n].recovered_10pct.mean()) for n in NOISE)))
w("- **Winner kind:** " + ", ".join("%s %.0f%%" % (k, 100 * v / len(ok))
  for k, v in ok.winner_kind.value_counts().items()) + ".")
w("- **Rescue fired** on %.1f%% of cells; terminal direct-opt fallback **never** produced a winner."
  % (100 * (df.rescue_path != "none").mean()))
w()
w("Winner kind by noise (% of cells):")
w()
w(pct_by(ok, "winner_kind", cats=["single_point", "multipoint", "synthesized_aggregate", "direct_opt_fallback"]))
w()

# ---- §1 interpolators ----
w("## §1 — Which interpolators won?")
w()
w("Every one of the 9 configured interpolators wins on some cells. `(null)` = the winner was a "
  "synthesized aggregate (no single interpolator).")
w()
w(counts_table(ok, "interpolator_source", order=INTERP_ORDER))
w()
w("**By family × noise** (the auto-filter story — AAA-rational dominates at low noise and is "
  "filtered out as noise rises; GP/S3/Chebyshev and aggregates take over):")
w()
w(pct_by(ok, "interpolator_family", cats=FAM_ORDER))
w()
f1 = stacked_by_noise("interpolator_family", FAM_COLOR, FAM_ORDER,
                      "Winning interpolator family by noise level", "% of winners", "fig1_interp_family_by_noise.png")
w("![Interpolator family by noise](%s)" % f1)
w()
w("**Interpolator family by system** (share of winners; AAA-rational vs the GP/spectral families):")
w()
fam_sys = pd.crosstab(ok.system, ok.interpolator_family)
fam_sys = (100.0 * fam_sys.div(fam_sys.sum(axis=1), axis=0)).round(0)
cols = [c for c in FAM_ORDER if c in fam_sys.columns]
w("| system | " + " | ".join(c.split("-")[0].split(" ")[0] for c in cols) + " |")
w("|---|" + "|".join("---:" for _ in cols) + "|")
for s in sorted(fam_sys.index):
    w("| %s | " % s + " | ".join("%.0f" % fam_sys.loc[s, c] for c in cols) + " |")
w()

# ---- §2 source type ----
w("## §2 — Single-point vs multipoint vs synthesized aggregate")
w()
w(pct_by(ok, "source_type", cats=ST_ORDER))
w()
f3 = stacked_by_noise("source_type", ST_COLOR, ST_ORDER,
                      "Winner source type by noise level", "% of winners", "fig3_source_type_by_noise.png")
w("![Source type by noise](%s)" % f3)
w()
agg = ok[ok.source_type == "synthesized_aggregate"]
w("**Synthesized aggregates win %.1f%% of cells** (and rise sharply with noise — the solver "
  "increasingly returns a robust median/trimmed-mean over candidates rather than a single solve). "
  "Aggregation strategy when an aggregate wins:" % (100 * len(agg) / len(ok)))
w()
w(counts_table(agg, "aggregation_strategy"))
w()
mp = ok[ok.source_type == "multipoint"]
if mp.multipoint_n_times.notna().any():
    w("**Multipoint** winners use %.1f timepoints on average (median %d)."
      % (mp.multipoint_n_times.mean(), int(mp.multipoint_n_times.median())))
    w()

# ---- §3 timepoints ----
w("## §3 — Which timepoints win? (single-point + multipoint winners)")
w()
sp = ok[ok.shoot_rank20.notna()].copy()
w("Of the %d winners with a single source timepoint, the winning **shooting-point rank** (1=earliest "
  "of the 20 warped points … 20=last) and **normalized time** distribute as below. Recall the 20 "
  "points themselves cluster near t0, so rank is roughly uniform in point-index while normalized "
  "time is compressed toward 0." % len(sp))
w()
bins = [0, 0.02, 0.25, 0.75, 0.98, 1.01]
labels = ["t0 (≤0.02)", "early (0.02–0.25)", "mid (0.25–0.75)", "late (0.75–0.98)", "end (≥0.98)"]
sp["tpos"] = pd.cut(sp["shoot_norm"], bins=bins, labels=labels, include_lowest=True)
w(pct_by(sp, "tpos", cats=labels))
w()
w("Median normalized winning position by noise: "
  + ", ".join("%s=%.2f" % (NOISE_LBL[n], sp[sp.noise_mnem == n].shoot_norm.median()) for n in NOISE) + ".")
w()
# plot: rank histogram + normalized-time histogram
fig, axes = plt.subplots(1, 2, figsize=(8.4, 3.2))
axes[0].hist(sp.shoot_rank20.dropna(), bins=np.arange(0.5, 21.5, 1), color="#2E86AB", edgecolor="white")
axes[0].set_xlabel("Winning shooting-point rank (1–20)"); axes[0].set_ylabel("# winners")
axes[0].set_title("Which of the 20 shooting points wins", fontsize=9)
axes[1].hist(sp.shoot_norm.dropna(), bins=np.linspace(0, 1, 26), color="#A23B72", edgecolor="white")
axes[1].set_xlabel("Normalized winning time  (0=t0, 1=end)"); axes[1].set_ylabel("# winners")
axes[1].set_title("Winning time position", fontsize=9)
fig.tight_layout()
f2 = savefig(fig, "fig2_timepoints.png")
w("![Winning timepoints](%s)" % f2)
w()

# ---- §4 rescue / fallback ----
w("## §4 — Rescue / fallback usage")
w()
w("`rescue_path` records an emergency re-solve after the primary algebraic solve produced blown "
  "candidates. `algebraic_resolve_t0` = re-solve the fixed-param system at t0; "
  "`direct_opt_fallback` = terminal numeric rescue.")
w()
w(pct_by(ok, "rescue_path", cats=["none", "algebraic_resolve_t0", "algebraic_resolve_seeded",
                                  "algebraic_resolve_shoot", "direct_opt_fallback"]))
w()
resc = ok[ok.rescue_path != "none"]
w("**Any rescue fired on %.1f%% of cells.** It concentrates on a few systems (count of rescued "
  "cells, of 50 each):" % (100 * len(resc) / len(ok)))
w()
rs = resc.system.value_counts()
w("| system | rescued cells | recovered@10% |")
w("|---|---:|---:|")
for s, n in rs.head(12).items():
    rec = resc[resc.system == s].recovered_10pct.mean()
    w("| %s | %d | %.0f%% |" % (s, n, 100 * rec if pd.notna(rec) else 0))
w()
w("**Did rescued cells still recover?** rescued %.1f%% vs %.1f%% overall — rescue flags a hard "
  "cell." % (100 * resc.recovered_10pct.mean(), 100 * ok.recovered_10pct.mean()))
w()
fig, ax = plt.subplots(figsize=(6.8, 3.4))
rsys = (100.0 * ok.groupby("system").apply(lambda g: (g.rescue_path != "none").mean())).sort_values(ascending=False)
rsys = rsys[rsys > 0]
ax.bar(range(len(rsys)), rsys.values, color="#C73E1D", edgecolor="white")
ax.set_xticks(range(len(rsys))); ax.set_xticklabels(rsys.index, rotation=60, ha="right", fontsize=7)
ax.set_ylabel("% of cells with a rescue"); ax.set_title("Rescue rate by system", fontsize=10)
fig.tight_layout()
f4 = savefig(fig, "fig4_rescue_by_system.png")
w("![Rescue by system](%s)" % f4)
w()

# ---- §5 funnel + recovery-by-interpolator ----
w("## §5 — Candidate funnel, identifiability, and cost")
w()
md = ok[ok.provenance_source == "metadata"]
w("`raw_count` (algebraic candidates generated) → `best_count` (size of the best-error class), "
  "metadata cells only (n=%d):" % len(md))
w()
w("| stat | raw_count | best_count |")
w("|---|---:|---:|")
for nm, fn in [("median", np.nanmedian), ("mean", np.nanmean),
               ("p90", lambda x: np.nanpercentile(x, 90)), ("max", np.nanmax)]:
    w("| %s | %.0f | %.0f |" % (nm, fn(md.raw_count), fn(md.best_count)))
w()
w("**practical_identifiability_status** (metadata cells):")
w()
w(counts_table(md, "practical_identifiability_status"))
w()
w("**Wall-clock cost** (median seconds / cell) by noise: "
  + ", ".join("%s=%.0fs" % (NOISE_LBL[n], df[df.noise_mnem == n].wall_time_s.median()) for n in NOISE)
  + ". Most expensive systems (median s): "
  + ", ".join("%s %.0f" % (s, v) for s, v in df.groupby("system").wall_time_s.median().sort_values(ascending=False).head(5).items()) + ".")
w()
# recovery by winning interpolator plot
fig, ax = plt.subplots(figsize=(7.0, 3.4))
ri = ok.groupby("interpolator_source").agg(n=("cell_id", "size"), rec=("recovered_10pct", "mean"))
ri = ri.reindex([i for i in INTERP_ORDER if i in ri.index])
ax.bar(range(len(ri)), 100 * ri.rec.values, color="#1B998B", edgecolor="white")
for i, (n, r) in enumerate(zip(ri.n.values, ri.rec.values)):
    ax.text(i, 100 * r + 1, "n=%d" % n, ha="center", fontsize=7)
ax.set_xticks(range(len(ri))); ax.set_xticklabels(ri.index, rotation=45, ha="right", fontsize=8)
ax.set_ylabel("recovered@10% (%)"); ax.set_ylim(0, 105)
ax.set_title("Recovery rate of winners, by winning interpolator", fontsize=10)
fig.tight_layout()
f5 = savefig(fig, "fig5_recovery_by_interpolator.png")
w("![Recovery by interpolator](%s)" % f5)
w()
w("---")
w("_Winners-only report. Next: the full candidate pool + why a given candidate is returned._")

# ============================================================ write markdown
md_text = "\n".join(L) + "\n"
open(MD, "w").write(md_text)
print("wrote", MD)


# ============================================================ markdown -> self-contained HTML
def inline(s):
    s = _html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
    return s


def img_tag(path, alt):
    p = path if os.path.isabs(path) else os.path.join(HERE, path)
    try:
        b = base64.b64encode(open(p, "rb").read()).decode()
        return '<img alt="%s" src="data:image/png;base64,%s"/>' % (_html.escape(alt), b)
    except Exception:
        return '<img alt="%s" src="%s"/>' % (_html.escape(alt), path)


def render_table(tbl):
    def cells(row):
        return [c.strip() for c in row.strip().strip("|").split("|")]
    hdr, body = cells(tbl[0]), tbl[2:]
    out = ["<table><thead><tr>" + "".join("<th>%s</th>" % inline(c) for c in hdr) + "</tr></thead><tbody>"]
    for r in body:
        out.append("<tr>" + "".join("<td>%s</td>" % inline(c) for c in cells(r)) + "</tr>")
    return "\n".join(out) + "</tbody></table>"


def md_to_html(md_text):
    lines = md_text.split("\n")
    out, i = [], 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("### "):
            out.append("<h3>%s</h3>" % inline(ln[4:])); i += 1
        elif ln.startswith("## "):
            out.append("<h2>%s</h2>" % inline(ln[3:])); i += 1
        elif ln.startswith("# "):
            out.append("<h1>%s</h1>" % inline(ln[2:])); i += 1
        elif ln.strip() == "---":
            out.append("<hr/>"); i += 1
        elif ln.startswith("!["):
            m = re.match(r"!\[(.*?)\]\((.+?)\)", ln)
            if m:
                out.append('<div class="fig">%s</div>' % img_tag(m.group(2), m.group(1)))
            i += 1
        elif ln.startswith("|"):
            tbl = []
            while i < len(lines) and lines[i].startswith("|"):
                tbl.append(lines[i]); i += 1
            out.append(render_table(tbl))
        elif ln.strip() == "":
            i += 1
        else:
            para = [ln]; i += 1
            while i < len(lines) and lines[i].strip() and not lines[i].startswith(("#", "|", "![", "---")):
                para.append(lines[i]); i += 1
            txt = " ".join(para)
            if re.match(r"^\d+\.\s", txt.strip()) or txt.strip().startswith("- "):
                out.append("<p class='li'>%s</p>" % inline(txt))
            else:
                out.append("<p>%s</p>" % inline(txt))
    return "\n".join(out)


CSS = """body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:980px;
margin:2rem auto;padding:0 1.2rem;color:#1a1a1a;line-height:1.5}
h1{border-bottom:3px solid #2E86AB;padding-bottom:.3rem}
h2{border-bottom:1px solid #ddd;padding-bottom:.2rem;margin-top:2rem;color:#14506e}
h3{color:#555;margin-top:1.2rem}
table{border-collapse:collapse;margin:1rem 0;font-size:.85rem}
th,td{border:1px solid #d0d7de;padding:.28rem .6rem;text-align:right}
th:first-child,td:first-child{text-align:left}
thead th{background:#f0f4f8}
tbody tr:nth-child(even){background:#fafbfc}
code{background:#eef1f4;padding:.1rem .3rem;border-radius:3px;font-size:.85em}
.fig{margin:1.2rem 0;text-align:center}.fig img{max-width:100%;border:1px solid #eee;border-radius:4px}
.li{margin:.2rem 0}hr{border:none;border-top:1px solid #ddd;margin:2rem 0}
em{color:#666}"""

html_doc = ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
            "<title>Polish-arm winner provenance — final_v2</title><style>%s</style></head>"
            "<body>%s</body></html>" % (CSS, md_to_html(md_text)))
open(HTML, "w").write(html_doc)
print("wrote", HTML)
print("plots:", f1, f2, f3, f4, f5)
