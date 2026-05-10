# ODEPE oracle-ranking audit — write-up

**Date:** 2026-05-10
**Authors:** O. Bassik + Claude (Opus 4.7, 1M ctx) on numbat HPC login node
**Status:** open — no decisions made; intended as input to a future investigation.

This document captures (a) what we found, (b) what we think it means, (c) what
might or might not be worth doing about it. It deliberately stops short of
proposing a single fix; the goal is to lay out enough evidence and structure
for a follow-up session (probably on a non-login machine) to act on.

---

## 0. TL;DR

ODEParameterEstimation's user-visible "best solution" is sorted by ground-truth
distance, not by data-residual. This is a behavior of the library, not of the
benchmark harness. The published "best error" metrics in `odepe_metadata.json`
are also derived from oracle stats. The data residual `candidate.err` exists
internally and is preserved on each candidate, but is invisible at the API
boundary (no `err` column in `result.csv`; only one buried scalar
`best_approximation_error` in the metadata).

We audited 60 cells (`results/numbat_analysis/oracle_ranking_audit.py`),
re-integrating the ODE in Python with each candidate's parameters and computing
the data-residual we *would* have ranked by, had we not been cheating. We found
the cheat is real but, in most cases, cosmetic: residual-best ≈ truth-best for
the easy systems. For the hard systems, the picture is mixed, and an
**audit bug we caught mid-investigation cleaned up most of the apparent
catastrophe** (initial audit reported daisy_mamil4 truth-best at rank 220
median; correctly-implemented audit shows median rank 2).

The remaining "bad" cells are bad for reasons mostly unrelated to the
oracle-ranking choice:

- biohydrogenation_low-noise: 542 returned candidates are tied along the
  declared non-identifiable dimension `x7`. Ranking among them is arbitrary.
- biohydrogenation_high-noise / cstr_high-noise: at high noise multiple
  parameters become *practically* unidentifiable on the data; the cells are
  underdetermined regardless of ranking metric.
