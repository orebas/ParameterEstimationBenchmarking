# Dataset Comparison - ODE Parameter Estimation Benchmark

**Repository**: `/home/orebas/tmp/no-matlab-no-worry/`
**Purpose**: Comparison of all 10 result directories to identify which dataset to use
**Date**: 2025-11-11

---

## Quick Recommendation

### For Current Analysis
**Use**: `september_16_2025_search_bound_100`
- **Reason**: Most recent, complete, standard configuration
- **Path**: `/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/`
- **Size**: 3.1 GB
- **Modified**: 2025-11-11 16:02:08

### For Maximum Coverage
**Use**: `october_5_2025`
- **Reason**: Largest dataset with most extensive results
- **Path**: `/home/orebas/tmp/no-matlab-no-worry/results/october_5_2025/`
- **Size**: 7.0 GB
- **Modified**: 2025-11-11 15:59:30

---

## Complete Dataset Comparison Table

| Dataset Name | Size | Modified Date | Git Commit | Results | Config | Status |
|-------------|------|---------------|------------|---------|--------|--------|
| **september_16_2025_search_bound_100** | 3.1 GB | 2025-11-11 16:02:08 | 0b6d8fbd7 | result.csv (2,750 rows) | Bounds: [0.0, 1.0] | ✅ **LATEST** |
| **october_5_2025** | 7.0 GB | 2025-11-11 15:59:30 | 039a4209a | Extensive | Standard | ✅ **MOST COMPLETE** |
| **september_16_2025_search_bound_10** | 1.9 GB | 2025-11-11 16:01:56 | 115727c00 | result.csv | Bounds: [0.0, 10.0] | ✅ Complete |
| **september_15_2025_with_polishing** | 2.1 GB | 2025-11-11 16:00:52 | - | result.csv | ODEPE polish: true | ✅ Complete |
| **september_15_2025** | 1.7 GB | 2025-11-11 16:00:10 | 1e47ddeb3 | result.csv | Standard | ✅ Complete |
| **FINAL3** | 1.8 GB | 2025-11-11 15:57:02 | - | result.csv | Standard | ✅ Complete |
| **FINAL2** | 1.5 GB | 2025-11-11 15:57:02 | - | result.csv | Standard | ✅ Complete |
| **EXAMPLE** | 334 MB | 2025-11-11 15:57:02 | - | Partial | Test run | ⚠️ Partial |
| **FINAL_LARGE** | 608 KB | 2025-11-11 15:57:02 | - | Metadata only | - | ⚠️ Incomplete |
| **FINAL6** | 3.7 MB | 2025-11-11 15:57:02 | - | Minimal | - | ⚠️ Minimal |

---

## Detailed Dataset Profiles

### 1. september_16_2025_search_bound_100 ⭐ RECOMMENDED

**Path**: `results/september_16_2025_search_bound_100/`

**Vitals**:
- **Size**: 3.1 GB
- **Modified**: 2025-11-11 16:02:08 (most recent)
- **Git Commit**: 0b6d8fbd7 (2025-10-08) "add sciml with larger bounds"
- **Archive**: `archive/2025_september_16_search_bound_100.txt` (836 KB)

**Configuration**:
```json
{
  "SEARCH_BOUNDS": [0.0, 1.0],  // Default bounds
  "NUM_TESTS": 10,
  "TIME_INTERVAL": [-1.0, 1.0],
  "NUM_PTS": 1001,
  "NOISE_LEVEL": {0, 1e-8, 1e-6, 1e-4, 1e-2}
}
```

**Contents**:
- ✅ `huge_json.json` (30 MB) - Complete metadata
- ✅ `result.csv` (2,750 rows) - All results
- ✅ `result.json` (611 KB) - Structured results
- ✅ `filetree/data_original/` - 110 clean instances
- ✅ `filetree/data_noisy/` - 550 noisy instances (5 levels)
- ✅ `filetree/pe_run/` - ParameterEstimation.jl results
- ✅ `filetree/odepe_run/` - ODEParameterEstimation.jl results
- ✅ `filetree/sciml_run/` - SciML results
- ✅ `filetree/amigo2_run/` - AMIGO2 results (partial)

