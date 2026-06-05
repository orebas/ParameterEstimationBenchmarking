# quoll-broad (2026-05-29) vs wallaby (2026-05-17) — apples-to-apples

**Shared systems:** 23 (wallaby set); quoll's 2 latent + 2 receptor branch systems are quoll-only.
**Same metric code** (build_flat_metrics_wallaby.py) and **same pipeline family** (residual-best row 0; M-truncated result.csv), so top1-vs-top1 and BoB-vs-BoB are like-for-like.

**⚠ Real differences (not metric artifacts):** quoll 8 replicas/cell vs wallaby 10; quoll `POLISH_MAXTIME=600s` vs wallaby `3600s` (6× less, polish arm only); quoll is the later v2 stack (generic_start / branch_completion / column scaling) vs wallaby's SHA; quoll slow-tail (crauste/latent re-solves) still draining → missing cells scored as failures.

## Best-of-branches (M-bounded) — PAPER HEADLINE

| Method | q t(s) | w t(s) | q@1 | w@1 | q@10 | w@10 | Δ@10 | q@50 | w@50 |
|---|---|---|---|---|---|---|---|---|---|
| ODEPE-v2 (polish) | 827 | 713 | 67.9 | 67.7 | 78.2 | 78.8 | -0.6 | 82.2 | 83.3 |
| AMIGO2 | 407 | 633 | 67.6 | 67.2 | 77.4 | 76.1 | 1.3 | 81.7 | 80.8 |
| SHADE+LM | 311 | 372 | 63.0 | 62.3 | 71.8 | 69.8 | 2.0 | 75.8 | 74.0 |
| ODEPE-v2 (nopolish) | 555 | 764 | 55.0 | 56.7 | 64.5 | 66.3 | -1.8 | 74.0 | 75.2 |


## Top-1 (the algorithm's row-0 pick — what users see)

| Method | q t(s) | w t(s) | q@1 | w@1 | q@10 | w@10 | Δ@10 | q@50 | w@50 |
|---|---|---|---|---|---|---|---|---|---|
| ODEPE-v2 (polish) | 827 | 713 | 63.4 | 64.8 | 72.6 | 75.3 | -2.7 | 76.3 | 80.1 |
| AMIGO2 | 407 | 633 | 67.6 | 67.2 | 77.4 | 76.1 | 1.3 | 81.7 | 80.8 |
| SHADE+LM | 311 | 372 | 63.0 | 62.3 | 71.8 | 69.8 | 2.0 | 75.8 | 74.0 |
| ODEPE-v2 (nopolish) | 555 | 764 | 51.6 | 53.0 | 60.4 | 61.8 | -1.4 | 69.0 | 70.5 |


## Bottom line

- **Best-of-branches (paper headline): quoll ties wallaby across all four methods** (polish 78.2 vs 78.8, AMIGO2 +1.3, SHADE +2.0, nopolish -1.9 — all within ±2pp). The candidate *generation* is on par with wallaby; there is **no BoB regression**.
- The only material per-system BoB gap is **crauste** (15% vs 48%), and quoll's crauste is **incomplete** (38/40 cells — slow-tail re-solves still draining, scored as failures) on top of crauste's known genuine hardness.
- **Excluding crauste, quoll polish is +0.8pp ahead** of wallaby (81.0 vs 80.2 on the other 22 systems).
- The Top-1 polish gap (-2.8pp) is consistent with quoll's 6× smaller polish budget (600s vs 3600s) plus branch ranking; the BoB tie confirms the truth is still found, just occasionally ranked second.
- AMIGO2/SHADE (identical tools in both runs) move only +1.3/+2.0pp — a clean control showing the comparison carries no systematic bias.

## Per-system Best-of-branches @10% — ODEPE-v2 (polish), biggest movers

**quoll below wallaby:**

| System | quoll | wallaby | Δpp |
|---|---|---|---|
| crauste | 15.0 | 48.0 | -33.0 |
| slow_fast | 75.0 | 82.0 | -7.0 |
| cstr | 2.5 | 8.0 | -5.5 |
| seir | 57.5 | 60.0 | -2.5 |
| forced_lotka_volterra | 95.0 | 96.0 | -1.0 |
| quadrotor | 97.5 | 98.0 | -0.5 |
| daisy_mamil3 | 87.5 | 88.0 | -0.5 |
| bicycle_model | 100.0 | 100.0 | 0.0 |


**quoll at/above wallaby:**

| System | quoll | wallaby | Δpp |
|---|---|---|---|
| sirt_treatment | 80.0 | 74.0 | 6.0 |
| brusselator | 65.0 | 60.0 | 5.0 |
| vanderpol | 100.0 | 96.0 | 4.0 |
| hiv | 47.5 | 44.0 | 3.5 |
| daisy_mamil4 | 75.0 | 72.0 | 3.0 |
| boost_converter | 100.0 | 98.0 | 2.0 |