- crauste at all noise: scipy's LSODA can't reliably re-integrate even truth
  parameters in 2 s. Audit data for crauste is unreliable. Need a Julia-side
  re-audit (using ODEPE's own integrator) before drawing conclusions.

A clean fix would change the package's reported metrics and sort order to be
data-residual based, leaving oracle-derived numbers as a separate
`oracle.*` namespace inside metadata for the benchmarking we actually want
to do. Net effect on headline numbers: probably 3–5 pp downward on
`odepe_v2_polish` (best guess from per-cell top-1 capture rates), without
changing the per-system shape of which systems are easy and which are hard.

---

## 1. The cheat, located precisely

### 1.1 Where the order is set

`environments/ODEParameterEstimation/src/core/analysis_utils.jl:426`:

```julia
return (
    sort([first(cluster) for cluster in clusters],
         by = candidate -> oracle_sort_key(problem, candidate)),
    besterror,
    best_min_error,
    ...
)
```

`oracle_sort_key` (lines 116–122):

```julia
function oracle_sort_key(problem, candidate)
    stats = oracle_error_stats(problem, candidate)
    if isnothing(stats)
        return (Inf, Inf, isnothing(candidate.err) ? Inf : candidate.err)
    end
    return (stats.maximum, stats.median,
            isnothing(candidate.err) ? Inf : candidate.err)
end
```

Tuple-sorted lexicographically: oracle.maximum first, oracle.median second,
data-residual `candidate.err` only as the third tiebreaker (which essentially
never fires).

`oracle_error_stats` (lines 81–114) computes
`relative_error_value(candidate.parameters[p], problem.p_true[p])` and
`relative_error_value(candidate.states[s], problem.ic[s])` over identifiable
variables. So `problem.p_true` and `problem.ic` are read at sort-time.

### 1.2 What's reported

`odepe_metadata.json` for any cell contains seven scalar metrics. Six are
oracle:

| field                          | source                                | type   |
|--------------------------------|---------------------------------------|--------|
| `besterror`                    | `min(stats.maximum)` over candidates  | oracle |
| `best_min_error`               | `min(stats.minimum)`                  | oracle |
| `best_mean_error`              | `min(stats.mean)`                     | oracle |
| `best_median_error`            | `min(stats.median)`                   | oracle |
| `best_max_error`               | `min(stats.maximum)` (== besterror)   | oracle |
| `best_rms_error`               | `min(stats.rms)`                      | oracle |
| `best_approximation_error`     | `first(sorted_results).err`           | data residual |

The single `best_approximation_error` is the only data-residual-derived number
that survives into metadata. The rest are oracle-derived but named in a way
that doesn't telegraph that.

### 1.3 What's in `result.csv`

For every cell, `result.csv` contains one row per cluster representative, with
columns for each state and parameter. **No error column.** Order follows the
oracle sort. Sample (lotka_volterra_0_0):

```
r(t),k3,w(t),k1,k2
0.141,0.114,0.412,0.618,0.544
0.141,0.114,0.412,0.618,0.544
...
```

There are typically 100s–1000s of rows per cell. The numbat benchmark uses row
1 as "the answer" downstream — which means downstream consumers consume the
oracle-sorted top with no way to recover data residual without re-integrating.

### 1.4 Where it isn't a cheat

The pre-clustering sort at line 253 (`sort(scored_results, by = _result_err_key)`)
uses `candidate.err` (data residual) and is clean. The clustering itself
operates on legitimate scoring. It's only the post-clustering, user-visible
ordering at line 426 that switches to oracle.

The candidate's `.err` field is also never overwritten — it stays valid
throughout. So the data residual is *available* internally; it just isn't
*surfaced*.

---

## 2. The audit

### 2.1 Method

`results/numbat_analysis/oracle_ranking_audit.py` for each (cell, candidate row)
re-integrates the ODE in scipy (LSODA, rtol=1e-7, atol=1e-10, 50-point
subsampled t-grid, 2 s wallclock per row, 16 parallel workers). Records:

- per-row oracle err (`max_rel_err` over identifiable vars vs ground truth)
- per-row data residual (sum of squares of (predicted - observed) over channels and time)
- truth-best row index (`argmin(oracle)`)
- truth-best's rank when sorted by data residual (1-based)
- top-K capture: did truth-best end up in the top K by residual?

Sample of 60 cells stratified across (system, noise) for `odepe_v2_polish`.

### 2.2 An important bug we hit mid-investigation

Initial audit results suggested four systems were broken (median ranks
148–542). Deep-dive on `daisy_mamil4_4_0` showed scipy-integrating truth params
gave residual ≈ 1042 at noise=0, where it should have been near machine ε.
Diagnosis: data.csv columns are alphabetical (`measurement_variables` order),
but I was iterating `inst["measurements"]` (a Python dict whose key order can
differ — `[y3, y1, y2]` for daisy_mamil4 specifically). Five systems are
affected: crauste, daisy_mamil4, hiv, repressilator, slow_fast.

After fix, daisy_mamil4 truth gives residual ~ 1e-23 (LSODA, tight tol), and
the audit ranks drop dramatically. **Conclusions in §3 are post-fix.**

### 2.3 Top-line numbers (60 cells, post-fix)

| cohort                         | top-1 | top-5 | top-10 | top-20 | top-100 |
|--------------------------------|------:|------:|-------:|-------:|--------:|
| All cells                      |   37% |   57% |    65% |    67% |     80% |
| Answer-bearing (truth_best_oracle < 1%) | 42% |   63% |    70% |    73% |     88% |

| system            | n | median rank | max rank |
|-------------------|--:|------------:|---------:|
| daisy_mamil3      | 5 |           1 |        1 |
| flexible_arm      | 5 |           1 |       14 |
| brusselator       | 5 |           1 |        2 |
| fitzhugh_nagumo   | 5 |           1 |       53 |
| dc_motor          | 5 |           2 |       38 |
| daisy_mamil4      | 5 |           2 |       52 |
| bicycle_model     | 5 |           3 |       75 |
| boost_converter   | 5 |           4 |        9 |
| aircraft_pitch    | 5 |          26 |      101 |
| cstr              | 5 |         189 |      427 |
| biohydrogenation  | 5 |         356 |      786 |
| crauste           | 5 |         409 |     1149 |

Raw audit data: `results/numbat_analysis/oracle_ranking_audit.csv`.

---

## 3. What's actually in the residual landscape

We deep-dove seven cells. For each: re-computed per-row residual + oracle, then
looked at the spread of state/parameter values within the "plateau"
(rows with residual ≤ 2× of residual-best). What the plateaus look like
varies wildly system-by-system.

Per-cell deep-dive CSVs: `results/numbat_analysis/deepdive_<cell_id>.csv`.
Each has the original (states, params) plus computed `residual` and `oracle`
columns, sortable any way you like.

### 3.1 biohydrogenation — non-identifiability of x7 (the clean case)

`biohydrogenation_4_1em8` (noise=1e-8). 2125 returned candidates. Of those,
542 have residual within 0.001% of best. Within those 542 rows:

```
var           truth        plateau_min   plateau_max   plateau_med
x4            0.678        0.678         0.678         0.678
x5            0.139        0.139         0.139         0.139
x6            0.614        0.614         0.614         0.614
x7            0.251        1e-5          10            1.025      ← non-id, full search range
k5..k10                    [all pinned to truth, 1.00x spread]
```

ODEPE's `all_unidentifiable` field correctly flags `x7(t)`. The 542 plateau
rows ARE the x7-axis manifold. They're all the same answer modulo
unidentifiable x7. Top-1 returns one; top-100 returns 100 — they're equally
correct. Truth-best's "rank 9" is not meaningful because
within-plateau ordering is arbitrary noise.

`biohydrogenation_6_0` (noise=0) is the same shape, fewer rows in plateau
because at zero noise the residual at truth is *slightly* less precise than
some non-truth x7 due to floating-point arithmetic.

### 3.2 aircraft_pitch — same pattern, different non-id variable

`aircraft_pitch_6_1em6`. ODEPE flags `theta` non-id. 41 plateau rows; q,
alpha, M_alpha, M_q, M_delta_e, Z_alpha all pinned to truth (1.00x). theta
spans -6263 to +3.7 across plateau. Truth (theta=0.25) is one of the 41.

Same story as biohydrogenation, just one non-id variable instead of one. Top-K
catches it because every plateau row is a valid solution.

### 3.3 daisy_mamil4 — practical identifiability ridge (no flagged non-id)

`daisy_mamil4_4_0` (noise=0). 8 plateau rows. ODEPE doesn't flag any
parameter as non-id. Within plateau:

```
var           truth        plateau_min   plateau_max
x1            0.261        0.261         0.261        ← pinned
x2            0.477        0.477         0.477        ← pinned
x3            0.864        0.864         1.058        ← 1.22x range
x4            0.793        0.648         0.793        ← 1.22x range
k01           0.835        0.835         0.835        ← pinned
k12           0.692        0.692         0.692        ← pinned
k13           0.818        0.637         0.818        ← 1.28x range
k14           0.478        0.478         0.614        ← 1.28x range
k21           0.895        0.895         0.895        ← pinned
k31           0.300        0.219         0.300        ← 1.37x range
k41           0.188        0.188         0.257        ← 1.37x range
```

Looks like a near-symmetry: pairs (x3, x4), (k13, k14), (k31, k41) move
together. Likely a partial state-relabeling symmetry that the structural
identifiability analysis didn't catch (but local sensitivity analysis would).
Truth is rank 5/618. Top-10 capture is robust.

`daisy_mamil4_3_1em6` (noise=1e-6) shows the same pattern with just 2
plateau rows: truth and an "alt" with x3↔x4 numerically swapped. Ranks 1 and 2.

### 3.4 cstr — stiff system with practical-id failure at noise

`cstr_5_1em8`. Truth's residual = ∞ in my audit (LSODA timed out at 2 s on
truth params). Plateau (21 rows): Temp, tau, Tin, UA_VrhoCP all pinned to
truth (1.01–1.04x). C and r_eff have huge spreads (std ~ 67, 1.2e-13).

