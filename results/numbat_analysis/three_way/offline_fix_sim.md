# Offline fix simulation

**Source**: 101 probe cells from 124-cell regression set (polished_dump.csv pre-clustering).

## Baseline (current 13)
- Median oracle on these probe cells: **1.75e-01**
- Cells within 2× of 06: 3/101 = 3%

## Recovery to within 2× of 06

| variant | n recovered | % |
|---|---|---|
| current 13 (clustering + top_k=20) | 3/101 | 3% |
| fixA K=20 (dedup@1e-5 + top-K) | 75/101 | 74% |
| fixA K=50 (dedup@1e-5 + top-K) | 77/101 | 76% |
| fixA K=100 (dedup@1e-5 + top-K) | 78/101 | 77% |
| fixA K=200 (dedup@1e-5 + top-K) | 80/101 | 79% |
| fixA K=500 (dedup@1e-5 + top-K) | 81/101 | 80% |
| noClust K=20 (sort polished, top-K) | 72/101 | 71% |
| noClust K=50 (sort polished, top-K) | 75/101 | 74% |
| noClust K=100 (sort polished, top-K) | 77/101 | 76% |
| noClust K=200 (sort polished, top-K) | 79/101 | 78% |
| noClust K=500 (sort polished, top-K) | 81/101 | 80% |

## Improvement over current 13 (≥2× better)

| variant | n improved | % |
|---|---|---|
| fixA K=20 | 89/101 | 88% |
| fixA K=50 | 90/101 | 89% |
| fixA K=100 | 91/101 | 90% |
| fixA K=200 | 91/101 | 90% |
| fixA K=500 | 91/101 | 90% |
| noClust K=20 | 89/101 | 88% |
| noClust K=50 | 90/101 | 89% |
| noClust K=100 | 91/101 | 90% |
| noClust K=200 | 91/101 | 90% |
| noClust K=500 | 91/101 | 90% |

## fixA vs noClust at same K (does cluster_solutions dedup hurt?)

| K | fixA better than noClust | fixA equal | fixA worse |
|---|---|---|---|
| 20 | 6 | 95 | 0 |
| 50 | 2 | 99 | 0 |
| 100 | 1 | 100 | 0 |
| 200 | 2 | 99 | 0 |
| 500 | 0 | 101 | 0 |

## Headline

- **fixA K=100** recovers 78/101 = 77% of probe cells to 2× of 06
- **noClust K=100** recovers 77/101 = 76% (essentially same as fixA — dedup@1e-5 only catches identical convergences)
- vs current 13's 3/101 = 3% on the same cells

## Median n_deduped (cells get this many candidates if we apply cluster_solutions only)

- min=1, p25=8, median=39, p75=75, max=350

## Median n_polished (cells get this many candidates with NO dedup)

- min=6, p25=46, median=73, p75=170, max=564