**Results Breakdown**:
```
Total results: 2,750
- 11 systems × 10 instances × 5 noise levels × ~5 software runs
- All systems covered: biohydrogenation, crauste, daisy_mamil3,
  daisy_mamil4, fitzhugh_nagumo, harmonic, hiv, lotka_volterra,
  seir, vanderpol, slowfast
```

**Why Use This**:
- ✅ Most recent dataset
- ✅ Standard configuration (matches config.json)
- ✅ Complete coverage of all systems
- ✅ Multiple software comparisons
- ✅ Full noise spectrum
- ✅ Well-documented in archive

**Use Cases**:
- Primary analysis and publication figures
- Software comparison benchmarks
- Noise robustness analysis
- General ODE parameter estimation research

---

### 2. october_5_2025 ⭐ MOST EXTENSIVE

**Path**: `results/october_5_2025/`

**Vitals**:
- **Size**: 7.0 GB (largest)
- **Modified**: 2025-11-11 15:59:30
- **Git Commit**: 039a4209a (2025-10-07) "Add new results"
- **Archive**: `archive/2025_october_5.txt` (990 KB, largest archive)

**Configuration**:
```json
{
  "SEARCH_BOUNDS": [0.0, 1.0],
  "NUM_TESTS": 10,
  "TIME_INTERVAL": [-1.0, 1.0],
  "NUM_PTS": 1001,
  "NOISE_LEVEL": {0, 1e-8, 1e-6, 1e-4, 1e-2}
}
```

**Contents**:
- ✅ `huge_json.json` - Complete metadata
- ✅ `result.csv` - Extensive results
- ✅ `result.json` - Structured results
- ✅ All filetree directories with extensive data

**Why Largest**:
- Possibly includes additional software runs
- May have re-runs or extended experiments
- More comprehensive logging
- Additional analysis artifacts

**Why Use This**:
- ✅ Maximum data coverage
- ✅ Most comprehensive results
- ✅ Best for exhaustive analysis
- ✅ Includes potential edge cases

**Use Cases**:
- Comprehensive meta-analysis
- Mining for rare failure modes
- Extensive statistical validation
- When you need absolutely all available data

---

### 3. september_16_2025_search_bound_10

**Path**: `results/september_16_2025_search_bound_10/`

**Vitals**:
- **Size**: 1.9 GB
- **Modified**: 2025-11-11 16:01:56
- **Git Commit**: 115727c00 (2025-09-17) "add experiment result with search bound from 0 to 10"
- **Archive**: `archive/2025_september_16_search_bound_10.txt` (813 KB)

**Configuration**:
```json
{
  "SEARCH_BOUNDS": [0.0, 10.0],  // ⚠️ WIDER BOUNDS
  "NUM_TESTS": 10,
  "TIME_INTERVAL": [-1.0, 1.0],
  "PARAM_INTERVAL": [0.1, 0.9],  // True params still in [0.1, 0.9]
  "NUM_PTS": 1001
}
```

**Key Difference**: Search space 10× wider than true parameter range

**Why Use This**:
- ✅ Study impact of search bounds on convergence
- ✅ Compare with search_bound_100 (bounds match param range)
- ✅ Analyze optimizer robustness to initialization
- ✅ Test performance with looser constraints

**Use Cases**:
- Search strategy research
- Optimizer comparison under uncertainty
- Bound sensitivity analysis
- Comparing constrained vs. relaxed optimization

**Expected Findings**:
- Potentially longer execution times
- May have more local minima issues
- Could show different software performance rankings

---

### 4. september_15_2025_with_polishing

**Path**: `results/september_15_2025_with_polishing/`