Reading: C and r_eff are coupled algebraically (r_eff is a stiff reaction
rate); the data only constrains their joint effect on Temp. So they can swap
on the algebraic manifold without changing the residual. This isn't a sort-order
issue — it's a structural issue with how this system is observed.

The 2-second wall-clock cutoff in my audit is doing real damage on cstr.
Need to retest with longer integration budget or Julia integrator.

### 3.5 crauste — integrator unreliable; results not actionable

`crauste_9_0`. Truth residual = ∞ (LSODA timeout). Residual-best at 6.3e12,
oracle 3.4e4 — i.e. residual-best is total nonsense. We can't say from this
audit whether crauste is genuinely hard or my integrator is wrong; the
residual scale of 6e12 at noise=0 says the integrator isn't reproducing data,
period. ODEPE's own (Vern9-based) integrator is presumably handling it; my
scipy LSODA isn't.

A Julia-side re-audit using ODEPE's own integrator would settle this.

### 3.6 high-noise pathology (biohydrogenation @ 1e-2, cstr @ 1e-2)

`biohydrogenation_0_1em2`: ODEPE didn't find truth (row 1 oracle = 0.96).
Plateau has 402 rows. Within plateau: x4, x5, k5, k6 pinned within 5% of
truth; x6 spans 1e-5 to 5; k7–k10 spread 100–500x. At noise=1e-2 the data
simply doesn't constrain those parameters. There's no "true answer" to
inflate to — the cell is underdetermined.

