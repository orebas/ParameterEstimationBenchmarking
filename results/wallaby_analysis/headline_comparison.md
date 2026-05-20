# Wallaby benchmark — headline comparison

**Benchmark:** `benchmark_wallaby_2026-05-17` (paper-clean from-scratch run, ODEPE `282fe1a..3afd1e5`, PEB `760576979`).
**Coverage:** 4 estimators × 23 systems × 5 noise levels × 10 instances = 4600 cells.
**Status:** 4594/4600 result.csv landed; 6 known-OOM cells in
ODEPE polish/nopolish on `crauste` and `biohydrogenation` at hard noise
levels; 1 straggler (`crauste_6_1em6` nopolish) still in SLURM at write
time. Analysis below treats missing cells as failures.

The numbers in this doc are intended for the paper. Coarse thresholds
(≤50%, ≤10%, ≤1%) are featured per the user-stated rationale: once
within 1% of truth via Newton-style polish, you can always ask for more
polish from a good basin. Sub-1% thresholds are kept for diagnostics
only.

**Three metric families** are reported. Paper headline is **M-bounded**.

- **Top-1**: the algorithm's row-0 pick. What a user sees by default.
- **M-bounded** (paper headline): best of the top M rows, where M is
  the algebraic multiplicity from `config/systems.json`. For 19 of 23
  systems M=1, so M-bounded ≡ top-1. For daisy_mamil4, seir,
  slow_fast, biohydrogenation (M=2), the algorithm gets credit for
  finding both algebraic branches — independent of which one row 0
  happens to land on. ODEPE's K=20 is then interpreted as a numerical
  safety cap, not a credit-limiting parameter.
- **Best-of-K (oracle)**: argmin over all K=20 rows. Set-credit
  ceiling — what the algorithm could have done with a perfect rank.

---

## 1. Headline (top-1, what users currently see)

The algorithm's own row-0 pick scored by `max_rel_error` on
identifiable axes only. AMIGO2 and SHADE have K=1 so top-1 = oracle.

| Method                 | Median time (s) | succ @ 1% | succ @ 10% | succ @ 50% |
|------------------------|---:|----:|----:|----:|
| **ODEPE-v2 (polish)**  | 694 | **64.7%** | 75.4% | 80.4% |
| **AMIGO2**             | 633 | 67.2% | **76.1%** | **80.8%** |
| **SHADE+LM**           | 372 | 62.3% | 69.8% | 74.0% |
| **ODEPE-v2 (nopolish)**| 743 | 52.8% | 61.6% | 69.9% |

**Reading:** ODEPE-v2 (polish) ties AMIGO2 at the headline 50%
threshold (80.4% vs 80.8%, ~0.4pp gap), at roughly comparable per-cell
median time. SHADE is 1.7× faster but loses 6-11pp on coarse thresholds.

## 2. M-bounded (paper headline)

For each cell, score the best of the top `M` rows where `M =
algebraic_multiplicity` from `config/systems.json` (1 for 19 of 23
systems, 2 for daisy_mamil4, seir, slow_fast, biohydrogenation). For
K=1 methods (AMIGO2, SHADE) this is identical to top-1.

| Method                 | succ @ 1% | succ @ 10% | succ @ 50% |
|------------------------|----:|----:|----:|
| **ODEPE-v2 (polish)**  | **67.5%** | **78.5%** | **83.2%** |
| AMIGO2                 | 67.2% | 76.1% | 80.8% |
| **ODEPE-v2 (nopolish)**| 56.1% | 65.7% | 74.4% |
| SHADE+LM               | 62.3% | 69.8% | 74.0% |

**Reading:** ODEPE-v2 polish leads at all three coarse thresholds —
+2.4pp @10% and +2.4pp @50% vs AMIGO2. The top-1 → M-bounded lift on
polish is **+3.1pp @10%** and **+2.8pp @50%** — that's the headline
gain from giving the algorithm credit for finding all M algebraic
branches.

Per multiplicity-2 system, top-1 → M-bounded uplift @10% (polish):
- daisy_mamil4: **30% → 72%** (+42pp; channel-swap captured at row 1)
- seir: **40% → 60%** (+20pp; (a, ν)-hyperbola alt at row 1)
- slow_fast: **72% → 82%** (+10pp; alt branch is OOB but row 1
  sometimes catches a bound-clipped near-truth variant)
