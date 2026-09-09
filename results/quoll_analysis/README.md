# quoll-broad analysis (receptor excluded)

Independent analysis of `benchmark_quoll_broad_2026-05-29`, reproducing the
**wallaby** artifact pipeline on the quoll run, with **all receptor systems
excluded** per request.

## Deliverables

- **(A) The artifact** — `independent_analysis/presentation.html` (+ `REPORT.md`,
  `tables/`, `figures/`). Same reveal.js deck the team produced for wallaby,
  rebuilt on quoll data: 25 systems (23 wallaby + 2 latent branch; receptor
  dropped), 4 methods, 5 noise levels, 8 replicas. Headline metric =
  **Best-of-branches (M-bounded)**, with Top-1 and Oracle variants alongside.
- **(B) Apples-to-apples vs wallaby** — `wallaby_compare.md` (+ `_headline.csv`,
  `_by_system.csv`). quoll (2026-05-29) vs `benchmark_wallaby_2026-05-17` on the
  23 shared systems, same metric code, same pipeline family.

## How it was built (re-runnable as the slow tail drains)

```bash
# 0. consolidate cloud results into the local filetree (idempotent, local-wins)
python3 merge_cloud_into_filetree.py
# 1. collect: 3-metric flat (top1 / mbounded / oracle), all 27 systems
python3 results/quoll_analysis/build_flat_metrics_wallaby.py \
    --bench-dir benchmark_quoll_broad_2026-05-29 \
    --out results/quoll_analysis/flat_results_with_metrics_ALL.csv
# 2. drop receptor -> artifact input (25 systems)
python3 -c "import pandas as pd; a=pd.read_csv('results/quoll_analysis/flat_results_with_metrics_ALL.csv'); \
a[~a['name'].str.startswith('receptor')].to_csv('results/quoll_analysis/flat_results_with_metrics.csv',index=False)"
# 3. analyze + present
python3 results/quoll_analysis/independent_analysis/run_analysis.py
python3 results/quoll_analysis/independent_analysis/make_presentation.py
# 4. compare to wallaby
python3 results/quoll_analysis/compare_to_wallaby.py
```

## Metric vocabulary (from wallaby's headline_comparison.md)

- **Top-1** — result.csv row 0 (residual-best); the algorithm's default pick.
- **Best-of-branches (BoB, paper headline)** — best of the M candidate branches
  ODEPE returned, scored vs truth. **M = the number of rows in result.csv** —
  ODEPE auto-detects its algebraic multiplicity at runtime and truncates to
  exactly M, so we read M straight off the returned rows. This is just **oracle
  ranking over the returned rows**: no `config/systems.json` lookup, no canonical-M
  overlay. daisy_mamil4/seir/slow_fast/biohydrogenation return 2 rows;
  latent_subpopulation_branch returns 6 (S3 symmetry); everything else 1.
- **Oracle** — argmin over all returned rows. Identical to BoB by construction
  (result.csv is M-truncated), so `mbounded_* == oracle_*` in the flat metrics.

## Caveats (real, not metric artifacts)

- quoll = **8 replicas/cell**, wallaby = 10.
- quoll `POLISH_MAXTIME=600s`, wallaby `3600s` (6× less; polish arm only).
- quoll = later v2 stack (generic_start default, branch_completion, column
  scaling, ODEPE 1.1.0-DEV); wallaby = its own SHA.
- quoll's slow-tail re-solves (crauste, latent) were still draining at build
  time; **missing cells are scored as failures**. crauste polish was 34/40 — the
  one system materially below wallaby. Re-run as cells land to update.

## Bottom line

At Best-of-branches (paper headline) quoll **ties** wallaby across all four
methods (polish −0.7pp overall, **+0.7pp ex-crauste**; AMIGO2 +1.3, SHADE +2.0,
nopolish −1.9). No generation regression. The Top-1 polish gap (−2.8pp) tracks
the 6× smaller polish budget plus branch ranking. AMIGO2/SHADE (identical tools)
move only +1.3/+2.0pp — a clean no-bias control.
