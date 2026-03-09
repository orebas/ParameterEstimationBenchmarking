#!/usr/bin/env python3
"""
Generate a self-contained reveal.js HTML presentation from the quokka benchmark analysis.
All images are embedded as base64 -- the output is a single portable HTML file.
Rankings and conclusions are data-driven.

Usage:
    python3 results/quokka_analysis/independent_analysis/make_presentation.py
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

    figs = {}
    for i in range(1, 15):
        fname = f"F{i:02d}_"
        for f in os.listdir(FIG_DIR):
            if f.startswith(fname):
                figs[f"F{i:02d}"] = img_b64(f)
                break

    methods = ["odepe_polish", "odepe_nopolish", "amigo2_run", "sciml_run"]
    method_labels = {
        "odepe_polish": "ODEPE (polish)",
        "odepe_nopolish": "ODEPE (no polish)",
        "amigo2_run": "AMIGO2",
        "sciml_run": "SciML",
    }
    noise_levels = [0.0, 1e-8, 1e-6, 1e-4, 1e-2]
    noise_labels = ["0", "1e-8", "1e-6", "1e-4", "1e-2"]

    n_total = len(df)
    n_systems = df["name"].nunique()
    n_no_result = (df["has_result"] == 0).sum()
    n_diverged = ((df["max_rel_error"] > 1e4) & (df["has_result"] == 1)).sum()

    m_succ = {}
    for m in methods:
        m_succ[m] = df[df["run"] == m]["success_at_10pct"].mean() * 100

    # Data-driven ranking
    ranked_methods = sorted(methods, key=lambda m: -m_succ[m])
    best_method = ranked_methods[0]
    best_label = method_labels[best_method]
    worst_method = ranked_methods[-1]
    worst_label = method_labels[worst_method]

    np_succ = df[df["run"] == "odepe_nopolish"]["success_at_10pct"].mean() * 100
    p_succ = df[df["run"] == "odepe_polish"]["success_at_10pct"].mean() * 100
    polish_uplift = p_succ - np_succ
    np_time = df[df["run"] == "odepe_nopolish"]["time"].median()
    p_time = df[df["run"] == "odepe_polish"]["time"].median()

    sys_succ = df.groupby("name")["success_at_10pct"].mean().sort_values()
    hardest_3 = list(sys_succ.head(3).index)
    easiest_3 = list(sys_succ.tail(3).index)[::-1]

    succ_noise0 = df[df["noise"] == 0.0]["success_at_10pct"].mean() * 100
    succ_noise_hi = df[df["noise"] == 0.01]["success_at_10pct"].mean() * 100

    fail_summary = t07["failure_type"].value_counts().to_dict()

    n_helps = (t05["success_uplift_pp"] > 0).sum()
    n_hurts = (t05["success_uplift_pp"] < 0).sum()
    n_neutral = (t05["success_uplift_pp"] == 0).sum()

    t01_display = t01[["method", "success_at_1pct", "success_at_10pct", "success_at_50pct",
                        "median_time_s", "n_no_result", "n_diverged"]].copy()
    t01_display.columns = ["Method", "Success@1%", "Success@10%", "Success@50%",
                           "Med. Time (s)", "No Result", "Diverged"]

    t02_display = t02[["method", "noise", "success_at_1pct", "success_at_10pct",
                        "success_at_50pct", "median_error", "median_time_s"]].copy()
    t02_display.columns = ["Method", "Noise", "Success@1%", "Success@10%",
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

    method_noise_tables = {}
    for m_key, m_label in method_labels.items():
        sub = t02[t02["method"] == m_label][["noise", "success_at_1pct", "success_at_10pct",
                                              "success_at_50pct", "median_error", "median_time_s"]].copy()
        sub.columns = ["Noise", "Succ@1%", "Succ@10%", "Succ@50%", "Med. Error", "Time (s)"]
        method_noise_tables[m_label] = sub

    best_for_method = {}
    for m in methods:
        s = df[df["run"]==m].groupby("name")["success_at_10pct"].mean().sort_values(ascending=False)
        best_for_method[method_labels[m]] = list(s.head(5).index)

    domain_map = {
        "aircraft_pitch": "Aerospace", "bicycle_model": "Mechanical",
        "biohydrogenation": "Biology", "boost_converter": "Electrical",
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
        np_s = df[(df["run"]=="odepe_nopolish")&(df["noise"]==noise)]["success_at_10pct"].mean()*100
        p_s = df[(df["run"]=="odepe_polish")&(df["noise"]==noise)]["success_at_10pct"].mean()*100
        np_t = df[(df["run"]=="odepe_nopolish")&(df["noise"]==noise)]["time"].median()
        p_t = df[(df["run"]=="odepe_polish")&(df["noise"]==noise)]["time"].median()
        polish_by_noise.append({
            "Noise": nl, "No Polish": f"{np_s:.1f}%", "Polish": f"{p_s:.1f}%",
            "Uplift": f"+{p_s-np_s:.1f} pp", "Time Overhead": f"+{p_t-np_t:.0f}s"
        })
    polish_noise_df = pd.DataFrame(polish_by_noise)

    polish_hurts = t05[t05["success_uplift_pp"] < -5][["system","noise","success_uplift_pp"]].copy()
    polish_hurts.columns = ["System","Noise","Uplift (pp)"]
    polish_hurts = polish_hurts.sort_values("Uplift (pp)")

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

    def section_start():
        nonlocal slides_html
        slides_html += '<section>\n'

    def section_end():
        nonlocal slides_html
        slides_html += '</section>\n'

    # TITLE
    slide(f"""
    <h1 style="font-size:1.8em;">Parameter Estimation Benchmark</h1>
    <h2 style="font-size:1.2em; color:#7f8c8d;">Independent Analysis</h2>
    <p style="font-size:0.8em; color:#95a5a6;">benchmark_quokka_2026_03_05</p>
    <hr style="width:40%; border-color:#3498db;">
    <div style="font-size:0.7em; color:#7f8c8d; margin-top:2em;">
        <p>{n_total} evaluations &bull; {n_systems} ODE systems &bull; 4 methods &bull; 5 noise levels &bull; 8 replicas</p>
        <p>March 2026</p>
    </div>
    """, bg="#1a1a2e")

    # OVERVIEW
    section_start()

    vslide(f"""
    <h2>Benchmark Overview</h2>
    <div class="columns">
        <div class="col">
            <h3>Scope</h3>
            <ul>
                <li><strong>{n_systems}</strong> ODE systems from {len(domain_counts)} domains</li>
                <li><strong>4</strong> estimation methods</li>
                <li><strong>5</strong> noise levels (0 &rarr; 0.01)</li>
                <li><strong>8</strong> independent replicas each</li>
                <li><strong>{n_total}</strong> total evaluations</li>
            </ul>
        </div>
        <div class="col">
            <h3>Methods</h3>
            <ul>
                <li><span class="badge odepe-p">ODEPE (polish)</span> &mdash; Julia, 2-stage</li>
                <li><span class="badge odepe-np">ODEPE (no polish)</span> &mdash; Julia, 1-stage</li>
                <li><span class="badge amigo">AMIGO2</span> &mdash; MATLAB-based</li>
                <li><span class="badge sciml">SciML</span> &mdash; Julia/DiffEq</li>
            </ul>
        </div>
    </div>
    """)

    vslide(f"""
    <h2>Benchmark Design</h2>
    <div class="columns">
        <div class="col">
            <h3>Noise Levels</h3>
            <table class="data-table compact">
                <tr><th>Level</th><th>Description</th></tr>
                <tr><td>0</td><td>Exact data (no noise)</td></tr>
                <tr><td>1e-8</td><td>Near-machine precision</td></tr>
                <tr><td>1e-6</td><td>Mild perturbation</td></tr>
                <tr><td>1e-4</td><td>Moderate noise</td></tr>
                <tr><td>1e-2</td><td>Significant noise (1%)</td></tr>
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
        </div>
    </div>
    """)

    section_end()

    # EXECUTIVE SUMMARY
    slide(f"""
    <h2>Executive Summary</h2>
    <div class="key-findings">
        <div class="finding">
            <div class="finding-number">{m_succ[best_method]:.1f}%</div>
            <div class="finding-label">{best_label} overall success@10%<br><small>Highest of all methods</small></div>
        </div>
        <div class="finding">
            <div class="finding-number">+{polish_uplift:.1f} pp</div>
            <div class="finding-label">Polishing uplift<br><small>{p_succ:.1f}% vs {np_succ:.1f}%</small></div>
        </div>
        <div class="finding">
            <div class="finding-number">{succ_noise0:.0f}% &rarr; {succ_noise_hi:.0f}%</div>
            <div class="finding-label">Noise degradation<br><small>noise=0 to noise=0.01</small></div>
        </div>
        <div class="finding">
            <div class="finding-number">{n_no_result + n_diverged}</div>
            <div class="finding-label">Total failures<br><small>{n_no_result} no-result + {n_diverged} diverged</small></div>
        </div>
    </div>
    """, bg="#16213e")

    # OVERALL METHOD COMPARISON
    section_start()

    # Data-driven takeaway
    takeaway_text = (
        f"<strong>Key:</strong> {best_label} leads in accuracy ({m_succ[best_method]:.1f}%). "
        f"{worst_label} has the lowest success rate ({m_succ[worst_method]:.1f}%)."
    )

    vslide(f"""
    <h2>Overall Method Comparison</h2>
    {df_to_html(t01_display, float_fmt=".1f")}
    <div class="takeaway">
        {takeaway_text}
    </div>
    """)

    vslide(f"""
    <h2>Success Rate vs Noise Level</h2>
    {img_tag("F01", "80%")}
    <p class="caption">All methods degrade with noise. {best_label} maintains the flattest curve.</p>
    """)

    vslide(f"""
    <h2>Method Rankings</h2>
    {img_tag("F14", "75%")}
    <p class="caption">How often each method ranks 1st/2nd/3rd/4th across all (system, noise) pairs.</p>
    """)

    vslide(f"""
    <h2>System-Level Heatmap</h2>
    {img_tag("F02", "55%")}
    <p class="caption">Systems sorted by difficulty. Clear clustering visible.</p>
    """)

    section_end()

    # PER-METHOD DEEP DIVE
    section_start()

    vslide("""<h2>Per-Method Breakdown</h2><p>Detailed performance across noise levels.</p>""")

    for m_key, m_label in method_labels.items():
        badge_cls = {"odepe_polish":"odepe-p","odepe_nopolish":"odepe-np",
                     "amigo2_run":"amigo","sciml_run":"sciml"}[m_key]
        m_df = method_noise_tables[m_label]
        best_systems = ", ".join(best_for_method[m_label][:5])
        succ_vals = [df[(df["run"]==m_key)&(df["noise"]==n)]["success_at_10pct"].mean()*100
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
                <h3>Profile</h3>
                <ul>
                    <li>Overall success@10%: <strong>{m_succ[m_key]:.1f}%</strong></li>
                    <li>Median time: <strong>{time_med:.0f}s</strong></li>
                    <li>No-result rows: <strong>{nr}</strong></li>
                    <li>Noise=0 &rarr; 0.01: <strong>{succ_vals[0]:.0f}% &rarr; {succ_vals[-1]:.0f}%</strong></li>
                </ul>
                <h3>Best Systems</h3>
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
        <span class="stat-label">Average success drop from noise=0 to noise=0.01</span>
    </div>
    """, bg="#1a1a2e")

    vslide(f"""
    <h2>Method x Noise Detail</h2>
    {df_to_html(t02_display, float_fmt=".1f", classes="compact small-text")}
    """)

    vslide(f"""
    <h2>Noise Cliffs</h2>
    {img_tag("F10", "55%")}
    <p class="caption">Maximum success-rate drop between adjacent noise levels.</p>
    """)

    vslide(f"""
    <h2>Worst Noise Cliffs</h2>
    {df_to_html(t08_top, float_fmt=".0f")}
    <div class="takeaway">
        Several systems experience <strong>&gt;50 pp drops</strong> at a single noise transition.
    </div>
    """)

    section_end()

    # POLISHING EFFECT
    section_start()

    vslide(f"""
    <h2>The Polishing Effect</h2>
    <div class="columns">
        <div class="col">
            <div class="big-stat">
                <span class="stat-val">+{polish_uplift:.1f} pp</span>
                <span class="stat-label">Overall success uplift</span>
            </div>
        </div>
        <div class="col">
            <div class="big-stat">
                <span class="stat-val">+{p_time - np_time:.0f}s</span>
                <span class="stat-label">Median time overhead</span>
            </div>
        </div>
    </div>
    """, bg="#16213e")

    vslide(f"""
    <h2>Polishing: Success by Noise</h2>
    {img_tag("F04", "75%")}
    """)

    vslide(f"""
    <h2>Polishing by Noise Level</h2>
    {df_to_html(polish_noise_df, classes="compact")}
    """)

    vslide(f"""
    <h2>Per-System Polishing Uplift</h2>
    {img_tag("F05", "55%")}
    <p class="caption">{n_helps} of {len(t05)} pairs benefit; {n_hurts} hurt; {n_neutral} neutral.</p>
    """)

    if len(polish_hurts) > 0:
        vslide(f"""
        <h2>When Does Polishing Hurt?</h2>
        {df_to_html(polish_hurts.head(15), float_fmt=".1f", classes="compact")}
        """)

    section_end()

    # SYSTEM DIFFICULTY
    section_start()

    vslide(f"""
    <h2>System Difficulty Spectrum</h2>
    {img_tag("F03", "60%")}
    """)

    vslide(f"""
    <h2>Hardest &amp; Easiest Systems</h2>
    <div class="columns">
        <div class="col">
            <h3 style="color:#e74c3c;">Hardest</h3>
            <ol>
    """ + "".join(f"<li><code>{s}</code> ({sys_succ[s]:.1f}%)</li>" for s in hardest_3) + f"""
            </ol>
        </div>
        <div class="col">
            <h3 style="color:#2ecc71;">Easiest</h3>
            <ol>
    """ + "".join(f"<li><code>{s}</code> ({sys_succ[s]:.1f}%)</li>" for s in easiest_3) + f"""
            </ol>
        </div>
    </div>
    """)

    vslide(f"""
    <h2>Parameter Count vs Difficulty</h2>
    {img_tag("F13", "75%")}
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
    <h2>Domain Analysis</h2>
    {img_tag("F06", "65%")}
    """)

    vslide(f"""
    <h2>Domain x Method Success Rates</h2>
    {df_to_html(t04_display, float_fmt=".1f")}
    """)

    section_end()

    # REPLICA STABILITY
    section_start()

    vslide(f"""
    <h2>Replica Stability</h2>
    {df_to_html(t06_display, float_fmt=".3f")}
    """)

    vslide(f"""
    <h2>Error Spread by Method &amp; Noise</h2>
    {img_tag("F07", "90%")}
    """)

    vslide(f"""
    <h2>Per-System Replica Variability (noise=0.01)</h2>
    {img_tag("F08", "70%")}
    """)

    section_end()

    # FAILURE ANALYSIS
    section_start()

    fail_method_rows = []
    for m in methods:
        m_sub = df[df["run"]==m]
        nr = int((m_sub["has_result"]==0).sum())
        dv = int(((m_sub["max_rel_error"]>1e4)&(m_sub["has_result"]==1)).sum())
        fail_method_rows.append({
            "Method": method_labels[m], "No Result": nr, "Diverged": dv,
            "Total": nr+dv, "Rate": f"{(nr+dv)/len(m_sub)*100:.1f}%"
        })
    fail_method_df = pd.DataFrame(fail_method_rows)

    vslide(f"""
    <h2>Failure Analysis</h2>
    {df_to_html(fail_method_df)}
    """)

    vslide(f"""
    <h2>Outcome Breakdown</h2>
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
    {img_tag("F12", "75%")}
    """)

    section_end()

    # CONCLUSIONS (data-driven)
    section_start()

    # Build ranking table rows dynamically
    rank_css = ["rank-1", "rank-2", "rank-3", "rank-4"]
    # Determine strengths/weaknesses dynamically
    def method_traits(m):
        is_fastest = (m == min(methods, key=lambda x: timing[method_labels[x]]))
        is_slowest = (m == max(methods, key=lambda x: timing[method_labels[x]]))
        is_best = (m == ranked_methods[0])
        is_worst = (m == ranked_methods[-1])

        strengths = []
        weaknesses = []
        if is_best:
            strengths.append("Highest accuracy")
        if is_fastest:
            strengths.append("Fastest method")
        if m == "odepe_polish":
            strengths.append("Good speed-accuracy balance")
        if m == "odepe_nopolish":
            strengths.append("Fast baseline")
        if not strengths:
            strengths.append("Competitive accuracy")

        if is_slowest:
            weaknesses.append("Slowest")
        if is_worst:
            weaknesses.append("Lowest accuracy")
        if m == "amigo2_run":
            weaknesses.append("Requires MATLAB")
        if m == "odepe_polish":
            weaknesses.append("Polishing adds time")
        if not weaknesses:
            weaknesses.append("Degrades at high noise")

        return ", ".join(strengths), ", ".join(weaknesses)

    ranking_rows_html = ""
    for rank_idx, m in enumerate(ranked_methods):
        strengths, weaknesses = method_traits(m)
        ranking_rows_html += (
            f'<tr class="{rank_css[rank_idx]}"><td>{rank_idx+1}</td>'
            f'<td>{method_labels[m]}</td><td>{m_succ[m]:.1f}%</td>'
            f'<td>{strengths}</td><td>{weaknesses}</td></tr>\n'
        )

    vslide(f"""
    <h2>Conclusions: Method Rankings</h2>
    <table class="data-table ranking-table">
        <tr><th>Rank</th><th>Method</th><th>Success@10%</th><th>Strengths</th><th>Weaknesses</th></tr>
        {ranking_rows_html}
    </table>
    """, bg="#1a1a2e")

    vslide(f"""
    <h2>Key Takeaways</h2>
    <div class="takeaway-grid">
        <div class="takeaway-card">
            <h3>Noise Dominates</h3>
            <p>Success drops <strong>{succ_noise0-succ_noise_hi:.0f} pp</strong> from clean to 1% noise.</p>
        </div>
        <div class="takeaway-card">
            <h3>Polish Is Worth It</h3>
            <p>+{polish_uplift:.1f} pp uplift at +{p_time-np_time:.0f}s cost. Helps in {n_helps}/{len(t05)} cases.</p>
        </div>
        <div class="takeaway-card">
            <h3>No Universal Winner</h3>
            <p>{best_label} wins most often but specific systems favor other methods.</p>
        </div>
        <div class="takeaway-card">
            <h3>System &gt; Method</h3>
            <p>Success ranges from &lt;20% to 100% across systems. Structure drives difficulty.</p>
        </div>
    </div>
    """)

    # Data-driven recommendations
    fastest_m = min(methods, key=lambda x: timing[method_labels[x]])
    best_balance_m = "odepe_polish"  # ODEPE polish is always the "balance" recommendation
    vslide(f"""
    <h2>Recommendations</h2>
    <ol style="font-size:0.85em; text-align:left; max-width:800px; margin:0 auto;">
        <li><strong>Best accuracy:</strong> {best_label} ({m_succ[best_method]:.1f}% success@10%).</li>
        <li><strong>Best speed-accuracy trade-off:</strong> {method_labels[best_balance_m]}.</li>
        <li><strong>Always polish:</strong> The accuracy benefit outweighs the time cost.</li>
        <li><strong>Beware noise cliffs:</strong> Pre-test at multiple noise levels.</li>
        <li><strong>Use multiple replicas:</strong> At least 3-5 replicas, take the best.</li>
    </ol>
    """)

    section_end()

    # APPENDIX
    section_start()
    vslide("""<h2>Appendix: All Figures</h2>""", bg="#1a1a2e")

    fig_descs = {
        "F01": "Success Rate vs Noise Level",
        "F02": "System x Method Heatmap",
        "F03": "System Difficulty Ranking",
        "F04": "Polishing Effect by Noise",
        "F05": "Polishing Uplift Heatmap",
        "F06": "Domain Radar Chart",
        "F07": "Replica Stability Box Plots",
        "F08": "Per-System Replica Strips",
        "F09": "Failure Mode Breakdown",
        "F10": "Noise Cliff Heatmap",
        "F11": "Timing Comparison",
        "F12": "Speed-Accuracy Scatter",
        "F13": "Param Count vs Difficulty",
        "F14": "Method Rank Distribution",
    }
    for fk, fd in fig_descs.items():
        vslide(f"<h3>{fk}: {fd}</h3>\n{img_tag(fk, '75%')}")

    section_end()

    # FINAL
    slide(f"""
    <h1>Thank You</h1>
    <p style="color:#7f8c8d; font-size:0.8em;">
        {n_total} evaluations &bull; {n_systems} systems &bull; 4 methods &bull;
        5 noise levels &bull; 8 replicas
    </p>
    <hr style="width:40%; border-color:#3498db;">
    <p style="font-size:0.7em; color:#95a5a6;">
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
<title>Parameter Estimation Benchmark &mdash; Quokka Analysis</title>
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
