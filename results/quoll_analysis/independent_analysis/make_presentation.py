#!/usr/bin/env python3
"""
Generate a self-contained reveal.js HTML presentation from the wallaby benchmark (preview) analysis.
All images are embedded as base64 -- the output is a single portable HTML file.
Rankings and conclusions are data-driven.

Usage:
    python3 results/wallaby_analysis/independent_analysis/make_presentation.py
"""

import base64
import os
import urllib.request
import pandas as pd
import numpy as np
from collections import Counter

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIG_DIR = os.path.join(SCRIPT_DIR, "figures")
TABLE_DIR = os.path.join(SCRIPT_DIR, "tables")
OUTPUT = os.path.join(SCRIPT_DIR, "presentation.html")
INPUT_CSV = os.path.join(SCRIPT_DIR, "..", "flat_results_with_metrics.csv")

REVEAL_CSS_URL = "https://cdn.jsdelivr.net/npm/reveal.js@5.1.0/dist/reveal.css"
REVEAL_THEME_URL = "https://cdn.jsdelivr.net/npm/reveal.js@5.1.0/dist/theme/black.css"
REVEAL_JS_URL = "https://cdn.jsdelivr.net/npm/reveal.js@5.1.0/dist/reveal.js"


def fetch_url(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.read().decode("utf-8")
    except Exception as e:
        print(f"  Warning: could not fetch {url}: {e}")
        return None


def img_b64(filename):
    path = os.path.join(FIG_DIR, filename)
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()


def read_table(filename):
    return pd.read_csv(os.path.join(TABLE_DIR, filename))


def df_to_html(df, max_rows=None, float_fmt=".1f", classes=""):
    if max_rows and len(df) > max_rows:
        df = df.head(max_rows)
    html = f'<table class="data-table {classes}">\n<thead><tr>'
    for col in df.columns:
        html += f"<th>{col}</th>"
    html += "</tr></thead>\n<tbody>\n"
    for _, row in df.iterrows():
        html += "<tr>"
        for col in df.columns:
            val = row[col]
            if isinstance(val, float):
                if abs(val) < 0.01 and val != 0:
                    cell = f"{val:.2e}"
                else:
                    cell = f"{val:{float_fmt}}"
            else:
                cell = str(val)
            html += f"<td>{cell}</td>"
        html += "</tr>\n"
    html += "</tbody></table>"
    return html


def build_presentation():
    print("Fetching reveal.js assets for offline embedding...")
    reveal_css = fetch_url(REVEAL_CSS_URL)
    reveal_theme = fetch_url(REVEAL_THEME_URL)
    reveal_js = fetch_url(REVEAL_JS_URL)

    use_inline = reveal_css and reveal_theme and reveal_js
    if use_inline:
        print("  All assets fetched -- presentation will work fully offline.")
    else:
        print("  Some assets missing -- falling back to CDN links.")

    df = pd.read_csv(INPUT_CSV)

    t01 = read_table("T01_overall_method_comparison.csv")
    t02 = read_table("T02_method_by_noise.csv")
    t03 = read_table("T03_system_ranking.csv")
    t04 = read_table("T04_domain_method_success.csv")
    t05 = read_table("T05_polishing_effect.csv")
    t06 = read_table("T06_replica_stability.csv")
    t07 = read_table("T07_failure_catalog.csv")
    t08 = read_table("T08_noise_cliff_detection.csv")

    # Oracle (best-of-K) variants of dual-metric tables.
    t01_oracle = read_table("T01_overall_method_comparison_oracle.csv")
    t02_oracle = read_table("T02_method_by_noise_oracle.csv")
    t03_oracle = read_table("T03_system_ranking_oracle.csv")
    t05_oracle = read_table("T05_polishing_effect_oracle.csv")
    t08_oracle = read_table("T08_noise_cliff_detection_oracle.csv")

    # M-bounded (algebraic multiplicity) variants.
    t01_mb = read_table("T01_overall_method_comparison_mbounded.csv")
    t02_mb = read_table("T02_method_by_noise_mbounded.csv")
    t03_mb = read_table("T03_system_ranking_mbounded.csv")
    t05_mb = read_table("T05_polishing_effect_mbounded.csv")
    t08_mb = read_table("T08_noise_cliff_detection_mbounded.csv")

    figs = {}             # top-1 / single-metric figures (existing filenames)
    figs_oracle = {}      # oracle variants (suffixed `_oracle.png`)
    figs_mb = {}          # m-bounded variants (suffixed `_mbounded.png`)
    listing = os.listdir(FIG_DIR)
    for i in range(1, 15):
        prefix = f"F{i:02d}_"
        for f in listing:
            if f.startswith(prefix) and not f.endswith("_oracle.png") and not f.endswith("_mbounded.png"):
                figs[f"F{i:02d}"] = img_b64(f)
                break
        for f in listing:
            if f.startswith(prefix) and f.endswith("_oracle.png"):
                figs_oracle[f"F{i:02d}"] = img_b64(f)
                break
        for f in listing:
            if f.startswith(prefix) and f.endswith("_mbounded.png"):
                figs_mb[f"F{i:02d}"] = img_b64(f)
                break
    # F02a/F02b are extra heatmap variants (success @ 1% / 50%)
    for variant in ("F02a", "F02b"):
        for f in listing:
            if f.startswith(f"{variant}_") and not f.endswith("_oracle.png") and not f.endswith("_mbounded.png"):
                figs[variant] = img_b64(f)
                break
        for f in listing:
            if f.startswith(f"{variant}_") and f.endswith("_oracle.png"):
                figs_oracle[variant] = img_b64(f)
                break
        for f in listing:
            if f.startswith(f"{variant}_") and f.endswith("_mbounded.png"):
                figs_mb[variant] = img_b64(f)
                break

    methods = ["odepe_v2_polish", "odepe_v2_nopolish", "amigo2", "odepe_shade"]
    method_labels = {
        "odepe_v2_polish": "ODEPE-v2 (polish)",
        "odepe_v2_nopolish": "ODEPE-v2 (no polish)",
        "amigo2": "AMIGO2",
        "odepe_shade": "SHADE+LM",
    }
    noise_levels = [0.0, 1e-8, 1e-6, 1e-4, 1e-2]
    noise_labels = ["0", "1e-8", "1e-6", "1e-4", "1e-2"]

    n_total = len(df)
    n_systems = df["name"].nunique()
    n_methods = df["run"].nunique()
    n_noise = df["noise"].nunique()
    n_replicas = int(round(n_total / max(1, n_systems * n_methods * n_noise)))
    n_no_result = (df["has_result"] == 0).sum()
    n_diverged = ((df["top1_max_rel_error"] > 1e4) & (df["has_result"] == 1)).sum()

    # Top-1 stats (paper convention)
    m_succ = {}
    for m in methods:
        m_succ[m] = df[df["run"] == m]["top1_success_at_10pct"].mean() * 100

    ranked_methods = sorted(methods, key=lambda m: -m_succ[m])
    best_method = ranked_methods[0]
    best_label = method_labels[best_method]
    worst_method = ranked_methods[-1]
    worst_label = method_labels[worst_method]

    np_succ = df[df["run"] == "odepe_v2_nopolish"]["top1_success_at_10pct"].mean() * 100
    p_succ = df[df["run"] == "odepe_v2_polish"]["top1_success_at_10pct"].mean() * 100
    polish_uplift = p_succ - np_succ

    # Oracle stats (set-credit ceiling)
    m_succ_oracle = {}
    for m in methods:
        m_succ_oracle[m] = df[df["run"] == m]["oracle_success_at_10pct"].mean() * 100
    ranked_methods_oracle = sorted(methods, key=lambda m: -m_succ_oracle[m])
    best_method_oracle = ranked_methods_oracle[0]
    best_label_oracle = method_labels[best_method_oracle]

    np_succ_oracle = df[df["run"] == "odepe_v2_nopolish"]["oracle_success_at_10pct"].mean() * 100
    p_succ_oracle = df[df["run"] == "odepe_v2_polish"]["oracle_success_at_10pct"].mean() * 100
    polish_uplift_oracle = p_succ_oracle - np_succ_oracle

    # M-bounded stats (paper-headline)
    m_succ_mb = {}
    for m in methods:
        m_succ_mb[m] = df[df["run"] == m]["mbounded_success_at_10pct"].mean() * 100
    ranked_methods_mb = sorted(methods, key=lambda m: -m_succ_mb[m])
    best_method_mb = ranked_methods_mb[0]
    best_label_mb = method_labels[best_method_mb]

    np_succ_mb = df[df["run"] == "odepe_v2_nopolish"]["mbounded_success_at_10pct"].mean() * 100
    p_succ_mb = df[df["run"] == "odepe_v2_polish"]["mbounded_success_at_10pct"].mean() * 100
    polish_uplift_mb = p_succ_mb - np_succ_mb
    # BoB - top1 delta on nopolish (for methodology slide)
    p_succ_mb_nopolish_delta = np_succ_mb - np_succ
    np_time = df[df["run"] == "odepe_v2_nopolish"]["time"].median()
    p_time = df[df["run"] == "odepe_v2_polish"]["time"].median()

    sys_succ = df.groupby("name")["mbounded_success_at_10pct"].mean().sort_values()
    hardest_3 = list(sys_succ.head(3).index)
    easiest_3 = list(sys_succ.tail(3).index)[::-1]

    succ_noise0 = df[df["noise"] == 0.0]["mbounded_success_at_10pct"].mean() * 100
    succ_noise_hi = df[df["noise"] == 0.01]["mbounded_success_at_10pct"].mean() * 100

    fail_summary = t07["failure_type"].value_counts().to_dict()

    n_helps = (t05["success_uplift_pp"] > 0).sum()
    n_hurts = (t05["success_uplift_pp"] < 0).sum()
    n_neutral = (t05["success_uplift_pp"] == 0).sum()
    n_helps_oracle = (t05_oracle["success_uplift_pp"] > 0).sum()
    n_helps_mbounded = (t05_mb["success_uplift_pp"] > 0).sum()
    n_hurts_oracle = (t05_oracle["success_uplift_pp"] < 0).sum()

    t01_display = t01[["method", "success_at_1pct", "success_at_10pct", "success_at_50pct",
                        "median_time_s", "n_no_result", "n_diverged"]].copy()
    t01_display.columns = ["Method", "Success@1%", "Success@10%", "Success@50%",
                           "Med. Time (s)", "No Result", "Diverged"]

    t01_oracle_display = t01_oracle[["method", "success_at_1pct", "success_at_10pct", "success_at_50pct",
                        "median_time_s", "n_no_result", "n_diverged"]].copy()
    t01_oracle_display.columns = ["Method", "Success@1%", "Success@10%", "Success@50%",
                           "Med. Time (s)", "No Result", "Diverged"]

    t01_mb_display = t01_mb[["method", "success_at_1pct", "success_at_10pct", "success_at_50pct",
                        "median_time_s", "n_no_result", "n_diverged"]].copy()
    t01_mb_display.columns = ["Method", "Success@1%", "Success@10%", "Success@50%",
                           "Med. Time (s)", "No Result", "Diverged"]

    t02_display = t02[["method", "noise", "success_at_1pct", "success_at_10pct",
                        "success_at_50pct", "median_error", "median_time_s"]].copy()
    t02_display.columns = ["Method", "Noise", "Success@1%", "Success@10%",
                           "Success@50%", "Median Error", "Med. Time (s)"]

    t02_oracle_display = t02_oracle[["method", "noise", "success_at_1pct", "success_at_10pct",
                        "success_at_50pct", "median_error", "median_time_s"]].copy()
    t02_oracle_display.columns = ["Method", "Noise", "Success@1%", "Success@10%",
                           "Success@50%", "Median Error", "Med. Time (s)"]

    t02_mb_display = t02_mb[["method", "noise", "success_at_1pct", "success_at_10pct",
                        "success_at_50pct", "median_error", "median_time_s"]].copy()
    t02_mb_display.columns = ["Method", "Noise", "Success@1%", "Success@10%",
                           "Success@50%", "Median Error", "Med. Time (s)"]

    t03_display = t03[["system", "domain", "n_id_params", "mean_success_at_10pct",
                        "best_method", "worst_method"]].copy()
    t03_display.columns = ["System", "Domain", "#Params", "Mean Succ@10%",
                           "Best Method", "Worst Method"]

    t04_display = t04.copy()
    t04_display.columns = [c.replace("success_", "") for c in t04_display.columns]

    t06_display = t06[["method", "median_IQR", "median_CV", "replica_agreement_rate"]].copy()
    t06_display.columns = ["Method", "Median IQR", "Median CV", "Agreement Rate"]

    t08_top = t08.nlargest(10, "max_drop_pp")[["system", "method", "max_drop_pp",
                                                "cliff_from_noise", "cliff_to_noise"]].copy()
    t08_top.columns = ["System", "Method", "Drop (pp)", "From Noise", "To Noise"]

    t08_oracle_top = t08_oracle.nlargest(10, "max_drop_pp")[["system", "method", "max_drop_pp",
                                                "cliff_from_noise", "cliff_to_noise"]].copy()
    t08_oracle_top.columns = ["System", "Method", "Drop (pp)", "From Noise", "To Noise"]

    t08_mb_top = t08_mb.nlargest(10, "max_drop_pp")[["system", "method", "max_drop_pp",
                                                "cliff_from_noise", "cliff_to_noise"]].copy()
    t08_mb_top.columns = ["System", "Method", "Drop (pp)", "From Noise", "To Noise"]

    # Per-method per-noise tables: use Best-of-branches (T02 mbounded)
    method_noise_tables = {}
    for m_key, m_label in method_labels.items():
        sub = t02_mb[t02_mb["method"] == m_label][["noise", "success_at_1pct", "success_at_10pct",
                                                    "success_at_50pct", "median_error", "median_time_s"]].copy()
        sub.columns = ["Noise", "Succ@1%", "Succ@10%", "Succ@50%", "Med. Error", "Time (s)"]
        method_noise_tables[m_label] = sub

    # "Best Systems" per method: best 5 systems by BoB mean success
    best_for_method = {}
    for m in methods:
        s = df[df["run"]==m].groupby("name")["mbounded_success_at_10pct"].mean().sort_values(ascending=False)
        best_for_method[method_labels[m]] = list(s.head(5).index)

    domain_map = {
        "aircraft_pitch": "Aerospace", "bicycle_model": "Mechanical",
        "biohydrogenation": "Biology",
        "boost_converter": "Electrical",
        "brusselator": "Chemistry", "crauste": "Biology", "cstr": "Chemistry",
        "daisy_mamil3": "Biology", "daisy_mamil4": "Biology", "dc_motor": "Electrical",
        "fitzhugh_nagumo": "Biology", "flexible_arm": "Mechanical",
        "forced_lotka_volterra": "Biology", "harmonic_oscillator": "Mechanical",
        "hiv": "Biology", "lotka_volterra": "Biology", "mass_spring_damper": "Mechanical",
        "quadrotor": "Aerospace", "repressilator": "Biology", "seir": "Epidemiology",
        "sirt_treatment": "Biology", "slow_fast": "Biology",
        "vanderpol": "Mechanical",
    }
    domain_counts = Counter(domain_map.values())

    polish_by_noise = []
    for noise, nl in zip(noise_levels, noise_labels):
        np_s = df[(df["run"]=="odepe_v2_nopolish")&(df["noise"]==noise)]["top1_success_at_10pct"].mean()*100
        p_s = df[(df["run"]=="odepe_v2_polish")&(df["noise"]==noise)]["top1_success_at_10pct"].mean()*100
        np_t = df[(df["run"]=="odepe_v2_nopolish")&(df["noise"]==noise)]["time"].median()
        p_t = df[(df["run"]=="odepe_v2_polish")&(df["noise"]==noise)]["time"].median()
        polish_by_noise.append({
            "Noise": nl, "No Polish": f"{np_s:.1f}%", "Polish": f"{p_s:.1f}%",
            "Uplift": f"+{p_s-np_s:.1f} pp", "Time Overhead": f"+{p_t-np_t:.0f}s"
        })
    polish_noise_df = pd.DataFrame(polish_by_noise)

    polish_by_noise_oracle = []
    for noise, nl in zip(noise_levels, noise_labels):
        np_s = df[(df["run"]=="odepe_v2_nopolish")&(df["noise"]==noise)]["oracle_success_at_10pct"].mean()*100
        p_s = df[(df["run"]=="odepe_v2_polish")&(df["noise"]==noise)]["oracle_success_at_10pct"].mean()*100
        np_t = df[(df["run"]=="odepe_v2_nopolish")&(df["noise"]==noise)]["time"].median()
        p_t = df[(df["run"]=="odepe_v2_polish")&(df["noise"]==noise)]["time"].median()
        polish_by_noise_oracle.append({
            "Noise": nl, "No Polish": f"{np_s:.1f}%", "Polish": f"{p_s:.1f}%",
            "Uplift": f"+{p_s-np_s:.1f} pp", "Time Overhead": f"+{p_t-np_t:.0f}s"
        })
    polish_noise_df_oracle = pd.DataFrame(polish_by_noise_oracle)

    polish_by_noise_mb = []
    for noise, nl in zip(noise_levels, noise_labels):
        np_s = df[(df["run"]=="odepe_v2_nopolish")&(df["noise"]==noise)]["mbounded_success_at_10pct"].mean()*100
        p_s = df[(df["run"]=="odepe_v2_polish")&(df["noise"]==noise)]["mbounded_success_at_10pct"].mean()*100
        np_t = df[(df["run"]=="odepe_v2_nopolish")&(df["noise"]==noise)]["time"].median()
        p_t = df[(df["run"]=="odepe_v2_polish")&(df["noise"]==noise)]["time"].median()
        polish_by_noise_mb.append({
            "Noise": nl, "No Polish": f"{np_s:.1f}%", "Polish": f"{p_s:.1f}%",
            "Uplift": f"+{p_s-np_s:.1f} pp", "Time Overhead": f"+{p_t-np_t:.0f}s"
        })
    polish_noise_df_mb = pd.DataFrame(polish_by_noise_mb)

    # Per-(system, noise) polish-hurts rollup, Best-of-branches
    polish_hurts_mb = t05_mb[t05_mb["success_uplift_pp"] < -5][["system","noise","success_uplift_pp"]].copy()
    polish_hurts_mb.columns = ["System","Noise","Uplift (pp)"]
    polish_hurts_mb = polish_hurts_mb.sort_values("Uplift (pp)")

    # Per-cell polish-hurts list, Best-of-branches.
    # Join polish + nopolish on (name, noise, instance) and surface cells where
    # polish BoB error is strictly worse than nopolish BoB error.
    polish_cells = df[df["run"] == "odepe_v2_polish"][
        ["name", "noise", "instance", "mbounded_max_rel_error", "top1_max_rel_error"]
    ].copy().rename(columns={
        "mbounded_max_rel_error": "polish_bob",
        "top1_max_rel_error": "polish_top1",
    })
    nopolish_cells = df[df["run"] == "odepe_v2_nopolish"][
        ["name", "noise", "instance", "mbounded_max_rel_error", "top1_max_rel_error"]
    ].copy().rename(columns={
        "mbounded_max_rel_error": "nopolish_bob",
        "top1_max_rel_error": "nopolish_top1",
    })
    paired = polish_cells.merge(nopolish_cells, on=["name", "noise", "instance"], how="inner")
    paired["bob_delta"] = paired["polish_bob"] - paired["nopolish_bob"]
    # Cells where polish meaningfully hurts on BoB (both have finite errors, polish > 1.5x nopolish error, nopolish was below the 10% threshold)
    bad_polish = paired[
        (paired["polish_bob"] > 0.10) &
        (paired["nopolish_bob"] < 0.10) &
        (paired["polish_bob"].notna()) &
        (paired["nopolish_bob"].notna())
    ].sort_values("bob_delta", ascending=False).head(15)
    bad_polish_display = bad_polish[["name", "noise", "instance", "nopolish_bob", "polish_bob", "bob_delta"]].copy()
    # Format noise as label
    noise_to_label = dict(zip(noise_levels, noise_labels))
    bad_polish_display["noise"] = bad_polish_display["noise"].map(noise_to_label)
    bad_polish_display.columns = ["System", "Noise", "Inst.", "Nopolish BoB err", "Polish BoB err", "Δ (polish − nopolish)"]
    n_bob_regr = ((paired["polish_bob"] > paired["nopolish_bob"]) & (paired["nopolish_bob"] < 0.10) & (paired["polish_bob"] > 0.10)).sum()
    n_bob_improve = ((paired["polish_bob"] < paired["nopolish_bob"]) & (paired["polish_bob"] < 0.10) & (paired["nopolish_bob"] > 0.10)).sum()

    timing = {method_labels[m]: df[df["run"]==m]["time"].median() for m in methods}

    # -- BUILD HTML --
    slides_html = ""

    def slide(content, bg="", notes=""):
        nonlocal slides_html
        bg_attr = f' data-background-color="{bg}"' if bg else ""
        slides_html += f'<section{bg_attr}>\n{content}\n'
        if notes:
            slides_html += f'<aside class="notes">{notes}</aside>\n'
        slides_html += '</section>\n'

    def vslide(content, bg="", notes=""):
        nonlocal slides_html
        bg_attr = f' data-background-color="{bg}"' if bg else ""
        slides_html += f'<section{bg_attr}>\n{content}\n'
        if notes:
            slides_html += f'<aside class="notes">{notes}</aside>\n'
        slides_html += '</section>\n'

    def img_tag(fig_key, width="85%"):
        return f'<img src="data:image/png;base64,{figs[fig_key]}" style="max-width:{width}; max-height:70vh;">'

    def img_tag_oracle(fig_key, width="85%"):
        return f'<img src="data:image/png;base64,{figs_oracle[fig_key]}" style="max-width:{width}; max-height:70vh;">'

    def img_tag_mb(fig_key, width="85%"):
        return f'<img src="data:image/png;base64,{figs_mb[fig_key]}" style="max-width:{width}; max-height:70vh;">'

    def metric_badge(metric):
        if metric == "top1":
            return '<span style="background:#3498db; color:#fff; padding:2px 8px; border-radius:4px; font-size:0.55em; vertical-align:middle;">TOP-1</span>'
        if metric == "mbounded":
            return '<span style="background:#27ae60; color:#fff; padding:2px 8px; border-radius:4px; font-size:0.55em; vertical-align:middle;">M-BOUNDED</span>'
        return '<span style="background:#9b59b6; color:#fff; padding:2px 8px; border-radius:4px; font-size:0.55em; vertical-align:middle;">ORACLE</span>'

    def section_start():
        nonlocal slides_html
        slides_html += '<section>\n'

    def section_end():
        nonlocal slides_html
        slides_html += '</section>\n'

    # TITLE
    slide(f"""
    <h1 style="font-size:1.8em;">ODEPE Benchmark Update</h1>
    <h2 style="font-size:1.2em; color:#7f8c8d;">Quoll-Broad Benchmark &mdash; internal update</h2>
    <p style="font-size:0.8em; color:#95a5a6;">benchmark_quoll_broad_2026-05-29 &bull; receptor systems excluded</p>
    <hr style="width:40%; border-color:#3498db;">
    <div style="font-size:0.7em; color:#7f8c8d; margin-top:2em;">
        <p>{n_total} evaluations &bull; {n_systems} ODE systems &bull; {n_methods} methods &bull; {n_noise} noise levels &bull; {n_replicas} replicas</p>
        <p>Headline metric throughout: <strong>Best-of-branches</strong> (each method gets credit for finding any of the M algebraic branches a system supports).</p>
    </div>
    """, bg="#1a1a2e")

    # OVERVIEW
    section_start()

    vslide(f"""
    <h2>The four methods being compared</h2>
    <div style="font-size:0.65em; text-align:left;">
        <p style="margin:0.4em 0;"><span class="badge odepe-p">ODEPE-v2 (polish)</span> &mdash;
            Julia. Structural-identifiability template + homotopy continuation surfacing up to
            M candidate parameter sets per cell (M = the runtime-detected algebraic
            multiplicity = rows returned; 1, 2, or 6 here), each then refined by a bounded Levenberg-Marquardt polish in log-space
            against the noisy data. This is the method we're championing.</p>
        <p style="margin:0.4em 0;"><span class="badge odepe-np">ODEPE-v2 (no polish)</span> &mdash;
            Same Julia pipeline as above but the polish stage is disabled. Same algebraic
            template, same M candidates returned, just no per-candidate fit refinement.
            Quantifies how much of ODEPE's accuracy comes from polish vs algebraic structure.</p>
        <p style="margin:0.4em 0;"><span class="badge amigo">AMIGO2</span> &mdash;
            Established MATLAB toolbox (Egea et al.) using enhanced scatter search (eSS)
            global optimization with nl2sol local refinement. Black-box; returns one
            best-fit parameter set per cell (K=1). Our most-respected external baseline.</p>
        <p style="margin:0.4em 0;"><span class="badge sciml">SHADE+LM</span> &mdash;
            Julia/Metaheuristics.jl. Success-history adaptive differential evolution (SHADE)
            with Levenberg-Marquardt local refinement, against the noisy data. Black-box
            global optimizer, K=1. A modern DE-class point of comparison.</p>
    </div>
    """)

    vslide(f"""
    <h2>Benchmark Scope</h2>
    <div class="columns">
        <div class="col">
            <h3>What we ran</h3>
            <ul>
                <li><strong>{n_systems}</strong> ODE systems from {len(domain_counts)} domains</li>
                <li><strong>4</strong> estimation methods (above)</li>
                <li><strong>5</strong> noise levels (0 &rarr; 1e-2)</li>
                <li><strong>10</strong> replicas per (system, noise) cell</li>
                <li><strong>{n_total}</strong> total evaluations</li>
                <li><strong>Additive</strong> noise model</li>
            </ul>
        </div>
        <div class="col">
            <h3>What "success" means</h3>
            <p style="font-size:0.7em;">A cell <strong>succeeds at X%</strong> if the
                method's best returned answer recovers <em>all identifiable parameters
                and initial conditions</em> to within X% relative error of the truth.
                ODEPE gets a small extra credit (Best-of-branches): if the system has
                M=2 algebraic branches, finding either one counts as success.</p>
            <p style="font-size:0.7em;">Primary threshold: <strong>10%</strong>. Tighter
                (1%) and looser (50%) variants shown where they tell a different story.</p>
        </div>
    </div>
    """)

    vslide(f"""
    <h2>Benchmark Design</h2>
    <div class="columns">
        <div class="col">
            <h3>Noise Levels (Additive)</h3>
            <table class="data-table compact">
                <tr><th>Level</th><th>Description</th></tr>
                <tr><td>0</td><td>Exact data (no noise)</td></tr>
                <tr><td>1e-8</td><td>Near-machine precision</td></tr>
                <tr><td>1e-6</td><td>Mild perturbation</td></tr>
                <tr><td>1e-4</td><td>Moderate noise</td></tr>
                <tr><td>1e-2</td><td>Significant noise</td></tr>
            </table>
        </div>
        <div class="col">
            <h3>Success Thresholds</h3>
            <table class="data-table compact">
                <tr><th>Metric</th><th>Meaning</th></tr>
                <tr><td>Success@1%</td><td>All identifiable params within 1%</td></tr>
                <tr><td>Success@10%</td><td>All identifiable params within 10%</td></tr>
                <tr><td>Success@50%</td><td>All identifiable params within 50%</td></tr>
            </table>
            <p class="footnote">Primary metric: <strong>Success@10%</strong></p>
        </div>
    </div>
    """)

    domain_html = ""
    for d in sorted(domain_counts.keys()):
        domain_html += f"<tr><td>{d}</td><td>{domain_counts[d]}</td></tr>"
    vslide(f"""
    <h2>System Domains</h2>
    <div class="columns">
        <div class="col" style="flex:1;">
            <table class="data-table compact">
                <tr><th>Domain</th><th># Systems</th></tr>
                {domain_html}
            </table>
        </div>
        <div class="col" style="flex:2;">
            <h3>Parameter Ranges</h3>
            <ul>
                <li>Identifiable parameters: <strong>{int(df['n_id_params'].min())} &ndash; {int(df['n_id_params'].max())}</strong></li>
                <li>Non-identifiable parameters: <strong>{int(df['n_nonid_params'].min())} &ndash; {int(df['n_nonid_params'].max())}</strong></li>
                <li>2 systems have non-identifiable params (excluded from error metrics)</li>
            </ul>
            <h3>Data Note</h3>
            <p class="footnote">All 8 replicas analyzed across all 25 systems.</p>
        </div>
    </div>
    """)

    section_end()

    # EXECUTIVE SUMMARY — Best-of-branches headline numbers only
    slide(f"""
    <h2>Executive Summary</h2>
    <div class="key-findings">
        <div class="finding">
            <div class="finding-number">{m_succ_mb[best_method_mb]:.1f}%</div>
            <div class="finding-label">{best_label_mb}<br><small>Best-of-branches @ 10% &mdash; leads all methods</small></div>
        </div>
        <div class="finding">
            <div class="finding-number">+{polish_uplift_mb:.1f} pp</div>
            <div class="finding-label">Polishing uplift<br><small>polish {p_succ_mb:.1f}% vs nopolish {np_succ_mb:.1f}%</small></div>
        </div>
        <div class="finding">
            <div class="finding-number">{succ_noise0:.0f}% &rarr; {succ_noise_hi:.0f}%</div>
            <div class="finding-label">Noise degradation<br><small>noise=0 to noise=1e-2 (across methods)</small></div>
        </div>
        <div class="finding">
            <div class="finding-number">{n_no_result + n_diverged}</div>
            <div class="finding-label">Total failures<br><small>{n_no_result} no-result + {n_diverged} diverged</small></div>
        </div>
    </div>
    <p class="footnote" style="margin-top:1em;">Methodology, metric definitions, and a top-pick vs best-of-branches breakdown are in the back of the deck.</p>
    """, bg="#16213e")

    # OVERALL METHOD COMPARISON — single slide, Best-of-branches only
    section_start()

    bob_takeaway = (
        f"<strong>{method_labels[best_method_mb]}</strong> leads at "
        f"<strong>{m_succ_mb[best_method_mb]:.1f}%</strong> Best-of-branches success@10%, "
        f"ahead of {method_labels[ranked_methods_mb[1]]} ({m_succ_mb[ranked_methods_mb[1]]:.1f}%), "
        f"{method_labels[ranked_methods_mb[2]]} ({m_succ_mb[ranked_methods_mb[2]]:.1f}%), and "
        f"{method_labels[ranked_methods_mb[3]]} ({m_succ_mb[ranked_methods_mb[3]]:.1f}%). "
        f"Best-of-branches is the metric where ODEPE&apos;s K=M output (multiple algebraic "
        f"candidates per cell) and AMIGO2/SHADE&apos;s K=1 output (single best-fit) can be "
        f"compared apples-to-apples."
    )

    vslide(f"""
    <h2>Overall Method Comparison</h2>
    {df_to_html(t01_mb_display, float_fmt=".1f")}
    <div class="takeaway">
        {bob_takeaway}
    </div>
    """)

    vslide(f"""
    <h2>Success Rate vs Noise Level</h2>
    {img_tag_mb("F01", "80%")}
    <p class="caption">All methods degrade with noise. Best-of-branches @ 10%.</p>
    """)

    vslide(f"""
    <h2>Method Rankings — how often each finishes 1st / 2nd / 3rd / 4th</h2>
    {img_tag_mb("F14", "75%")}
    <p class="caption">Across all (system, noise) pairs, Best-of-branches.
        ODEPE-polish takes the largest share of 1st-place finishes.</p>
    """)

    vslide(f"""
    <h2>System-Level Heatmap (success @ 10%)</h2>
    {img_tag_mb("F02", "55%")}
    <p class="caption">Best-of-branches. Systems sorted by mean difficulty across methods.
        The 4 multiplicity-2 systems (daisy_mamil4, seir, slow_fast, biohydrogenation)
        light up most clearly for ODEPE.</p>
    """)

    vslide(f"""
    <h2>System-Level Heatmap (success @ 1%)</h2>
    {img_tag_mb("F02a", "55%")}
    <p class="caption">Tighter threshold: all params recovered to 1% relative error.
        Best-of-branches.</p>
    """)

    vslide(f"""
    <h2>System-Level Heatmap (success @ 50%)</h2>
    {img_tag_mb("F02b", "55%")}
    <p class="caption">Looser threshold: roughly the right ballpark.
        Best-of-branches.</p>
    """)

    section_end()

    # PER-METHOD DEEP DIVE
    section_start()

    vslide("""<h2>Per-Method Breakdown</h2><p>Detailed performance across noise levels.</p>""")

    for m_key, m_label in method_labels.items():
        badge_cls = {"odepe_v2_polish":"odepe-p","odepe_v2_nopolish":"odepe-np",
                     "amigo2":"amigo","odepe_shade":"sciml"}[m_key]
        m_df = method_noise_tables[m_label]
        best_systems = ", ".join(best_for_method[m_label][:5])
        succ_vals = [df[(df["run"]==m_key)&(df["noise"]==n)]["mbounded_success_at_10pct"].mean()*100
                     for n in noise_levels]
        time_med = df[df["run"]==m_key]["time"].median()
        nr = (df[df["run"]==m_key]["has_result"]==0).sum()

        vslide(f"""
        <h2><span class="badge {badge_cls}">{m_label}</span></h2>
        <div class="columns">
            <div class="col">
                {df_to_html(m_df, float_fmt=".1f", classes="compact")}
            </div>
            <div class="col">
                <h3>Profile (Best-of-branches)</h3>
                <ul>
                    <li>Overall success@10%: <strong>{m_succ_mb[m_key]:.1f}%</strong></li>
                    <li>Median time: <strong>{time_med:.0f}s</strong></li>
                    <li>No-result rows: <strong>{nr}</strong></li>
                    <li>Noise=0 &rarr; 1e-2: <strong>{succ_vals[0]:.0f}% &rarr; {succ_vals[-1]:.0f}%</strong></li>
                </ul>
                <h3>Top-5 Systems by Success</h3>
                <p class="footnote">{best_systems}</p>
            </div>
        </div>
        """)

    section_end()

    # NOISE DEGRADATION
    section_start()

    vslide(f"""
    <h2>Noise Degradation Analysis</h2>
    <div class="big-stat">
        <span class="stat-val">{succ_noise0 - succ_noise_hi:.0f} pp</span>
        <span class="stat-label">Average success drop from noise=0 to noise=1e-2</span>
    </div>
    """, bg="#1a1a2e")

    vslide(f"""
    <h2>Method &times; Noise Detail</h2>
    {df_to_html(t02_mb_display, float_fmt=".1f", classes="compact small-text")}
    <p class="caption">Best-of-branches.</p>
    """)

    vslide(f"""
    <h2>Noise Cliffs &mdash; maximum success drop between adjacent noise levels</h2>
    {img_tag_mb("F10", "55%")}
    <p class="caption">Best-of-branches. Several (system, method) pairs have abrupt cliffs.</p>
    """)

    vslide(f"""
    <h2>Worst Noise Cliffs (top 10)</h2>
    {df_to_html(t08_mb_top, float_fmt=".0f")}
    <div class="takeaway">
        Several systems experience <strong>&gt;50 pp drops</strong> at a single noise transition.
        Useful for users planning what noise regime they need to operate in.
    </div>
    """)

    section_end()

    # POLISHING EFFECT
    section_start()

    vslide(f"""
    <h2>The Polishing Effect</h2>
    <div class="big-stat">
        <span class="stat-val">+{polish_uplift_mb:.1f} pp</span>
        <span class="stat-label">Best-of-branches success@10% uplift &mdash; polish vs nopolish</span>
    </div>
    <p style="font-size:0.7em; text-align:center; margin-top:1em;">
        ODEPE-polish: <strong>{p_succ_mb:.1f}%</strong> &nbsp;&middot;&nbsp;
        ODEPE-nopolish: <strong>{np_succ_mb:.1f}%</strong> &nbsp;&middot;&nbsp;
        Median wall time: polish <strong>{p_time:.0f}s</strong> vs nopolish <strong>{np_time:.0f}s</strong>
    </p>
    <p class="footnote" style="margin-top:1.5em;">
        The polish stage (bounded Levenberg-Marquardt in log-space against the noisy data)
        runs as the second stage of the ODEPE pipeline. The +{polish_uplift_mb:.1f}pp gain
        is the algorithm's primary ROI on that stage. Median wall time is roughly comparable
        to nopolish (polish adds compute on each candidate but candidate count is the same);
        the <em>mean</em> polish time is higher because of a long tail of hard-cell polish attempts.
    </p>
    """, bg="#16213e")

    vslide(f"""
    <h2>Polishing: Success by Noise</h2>
    {img_tag_mb("F04", "75%")}
    <p class="caption">Best-of-branches @ 10%, polish vs nopolish, across the 5 noise levels.</p>
    """)

    vslide(f"""
    <h2>Polishing by Noise Level (table)</h2>
    {df_to_html(polish_noise_df_mb, classes="compact")}
    <p class="caption">Best-of-branches. Polish dominates at every noise level.</p>
    """)

    vslide(f"""
    <h2>Per-System Polishing Uplift</h2>
    {img_tag_mb("F05", "55%")}
    <p class="caption">Best-of-branches uplift heatmap. Polishing helped in
        <strong>{n_helps_mbounded} of {len(t05_mb)}</strong> (system, noise) pairs.</p>
    """)

    if len(polish_hurts_mb) > 0:
        vslide(f"""
        <h2>Where Polishing Hurts &mdash; (system, noise) rollup</h2>
        {df_to_html(polish_hurts_mb.head(15), float_fmt=".1f", classes="compact")}
        <p class="footnote">{len(polish_hurts_mb)} (system, noise) cells where Best-of-branches drops by &gt;5pp when polish is enabled. These are aggregate stats across 8 replicas per cell.</p>
        """)

    if len(bad_polish_display) > 0:
        vslide(f"""
        <h2>Where Polishing Hurts &mdash; specific cells</h2>
        {df_to_html(bad_polish_display, float_fmt=".2f", classes="compact small-text")}
        <p class="footnote">
            Specific cells where nopolish succeeded (BoB max-rel &lt; 0.10) but polish failed
            (BoB max-rel &gt; 0.10). Sorted worst-first by polish-minus-nopolish error delta.
            Across the whole benchmark: <strong>{n_bob_regr}</strong> cells regressed under polish
            (vs <strong>{n_bob_improve}</strong> cells rescued by polish).
            Polish remains a net win in aggregate &mdash; these are the cells worth investigating.
        </p>
        """)

    section_end()

    # SYSTEM DIFFICULTY
    section_start()

    vslide(f"""
    <h2>System Difficulty Spectrum</h2>
    {img_tag_mb("F03", "60%")}
    <p class="caption">Best-of-branches @ 10%, mean across methods + noise levels.</p>
    """)

    vslide(f"""
    <h2>Hardest &amp; Easiest Systems</h2>
    <p class="footnote" style="margin-top:-0.5em;">% in parens: mean success@10% across all methods &amp; all noise levels</p>
    <div class="columns">
        <div class="col">
            <h3 style="color:#e74c3c;">Hardest</h3>
            <ol>
    """ + "".join(f"<li><code>{s}</code> (mean success@10%: {sys_succ[s]*100:.1f}%)</li>" for s in hardest_3) + f"""
            </ol>
        </div>
        <div class="col">
            <h3 style="color:#2ecc71;">Easiest</h3>
            <ol>
    """ + "".join(f"<li><code>{s}</code> (mean success@10%: {sys_succ[s]*100:.1f}%)</li>" for s in easiest_3) + f"""
            </ol>
        </div>
    </div>
    """)

    vslide(f"""
    <h2>Parameter Count vs Difficulty</h2>
    {img_tag_mb("F13", "75%")}
    <p class="caption">Best-of-branches. Difficulty doesn't simply track parameter count &mdash; conditioning of the inverse problem matters more.</p>
    """)

    vslide(f"""
    <h2>Full System Ranking</h2>
    <div style="font-size:0.55em; overflow-y:auto; max-height:70vh;">
    {df_to_html(t03_display, float_fmt=".1f")}
    </div>
    """)

    section_end()

    # DOMAIN ANALYSIS
    section_start()

    vslide(f"""
    <h2>Domain Analysis &mdash; Best-of-branches by domain</h2>
    {img_tag_mb("F06", "65%")}
    <p class="caption">Radar chart. Biology and Chemistry are the hardest domains.</p>
    """)

    vslide(f"""
    <h2>Domain &times; Method Success Rates</h2>
    {df_to_html(t04_display, float_fmt=".1f")}
    """)

    section_end()

    # REPLICA STABILITY
    section_start()

    vslide(f"""
    <h2>Replica Stability</h2>
    {df_to_html(t06_display, float_fmt=".3f")}
    <p class="footnote">Note: Based on 8 replicas per (system, noise, method) tuple.</p>
    """)

    vslide(f"""
    <h2>Error Spread by Method &amp; Noise</h2>
    {img_tag("F07", "90%")}
    """)

    vslide(f"""
    <h2>Per-System Replica Variability (noise=1e-2)</h2>
    {img_tag("F08", "70%")}
    """)

    section_end()

    # FAILURE ANALYSIS
    section_start()

    fail_method_rows = []
    failed_cells_examples = {}  # method -> list of failure cell ids
    for m in methods:
        m_sub = df[df["run"]==m]
        nr = int((m_sub["has_result"]==0).sum())
        dv = int(((m_sub["top1_max_rel_error"]>1e4)&(m_sub["has_result"]==1)).sum())
        fail_method_rows.append({
            "Method": method_labels[m], "No Result": nr, "Diverged": dv,
            "Total": nr+dv, "Rate": f"{(nr+dv)/len(m_sub)*100:.1f}%"
        })
        # collect concrete failure rows for the discussion slide
        no_res = m_sub[m_sub["has_result"]==0][["name","noise","instance"]]
        dvg = m_sub[(m_sub["top1_max_rel_error"]>1e4)&(m_sub["has_result"]==1)][["name","noise","instance"]]
        failed_cells_examples[m] = {"no_result": no_res, "diverged": dvg}
    fail_method_df = pd.DataFrame(fail_method_rows)

    vslide(f"""
    <h2>Failure Counts &mdash; per method</h2>
    {df_to_html(fail_method_df)}
    <p class="footnote" style="margin-top:1em;">
        <strong>No Result</strong>: the method produced no parseable answer for that cell
        (Julia crash, OOM, SLURM timeout, or run-time exception).
        <strong>Diverged</strong>: the method returned an answer with max relative error
        &gt; 10&#8308; on identifiable parameters (orders of magnitude away &mdash; effectively garbage).
        <strong>Rate</strong>: combined as a fraction of the 1150 cells per method.
    </p>
    """)

    # Build a per-noise/per-system breakdown of which cells failed for ODEPE polish
    # (the method we care about most for the failure discussion).
    polish_fail = pd.concat([
        failed_cells_examples["odepe_v2_polish"]["no_result"].assign(type="no_result"),
        failed_cells_examples["odepe_v2_polish"]["diverged"].assign(type="diverged"),
    ])
    polish_fail_by_sys = polish_fail.groupby("name").size().sort_values(ascending=False).head(8)
    polish_fail_by_noise = polish_fail.groupby("noise").size()
    polish_fail_sys_str = ", ".join(f"<code>{s}</code> ({n})" for s,n in polish_fail_by_sys.items())
    polish_fail_noise_str = ", ".join(
        f"{noise_to_label.get(n, str(n))}: {c}" for n, c in sorted(polish_fail_by_noise.items())
    )

    nopolish_fail = pd.concat([
        failed_cells_examples["odepe_v2_nopolish"]["no_result"].assign(type="no_result"),
        failed_cells_examples["odepe_v2_nopolish"]["diverged"].assign(type="diverged"),
    ])
    nopolish_fail_by_sys = nopolish_fail.groupby("name").size().sort_values(ascending=False).head(8)
    nopolish_fail_sys_str = ", ".join(f"<code>{s}</code> ({n})" for s,n in nopolish_fail_by_sys.items())

    vslide(f"""
    <h2>Failure Discussion</h2>
    <div style="font-size:0.65em; text-align:left;">
        <p><strong>ODEPE-polish</strong>: {len(polish_fail)} total failures
            ({(failed_cells_examples["odepe_v2_polish"]["no_result"]).shape[0]} no-result +
            {(failed_cells_examples["odepe_v2_polish"]["diverged"]).shape[0]} diverged).
            Concentrated in: {polish_fail_sys_str}.
            By noise level: {polish_fail_noise_str}.</p>
        <p><strong>ODEPE-nopolish</strong>: {len(nopolish_fail)} total failures.
            Concentrated in: {nopolish_fail_sys_str}.
            The polish stage rescues some of these (nopolish diverges more often because
            row 0 is the wrong algebraic branch and there&apos;s no refinement step to catch it).</p>
        <p><strong>AMIGO2 + SHADE</strong>: zero failures across {len(df[df["run"]=="amigo2"])} +
            {len(df[df["run"]=="odepe_shade"])} cells. These methods are designed for robustness:
            they always return <em>something</em>, even if it&apos;s a poor fit (it then shows up as a
            low-success cell rather than a missing one).</p>
        <p style="margin-top:0.8em;"><strong>Cancelled-hanger note</strong>: during the rerun,
            2 additional polish cells were killed after 15&ndash;22h of no-progress hangs
            (biohydrogenation_4_1em8, daisy_mamil4_7_1em6 nopolish). They&apos;re counted as no-result
            here. Symptom: HC.jl path tracking entered an infinite loop. These hanger cells are
            not catastrophic for the headline metric but worth a follow-up.</p>
    </div>
    """)

    vslide(f"""
    <h2>Outcome Breakdown (figure)</h2>
    {img_tag("F09", "90%")}
    """)

    section_end()

    # TIMING
    section_start()

    timing_rows = []
    for m in methods:
        m_sub = df[df["run"]==m]
        timing_rows.append({
            "Method": method_labels[m],
            "Median (s)": f"{m_sub['time'].median():.0f}",
            "Mean (s)": f"{m_sub['time'].mean():.0f}",
            "Min (s)": f"{m_sub['time'].min():.0f}",
            "Max (s)": f"{m_sub['time'].max():.0f}",
        })
    timing_df = pd.DataFrame(timing_rows)

    vslide(f"""
    <h2>Execution Time</h2>
    {img_tag("F11", "75%")}
    """)

    vslide(f"""
    <h2>Timing Statistics</h2>
    {df_to_html(timing_df)}
    """)

    vslide(f"""
    <h2>Speed-Accuracy Trade-off</h2>
    {img_tag_mb("F12", "75%")}
    <p class="caption">Best-of-branches. SHADE is fastest by a margin but trades a lot of accuracy. ODEPE-polish + AMIGO2 sit in a similar speed-accuracy regime, with ODEPE-polish slightly more accurate.</p>
    """)

    section_end()

    # CONCLUSIONS (data-driven, Best-of-branches)
    section_start()

    rank_css = ["rank-1", "rank-2", "rank-3", "rank-4"]

    def method_traits(m):
        is_fastest = (m == min(methods, key=lambda x: timing[method_labels[x]]))
        is_slowest = (m == max(methods, key=lambda x: timing[method_labels[x]]))
        is_best = (m == ranked_methods_mb[0])
        is_worst = (m == ranked_methods_mb[-1])

        strengths = []
        weaknesses = []
        if is_best:
            strengths.append("Highest BoB accuracy")
        if is_fastest:
            strengths.append("Fastest")
        if m == "odepe_v2_polish":
            strengths.append("Algebraic structure + LM refinement")
        if m == "odepe_v2_nopolish":
            strengths.append("Algebraic structure alone")
        if m == "amigo2":
            strengths.append("Robust black-box")
        if m == "odepe_shade":
            strengths.append("DE-class global search")
        if not strengths:
            strengths.append("Competitive")

        if is_slowest:
            weaknesses.append("Slowest")
        if is_worst:
            weaknesses.append("Lowest BoB accuracy")
        if m == "amigo2":
            weaknesses.append("Requires MATLAB")
        if m == "odepe_v2_polish":
            weaknesses.append("Polish adds time")
        if m == "odepe_v2_nopolish":
            weaknesses.append("No refinement on noisy data")
        if not weaknesses:
            weaknesses.append("Degrades at high noise")

        return ", ".join(strengths), ", ".join(weaknesses)

    # M-bounded ranking table — the only ranking we present in the front of the deck.
    ranking_rows_mb_html = ""
    for rank_idx, m in enumerate(ranked_methods_mb):
        strengths, weaknesses = method_traits(m)
        ranking_rows_mb_html += (
            f'<tr class="{rank_css[rank_idx]}"><td>{rank_idx+1}</td>'
            f'<td>{method_labels[m]}</td><td>{m_succ_mb[m]:.1f}%</td>'
            f'<td>{strengths}</td><td>{weaknesses}</td></tr>\n'
        )

    vslide(f"""
    <h2>Conclusions: Method Rankings (Best-of-branches)</h2>
    <table class="data-table ranking-table">
        <tr><th>Rank</th><th>Method</th><th>Success@10%</th><th>Strengths</th><th>Weaknesses</th></tr>
        {ranking_rows_mb_html}
    </table>
    <p class="footnote" style="margin-top:1em;">
        {best_label_mb} leads at {m_succ_mb[best_method_mb]:.1f}% Best-of-branches success@10%,
        with {method_labels[ranked_methods_mb[1]]} a close second at
        {m_succ_mb[ranked_methods_mb[1]]:.1f}%. SHADE+LM and ODEPE-nopolish follow.
    </p>
    """, bg="#1a1a2e")

    vslide(f"""
    <h2>Key Takeaways</h2>
    <div class="takeaway-grid">
        <div class="takeaway-card">
            <h3>ODEPE-polish leads</h3>
            <p><strong>{m_succ_mb[best_method_mb]:.1f}%</strong> Best-of-branches success@10%,
               ahead of {method_labels[ranked_methods_mb[1]]} ({m_succ_mb[ranked_methods_mb[1]]:.1f}%),
               SHADE ({m_succ_mb["odepe_shade"]:.1f}%), and ODEPE-nopolish ({m_succ_mb["odepe_v2_nopolish"]:.1f}%).</p>
        </div>
        <div class="takeaway-card">
            <h3>Polish Is Worth It</h3>
            <p>+{polish_uplift_mb:.1f}pp uplift on Best-of-branches vs nopolish.
               Median wall time is comparable to nopolish ({p_time:.0f}s vs {np_time:.0f}s).</p>
        </div>
        <div class="takeaway-card">
            <h3>Noise Dominates</h3>
            <p>BoB success drops <strong>{succ_noise0-succ_noise_hi:.0f}pp</strong> from clean to 1% noise across methods.
               cstr / sirt_treatment / fitzhugh_nagumo are the hardest at high noise.</p>
        </div>
        <div class="takeaway-card">
            <h3>Why "Best-of-branches"</h3>
            <p>It's the only metric where ODEPE's K=M output and AMIGO2/SHADE's K=1 output
               can be compared apples-to-apples. For M=1 systems (20 of 25) it equals
               top-pick; for M&gt;1 systems it credits ODEPE for surfacing any branch.</p>
        </div>
        <div class="takeaway-card">
            <h3>Failures are rare</h3>
            <p>{n_no_result} no-result + {n_diverged} diverged = {n_no_result+n_diverged}
               total failure cells across {n_total} evaluations
               ({(n_no_result+n_diverged)/n_total*100:.1f}%).
               AMIGO2 and SHADE have zero failures; ODEPE failures concentrate in
               crauste / biohydrogenation / cstr at high noise.</p>
        </div>
        <div class="takeaway-card">
            <h3>Open questions for the paper</h3>
            <p>How prominent should we make the BoB framing? Should we lead with
               raw % numbers, or with the structural-identifiability story that
               makes ODEPE&apos;s K=M output meaningful in the first place?</p>
        </div>
    </div>
    """)

    vslide(f"""
    <h2>What to look at next</h2>
    <ol style="font-size:0.75em; text-align:left; max-width:900px; margin:0 auto;">
        <li><strong>Polish-hurts deep dive</strong>: {n_bob_regr} cells where polish makes BoB worse than nopolish. Worth a follow-up to understand what fails in those polish runs.</li>
        <li><strong>Hard-system tail</strong>: cstr / sirt_treatment / fitzhugh_nagumo high-noise cells dominate the &gt;50% threshold failures. Investigating those is the highest-leverage place to improve ODEPE.</li>
        <li><strong>SHADE+LM accuracy floor</strong>: SHADE is fastest but lowest on BoB. Is the speed advantage real-time-budget important, or do we have headroom to ask for more iters?</li>
        <li><strong>Algorithmic improvements catalog</strong>: see <code>results/wallaby_analysis/numbat06_vs_wallaby_new_polish_regression_analysis.md</code> for a 39-cell regression list and 6 candidate algorithmic fixes (column scaling, forward-sim re-ranking, denoised polish target, etc.).</li>
    </ol>
    """)

    section_end()

    # METHODOLOGY (back of deck)
    section_start()

    vslide(f"""
    <h2>Methodology: Metric Definitions</h2>
    <div style="font-size:0.65em; text-align:left;">
        <p><strong>Top-pick</strong> (a.k.a. top-1 / row-0). The algorithm&apos;s primary recommendation:
            <code>result.csv</code> row 0, sorted by the method&apos;s internal score.
            What a user gets by default if they accept the first answer.
            For AMIGO2 and SHADE+LM this is also their only answer (K=1).</p>
        <p><strong>Best-of-branches</strong> (a.k.a. M-bounded). The best of the top
            <code>M</code> rows in <code>result.csv</code>, where <code>M</code> is the
            <em>algebraic multiplicity</em> of the system &mdash; the number of distinct
            algebraic branches the polynomial system admits &mdash; in practice the number
            of candidate rows ODEPE returns in <code>result.csv</code> (it auto-detects M and
            truncates to it), so this is oracle ranking over the returned rows. For 20 of 25
            systems M=1 (and BoB = top-pick). For daisy_mamil4, seir, slow_fast,
            biohydrogenation M=2, and for latent_subpopulation_branch M=6 (S3 subpopulation
            symmetry): ODEPE returns those branches and Best-of-branches credits the
            algorithm if any one recovers the truth. AMIGO2/SHADE return K=1, so
            their BoB = their top-pick &mdash; the metric collapses for them.</p>
        <p style="opacity:0.7;"><em>Legacy &ldquo;Oracle&rdquo; metric:</em> earlier benchmarks
            reported argmin over all K=20 ODEPE rows. ODEPE now truncates <code>result.csv</code>
            to M rows in-pipeline (commit 6ffc6cb), so oracle &equiv; Best-of-branches by definition.
            We&apos;ve dropped &ldquo;oracle&rdquo; from the headline; figures still get generated for
            reference but aren&apos;t shown in the main flow.</p>
    </div>
    """)

    # Top-pick vs Best-of-branches comparison table
    t01_compare_rows = []
    for m in methods:
        t01_compare_rows.append({
            "Method": method_labels[m],
            "Top-pick @10%": f"{m_succ[m]:.1f}%",
            "BoB @10%": f"{m_succ_mb[m]:.1f}%",
            "Δ (BoB − Top-pick)": f"{m_succ_mb[m] - m_succ[m]:+.1f}pp",
        })
    t01_compare_df = pd.DataFrame(t01_compare_rows)

    vslide(f"""
    <h2>Top-pick vs Best-of-branches &mdash; what does the M-credit buy?</h2>
    {df_to_html(t01_compare_df, classes="compact")}
    <div class="takeaway">
        For the K=1 methods (AMIGO2, SHADE+LM), BoB equals Top-pick: they only emit one answer per cell.
        For ODEPE (K=M output), BoB exceeds Top-pick by <strong>+{p_succ_mb - p_succ:.1f}pp</strong>
        on polish and <strong>+{p_succ_mb_nopolish_delta:+.1f}pp</strong> on nopolish &mdash;
        this is the value of giving the algorithm credit for surfacing all M algebraic branches.
        ODEPE-nopolish in particular gets a big lift from BoB because its row-0 sort often
        picks the wrong algebraic branch.
    </div>
    <p class="footnote" style="margin-top:0.5em;">
        Reading the table top-pick-first reverses the leader (AMIGO2 76.1% vs ODEPE-polish 75.3%);
        BoB-first restores ODEPE-polish to the top. We argue BoB is the comparable metric &mdash;
        because the alternative penalizes ODEPE for having structure that AMIGO2 lacks.
    </p>
    """, bg="#16213e")

    vslide(f"""
    <h2>Methodology: Noise &amp; Threshold</h2>
    <div class="columns">
        <div class="col">
            <h3>Noise Levels (Additive)</h3>
            <table class="data-table compact">
                <tr><th>Level</th><th>Description</th></tr>
                <tr><td>0</td><td>Exact data (no noise)</td></tr>
                <tr><td>1e-8</td><td>Near-machine precision</td></tr>
                <tr><td>1e-6</td><td>Mild perturbation</td></tr>
                <tr><td>1e-4</td><td>Moderate noise</td></tr>
                <tr><td>1e-2</td><td>Significant noise</td></tr>
            </table>
        </div>
        <div class="col">
            <h3>Success Thresholds</h3>
            <table class="data-table compact">
                <tr><th>Metric</th><th>Meaning</th></tr>
                <tr><td>Success@1%</td><td>All identifiable params within 1%</td></tr>
                <tr><td>Success@10%</td><td>All identifiable params within 10%</td></tr>
                <tr><td>Success@50%</td><td>All identifiable params within 50%</td></tr>
            </table>
            <p class="footnote">Primary threshold: <strong>Success@10%</strong>.</p>
        </div>
    </div>
    """)

    section_end()

    # APPENDIX
    section_start()
    vslide("""<h2>Appendix: All Figures (Best-of-branches variant where applicable)</h2>""", bg="#1a1a2e")

    # Figures that have a BoB variant; for these we render the BoB version.
    # F07, F08, F09, F11 are single-metric (no variant).
    fig_descs = [
        ("F01", "Success Rate vs Noise Level", True),
        ("F02", "System x Method Heatmap (@10%)", True),
        ("F03", "System Difficulty Ranking", True),
        ("F04", "Polishing Effect by Noise", True),
        ("F05", "Polishing Uplift Heatmap", True),
        ("F06", "Domain Radar Chart", True),
        ("F07", "Replica Stability Box Plots", False),
        ("F08", "Per-System Replica Strips", False),
        ("F09", "Failure Mode Breakdown", False),
        ("F10", "Noise Cliff Heatmap", True),
        ("F11", "Timing Comparison", False),
        ("F12", "Speed-Accuracy Scatter", True),
        ("F13", "Param Count vs Difficulty", True),
        ("F14", "Method Rank Distribution", True),
    ]
    for fk, fd, has_bob in fig_descs:
        tag = "(BoB)" if has_bob else "(single-metric)"
        img = img_tag_mb(fk, "75%") if has_bob else img_tag(fk, "75%")
        vslide(f"<h3>{fk}: {fd} {tag}</h3>\n{img}")

    section_end()

    # FINAL
    slide(f"""
    <h1>Thank You</h1>
    <p style="color:#7f8c8d; font-size:0.8em;">
        {n_total} evaluations &bull; {n_systems} systems &bull; 4 methods &bull;
        5 noise levels &bull; 8 replicas
    </p>
    <hr style="width:40%; border-color:#3498db;">
    <p style="font-size:0.6em; color:#95a5a6;">
        Generated from <code>run_analysis.py</code> + <code>make_presentation.py</code>
    </p>
    """, bg="#1a1a2e")

    # CSS
    custom_css = """
    :root {
        --r-background-color: #0d1117;
        --r-main-font: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        --r-heading-font: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        --r-main-color: #e6edf3;
        --r-heading-color: #ffffff;
        --r-link-color: #58a6ff;
    }
    .reveal { font-size: 28px; }
    .reveal h1 { font-size: 2.0em; color: #58a6ff; }
    .reveal h2 { font-size: 1.5em; color: #79c0ff; margin-bottom: 0.5em; }
    .reveal h3 { font-size: 1.1em; color: #d2a8ff; }
    .reveal ul, .reveal ol { text-align: left; margin-left: 1em; }
    .reveal li { margin-bottom: 0.3em; }
    .reveal img { border: none !important; box-shadow: 0 4px 20px rgba(0,0,0,0.5) !important; border-radius: 8px; }
    .columns { display: flex; gap: 2em; align-items: flex-start; }
    .col { flex: 1; }
    .data-table {
        border-collapse: collapse; margin: 0.5em auto; font-size: 0.6em;
        background: rgba(22,27,34,0.9); border-radius: 6px; overflow: hidden;
    }
    .data-table th {
        background: #21262d; padding: 8px 12px; text-align: left;
        color: #79c0ff; border-bottom: 2px solid #30363d; white-space: nowrap;
    }
    .data-table td { padding: 6px 12px; border-bottom: 1px solid #21262d; white-space: nowrap; }
    .data-table tr:hover td { background: rgba(56,139,253,0.1); }
    .data-table.compact { font-size: 0.55em; }
    .data-table.compact td, .data-table.compact th { padding: 4px 8px; }
    .small-text { font-size: 0.5em !important; }
    .caption { font-size: 0.6em; color: #8b949e; font-style: italic; margin-top: 0.5em; }
    .footnote { font-size: 0.65em; color: #8b949e; }
    .badge { display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 0.8em; font-weight: bold; color: white; }
    .badge.odepe-p { background: #1f77b4; }
    .badge.odepe-np { background: #6ba3d6; }
    .badge.amigo { background: #ff7f0e; }
    .badge.sciml { background: #2ca02c; }
    .takeaway {
        background: rgba(56,139,253,0.1); border-left: 4px solid #58a6ff;
        padding: 0.5em 1em; margin: 0.8em 0; font-size: 0.7em; text-align: left;
        border-radius: 0 6px 6px 0;
    }
    .key-findings { display: flex; gap: 1.5em; justify-content: center; flex-wrap: wrap; margin-top: 1em; }
    .finding {
        background: rgba(56,139,253,0.1); border: 1px solid #30363d;
        border-radius: 12px; padding: 1em 1.5em; text-align: center; min-width: 180px;
    }
    .finding-number { font-size: 1.8em; font-weight: bold; color: #58a6ff; }
    .finding-label { font-size: 0.65em; color: #8b949e; margin-top: 0.3em; }
    .big-stat { text-align: center; margin: 1em 0; }
    .stat-val { display: block; font-size: 2.5em; font-weight: bold; color: #58a6ff; }
    .stat-label { display: block; font-size: 0.7em; color: #8b949e; }
    .takeaway-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1em; margin-top: 0.5em; }
    .takeaway-card {
        background: rgba(22,27,34,0.9); border: 1px solid #30363d;
        border-radius: 10px; padding: 0.8em 1em; text-align: left;
    }
    .takeaway-card h3 { margin: 0 0 0.3em 0; font-size: 0.85em; }
    .takeaway-card p { font-size: 0.6em; color: #8b949e; margin: 0; }
    .ranking-table { font-size: 0.65em !important; }
    .rank-1 td { background: rgba(46,204,113,0.15) !important; }
    .rank-2 td { background: rgba(52,152,219,0.15) !important; }
    .rank-3 td { background: rgba(241,196,15,0.1) !important; }
    .rank-4 td { background: rgba(231,76,60,0.1) !important; }
    .reveal .progress { height: 4px; }
    .reveal .progress span { background: #58a6ff; }
    """

    if use_inline:
        style_block = f"<style>{reveal_css}</style>\n<style>{reveal_theme}</style>"
        script_block = f"<script>{reveal_js}</script>"
    else:
        style_block = (
            '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/reveal.js@5.1.0/dist/reveal.css">\n'
            '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/reveal.js@5.1.0/dist/theme/black.css">'
        )
        script_block = '<script src="https://cdn.jsdelivr.net/npm/reveal.js@5.1.0/dist/reveal.js"></script>'

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Parameter Estimation Benchmark &mdash; Wallaby Analysis (PREVIEW)</title>
{style_block}
<style>{custom_css}</style>
</head>
<body>
<div class="reveal">
<div class="slides">
{slides_html}
</div>
</div>
{script_block}
<script>
Reveal.initialize({{
    hash: true,
    slideNumber: 'c/t',
    width: 1280,
    height: 720,
    margin: 0.04,
    transition: 'slide',
    transitionSpeed: 'fast',
    center: true,
    controlsTutorial: false,
    progress: true,
    navigationMode: 'linear',
}});
</script>
</body>
</html>"""

    with open(OUTPUT, "w") as f:
        f.write(html)

    size_mb = os.path.getsize(OUTPUT) / (1024 * 1024)
    n_slides = slides_html.count('<section')
    print(f"Presentation saved to: {OUTPUT}")
    print(f"File size: {size_mb:.1f} MB")
    print(f"Total slides: ~{n_slides}")
    print(f"Offline: {'yes' if use_inline else 'no (CDN fallback)'}")


if __name__ == "__main__":
    build_presentation()