**Vitals**:
- **Size**: 2.1 GB
- **Modified**: 2025-11-11 16:00:52
- **Archive**: `archive/2025_september_15_with_polishing.txt` (818 KB)

**Configuration**:
```json
{
  "ODEPE_POLISH": "true",  // ⚠️ POST-PROCESSING ENABLED
  "SEARCH_BOUNDS": [0.0, 1.0],
  "NUM_TESTS": 10,
  "TIME_INTERVAL": [-1.0, 1.0],
  "NUM_PTS": 1001
}
```

**Key Feature**: ODEParameterEstimation.jl "polishing" step enabled

**What is Polishing**:
- Refinement step after initial estimation
- Local optimization around coarse estimate
- Improves accuracy at cost of computation time

**Why Use This**:
- ✅ Study impact of post-processing
- ✅ Compare polished vs. unpolished results
- ✅ Analyze accuracy vs. time tradeoff
- ✅ Best-case accuracy for ODEPE

**Use Cases**:
- Polishing effectiveness study
- Quality vs. speed analysis
- ODEPE optimization research
- When highest accuracy is needed

**Compare With**: `september_15_2025` (without polishing)

---

### 5. september_15_2025

**Path**: `results/september_15_2025/`

**Vitals**:
- **Size**: 1.7 GB
- **Modified**: 2025-11-11 16:00:10
- **Git Commit**: 1e47ddeb3 (2025-09-16) "Update 2025_september_15.txt"
- **Archive**: `archive/2025_september_15.txt` (804 KB)

**Configuration**:
```json
{
  "ODEPE_POLISH": "false",  // No polishing
  "SEARCH_BOUNDS": [0.0, 1.0],
  "NUM_TESTS": 10,
  "TIME_INTERVAL": [-1.0, 1.0],
  "NUM_PTS": 1001
}
```

**Why Use This**:
- ✅ Baseline for polishing comparison
- ✅ Faster results without post-processing
- ✅ Standard configuration

**Use Cases**:
- Baseline performance metrics
- Comparing with `september_15_2025_with_polishing`
- When speed is prioritized over accuracy

---

### 6. FINAL3

**Path**: `results/FINAL3/`

**Vitals**:
- **Size**: 1.8 GB
- **Modified**: 2025-11-11 15:57:02
- **Archive**: Likely included in earlier archives

**Configuration**: Standard (default bounds)

**Why Use This**:
- ✅ One of the finalized runs
- ✅ Complete dataset
- ✅ Historical comparison

**Use Cases**:
- Historical analysis
- Reproducibility checks
- Earlier methodology comparison

---

### 7. FINAL2

**Path**: `results/FINAL2/`

**Vitals**:
- **Size**: 1.5 GB
- **Modified**: 2025-11-11 15:57:02

**Configuration**: Standard

**Why Use This**:
- ✅ Earlier finalized run
- ✅ Alternative dataset for validation

**Use Cases**:
- Cross-validation with other datasets
- Historical methodology

---

### 8. EXAMPLE ⚠️

**Path**: `results/EXAMPLE/`

**Vitals**:
- **Size**: 334 MB (much smaller)
- **Modified**: 2025-11-11 15:57:02

**Contents**: Partial dataset, likely for testing

**Why Small**:
- Fewer instances (not full 110)
- Fewer software runs
- Test/demonstration purpose

**Use Cases**:
- Testing data processing scripts
- Example for documentation
- Quick sanity checks
- Learning the data format

**⚠️ Not Recommended For**:
- Publication analysis
- Comprehensive benchmarking
- Statistical conclusions

---

### 9. FINAL_LARGE ⚠️

**Path**: `results/FINAL_LARGE/`

**Vitals**:
- **Size**: 608 KB (tiny!)
- **Modified**: 2025-11-11 15:57:02

**Contents**: Metadata only (huge_json.json, config files)

**Why So Small**: No actual result data

