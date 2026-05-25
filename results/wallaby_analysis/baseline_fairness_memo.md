# Baseline Fairness Memo — Wallaby Benchmark

**Generated:** 2026-05-24 (skeleton; needs codex/local pass-through for AMIGO2 specifics + final sign-off)
**Audience:** Paper 1 reviewer-defense + co-author review
**Scope:** Wallaby benchmark only. Quoll fairness will be a separate memo
once those runs land.

## Purpose

For each estimator compared in Wallaby's main tables, this memo records the
information a reviewer would need to verify the comparison is fair. The
intended outcome: a reviewer can reconstruct what was compared and see that
no method was tuned unfairly. The 13-field template below is codex's
proposed standard (round-3 of the Paper 1 alignment exchange).

Field labels indicating uncertainty:

- `TBD — needs <source>` — value not yet captured; identifies who/where to ask
- `N/A` — field not applicable for that method

## Method 1: ODEPE-v2 (polish)

| Field | Value |
|---|---|
| Estimator key | `odepe_v2_polish` |
| Template / script | `templates/julia_template_for_estimation_odepe_v2.jl`; ODEPE_POLISH=true |
| Software version | ODEPE.jl ref `282fe1a02c7a9ef277d176105d93a55bdca2b917` at original Wallaby launch (2026-05-17); rerun at `6ffc6cb54ff42d9afad638e6e9b43f3615f3e233` (2026-05-21) for ODEPE polish/nopolish only. SHADE+LM and AMIGO2 cells remain on the original ODEPE SHA. |
| Julia version | 1.12.5 (per `MANIFEST.toml[julia][version]`) |
| Julia env manifest sha256 | `b7d878a4a1c73b5656c579bc83d6841b5a1066184e77cd30f9e98dd286286280` (post-rerun) / `59b7ea13a95ffb47126f9839c969ddaba7b2a9b1319defa746af686fc318b2f1` (original); Wallaby MANIFEST records both. |
| Groebner.jl pin | `orebas/Groebner.jl@de072249b47c439278da2c2b113064593b00a0e4` (PR #218 fix for `align_up` bitmask bug; needed for biohydrogenation). |
| Data source | `benchmark_wallaby_2026-05-17/filetree/data_noisy/<cell>/data.csv`; deterministic md5-keyed seeds; same exact data file used by all 4 methods on the same cell. |
| Observables | Per-system from `huge_json.json[instances][*][measurement_variables]`; same for all methods. |
| Time grid | 750 points over per-system `time_interval` from `huge_json.json`; same for all methods. |
| Free vs fixed parameters | Free: all parameters listed in `huge_json.json[instances][*][parameter_variables]` plus initial conditions in `state_variables`. Fixed: none on Wallaby. Excluded from scoring: per-cell `all_unidentifiable` from `odepe_metadata.json[best]` (SI-derived; uniform across methods). |
| Bounds / search domain | `[1e-5, 10.0]` (lower/upper) on log-spaced parameter and state axes; applied as hard box constraints by the bounded LM polish (`PolishLSOBoundedLog`). Truth values are drawn from `[0.1, 0.9]` per the wallaby `param_interval`, so all truths are interior. |
| Objective | Multi-stage: (1) SI template builds polynomial system from data derivatives; (2) HC.jl finds real roots; (3) candidate clustering + ranking; (4) bounded LSO Levenberg-Marquardt polish against the noisy data in log-space with soft-wall regularization (`polish_softwall_lambda = 1e-2`, `polish_softwall_epsilon = 0.10`). |
| Global search budget | N/A (algebraic method — no global optimization phase). HC.jl tracks all complex roots of the polynomial system; no random restarts. |
| Local polish budget | `polish_maxiters = 5000`; `polish_maxtime = 3600s` per candidate (with ODE_maxiters = 20000 inside polish loss). |
| Stopping criteria | Polish stops on: (a) convergence at default LM tolerances, (b) `polish_maxiters`, (c) `polish_maxtime`, (d) divergence (loss > `polish_divergence_factor * initial_loss`), (e) stagnation (no improvement in `polish_stagnation_window=50` iters). |
| Initialization | Per-candidate: the algebraic candidate from HC.jl is the polish starting point. No random restarts; no truth-aware initialization. |
| Postprocessing | M-truncation: result.csv has at most `min(M, branch_top_k, n_clusters)` rows where M is auto-detected by ODEPE from the SI Gröbner basis. `branch_top_k = 20`. `rank_strategy = :sat_neg1_err` (S2). `branch_diversity_selection = true`, `branch_diversity_eps = 0.01`. |
| Output cardinality | K = M rows per cell (1 for M=1 systems, 2 for M=2 systems). The pre-truncation candidate pool is much larger (typically 100-700) but is NOT dumped to disk on Wallaby. |
| Tuning effort | Substantial. The wallaby init included a deliberate parameter-tuning pass: branch_top_k 100→20, soft-wall λ=1e-2 ε=0.10, S2 rank strategy, identifiable_subspace clustering, branch_cluster_eps 0.05→0.001, polish_maxtime 300→3600s, polish_softwall regularization added. See `MANIFEST.toml[lineage][changed_knobs_vs_numbat_14]`. These knobs were chosen before seeing wallaby results, based on numbat-14 lessons. |
| Cluster compute | 8 CPUs, 16 GB RAM, 36h walltime per cell. ~50 cells concurrent per array under SLURM throttle. |
| Failures recorded | 1 no-result + 5 diverged (top1 max-rel > 1e4); 2 cells cancelled at 15-22h no-progress hangs during the rerun. |
| Known caveats | Polish stage requires bounds; the algebraic stages do not. The M-truncation cuts off the pre-truncation pool, so the rank/diversity ablations cannot be replayed from stored data. |

## Method 2: ODEPE-v2 (no polish)

| Field | Value |
|---|---|
| Estimator key | `odepe_v2_nopolish` |
| Template / script | `templates/julia_template_for_estimation_odepe_v2.jl`; ODEPE_POLISH=false |
| Software version | Same ODEPE SHA history as polish variant (2026-05-17 and 2026-05-21 rerun). |
| Julia / env / Groebner | Same as polish. |
| Data / observables / time grid | Same as polish. |
| Free vs fixed parameters | Same as polish. |
| Bounds / search domain | Same `[1e-5, 10.0]` is set in the template but the polish stage that uses them is disabled. The algebraic stages do not constrain to bounds. |
| Objective | Same as polish, minus the final LM refinement. |
| Polish budget | N/A (polish disabled). |
| Stopping criteria | N/A for polish; algebraic stages have their own internal tolerances (HC.jl numerics + cluster_eps). |
| Initialization | N/A. |
| Postprocessing | Same M-truncation, same ranking, same diversity selection as polish. |
| Output cardinality | K = M rows per cell. Same as polish. |
| Tuning effort | Same as polish (knobs are shared). |
| Cluster compute | 2 CPUs, 8 GB RAM, 36h walltime per cell. Lower resource than polish because no LM optimization. |
| Failures recorded | 2 no-result + 23 diverged (top1 max-rel > 1e4). Higher than polish: the polish stage rescues some cells where row-0 is the wrong algebraic branch. |
| Known caveats | Same M-truncation caveat as polish. Without polish the row-0 sort more often picks the wrong branch — this is the +12.5pp BoB uplift that polish provides. |

## Method 3: AMIGO2

| Field | Value |
|---|---|
| Estimator key | `amigo2` |
| Template / script | `templates/amigo2.m.template` rendered to a per-cell `.m` file. MATLAB called via PEB's `src/estimate.py` driver. |
| Software version | AMIGO2_R2025 at `/scratch/oren-qc-13/AMIGO2_R2025`. **TBD — needs codex pass-through:** exact AMIGO2 release version + checksum / git ref of the AMIGO2 tarball used. |
| MATLAB version | TBD — needs cluster MATLAB `version` query. Run on the same arrow cluster as the other estimators (host `arrow3.arrow.local`). |
| Data / observables / time grid | Same data files as ODEPE (`benchmark_wallaby_2026-05-17/filetree/data_noisy/<cell>/data.csv`). Observables and time grid are PEB-controlled, not method-controlled. |
| Free vs fixed parameters | Free: same parameters + initial conditions as ODEPE. Fixed: none. Excluded from scoring: per-cell `all_unidentifiable` from ODEPE's `odepe_metadata.json` (uniform across methods, even though AMIGO2 doesn't compute SI itself). |
| Bounds / search domain | `[1e-5, 10.0]` log-spaced. AMIGO2's eSS scatter-search treats these as soft constraints / penalty bounds (NOT hard box constraints like ODEPE polish does). **This is a known methodological difference; should be stated in the paper.** |
| Objective | Sum-of-squared-residuals to noisy data (default AMIGO2 cost function). |
| Global search budget | eSS (enhanced scatter search) with `inputs.nlpsol.eSS.maxeval = 200_000`, `inputs.nlpsol.eSS.maxtime = 600s`. Local refinement: nl2sol. |
| Stopping criteria | First-reached of `maxeval = 200k` and `maxtime = 600s`. Local nl2sol convergence at AMIGO2 defaults. |
| Initialization | Random scatter-search starts within bounds (AMIGO2 default; no truth-aware initialization). |
| Postprocessing | K = 1 (single best-fit per cell). No branch-aware output. |
| Output cardinality | K = 1. The Best-of-branches metric for AMIGO2 collapses to top-pick. |
| Tuning effort | TBD — needs codex pass-through. Likely: AMIGO2's eSS defaults were used with PEB's wallaby search_bounds; no per-system tuning. |
| Cluster compute | TBD — read from `hpc/cuny/array_job_amigo2_cuny.s`. |
| Failures recorded | 0 no-result + 0 diverged (AMIGO2 always returns something; if the fit is bad, that just shows up as a low-success cell rather than a missing one). |
| Known caveats | (a) MATLAB licensing makes reviewer reproduction harder; reproducibility risk. (b) eSS budget (200k evals / 600s) may not be directly comparable to ODEPE polish's compute envelope. (c) K=1 means AMIGO2 cannot expose finite-branch structure even when systems have M>1 algebraic multiplicity; this is a methodological feature of the algorithm and is a fair comparison only for the top-pick metric. For Best-of-branches comparison, AMIGO2's number equals its top-pick by construction. (d) Bound handling is via penalty, not hard projection. |

