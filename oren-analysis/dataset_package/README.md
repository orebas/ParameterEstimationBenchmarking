# ODE Parameter Estimation Benchmark Dataset

**Package Date**: 2025-11-11

This package contains benchmark results for ODE parameter estimation software comparison.

---

## Contents

### Data Files

**`combined_results_filtered.csv`** (1.2 MB, 2,750 rows) - **RECOMMENDED**
- Combined benchmark results from 5 software variants
- 550 unique experiments (11 ODE systems × 5 noise levels × 10 instances)
- Single solution per row format (ODEPE preprocessed)
- **Non-identifiable parameters removed** (biohydrogenation x7 only)
- **Use this file for analysis**

**`combined_results.csv`** (1.2 MB, 2,750 rows) - Original unfiltered
- Same as above but includes all parameters/states
- Biohydrogenation includes x7 (non-identifiable state)
- Provided for reference/completeness

### Documentation

**`COMBINED_DATASET_REFERENCE.md`**
- Complete technical reference for the dataset
- Column descriptions, data formats, loading examples
- Data provenance and preprocessing details
- **START HERE** for understanding the data

### Configuration Files

**`config.json`**
- Experimental parameters used to generate synthetic data
- Time intervals, noise levels, parameter ranges
- Number of instances per configuration

**`systems.json`**
- ODE system definitions (equations, parameters, states)
- 11 benchmark systems from pharmacokinetics, epidemiology, ecology, etc.
- Parameter counts, measured variables, non-identifiable states

### Summary Statistics

**`summary_statistics/`** directory contains:
- `overall_performance.csv` - Success rates, mean/median errors, timing by software
- `performance_by_system.csv` - Mean error for each system-software combination
- `performance_by_noise.csv` - Mean error for each noise level-software combination
- `SUMMARY.md` - Human-readable markdown version with interpretations

**Generate/regenerate statistics**:
```bash
python3 generate_summary_statistics.py
```

### Analysis Documentation

**`PARAMETER_BOUNDS_FINDINGS.md`**
- Investigation of AMIGO's bound sensitivity
- Tests "hard-bounding" hypothesis (clamping to bound edges)
- Key finding: Clamping improves error by 61%, disproving hypothesis
- Shows AMIGO's issue is search space size (curse of dimensionality)

---

## Quick Start

### Software Variants Included

| Variant | Description | Rows |
|---------|-------------|------|
| `odepe` | ODEPE solver (oracle best-solution) | 550 |
| `odepe_polish` | ODEPE with polishing (oracle best-solution) | 550 |
| `amigo2_0_10` | AMIGO2 with bounds [0, 10] | 550 |
| `sciml` | SciML parameter estimation | 550 |
| `amigo2_0_100` | AMIGO2 with bounds [0, 100] | 550 |

### Load and Analyze (Python)

```python
import pandas as pd

# Load recommended filtered dataset
df = pd.read_csv('combined_results_filtered.csv')

# Filter to specific software
sciml = df[df['run'] == 'sciml']
amigo_10 = df[df['run'] == 'amigo2_0_10']

# Check success rates
print(df.groupby('run')['has_result'].sum())

# See COMBINED_DATASET_REFERENCE.md for:
# - Parsing result column
# - Calculating errors
# - Complete analysis examples
```

---

## Experimental Design

### Systems Tested (11)

- `biohydrogenation` (6 params) - Pharmacokinetics
- `crauste` (13 params) - Immune response (most complex)
- `daisy_mamil3` (4 params) - Pharmacokinetics
- `daisy_mamil4` (7 params) - Pharmacokinetics
- `fitzhugh_nagumo` (3 params) - Neuron dynamics
- `harmonic` (2 params) - Simple oscillator
- `hiv` (10 params) - HIV infection dynamics
- `lotka_volterra` (4 params) - Predator-prey
- `seir` (4 params) - Epidemic model
- `slowfast` (6 params) - Multi-scale dynamics
- `vanderpol` (2 params) - Oscillator

### Noise Levels (5)

- 0.0 (no noise)
- 1e-8 (very low)
- 1e-6 (low)
- 1e-4 (medium)
- 1e-2 (high)

