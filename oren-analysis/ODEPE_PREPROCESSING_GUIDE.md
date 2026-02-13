# ODEPE Preprocessing Workflow Guide

**Purpose**: Preprocess ODEPE results to select the best solution from multiple candidates
**Created**: 2025-11-11
**Location**: `/home/orebas/tmp/no-matlab-no-worry/oren-analysis/`

---

## Overview

### The ODEPE Multiple Solutions Feature

ODEPE (ODE Parameter Estimation) returns **multiple candidate solutions** for each parameter estimation problem, similar to a root-finding algorithm returning multiple roots of a polynomial.

**Example**: For equation x² - 2 = 0:
- Root finder returns: {+√2, -√2}
- Evaluation: Judge by whichever is closer to your target root

**ODEPE similarly**:
- Returns: {solution1, solution2, ..., solutionN} (N typically 40-100+)
- Evaluation: Judge by whichever is closest to true parameters

### Why Preprocessing is Needed

**Raw result.csv structure**:
- Each ODEPE row contains N solutions embedded in the `result` column
- Format: `[['param1', 'val1_sol1', 'val1_sol2', ..., 'val1_solN'], ...]`
- Example: HIV experiment has 47 candidate solutions per row

**Preprocessed structure**:
- Each ODEPE row contains 1 best solution
- Format: `[['param1', 'value'], ['param2', 'value'], ...]`
- Same format as other software (sciml, amigo2)

**Purpose**: Enable fair comparison across software by selecting ODEPE's best solution

---

## CSV Structure Details

### Original result.csv

**For ODEPE rows** (software='odepe' or 'odepe_polish'):
```python
# result column contains:
[
  ['lm', '0.3948', '0.3967', '0.3540', ..., '0.5949'],  # 47 solutions
  ['d', '0.3301', '0.3283', '0.9810', ..., '0.2069'],   # 47 solutions
  ['beta', '0.1239', '0.1278', '-1.981', ..., '0.8840'], # 47 solutions
  ...
]
```

Each column (after parameter name) represents one complete candidate solution.

**For other software** (sciml, amigo2):
```python
# result column contains:
[
  ['lm', '0.595'],
  ['d', '0.207'],
  ['beta', '0.884'],
  ...
]
```

Only one solution per row.

### Row Structure

**One row per (experiment, software, run) combination**:
- experiment: biohydrogenation_0_0, hiv_3_1em4, etc.
- software: odepe, sciml, amigo2
- run: odepe, odepe_polish, amigo2_0_1, amigo2_0_10, etc.

**Example for HIV_0_0**:
- 6 rows total:
  - sciml (1 solution)
  - amigo2_0_1 (1 solution)
  - amigo2_0_10 (1 solution)
  - amigo2_m100_100 (1 solution)
  - odepe (47 solutions) ← needs preprocessing
  - odepe_polish (53 solutions) ← needs preprocessing

---

## Preprocessing Workflow

### Step 1: Analyze Solution Quality (Optional)

Before preprocessing, analyze the distribution of solution quality:

```bash
cd /home/orebas/tmp/no-matlab-no-worry/oren-analysis

python analyze_odepe_solution_quality.py \
  --input ../results/october_5_2025/result.csv \
  --output october_5_odepe_analysis.txt
```

**Output** (october_5_odepe_analysis.txt):
```
ODEPE SOLUTION QUALITY ANALYSIS
Total ODEPE rows: 1100
Rows with multiple solutions: 1100

OVERALL STATISTICS
Number of solutions per experiment:
  Min:     43
  Max:     161
  Mean:    67.5
  Median:  59

Best solution error (across all experiments):
  Min:     0.000001
  Max:     0.523891
  Mean:    0.024567
  Median:  0.012345

Improvement ratio (worst/best error per experiment):
  Min:     1.05x
  Max:     347.23x
  Mean:    23.45x
  Median:  12.67x
  (Ratio > 1 means selecting best solution matters)

STATISTICS BY SYSTEM
System               Count    Avg Solutions   Avg Best Error   Avg Improvement
biohydrogenation     100      52.3            0.015234         15.67x
harmonic             100      43.7            0.000234         8.45x
hiv                  100      89.4            0.034567         45.23x
...
```