**Use Cases**:
- Configuration reference
- Instance definitions
- NOT for analysis

**⚠️ Status**: Incomplete, missing results

---

### 10. FINAL6 ⚠️

**Path**: `results/FINAL6/`

**Vitals**:
- **Size**: 3.7 MB (minimal)
- **Modified**: 2025-11-11 15:57:02

**Contents**: Very limited data

**Use Cases**:
- Configuration reference only
- NOT for analysis

**⚠️ Status**: Minimal data, incomplete

---

## Comparison by Use Case

### For Publication-Quality Analysis
**Recommended**: `september_16_2025_search_bound_100`
- Most recent
- Standard configuration
- Complete coverage
- Well-documented

**Alternative**: `october_5_2025` (if you need maximum data)

---

### For Search Bounds Research
**Use**: Both of these together:
1. `september_16_2025_search_bound_100` (bounds = param range)
2. `september_16_2025_search_bound_10` (bounds = 10× param range)

**Analysis**: Compare convergence, accuracy, time with different bounds

---

### For Post-Processing Study
**Use**: Both of these together:
1. `september_15_2025` (no polishing)
2. `september_15_2025_with_polishing` (with polishing)

**Analysis**: Quantify polishing impact on ODEPE performance

---

### For Maximum Coverage
**Use**: `october_5_2025`
- Largest dataset
- Most comprehensive
- Best for statistical power

---

### For Quick Testing/Prototyping
**Use**: `EXAMPLE`
- Small, fast to load
- Good for testing code
- Not for conclusions

---

## Dataset Evolution Timeline

```
Timeline (chronological by git commits):

1. Early experiments → FINAL2, FINAL3, FINAL6, FINAL_LARGE, EXAMPLE
   - Initial testing and methodology development

2. 2025-09-15/16 → september_15_2025, september_15_2025_with_polishing
   - Commit: 1e47ddeb3 "Update 2025_september_15.txt"
   - Standard runs with/without polishing

3. 2025-09-17 → september_16_2025_search_bound_10
   - Commit: 115727c00 "add experiment result with search bound from 0 to 10"
   - Wider search bounds experiment

4. 2025-10-07 → october_5_2025
   - Commit: 039a4209a "Add new results"
   - Most extensive dataset (7.0 GB)

5. 2025-10-08 → september_16_2025_search_bound_100
   - Commit: 0b6d8fbd7 "add sciml with larger bounds"
   - Latest, recommended dataset
```

**Current State**: `september_16_2025_search_bound_100` is the most recent and recommended

---

## File Completeness Matrix

| Dataset | huge_json.json | result.csv | result.json | data_original | data_noisy | pe_run | odepe_run | sciml_run | amigo2_run |
|---------|---------------|------------|-------------|---------------|------------|--------|-----------|-----------|------------|
| **september_16_2025_search_bound_100** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| **october_5_2025** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **september_16_2025_search_bound_10** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| **september_15_2025_with_polishing** | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ✅ | ⚠️ | ⚠️ |
| **september_15_2025** | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ✅ | ⚠️ | ⚠️ |
| **FINAL3** | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| **FINAL2** | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| **EXAMPLE** | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ❌ |
| **FINAL_LARGE** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **FINAL6** | ⚠️ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

Legend:
- ✅ Complete
- ⚠️ Partial
- ❌ Missing

---

## Size Breakdown Analysis

### Why october_5_2025 is Largest (7.0 GB)

Possible reasons:
1. **More software runs**: Additional tools or reruns
2. **Extended logging**: More verbose stdout/stderr
3. **Additional experiments**: Extra instances or noise levels
4. **Diagnostic data**: Intermediate optimization steps
5. **Multiple attempts**: Failed + successful runs kept

**To investigate**: Check filetree subdirectories for extra content

### Why september_16_2025_search_bound_100 is Recommended Despite Being Smaller