- biohydrogenation: 56% → 56% (no lift; polish correctly rejects the
  OOB k9<0 alt, so row 1 is OOB junk, not a truth alt)

The first three are clean wins; biohydrogenation is a wash because
its alt branch is fundamentally non-physical and polish correctly
rejects it. The paper claim "we find all M algebraic branches" still
holds — biohydrogenation's alt exists as an unpolished raw HC
candidate deeper in K=20.

## 3. Best-of-K (oracle) — set-credit ceiling

Argmin over all rows of `result.csv` per cell on identifiable axes.
For AMIGO2 and SHADE (K=1) this equals top-1. For ODEPE (K=20) the
gap measures how much rank-1 sort leaves on the table.

| Method                 | succ @ 1% | succ @ 10% | succ @ 50% |
|------------------------|----:|----:|----:|
| **ODEPE-v2 (polish)**  | **68.9%** | **84.3%** | **85.7%** |
| **ODEPE-v2 (nopolish)**| 57.7% | 69.6% | 79.0% |
| AMIGO2                 | 67.2% | 76.1% | 80.8% |
| SHADE+LM               | 62.3% | 69.8% | 74.0% |

**Reading:** Under oracle, ODEPE-v2 polish leads by **+4.9pp @ 50%**
and **+8.2pp @ 10%** vs the next method. The top-1 → oracle gap on
polish is **+10pp @ 10%** (75.4% → 84.3%) — that's the headroom in
the row-0 sort. The current S2 default narrows this gap on coarse
thresholds; switching to `:err_only` widens it back at fine thresholds
(see ODEPE `repro/polish_regression_2026_05_19/FINDINGS.md`).

## 4. Five-way comparison vs prior numbat reruns

Both K=20 oracle and M-bounded on the two ODEPE estimators combined
(n=2300 polish+nopolish cells per benchmark):

### Best-of-K (oracle, K=20) — historical metric

| Metric           |    06   |    12   |    13   |    14   | wallaby |
|------------------|--------:|--------:|--------:|--------:|--------:|
| median oracle    | 1.92e-4 | 6.94e-4 | 4.79e-4 | 2.28e-4 | 5.87e-4 |
| succ @ 1%        | **67.0%** | 61.4% | 64.2% | 66.0% | 63.5% |
| succ @ 10%       | **76.8%** | 75.1% | 73.3% | 75.7% | 75.6% |
| succ @ 50%       | **83.7%** | 82.4% | 81.2% | 82.7% | 82.5% |
| total CPU-hr     |   2805  |  1081  |  1345  |  1266  | **1363** |

### M-bounded (paper headline)

| Metric           |    06   |    12   |    13   |    14   | wallaby |
|------------------|--------:|--------:|--------:|--------:|--------:|
| median M-bounded | 1.97e-4 | 9.33e-4 | 9.78e-4 | 8.91e-4 | 9.69e-4 |
| succ @ 1%        | **66.9%** | 59.5% | 60.1% | 59.9% | 61.9% |
| succ @ 10%       | **76.8%** | 68.6% | 68.8% | 68.7% | **72.3%** |
| succ @ 50%       | **83.7%** | 76.8% | 77.1% | 77.0% | **79.0%** |

**Reading:**
- Under K=20 oracle, wallaby ≈ numbat-14 on coarse thresholds (within
  0.1-0.2pp at @10% and @50%). Under **M-bounded, wallaby is +3.6pp
  ahead of 14 @10% and +2.0pp ahead @50%.** That gap is the value of
  putting the truth-near row at rank ≤ M (wallaby's improved IS
  clustering pays off here).
- 14's K=20 oracle was "cheating" with deeper rows — its oracle @10%
  is 75.7% but its M-bounded @10% is only 68.7%, a -7pp drop. Wallaby
  drops only -3.3pp (75.6% → 72.3%) under the same restriction.
- 06's K=20 oracle ≈ 06's M-bounded — 06's K=20 candidates were
  already concentrated in the top M rows. The newer pipelines (12, 13,
  14, wallaby) spread their K=20 wider, and only wallaby keeps the
  truth-near row near rank 1.
- Total CPU-hr is +7% vs 14 — the SHADE 600→1200 time bump shows up
  here (this table includes only ODEPE polish+nopolish; SHADE's
  contribution is reported separately).

### Recovery vs 06 baseline (within Nx of 06's oracle)