## Method 4: SHADE+LM (`odepe_shade`)

| Field | Value |
|---|---|
| Estimator key | `odepe_shade` |
| Template / script | `templates/julia_template_for_estimation_odepe_shade.jl` |
| Software version | Lives in `julia_odepe` env (same env as ODEPE); ODEPE SHA `282fe1a02c7a9ef277d176105d93a55bdca2b917` at original Wallaby launch. NOT rerun in the 2026-05-21 ODEPE rerun (frozen). |
| Julia / env / Groebner | Same `julia_odepe` env as ODEPE polish/nopolish at the original Wallaby launch. Note: post-rerun, ODEPE polish/nopolish use `6ffc6cb` + Groebner PR #218; SHADE is on the older SHA. **This is a frozen-baseline difference flagged in `MANIFEST.toml[rerun_polish_nopolish_2026-05-21][out_of_scope]`.** |
| Data / observables / time grid | Same data files as ODEPE. |
| Free vs fixed parameters | Same as ODEPE. Same `all_unidentifiable` exclusion (uniform across methods). |
| Bounds / search domain | `[1e-5, 10.0]` (same as ODEPE), applied as hard box constraints by SHADE's bounded variant + by the bounded LM polish step. |
| Objective | SHADE (success-history adaptive differential evolution) on noisy-data SSE, then bounded LM polish on top SHADE candidates. Hybrid global+local. |
| Global search budget | `shade_total_max_evals = 200_000`, `shade_total_max_time = 1200s` (TWICE AMIGO2's 600s budget; this was deliberately bumped at wallaby init to give SHADE+LM a fair shot at the hybrid). |
| Local polish budget | Same polish settings as ODEPE-polish: `polish_maxiters = 5000`, `polish_maxtime` per cell, etc. Applied to top-K SHADE seeds (default K = 10 polish seeds). |
| Stopping criteria | SHADE: first of `max_evals = 200k` or `max_time = 1200s`. Polish: same as ODEPE-polish (convergence, maxiters, maxtime, divergence factor, stagnation window). |
| Initialization | Random SHADE population within bounds. No truth-aware initialization. |
| Postprocessing | K = 1 (best polished candidate per cell). No branch-aware output. |
| Output cardinality | K = 1. Best-of-branches collapses to top-pick. |
| Tuning effort | Wallaby-specific tuning: SHADE time budget bumped 600→1200s vs numbat-14. Otherwise default settings. |
| Cluster compute | 1 CPU, 4 GB RAM, 6h walltime per cell. Smaller envelope than ODEPE polish. |
| Failures recorded | 0 no-result + 0 diverged. Same robust-return-something behavior as AMIGO2. |
| Known caveats | (a) K=1 output limits its role in branch-aware claims. (b) SHADE is a separate ODEPE-family variant; it shares the polish stage code but the global search is SHADE (Metaheuristics.jl), not algebraic. (c) Bound handling is hard box constraints, more directly comparable to ODEPE polish than AMIGO2. |

## Cross-method comparison summary

| Comparison axis | ODEPE polish | ODEPE nopolish | AMIGO2 | SHADE+LM |
|---|---|---|---|---|
| Data files | Same | Same | Same | Same |
| Observables, time grid | Same (PEB-controlled) | Same | Same | Same |
| Free parameters | Same | Same | Same | Same |
| Excluded from scoring | per-cell `all_unidentifiable` (uniform) | Same | Same | Same |
| Bounds | `[1e-5, 10.0]`, hard box | Bounds set but polish disabled | `[1e-5, 10.0]`, soft penalty | `[1e-5, 10.0]`, hard box |
| Global search | N/A (algebraic) | N/A | eSS, 200k evals / 600s | SHADE, 200k evals / 1200s |
| Local refinement | Bounded LSO LM polish (5000 iters / 3600s) | None | nl2sol (AMIGO2 default) | Same as ODEPE polish |
| Output cardinality | K = M (1 or 2) | K = M | K = 1 | K = 1 |
| Compute / cell | 8 CPUs, 16 GB, 36h max | 2 CPUs, 8 GB, 36h max | TBD | 1 CPU, 4 GB, 6h max |
| Failures (Wallaby total) | 6 (1 no-result + 5 diverged) | 25 (2 no-result + 23 diverged) | 0 | 0 |

## What's protocol-clean and what's not

**Protocol-clean** (within the assumptions stated):

- Same data, observables, time grid, free-parameter set, identifiability exclusions across all 4 methods. ✓
- Bounds value uniform (`[1e-5, 10.0]`) across all methods. ✓
- All methods evaluated on the same cells (same SLURM-launched array index → same cell). ✓
- ODEPE polish + nopolish on the same ODEPE SHA per their respective Wallaby phases. ✓
- The K=1 vs K=M output difference is a methodological feature (algebraic methods can expose finite-branch structure; black-box optimizers don't). The Paper 1 framing is to (a) compare Best-of-branches as the apples-to-apples metric, and (b) discuss branch occupancy as a separate axis where K=1 methods have a constructive disadvantage. This is honest disclosure, not hidden tuning. ✓

**Caveats requiring explicit reviewer disclosure**:

- **AMIGO2 budget (600s eSS) vs SHADE budget (1200s)**: SHADE got 2× AMIGO2's global-search wall-time. SHADE compensates with smaller per-task compute (1 CPU vs AMIGO2's TBD). The paper should state both budgets and justify.
- **Bound enforcement differs**: ODEPE polish + SHADE use hard box constraints; AMIGO2 uses soft penalty. For interior truths (Wallaby's `param_interval = [0.1, 0.9]` is well inside `[1e-5, 10]`), this should not bite — but it's a real methodological difference.
- **ODEPE polish/nopolish SHA drift post-rerun**: 2026-05-21 rerun bumped ODEPE for these two methods only. SHADE+LM and AMIGO2 are on the older SHA (no algorithmic changes, but Julia env differs). For Paper 1, we should disclose this and confirm no behavior-relevant changes between SHAs that affect SHADE.
- **AMIGO2 reproducibility**: MATLAB licensing. Paper should ship a Julia/SciML stack that any reviewer can run independently of the AMIGO2 numbers.
- **Pre-truncation candidate pool not dumped**: rank-strategy and branch-diversity ablations cannot be done offline on Wallaby. Deferred to Quoll where dumps are enabled.

**Open TODOs** (need codex pass-through or cluster-side investigation):

- AMIGO2 exact version + checksum.
- AMIGO2 MATLAB version on the cluster.
- AMIGO2 per-cell SLURM resource allocation (read from `hpc/cuny/array_job_amigo2_cuny.s`).
- AMIGO2 tuning history: was any per-system or per-noise tuning applied? If yes, it must be disclosed.

## Sign-off

- cluster-Claude (this draft): 2026-05-24
- codex / local: PENDING (round-4 review of this memo + AMIGO2-specific fill-ins)
- Oren: PENDING (final sign-off before paper use)