This isn't an oracle-ranking issue. It's that at noise=1e-2 several systems
become genuinely unidentifiable on the data. Reporting noise=1e-2 success
rates is mostly reporting how often we get lucky, regardless of ranking
metric.

---

## 4. Interpretation

### 4.1 Three categories of plateau

The "plateau" (rows clustered near residual-best) has different structure
depending on the system:

1. **Single-axis non-id manifold.** ODEPE flags it correctly
   (biohydrogenation x7, aircraft_pitch theta). Plateau is parameterized by
   the non-id variable. All plateau rows are equally valid answers. Picking
   any one is fine. Top-K trivially captures truth.

2. **Multi-dim near-symmetry.** ODEPE doesn't flag (daisy_mamil4). Plateau
   is a low-dim ridge of equivalent-on-data solutions. Truth is one of 2–8
   candidates. Top-10 captures comfortably.

3. **Underdetermined at noise.** Multiple parameters become practically
   unidentifiable at high noise even if structurally identifiable
   (biohydrogenation_high-noise, cstr_high-noise). Plateau has 100s of
   distinct parameter combinations, no "correct" answer recoverable.

The first two are well-behaved problems with non-pathological residual
landscapes. The third is a noise pathology — not an oracle issue.

### 4.2 What the cheat actually buys

Across 60 cells, if we just took residual-best as the answer instead of
oracle-best, top-1 capture is 37% (all cells) / 42% (answer-bearing cells).
That sounds bad, but most "non-captures" are cells where:

- Truth is in plateau but isn't argmin (e.g. argmin is another point on the
  non-id manifold) → top-K with K ≥ size-of-plateau still catches it.
- Truth is buried in a flat region where ranking is dominated by numerical
  noise.
- Or the cell is underdetermined at noise and both truth and residual-best
  are "wrong" (so the cheat just picks a different "wrong" answer).

A more useful capture metric is "did residual ranking pick a candidate with
oracle within 10× of truth-best's oracle" — across most cells this is yes
for top-10. The cheat usually just shuffles within an equivalence class of
similar-quality solutions.

### 4.3 What the cheat costs (in headline numbers)

Estimating the impact on `odepe_v2_polish`'s 81% headline success rate is
hard because "success" is currently measured as `oracle_max_error < 0.1`,
which we'd compute from `oracle_max_error` of *whatever row gets picked as
the answer*. If we switched to residual-picking:

- 8 of 12 sampled systems: identical (residual-best = truth-best, or both are
  in the same equivalence class within tolerance)
- biohydrogenation, aircraft_pitch (non-id-flagged): identical, because all
  plateau rows have effectively the same `oracle_max_error` (they pin
  identifiable variables, only non-id varies).
- daisy_mamil4: maybe 1–2 cells out of 50 differ, because residual-best may
  pick a near-symmetric alt that's slightly off truth. Order ~1 pp on the
  per-system success rate.
- cstr / crauste / biohydrogenation high-noise: numbers shift more, but
  these were already low (~30–60% v2_polish success) — a few-pp swing.

Aggregated: order-of-magnitude estimate is 3–5 pp downward on the headline
v2_polish number, less on v2_nopolish. But this is a guess based on n=60;
to nail down would need a full audit at n ~ 4600 (one per cell), which
takes ~5 hours of compute.

---

## 5. Possible directions

### 5.1 The minimal honest fix

