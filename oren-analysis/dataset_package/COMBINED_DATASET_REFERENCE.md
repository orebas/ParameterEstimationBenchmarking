# Combined Dataset Reference Documentation

**File**: `combined_results.csv`
**Date Created**: 2025-11-11
**Size**: 1.2 MB
**Total Rows**: 2,750 (2,751 including header)

---

## Dataset Overview

This CSV file combines ODE parameter estimation benchmark results from two experimental runs, with preprocessing applied to ODEPE results. The dataset contains results from 5 software variants tested on 550 unique experiments (11 ODE systems × 5 noise levels × 10 instances).

### Software Variants Included

| Software Variant | Rows | Source Dataset | Description |
|-----------------|------|----------------|-------------|
| `odepe` | 550 | october_5_2025 | ODEPE solver (preprocessed to single solution) |
| `odepe_polish` | 550 | october_5_2025 | ODEPE with polishing (preprocessed to single solution) |
| `amigo2_0_10` | 550 | october_5_2025 | AMIGO2 with search bounds [0, 10] |
| `sciml` | 550 | october_5_2025 | SciML parameter estimation |
| `amigo2_0_100` | 550 | september_16_2025_search_bound_100 | AMIGO2 with search bounds [0, 100] |

---

## Data Provenance

### Source Datasets

**October 2025 Dataset**
- Path: `results/october_5_2025/result.csv`
- Created: October 7, 2024 (based on git history)
- Contains: 3,300 rows across 6 software variants
- Software variants extracted: `odepe`, `odepe_polish`, `amigo2_0_10`, `sciml`

**September 2025 Dataset**
- Path: `results/september_16_2025_search_bound_100/result.csv`
- Contains: 2,750 rows across 5 software variants
- Software variants extracted: `amigo2` (renamed to `amigo2_0_100`)
- Note: Name refers to search bound configuration [0, 100], not creation date

### Combination Process

1. **ODEPE Preprocessing**: ODEPE and ODEPE_polish rows originally contained multiple candidate solutions per experiment. These were preprocessed to select a single "best" solution using oracle-based selection (minimum relative error versus known true parameters).

2. **Data Extraction**: Specific software variants were extracted from each source dataset based on the `run` or `software` column.

3. **Renaming**: The September dataset's `amigo2` entries were renamed to `amigo2_0_100` to indicate the [0, 100] search bounds used in that configuration.

4. **Concatenation**: All extracted and preprocessed data was combined into a single CSV file, sorted by experiment ID and software variant.

---

## File Structure

### Columns

The CSV contains 17 columns:

| Column Name | Type | Description |
|-------------|------|-------------|
| `Unnamed: 0` | int | Original row index from source dataset |
| `index` | int | Secondary index |
| `id` | string | Unique experiment identifier (format: `{system}_{instance}_{noise}`) |
| `true_states` | dict string | True initial state values (Python dict as string) |
| `true_parameters` | dict string | True parameter values used to generate data (Python dict as string) |
| `time_start` | float | Start time for ODE integration |
| `time_end` | float | End time for ODE integration |
| `time_count` | int | Number of time points |
| `name` | string | ODE system name |
| `non_identifiable` | list string | List of non-identifiable state variables (Python list as string) |
| `noise` | float | Noise level applied to synthetic data |
| `finished` | bool | Whether the estimation run completed |
| `has_result` | bool | Whether a result was obtained (success indicator) |
| `run` | string | Software variant identifier |
| `software` | string | Software package name |
| `result` | list string | Estimated parameters (Python list as string, format: `[['param1', 'value1'], ...]`) |
| `time` | float | Computation time in seconds |

### Data Format Details

**true_parameters format**:
```python
"{'k5': 0.539, 'k6': 0.672, 'k7': 0.582}"
```

**result format** (single solution):
```python
"[['k5', '0.5390000000052579'], ['k6', '0.6720000000084422'], ['k7', '0.5820000033365446']]"
```

**id format**:
```
{system_name}_{instance_number}_{noise_level}
# Examples:
biohydrogenation_0_0        # instance 0, no noise
lotka_volterra_5_1em4       # instance 5, noise = 1e-4
```