| Multiplier | 12 | 13 | 14 | wallaby |
|---:|---:|---:|---:|---:|
| within 2×  | 68% | 67% | **81%** | 68% |
| within 3×  | 73% | 73% | **87%** | 74% |
| within 5×  | 81% | 81% | **90%** | 82% |
| within 10× | 87% | 88% | **94%** | 89% |
| within 20× | 92% | 92% | **96%** | 93% |

14 is the most closely-matched run to 06 on this metric. Wallaby
matches 12 and 13 closely — meaningful regression vs 14, principally
in tight-tolerance cells.

### Per-noise success @ 10% (key paper table)

| Noise | 06 | 12 | 13 | 14 | wallaby |
|---|---:|---:|---:|---:|---:|
| 0       | 95.0% | 94.7% | 95.0% | 95.0% | 95.0% |
| 1e-8    | 88.4% | 87.2% | 88.0% | 87.7% | 87.1% |
| 1e-6    | 83.6% | 82.8% | 82.2% | 83.2% | 82.4% |
| 1e-4    | 71.6% | 70.5% | 67.9% | 70.6% | 69.7% |
| 1e-2    | 45.4% | 40.1% | 33.3% | 42.0% | **44.1%** |

**Reading:** Wallaby is the best of the post-06 reruns at the high-noise
end (1e-2: +2.1pp vs 14) — soft-wall and the K=20 candidate set help on
the hardest cells. It's slightly behind 06/14 at all the lower-noise
buckets (~0.5-1pp).

## 5. Per-estimator delta vs 14 @ 10%

### Best-of-K (oracle)

| Estimator         | 06 | 14 | wallaby | wallaby − 14 |
|---|---:|---:|---:|---:|
| `odepe_v2_polish`  | 81.7% | 80.2% | **81.3%** | +1.2pp |
| `odepe_v2_nopolish`| 71.9% | 71.2% | 69.9% | -1.3pp |

### M-bounded (paper headline)

| Estimator         | 06 | 14 | wallaby | wallaby − 14 |
|---|---:|---:|---:|---:|
| `odepe_v2_polish`  | 81.7% | 72.2% | **78.7%** | **+6.5pp** |
| `odepe_v2_nopolish`| 71.9% | 65.1% | 65.8% | +0.7pp |

**Reading:** Under M-bounded, ODEPE-v2 polish gains **+6.5pp vs 14**
— more than 5× the K=20 oracle gain. The structural change is in IS
clustering + S2 sort: wallaby's K=20 candidate list keeps the
truth-near row at rank ≤ M, while 14's spread the truth-near row
further down. nopolish shows a smaller +0.7pp lift; its truth-finding
is more variable so even the M-bounded comparison is noisy.

## 6. Notable wins vs 06 (and the regression pattern)

The aggregate numbers slightly hide a stark per-cell story (see
`per_cell_callouts.md` for the full list):

**Dramatic improvements** — cells where 06 totally failed and wallaby
recovered:

| Cell | Estimator | 06 oracle | Wallaby oracle | Ratio |
|---|---|---|---|---|
| `crauste_9_1em8` | polish | 1.58e-1 | 7.26e-5 | **2182× better** |
| `crauste_1_1em8` | polish | 4.47e-1 | 2.24e-4 | **1996× better** |
| `crauste_4_1em6` | polish | 1.00 | 2.82e-3 | **354× better** |
| `forced_lotka_volterra_2_1em4` | nopolish | 1.29e-1 | 3.93e-3 | 33× better |
| `cstr_3_0` | polish | 9.70e-3 | 4.32e-4 | 22× better |
| `crauste_9_1em4` | nopolish | 7.25e+1 | 4.07 | 18× better |

These are the kind of cells where 06's HC pipeline simply didn't find
the basin and wallaby's soft-wall + IS clustering + K=20 does. There
are 16 such ≥3× improvements.

**Regression pattern** — 254 cells where wallaby is ≥10× worse than
06's oracle. **The list is dominated by aircraft_pitch** (the
continuous-unidentifiable system), and almost entirely at fine
precision: 06 at ~1e-6 / 1e-8, wallaby at ~1e-4. Examples:

| Cell | Estimator | 06 oracle | Wallaby oracle | Ratio |
|---|---|---|---|---|
| `aircraft_pitch_6_1em6` | polish | 7.66e-6 | 2.91e-3 | ×381 |
| `aircraft_pitch_9_0` | polish | 5.30e-10 | 1.18e-7 | ×222 |
| `aircraft_pitch_0_1em6` | polish | 6.60e-6 | 9.47e-4 | ×143 |