Change line 426 from:

```julia
sort([first(cluster) for cluster in clusters],
     by = candidate -> oracle_sort_key(problem, candidate))
```

to:

```julia
sort([first(cluster) for cluster in clusters],
     by = _result_err_key)
```

(i.e. use the same data-residual key already used at line 253.) This makes
the user-visible top-1 honest. Requires:

- Renaming `besterror` and the six `best_*_error` fields in
  `analysis_utils.jl` (they're computed from oracle stats; they should be
  named that way). E.g.:
  - `best_oracle_max_error` (was `besterror`)
  - `best_oracle_min_error` (was `best_min_error`)
  - ... etc.
  - Add `best_data_residual = first(sorted_results).err` (was
    `best_approximation_error` — the existing data-residual scalar).
- Updating downstream readers (numbat's `build_flat_metrics.py`, bilby's
  similar pipeline, the templates that print these) to handle both naming
  schemes during a transition window or pick one.
- Re-running the benchmark or post-hoc re-ranking. For a post-hoc re-rank
  we'd need each candidate's `.err` written to disk — see §5.3.

This is, plausibly, half a day of focused surgery.

### 5.2 Add an `err` column to result.csv

Currently `result.csv` is just states+params. Add a column `data_residual`
(value of `candidate.err`). This lets downstream re-rank on data residual
post-hoc without re-integrating.

```julia
# in templates/julia_template_for_estimation_odepe_v2.jl ~line 193
table = merge(
    Dict("data_residual" => [each.err for each in solutions_vector]),
    Dict((string(x) => [each.states[x] for each in solutions_vector] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in solutions_vector] for x in parameters)),
)
```

Tiny change. Big enabling effect: lets future experiments rank by anything
they want without re-integrating 4600 cells. Should probably also add
oracle.* columns optionally for benchmark mode (since the benchmark code
already has truth on hand and computing oracle is cheap once integration is
done).

### 5.3 Return top-K with metadata, let downstream choose

Make the API return a list of cluster representatives **with each one's
data residual and cluster-size attached**, sorted by data residual.
Downstream (the user, or in our case the benchmark harness) then makes
choices about top-1 vs top-K vs noise-aware-thresholded.

This is more invasive but makes the package philosophically cleaner: the
package returns *information about the residual landscape*, not a single
"answer." For non-id systems that's the only honest thing to return. For
identifiable systems the top-1 by residual will usually be unique.

### 5.4 Better non-cheating ranking heuristics

If the goal is "pick a single best candidate" (and we don't want to expose
the user to top-K complexity), then for the systems where residual-best ≠
truth-best, what other scoring signals could we use?

- **Cluster size.** The pre-clustering step groups candidates by similarity.
  A candidate from a 50-row cluster is more likely to be the right answer
  than a candidate from a 1-row cluster (singleton clusters are often
  numerical artifacts of HC).
- **Approximation-error consistency.** Each candidate has both `err` (data
  residual) and `approximation_error` (interpolation residual at sampled
  derivatives). When these agree, the candidate is likely real; when they
  disagree by orders of magnitude, the candidate is probably an HC
  artifact.
- **Stability under polish.** If a candidate's pre-polish and post-polish
  err are both small AND nearly equal, that's a stable optimum. Oracillating
  between them suggests polish is masking divergence.
- **BIC-style penalty for parameter magnitude.** Many of our pathological
  cases (cstr, crauste residual-bests) have parameters pegged at the search
  bounds (1e-5 or 10). A BIC-style or magnitude-prior penalty would
  deprecate those in favor of physically reasonable parameter values.

Worth investigating. None of these are silver bullets but combined they
would probably move the residual-only ranking from 42% top-1 capture to
maybe 60–70%, without using truth.

### 5.5 The variable-column-scaling investigation

Per `environments/ODEParameterEstimation/CLAUDE.md`'s open-investigations
section: many of the systems where residual-only ranking fails (cstr,
biohydrogenation, daisy_mamil4) show Jacobian condition numbers of 1e6–1e10
in the polynomial system. If column scaling fixed the conditioning, the
spurious "good residual" candidates from numerical artifacts of HC would
collapse, and residual ranking would work much better. So §5.4 and §5.5
are partially substitutes — solve the conditioning and you may not need the
fancy heuristics.