---

## Experimental Design

### ODE Systems (11 total)

1. `biohydrogenation` - 6 parameters
2. `crauste` - 13 parameters (most complex)
3. `daisy_mamil3` - 4 parameters
4. `daisy_mamil4` - 7 parameters
5. `fitzhugh_nagumo` - 3 parameters
6. `harmonic` - 2 parameters
7. `hiv` - 10 parameters
8. `lotka_volterra` - 4 parameters
9. `seir` - 4 parameters
10. `slowfast` - 6 parameters
11. `vanderpol` - 2 parameters

### Noise Levels (5 total)

| Noise Level | Value | Identifier in `id` |
|-------------|-------|--------------------|
| No noise | 0.0 | `_0` |
| Very low | 1×10⁻⁸ | `_1em8` |
| Low | 1×10⁻⁶ | `_1em6` |
| Medium | 1×10⁻⁴ | `_1em4` |
| High | 1×10⁻² | `_1em2` |

### Instances

Each system-noise combination was run 10 times (instances 0-9) with different randomly generated true parameter values.

**Total experiments**: 11 systems × 5 noise levels × 10 instances = 550 unique experiments

---

## ODEPE Preprocessing Details

### Original ODEPE Format

ODEPE returns multiple candidate solutions for each problem. The original format stored N solutions as:

```python
[
  ['param1', 'sol1_val', 'sol2_val', ..., 'solN_val'],
  ['param2', 'sol1_val', 'sol2_val', ..., 'solN_val'],
  ...
]
```

### Preprocessing Applied

**Method**: Oracle-based best-solution selection
- For each experiment, all N candidate solutions were evaluated
- Relative error was calculated for each solution versus true parameters
- The solution with minimum relative error was selected
- Result column was reformatted to single-solution format

**Relative Error Formula**:
```
For each parameter:
  if |true_value| < 1e-10:
    error = |estimated - true|
  else:
    error = |estimated - true| / |true_value|

mean_error = mean(all parameter errors)
```

**Important Note**: This preprocessing uses knowledge of true parameters (oracle), which is only valid for benchmarking. In real applications, ODEPE's multiple solutions would be retained and solution selection would use different criteria (e.g., residual error, physical constraints).

---

## Loading the Data

### Python (pandas)

```python
import pandas as pd

# Load dataset
df = pd.read_csv('combined_results.csv')

# Filter to specific software
sciml_results = df[df['run'] == 'sciml']
odepe_results = df[df['run'] == 'odepe']

# Parse result column
import ast
def parse_result(result_str):
    if pd.isna(result_str) or result_str == '[]':
        return {}
    result_list = ast.literal_eval(result_str)
    return {param: float(value) for param, value in result_list}

df['result_dict'] = df['result'].apply(parse_result)

# Parse true parameters
df['true_params_dict'] = df['true_parameters'].apply(
    lambda x: ast.literal_eval(x) if pd.notna(x) else {}
)

# Calculate errors
def calculate_relative_error(row):
    estimated = row['result_dict']
    true_params = row['true_params_dict']

    common_params = set(estimated.keys()) & set(true_params.keys())
    if len(common_params) == 0:
        return float('inf')

    errors = []
    for param in common_params:
        est_val = estimated[param]
        true_val = true_params[param]

        if abs(true_val) < 1e-10:
            errors.append(abs(est_val - true_val))
        else:
            errors.append(abs(est_val - true_val) / abs(true_val))

    return sum(errors) / len(errors)

df['mean_error'] = df.apply(calculate_relative_error, axis=1)
```

### R

```r
library(readr)
library(jsonlite)
library(dplyr)

# Load dataset
df <- read_csv('combined_results.csv')

# Parse result column
parse_result <- function(result_str) {
  if (is.na(result_str) || result_str == '[]') {
    return(list())
  }
  # Convert Python list format to R
  result_str <- gsub("'", '"', result_str)
  result_list <- fromJSON(result_str)

  params <- setNames(
    as.numeric(result_list[, 2]),
    result_list[, 1]
  )
  return(params)
}

df$result_parsed <- lapply(df$result, parse_result)

# Filter to specific software
sciml_results <- df %>% filter(run == 'sciml')
```