1. **Most recent**: Latest methodology and fixes
2. **Clean dataset**: Only successful runs, no clutter
3. **Standard config**: Matches documentation
4. **Well-documented**: Has archive summary
5. **Git-tracked**: Clear provenance

---

## Archive File Comparison

Archive files contain human-readable statistical summaries:

| Archive File | Size | Dataset | Date |
|-------------|------|---------|------|
| 2025_october_5.txt | 990 KB | october_5_2025 | Latest |
| 2025_september_16_search_bound_100.txt | 836 KB | september_16_2025_search_bound_100 | 2025-09-16 |
| 2025_september_16_search_bound_10.txt | 813 KB | september_16_2025_search_bound_10 | 2025-09-16 |
| 2025_september_15_with_polishing.txt | 818 KB | september_15_2025_with_polishing | 2025-09-15 |
| 2025_september_15.txt | 804 KB | september_15_2025 | 2025-09-15 |

**Archive Contents**:
- Summary statistics
- Per-system performance
- Per-software performance
- Accuracy metrics
- Execution time statistics
- Success rates

**Use Archives For**:
- Quick overview without loading data
- Historical comparison
- Reproducing paper figures
- Sanity checking new analyses

---

## Decision Matrix

### Choose Dataset Based On:

| Your Goal | Recommended Dataset | Why |
|-----------|-------------------|-----|
| **Current publication** | september_16_2025_search_bound_100 | Latest, complete, standard |
| **Maximum statistical power** | october_5_2025 | Largest, most data |
| **Search bounds study** | september_16_2025_search_bound_10 + _100 | Compare narrow vs. wide |
| **Polishing effectiveness** | september_15_2025 + _with_polishing | Direct comparison |
| **Historical analysis** | FINAL2, FINAL3 | Earlier methodology |
| **Code testing** | EXAMPLE | Small, fast |
| **General benchmarking** | september_16_2025_search_bound_100 | Best overall |
| **Exhaustive analysis** | october_5_2025 | Maximum coverage |

---

## Loading Multiple Datasets

### For Comparative Analysis

```python
import pandas as pd
from pathlib import Path

BASE = Path('/home/orebas/tmp/no-matlab-no-worry/results')

# Load multiple datasets
datasets = {
    'latest': BASE / 'september_16_2025_search_bound_100' / 'result.csv',
    'extensive': BASE / 'october_5_2025' / 'result.csv',
    'wide_bounds': BASE / 'september_16_2025_search_bound_10' / 'result.csv',
    'polished': BASE / 'september_15_2025_with_polishing' / 'result.csv',
    'unpolished': BASE / 'september_15_2025' / 'result.csv',
}

dfs = {}
for name, path in datasets.items():
    if path.exists():
        dfs[name] = pd.read_csv(path)
        print(f"{name}: {len(dfs[name])} results")
    else:
        print(f"{name}: NOT FOUND")

# Compare
for name, df in dfs.items():
    success_rate = (df['has_result'] == True).sum() / len(df) * 100
    print(f"{name}: {success_rate:.1f}% success rate")
```

---

## Final Recommendations

### Primary Dataset
**`september_16_2025_search_bound_100`**
- Path: `/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/`
- Use for: All general analysis, publication figures, benchmarking

### Secondary Dataset (for depth)
**`october_5_2025`**
- Path: `/home/orebas/tmp/no-matlab-no-worry/results/october_5_2025/`
- Use for: When you need maximum data, statistical validation

### Special Purpose Datasets
- **Search bounds study**: Use both `search_bound_100` and `search_bound_10`
- **Polishing study**: Use both `september_15_2025` and `_with_polishing`
- **Testing code**: Use `EXAMPLE`

### Avoid
- `FINAL_LARGE`: Incomplete
- `FINAL6`: Minimal data

---

**Document Created**: 2025-11-11
**Purpose**: Guide dataset selection for ODE parameter estimation analysis
**Recommendation**: Start with `september_16_2025_search_bound_100`