### 5.6 What we shouldn't do

**Don't** quietly fix line 426 without changing the metadata names. The
current metadata is widely consumed and has been since at least bilby; renames
need a transition. **Don't** assume the audit numbers transfer to v2_nopolish
without re-running — different selection criteria between polish and no-polish
flow. **Don't** attempt to "rerun the benchmark with the fix" before
understanding what fix to apply — the cstr/crauste integrator issues are real
problems that need investigation independent of ranking.

---

## 6. Open questions

- **How does v2_nopolish look?** Audit was v2_polish only. nopolish skips a
  step where local optimization can move candidates around — possibly the
  rank distribution is different.
- **Crauste integrator.** Is scipy LSODA failing because the system is genuinely
  intractable in 2 s, or because there's a parameter magnitude that pegs the
  solver? A Julia-side audit using `AutoVern9(Rodas4P())` would be definitive.
- **CSTR algebraic structure.** Is r_eff intended to be observed or is it an
  internal stiff variable? If it's internal-only, the fact that it's freely
  varying within plateau is correct, and the oracle metric is unfair to count
  it as an estimation error.
- **What's the residual-best behavior on AMIGO2 / SHADE results?** They return
  one candidate, so the question doesn't directly apply. But we could compare
  AMIGO2's chosen answer's residual to ODEPE's row 1's residual on the same
  cell.
- **How many of the 4600 cells in the full benchmark actually have
  truth-best ≠ residual-best?** Audit-extrapolation says ~40-60%, but this
  is from n=60. A full pass would be definitive and is computationally
  feasible (~5 hours).

---

## 7. Files in this audit

In `results/numbat_analysis/`:

- `oracle_ranking_audit.py` — the audit driver. CLI:
  `python3 oracle_ranking_audit.py --sample 60 --workers 16`.
  Uses scipy LSODA with SIGALRM timeouts and a 16-worker pool. Outputs
  `oracle_ranking_audit.csv`.
- `oracle_ranking_audit.csv` — per-cell results: `n_rows`,
  `rank_truth_best_by_residual`, top-K capture, etc. 60 rows currently.
- `oracle_ranking_summary.py` — summary statistics: per-cohort/per-noise/
  per-system breakdowns.
- `oracle_ranking_deepdive.py` — per-cell deep dive: re-computes per-row
  residual + oracle, characterizes the plateau structure, prints
  per-variable spread within the plateau.
- `deepdive_<cell_id>.csv` (one per cell) — augmented result.csv with
  added `residual` and `oracle` columns. Sortable any way.
- This file (`oracle_ranking_writeup.md`) — the present document.

Not in this commit (live state):

- 60 `deepdive_*.csv` files for cells outside the seven we focused on.
  Easy to regenerate.
- A full-benchmark (n=4600) audit. Would take ~5 hours; not run.

---

## 8. References (line numbers)

- `environments/ODEParameterEstimation/src/core/analysis_utils.jl:81–122` —
  `oracle_error_stats`, `oracle_sort_key` definitions.
- `environments/ODEParameterEstimation/src/core/analysis_utils.jl:131` —
  `_result_err_key` (the clean data-residual key, used at line 253 but not
  at line 426).
- `environments/ODEParameterEstimation/src/core/analysis_utils.jl:253` —
  pre-clustering sort by data residual (clean).
- `environments/ODEParameterEstimation/src/core/analysis_utils.jl:382` —
  `best_approximation_error = first(sorted_results).err` (the only
  honest data-residual scalar that survives into metadata).
- `environments/ODEParameterEstimation/src/core/analysis_utils.jl:388–407` —
  computation of `besterror`/`best_min_error`/`best_mean_error`/etc., all
  oracle-derived.
- `environments/ODEParameterEstimation/src/core/analysis_utils.jl:426` —
  the post-clustering sort by oracle (the cheat).
- `environments/ODEParameterEstimation/src/core/parameter_estimation.jl:901–914` —
  the legitimate `err` formula (sum of L2 norms of integrated-vs-observed
  data; no truth references).
- `templates/julia_template_for_estimation_odepe_v2.jl:193–199` — what gets
  written to `result.csv` (states + params, no err).
- `environments/ODEParameterEstimation/CLAUDE.md` — open-investigations
  section, variable-column-scaling note.