---

## Success Rates

Number of successful results (has_result = True) by software variant:

| Software Variant | Success Count | Total | Success Rate |
|-----------------|---------------|-------|--------------|
| `odepe` | 548 | 550 | 99.6% |
| `odepe_polish` | 545 | 550 | 99.1% |
| `amigo2_0_10` | 547 | 550 | 99.5% |
| `sciml` | 548 | 550 | 99.6% |
| `amigo2_0_100` | 536 | 550 | 97.5% |

---

## Parameter Value Ranges

### True Parameters

All true parameters were generated from uniform distribution [0.1, 0.9] as specified in `config/config.json`:

```json
{
  "PARAM_INTERVAL": [0.1, 0.9]
}
```

Therefore, all true parameter values are in the range [0.1, 0.9].

### Search Bounds by Software

| Software | Search Bounds | Notes |
|----------|---------------|-------|
| `odepe` | Not bounded | Uses profile likelihood approach |
| `odepe_polish` | Not bounded | ODEPE with refinement step |
| `amigo2_0_10` | [0, 10] | Each parameter bounded in [0, 10] |
| `amigo2_0_100` | [0, 100] | Each parameter bounded in [0, 100] |
| `sciml` | Not specified | SciML default bounds |

---

## Time Intervals and Data Points

All experiments used consistent time configuration:

- **Time interval**: [-1.0, 1.0]
- **Number of points**: 1,001
- **Time step**: 0.002

This configuration is defined in `config/config.json`.

---

## Generation Script

This combined dataset was created using:

**Script**: `oren-analysis/combine_datasets.py`

**Command**:
```bash
python3 combine_datasets.py \
  --october ../results/october_5_2025/result.csv \
  --september ../results/september_16_2025_search_bound_100/result.csv \
  --output combined_results.csv \
  --verbose
```

**Script functions**:
- `parse_result_column_multi()`: Parses ODEPE multi-solution format
- `select_best_solution()`: Oracle-based solution selection for ODEPE
- `preprocess_odepe_row()`: Converts ODEPE row to single-solution format
- `combine_datasets()`: Main combination function

---

## Notes for Analysis

1. **ODEPE preprocessing**: The `odepe` and `odepe_polish` results have been preprocessed from multiple solutions to single solutions. If analyzing ODEPE's multiple-solution capability is important, use the original source datasets.

2. **Search bounds**: The `amigo2_0_10` and `amigo2_0_100` variants differ only in search bounds. Comparing these shows AMIGO's sensitivity to bound specification.

3. **Success indicator**: Use `has_result` column to filter successful runs. Unsuccessful runs have `result = '[]'`.

4. **Noise levels**: The `noise` column contains the actual noise value (0.0, 1e-8, etc.), while the `id` contains a string identifier (`_0`, `_1em8`, etc.).

5. **Non-identifiable states**: Some systems have non-identifiable state variables listed in the `non_identifiable` column. These were not measured/used in parameter estimation.

6. **Computation time**: The `time` column shows wall-clock time in seconds. This includes all computational overhead (not just core optimization).

---

## Related Files

- Original datasets:
  - `results/october_5_2025/result.csv` (source for odepe, odepe_polish, amigo2_0_10, sciml)
  - `results/september_16_2025_search_bound_100/result.csv` (source for amigo2_0_100)

- Configuration:
  - `config/config.json` - Experimental parameters
  - `config/systems.json` - ODE system definitions

- Documentation:
  - `oren-analysis/REPOSITORY_SUMMARY.md` - Complete repository overview
  - `oren-analysis/DATA_PROCESSING_GUIDE.md` - Detailed data processing instructions
  - `oren-analysis/ODEPE_PREPROCESSING_GUIDE.md` - ODEPE preprocessing documentation

---

## Contact

For questions about this dataset, refer to the original repository documentation or the analysis scripts in `oren-analysis/`.

---

**Document Version**: 1.0
**Last Updated**: 2025-11-11