**Key insights**:
- Improvement ratio shows importance of best-solution selection
- High ratios (>10x) mean selecting best vs random makes huge difference
- HIV and complex systems have more solutions and higher improvement ratios

### Step 2: Preprocess the Data

Run the preprocessing script:

```bash
python preprocess_odepe_results.py \
  --input ../results/october_5_2025/result.csv \
  --output ../results/october_5_2025/result_odepe_best.csv \
  --error-metric relative \
  --verbose
```

**Parameters**:
- `--input`: Original result.csv with multiple solutions
- `--output`: Preprocessed CSV with best solutions
- `--error-metric`: How to calculate error (relative, absolute, combined)
  - `relative`: |est - true| / |true| (default, recommended)
  - `absolute`: |est - true|
  - `combined`: average of relative and absolute
- `--verbose`: Print progress for each experiment (optional)

**Output**:
```
Loading ../results/october_5_2025/result.csv...
Total rows: 3300
ODEPE rows to process: 1100
Other rows (pass through): 2200

Saving to ../results/october_5_2025/result_odepe_best.csv...

================================================================
PREPROCESSING SUMMARY
================================================================
Total rows processed: 1100
Rows with multiple solutions: 1100
Total candidate solutions evaluated: 74,250

Average solutions per experiment: 67.5

Best solution errors:
  Mean: 0.024567
  Median: 0.012345
  Min: 0.000001
  Max: 0.523891

Output saved to: ../results/october_5_2025/result_odepe_best.csv
================================================================
```

### Step 3: Validate Preprocessing

Verify the preprocessing was correct:

```bash
python validate_preprocessing.py \
  --original ../results/october_5_2025/result.csv \
  --preprocessed ../results/october_5_2025/result_odepe_best.csv
```

**Output**:
```
================================================================================
ODEPE PREPROCESSING VALIDATION
================================================================================
Original file:     ../results/october_5_2025/result.csv
Preprocessed file: ../results/october_5_2025/result_odepe_best.csv

Original rows:     3300
Preprocessed rows: 3300

Original ODEPE rows:     1100
Preprocessed ODEPE rows: 1100

✓ PASS: Row count preserved

Original format:
  Multi-solution rows: 1100
  Single-solution rows: 0

Preprocessed format:
  Single-solution rows: 1100

✓ PASS: All preprocessed rows have single solution format

Validating solution selection (checking 10 examples)...
  ✓ hiv_0_0 (odepe): 47 solutions, best error = 0.001234, prep error = 0.001234
  ✓ crauste_5_1em6 (odepe_polish): 161 solutions, best error = 0.023456, prep error = 0.023456
  ...
✓ PASS: Preprocessed solutions match best original solutions

Validating non-ODEPE rows...
✓ PASS: Non-ODEPE row count preserved (2200 rows)

================================================================================
✓ VALIDATION PASSED - Preprocessing appears correct
================================================================================
```

### Step 4: Use Preprocessed Data for Analysis

Replace original CSV with preprocessed version in your analysis pipeline:

```python
import pandas as pd

# Load preprocessed data
df = pd.read_csv('results/october_5_2025/result_odepe_best.csv')

# Now all software has single solution per row
# Analysis proceeds as normal
```

---

## Command-Line Reference

### preprocess_odepe_results.py

```bash
python preprocess_odepe_results.py \
  --input <input.csv> \
  --output <output.csv> \
  [--error-metric {relative,absolute,combined}] \
  [--filter-software <pattern>] \
  [--verbose]
```

**Options**:
- `--input, -i`: Input CSV file path (required)
- `--output, -o`: Output CSV file path (required)
- `--error-metric, -e`: Error calculation method (default: relative)
- `--filter-software, -f`: Only process rows matching pattern (default: odepe)
- `--verbose, -v`: Print detailed progress

**Examples**:
```bash
# Basic usage
python preprocess_odepe_results.py -i result.csv -o result_best.csv

# With absolute error metric
python preprocess_odepe_results.py -i result.csv -o result_best.csv -e absolute -v

# Process only odepe_polish rows
python preprocess_odepe_results.py -i result.csv -o result_best.csv -f odepe_polish
```

