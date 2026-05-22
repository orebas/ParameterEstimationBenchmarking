# M-truncation impact estimate

**Question.** If ODEPE truncates `result.csv` from K=20 rows to M rows 
(where M is the algebraic multiplicity from `config/systems.json`), what's 
the visible impact on benchmark stats?

**Method.** The new ODEPE would output `rows[0:M]` of what it currently 
outputs as K=20. So:
- top-1 is **unchanged** (row 0 doesn't move)
- new "oracle" = best-of-M = today's `mbounded_*` columns

All numbers below come from `flat_results_with_metrics.csv`. No new 
benchmark run is needed.

## 1. Per-estimator headline (top-1 / K=20 oracle / new oracle = mbounded)

| Method | Threshold | Top-1 | Oracle (K=20) | New (≡ mbounded) | Δ |
|---|---|---:|---:|---:|---:|
| ODEPE-v2 (polish) | @1% | 64.8% | 67.7% | 67.7% | +0.00pp |
| ODEPE-v2 (polish) | @10% | 75.4% | 78.9% | 78.9% | +0.00pp |
| ODEPE-v2 (polish) | @50% | 80.2% | 83.4% | 83.4% | +0.00pp |
| ODEPE-v2 (no polish) | @1% | 53.1% | 56.8% | 56.8% | +0.00pp |
| ODEPE-v2 (no polish) | @10% | 61.9% | 66.4% | 66.4% | +0.00pp |
| ODEPE-v2 (no polish) | @50% | 70.6% | 75.3% | 75.3% | +0.00pp |
| AMIGO2 | @1% | 67.2% | 67.2% | 67.2% | +0.00pp |
| AMIGO2 | @10% | 76.1% | 76.1% | 76.1% | +0.00pp |
| AMIGO2 | @50% | 80.8% | 80.8% | 80.8% | +0.00pp |
| SHADE+LM | @1% | 62.3% | 62.3% | 62.3% | +0.00pp |
| SHADE+LM | @10% | 69.8% | 69.8% | 69.8% | +0.00pp |
| SHADE+LM | @50% | 74.0% | 74.0% | 74.0% | +0.00pp |

**Reading:** AMIGO2 and SHADE are K=1 and unaffected. ODEPE polish loses 
~0.0pp of K=20-oracle credit at @10%; top-1 unchanged. 
**Paper-headline M-bounded metric is unaffected** by definition.

## 2. Per-system (ODEPE @10%) where truncation costs accuracy

(no system shows any delta at @10%)

## 3. Cells where truncation costs (oracle <1% but new ≥10%)

**0 cells / 2300 ODEPE cells** where the K=20 
oracle found a truth-near row beyond `rows[0:M]`.


## 4. Implication

**Truncation is fully benign at the paper-headline thresholds.** No 
cell loses its truth-near row by going from K=20 to M.

Detailed per-cell data in `m_truncation_impact.csv`.