### Instances

10 independent runs per system-noise combination with randomly generated true parameters from [0.1, 0.9].

**Total**: 11 × 5 × 10 = 550 experiments per software variant

---

## Software Versions

Original experiments were run with:
- **Julia**: 1.11.5
- **Python**: 3.9 / 3.10

Software packages:
- ODEPE (profile likelihood approach)
- AMIGO2 (MATLAB-based optimization)
- SciML (Julia DifferentialEquations.jl ecosystem)

---

## Key Methodological Notes

### ODEPE Preprocessing

ODEPE returns multiple candidate solutions per experiment (typically 40-200 solutions). For this combined dataset:

- **Preprocessing applied**: Oracle-based best-solution selection
- **Selection criterion**: Minimum relative error versus known true parameters
- **Result**: Single solution per row (same format as AMIGO/SciML)
- **Validity**: This approach is valid for benchmarking only (uses ground truth)

In real applications, ODEPE's multiple solutions would be retained as they represent parameter uncertainty.

### AMIGO Search Bounds

The two AMIGO variants differ only in search bound specification:

- `amigo2_0_10`: Each parameter searched in [0, 10]
- `amigo2_0_100`: Each parameter searched in [0, 100]

True parameters are all in [0.1, 0.9], so both bounds contain the true values. The comparison shows AMIGO's sensitivity to search space size.

**Excluded variants**:
- `amigo2_0_1` (bounds [0, 1]) - Considered unrealistically tight
- `amigo2_m100_100` (bounds [-100, 100]) - Too punitive (46.5% failure rate)

The included [0, 10] and [0, 100] bounds represent realistic practitioner conditions.

### Non-Identifiable Parameters

**What was filtered**: Biohydrogenation state variable **x7**

**Why it's non-identifiable**: The biohydrogenation system measures only states x4 and x5. State x7 evolves according to the ODE `x7' = k9 * x6 * (k10 - x6) / k10` but does not affect any measured quantities. Therefore, x7 cannot be uniquely determined from the measurements alone - it is structurally non-identifiable.

**What was done**:
- The **filtered dataset** (`combined_results_filtered.csv`) removes x7 from both `result` and `true_states` columns for all biohydrogenation experiments
- All other systems have no non-identifiable parameters
- This prevents x7 from incorrectly affecting error calculations

**Which file to use**:
- **For analysis/comparisons**: Use `combined_results_filtered.csv` (recommended)
- **For reference**: Use `combined_results.csv` (includes x7)

**Regenerating the filtered file**:
```bash
python3 filter_nonidentifiable.py
```

---

## Data Provenance

### Source Datasets

**October 2025 Dataset** (`results/october_5_2025/result.csv`)
- Created: October 7, 2024
- Software extracted: odepe, odepe_polish, amigo2_0_10, sciml

**September 2025 Dataset** (`results/september_16_2025_search_bound_100/result.csv`)
- Named for search bound configuration [0, 100]
- Software extracted: amigo2_0_100

### Combination Process

1. Extracted specific software variants from each source
2. Preprocessed ODEPE variants (multi-solution → single best solution)
3. Renamed September AMIGO entries to `amigo2_0_100` for clarity
4. Combined and sorted by experiment ID

**Script**: `combine_datasets.py` (in parent repository)

---

## Citation and Usage

This dataset was generated for benchmarking ODE parameter estimation software. When using this data:

1. Cite the software packages being compared
2. Note that ODEPE results use oracle-based solution selection
3. Acknowledge that true parameters are known (synthetic benchmark)

---

## Questions?

See **`COMBINED_DATASET_REFERENCE.md`** for complete technical details including:
- All column definitions
- Data format specifications
- Complete loading and analysis code examples
- Error calculation methods
- Success rate breakdowns

For ODE system equations and parameter details, see **`systems.json`**.

For experimental configuration, see **`config.json`**.

For AMIGO bound sensitivity analysis, see **`PARAMETER_BOUNDS_FINDINGS.md`**.

---

**Package Created**: 2025-11-11
**Repository**: https://github.com/sumiya11/no-matlab-no-worry