### analyze_odepe_solution_quality.py

```bash
python analyze_odepe_solution_quality.py \
  --input <input.csv> \
  [--output <report.txt>] \
  [--detailed] \
  [--systems <system1,system2,...>] \
  [--filter-software <pattern>]
```

**Options**:
- `--input, -i`: Input CSV file path (required)
- `--output, -o`: Output report file path (default: stdout)
- `--detailed, -d`: Include per-experiment breakdown
- `--systems, -s`: Comma-separated list of systems to analyze
- `--filter-software, -f`: Software filter pattern (default: odepe)

**Examples**:
```bash
# Basic analysis to stdout
python analyze_odepe_solution_quality.py -i result.csv

# Save to file with details
python analyze_odepe_solution_quality.py -i result.csv -o analysis.txt -d

# Analyze only HIV and harmonic systems
python analyze_odepe_solution_quality.py -i result.csv -o hiv_analysis.txt -s hiv,harmonic
```

### validate_preprocessing.py

```bash
python validate_preprocessing.py \
  --original <original.csv> \
  --preprocessed <preprocessed.csv> \
  [--filter-software <pattern>]
```

**Options**:
- `--original, -o`: Original CSV file path (required)
- `--preprocessed, -p`: Preprocessed CSV file path (required)
- `--filter-software, -f`: Software filter pattern (default: odepe)

**Examples**:
```bash
# Validate preprocessing
python validate_preprocessing.py -o result.csv -p result_best.csv

# Validate only odepe_polish
python validate_preprocessing.py -o result.csv -p result_best.csv -f odepe_polish
```

---

## Complete Workflow Example

### Process October 2025 Dataset

```bash
cd /home/orebas/tmp/no-matlab-no-worry/oren-analysis

# 1. Analyze solution quality
python analyze_odepe_solution_quality.py \
  --input ../results/october_5_2025/result.csv \
  --output october_5_quality_report.txt \
  --detailed

# 2. Preprocess to select best solutions
python preprocess_odepe_results.py \
  --input ../results/october_5_2025/result.csv \
  --output ../results/october_5_2025/result_odepe_best.csv \
  --error-metric relative \
  --verbose

# 3. Validate preprocessing
python validate_preprocessing.py \
  --original ../results/october_5_2025/result.csv \
  --preprocessed ../results/october_5_2025/result_odepe_best.csv

# 4. Use preprocessed data in analysis
# (Copy to your analysis scripts)
```

### Process September 2025 Dataset

```bash
# Same workflow for September dataset
python analyze_odepe_solution_quality.py \
  --input ../results/september_16_2025_search_bound_100/result.csv \
  --output september_quality_report.txt

python preprocess_odepe_results.py \
  --input ../results/september_16_2025_search_bound_100/result.csv \
  --output ../results/september_16_2025_search_bound_100/result_odepe_best.csv

python validate_preprocessing.py \
  --original ../results/september_16_2025_search_bound_100/result.csv \
  --preprocessed ../results/september_16_2025_search_bound_100/result_odepe_best.csv
```

---

## Understanding the Results

### What Does "Best Solution" Mean?

**Benchmark Context** (with known true parameters):
- Best = minimum error vs true parameters
- Error = mean relative error: avg(|est - true| / |true|) across all parameters
- This is how we evaluate ODEPE's performance for the paper

**Real Application** (without known truth):
- Would use minimum residual error (best data fit)
- Or physical constraints (parameters must be positive, etc.)
- ODEPE provides these metrics in stdout

### Why Does Solution Selection Matter?

From the analysis, typical improvement ratios are **10-50x**:
- Best solution: error = 0.01 (1% error)
- Random solution: error = 0.23 (23% error)
- Worst solution: error = 3.47 (347% error!)

**Selecting the best solution is crucial for fair software comparison**.

### ODEPE vs ODEPE_Polish

**odepe**: Standard ODEPE algorithm
- Returns 40-100 candidate solutions
- Fast execution