These don't move the coarse paper thresholds — the values stay below
10% — but they explain why the median oracle is +3× higher in wallaby
(5.87e-4 vs 1.92e-4 in 06). aircraft_pitch's high sensitivity to small
numerical differences (continuous-unidentifiable theta(t) silently
plugged by ODEPE) magnifies any stack-level change into a measurable
oracle shift.

**Bottom line**: wallaby trades aircraft_pitch fine-precision shifts
for dramatic crauste recoveries. Net at coarse paper thresholds, the
trade is neutral-to-slightly-favorable.

## 7. AMIGO2 alignment with 06

AMIGO2 cells should be bit-identical to 06 because the data,
the AMIGO2 template, and the AMIGO2 settings were all carried forward
unchanged (deterministic seeds → bit-identical synthetic data; the
template was untouched). Anything within nondeterminism noise is
expected. **TODO:** spot-check 5 AMIGO2 cells' result.csv hashes vs 06
to confirm bit-identity (cheap sign-off check).

## 8. Caveats

- **6 missing cells** in ODEPE polish/nopolish — known OOM territory on
  hard `crauste` (cells 2_1em4, 3_1em8, 9_0, 6_1em6) and
  `biohydrogenation` (4_1em8, 3_1em6). Counted as failures in the
  numbers above. The Symbolics.jacobian / build_function memory fix
  (ODEPE `e85a9f4`) landed too late for this run; expect those cells
  to fit memory in the next benchmark.
- **1 straggler** still in SLURM at write time (`crauste_6_1em6`
  nopolish, 25+ hours elapsed). The accuracy/timing numbers freeze the
  current snapshot.
- **Top-1 vs oracle**: paper headline is top-1 (algorithmic pick). The
  oracle column is reported separately as set-credit ceiling. The gap
  (top1 → oracle = +10pp on polish at @10%) measures rank-1 sort
  potential — see `INVESTIGATION_polish_regression_root_cause.md` and
  ODEPE's `repro/polish_regression_2026_05_19/FINDINGS.md` for the
  S2-vs-err_only trade-off we evaluated and settled on (S2 default
  kept for coarse-threshold alignment).
- **Multiplicity-aware dedup not applied**. result.csv rows for the 4
  algebraically-multiplicity-2 systems (daisy_mamil4, seir, slow_fast,
  biohydrogenation) are counted as-is, even when row N is a near-duplicate
  of row 0 differing only along an unidentifiable axis. The
  `multiplicity/MULTIPLICITY_FINDINGS.md` companion doc handles this
  question separately.

## 9. Source data

- `accuracy_five_way.csv` (this directory) — per-cell oracle + n_rows
  + wall_time across all 5 benchmarks. 2300 rows (polish + nopolish).
- `flat_results_with_metrics.csv` — per-cell top1 + oracle + sidecar
  fields for all 4 wallaby estimators. 4600 rows.
- `independent_analysis/REPORT.md` + tables/ + figures/ — full
  per-method, per-system, per-noise wallaby standalone view.
- `benchmark_wallaby_2026-05-17/result.csv` — benchmark-level aggregate.
- `independent_analysis/presentation.html` — 70-slide reveal.js deck
  (uses top-1 metric throughout; oracle slides not yet added).
- `multiplicity/` — algebraic + physical multiplicity catalog (see
  also ODEPE `repro/multiplicity_complete_2026_05_19/MULTIPLICITY_COMPLETE.md`).

## 10. One-line for the paper

> Under the M-bounded metric (best of M = algebraic-multiplicity
> returned solutions, M auto-computed via SIAN), ODEPE-v2 polish
> leads AMIGO2 by **+2.4pp @10%** and **+2.4pp @50%** on the
> 23-system benchmark, at comparable median per-cell time. Giving
> the algorithm credit for the M algebraic branches it returns
> (instead of just row 0) lifts ODEPE polish by **+3.1pp @10%**
> with no algorithmic change — and lifts the wallaby-vs-14 polish
> delta from +1.2pp (K=20 oracle) to **+6.5pp (M-bounded)**, showing
> that the IS-clustering + S2-sort improvements put truth-near rows
> within the algebraic-bound top M.