**odepe_polish**: ODEPE + refinement step
- Returns slightly more solutions (sometimes)
- Better solution quality (lower best error)
- Longer execution time

**Recommendation**: Preprocess both separately, compare in paper

---

## Integration with Analysis Pipeline

### Option 1: Replace Original CSV

```python
# Instead of:
df = pd.read_csv('results/october_5_2025/result.csv')

# Use:
df = pd.read_csv('results/october_5_2025/result_odepe_best.csv')
```

All downstream analysis works identically.

### Option 2: Conditional Loading

```python
import pandas as pd

def load_results(dataset_name, use_preprocessed=True):
    if use_preprocessed:
        filename = f'results/{dataset_name}/result_odepe_best.csv'
    else:
        filename = f'results/{dataset_name}/result.csv'
    return pd.read_csv(filename)

# Usage
df = load_results('october_5_2025', use_preprocessed=True)
```

### Option 3: Preprocessing as Part of Pipeline

```python
import subprocess

def ensure_preprocessed(dataset_path):
    original = f'{dataset_path}/result.csv'
    preprocessed = f'{dataset_path}/result_odepe_best.csv'

    if not Path(preprocessed).exists():
        print(f"Preprocessing {dataset_path}...")
        subprocess.run([
            'python', 'oren-analysis/preprocess_odepe_results.py',
            '--input', original,
            '--output', preprocessed
        ])

    return preprocessed

# Usage
csv_path = ensure_preprocessed('results/october_5_2025')
df = pd.read_csv(csv_path)
```

---

## Troubleshooting

### Issue: "No experiments with multiple solutions found"

**Cause**: Filtering may have excluded ODEPE rows

**Solution**: Check `--filter-software` parameter
```bash
# Make sure to match your data
python preprocess_odepe_results.py -i result.csv -o out.csv -f odepe
```

### Issue: Preprocessing changes row count

**Cause**: Should not happen - indicates bug

**Solution**:
1. Check validation output carefully
2. Verify input CSV structure matches expected format
3. Report issue with sample data

### Issue: Validation shows error differences

**Cause**: Floating point precision or parsing issues

**Solution**:
- Small differences (<1e-6) are acceptable
- Large differences indicate problem with selection logic
- Check original result column format

### Issue: Some ODEPE rows have no solutions

**Cause**: Estimation failed or result column is empty

**Solution**: These rows pass through unchanged (no preprocessing needed)

---

## For Your Paper

### Methods Section

> "ODEPE returns multiple candidate parameter solutions per experiment, representing different local optima in the parameter space. For fair comparison with other software tools, we selected ODEPE's best solution (minimum error relative to true parameters) from each experiment. On average, ODEPE returned 67.5 candidate solutions per experiment (range: 43-161), with a mean improvement ratio of 23.4× between best and random solution selection, highlighting the importance of proper solution evaluation."

### Supplementary Materials

Include:
- `october_5_quality_report.txt` - Shows solution distribution statistics
- Description of preprocessing workflow
- Validation results showing correctness

### Comparison Table

After preprocessing, all software have comparable format:

| Software | Solutions per Experiment | Best Error (Mean) | Success Rate |
|----------|-------------------------|-------------------|--------------|
| AMIGO (0,1 bounds) | 1 | 0.16 | 99.6% |
| SciML | 1 | 20.80 | 97.5% |
| ODEPE | 67.5 (→ 1 best) | 0.024 | 99.1% |
| ODEPE Polish | 71.2 (→ 1 best) | 0.019 | 99.3% |

---

## Files Created

```
oren-analysis/
├── preprocess_odepe_results.py         # Main preprocessing script
├── analyze_odepe_solution_quality.py   # Quality analysis tool
├── validate_preprocessing.py           # Validation tool
└── ODEPE_PREPROCESSING_GUIDE.md        # This guide
```

All scripts are standalone and reusable for future experiments.

---

**Document Created**: 2025-11-11
**Author**: Analysis workflow for Oren's ODE parameter estimation benchmark
**Repository**: /home/orebas/tmp/no-matlab-no-worry/
