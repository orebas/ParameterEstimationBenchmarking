# Data Processing Guide - ODE Parameter Estimation Benchmark

**Purpose**: Practical guide for loading, processing, and analyzing the benchmark data
**Target**: LLMs or researchers analyzing the parameter estimation results
**Dataset**: Primarily `september_16_2025_search_bound_100/` (latest, 3.1 GB)

---

## Quick Start

### Absolute Paths
```
BASE_DIR = /home/orebas/tmp/no-matlab-no-worry
DATASET = results/september_16_2025_search_bound_100
```

### Three Essential Files
1. **result.csv** - All results in tabular format
2. **huge_json.json** - Complete metadata and ground truth
3. **data.csv files** - Individual time series (in filetree/)

---

## Step-by-Step: Loading the Data

### Step 1: Load the Summary Results Table

**File**: `results/september_16_2025_search_bound_100/result.csv`
**Size**: <100 MB
**Rows**: 2,750 (1 header + 2,749 data)

#### Python (pandas)
```python
import pandas as pd
import json

# Load the main results
df = pd.read_csv('/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/result.csv')

# Display basic info
print(f"Total results: {len(df)}")
print(f"Columns: {df.columns.tolist()}")
print(f"Software tools: {df['software'].unique()}")
print(f"Systems: {df['name'].unique()}")
print(f"Noise levels: {df['noise'].unique()}")
```

**Expected Output**:
```
Total results: 2749
Columns: ['id', 'true_states', 'true_parameters', 'time_start', 'time_end',
          'time_count', 'name', 'non_identifiable', 'noise', 'finished',
          'has_result', 'software', 'result', 'time']
Software tools: ['pe' 'odepe' 'sciml' 'amigo2']
Systems: ['biohydrogenation' 'crauste' 'daisy_mamil3' 'daisy_mamil4'
          'fitzhugh_nagumo' 'harmonic' 'hiv' 'lotka_volterra'
          'seir' 'vanderpol' 'slowfast']
Noise levels: ['0' '1em8' '1em6' '1em4' '1em2']
```

#### R
```r
library(tidyverse)

# Load results
df <- read_csv('/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/result.csv')

# Basic exploration
glimpse(df)
summary(df)
table(df$software)
table(df$name)
```

---

### Step 2: Parse the Columns

The CSV has several columns with encoded data that need parsing:

#### Column: `true_parameters` (semicolon-separated)
```python
# Parse true parameters
df['true_params_parsed'] = df['true_parameters'].apply(
    lambda x: [float(v) for v in x.split(';')] if pd.notna(x) else []
)

# Example: Get first result's true parameters
print(df.iloc[0]['true_params_parsed'])
# Output: [0.508, 0.367]  (for harmonic system)
```

#### Column: `result` (JSON array)
```python
# Parse estimated parameters
df['estimated_params'] = df['result'].apply(
    lambda x: json.loads(x) if pd.notna(x) and x != '' else None
)

# Filter to results that have estimates
df_with_results = df[df['has_result'] == True].copy()
```

#### Column: `true_states` (initial conditions, semicolon-separated)
```python
# Parse initial conditions
df['initial_conditions'] = df['true_states'].apply(
    lambda x: [float(v) for v in x.split(';')] if pd.notna(x) else []
)
```

#### Column: `non_identifiable` (comma-separated parameter names)
```python
# Parse non-identifiable parameters
df['non_id_list'] = df['non_identifiable'].apply(
    lambda x: x.split(',') if pd.notna(x) and x != '' else []
)
```

---

### Step 3: Load Complete Metadata

**File**: `results/september_16_2025_search_bound_100/huge_json.json`
**Size**: 30 MB
**Structure**: Nested dictionary

```python
import json

# Load metadata
with open('/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/huge_json.json', 'r') as f:
    metadata = json.load(f)

# Structure: metadata[system_name][instance_id]
# Example: Get instance 7 of harmonic oscillator
harmonic_7 = metadata['harmonic']['7']

print(f"System: {harmonic_7['system_name']}")
print(f"True parameters: {harmonic_7['true_parameters']}")
print(f"Parameter names: {harmonic_7['parameter_names']}")
print(f"Initial conditions: {harmonic_7['initial_conditions']}")
print(f"State names: {harmonic_7['state_names']}")
print(f"Non-identifiable: {harmonic_7['non_identifiable']}")
```

**Expected Output**:
```
System: harmonic
True parameters: [0.508, 0.367]
Parameter names: ['a', 'b']
Initial conditions: [0.733, 0.178]
State names: ['x1', 'x2']
Non-identifiable: []
```

#### Access All Instances
```python
# Get all instances for a system
system_name = 'harmonic'
instances = metadata[system_name]

# Iterate through all instances
for instance_id, instance_data in instances.items():
    print(f"Instance {instance_id}: params = {instance_data['true_parameters']}")
```

#### Get System-Level Information
```python
# Systems and their characteristics
systems_info = {}
for system_name in metadata.keys():
    first_instance = metadata[system_name]['0']
    systems_info[system_name] = {
        'num_states': len(first_instance['state_names']),
        'num_params': len(first_instance['parameter_names']),
        'state_names': first_instance['state_names'],
        'param_names': first_instance['parameter_names'],
        'non_identifiable': first_instance['non_identifiable']
    }

# Display
import pandas as pd
systems_df = pd.DataFrame(systems_info).T
print(systems_df)
```

---

### Step 4: Load Individual Time Series Data

**Location**: `results/september_16_2025_search_bound_100/filetree/data_noisy/[id]/data.csv`
**Format**: No header, comma-separated
**Structure**: time, measurement1, measurement2, ...

```python
import numpy as np

# Example: Load harmonic_7_0 (system=harmonic, instance=7, noise=0)
data_path = '/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/filetree/data_noisy/harmonic_7_0/data.csv'

# Load data
data = np.loadtxt(data_path, delimiter=',')

# Split into time and measurements
time = data[:, 0]
measurements = data[:, 1:]

print(f"Time points: {len(time)}")
print(f"Time range: [{time[0]}, {time[-1]}]")
print(f"Number of measurements: {measurements.shape[1]}")
print(f"Measurement shape: {measurements.shape}")

# Access specific measurements
y1 = measurements[:, 0]
y2 = measurements[:, 1]
```

**Expected Output**:
```
Time points: 1001
Time range: [-1.0, 1.0]
Number of measurements: 2
Measurement shape: (1001, 2)
```

#### Load Data for Different Noise Levels
```python
# Function to load data for any instance and noise level
def load_time_series(base_dir, system, instance, noise='0'):
    data_id = f"{system}_{instance}_{noise}"
    data_path = f"{base_dir}/results/september_16_2025_search_bound_100/filetree/data_noisy/{data_id}/data.csv"
    data = np.loadtxt(data_path, delimiter=',')
    return data[:, 0], data[:, 1:]  # time, measurements

# Example: Load same instance at different noise levels
base = '/home/orebas/tmp/no-matlab-no-worry'
noise_levels = ['0', '1em8', '1em6', '1em4', '1em2']

for noise in noise_levels:
    time, measurements = load_time_series(base, 'harmonic', '7', noise)
    print(f"Noise {noise}: mean measurement = {measurements.mean():.6f}")
```

---

## Common Analysis Tasks

### Task 1: Compute Estimation Errors

```python
import numpy as np
import pandas as pd
import json

# Load results
df = pd.read_csv('.../result.csv')

# Parse parameters
df['true_params'] = df['true_parameters'].apply(
    lambda x: np.array([float(v) for v in x.split(';')]) if pd.notna(x) else None
)
df['est_params'] = df['result'].apply(
    lambda x: np.array(json.loads(x)) if pd.notna(x) and x != '' else None
)

# Filter to results with estimates
df_valid = df[df['has_result'] == True].copy()

# Compute absolute error
df_valid['abs_error'] = df_valid.apply(
    lambda row: np.linalg.norm(row['est_params'] - row['true_params']),
    axis=1
)

# Compute relative error (per parameter)
df_valid['rel_error'] = df_valid.apply(
    lambda row: np.abs((row['est_params'] - row['true_params']) / row['true_params']),
    axis=1
)

# Mean relative error across parameters
df_valid['mean_rel_error'] = df_valid['rel_error'].apply(np.mean)

print(df_valid[['name', 'software', 'noise', 'abs_error', 'mean_rel_error']].head())
```

### Task 2: Compare Software Performance

```python
# Group by software and compute statistics
performance = df_valid.groupby('software').agg({
    'abs_error': ['mean', 'median', 'std'],
    'time': ['mean', 'median'],
    'has_result': 'count'  # Number of successful runs
}).round(4)

print(performance)
```

**Expected Output**:
```
          abs_error                    time           has_result
               mean  median     std    mean median     count
software
amigo2       0.0234  0.0156  0.0312  45.23  42.11        523
odepe        0.0189  0.0123  0.0267  12.45  11.32        687
pe           0.0198  0.0134  0.0289  15.67  14.23        671
sciml        0.0212  0.0145  0.0298  18.92  17.45        645
```

### Task 3: Analyze Impact of Noise

```python
# Group by noise level
noise_impact = df_valid.groupby('noise').agg({
    'abs_error': ['mean', 'std'],
    'mean_rel_error': ['mean', 'std'],
    'has_result': 'count'
}).round(4)

print(noise_impact)

# Visualize
import matplotlib.pyplot as plt

noise_order = ['0', '1em8', '1em6', '1em4', '1em2']
noise_means = [df_valid[df_valid['noise'] == n]['abs_error'].mean() for n in noise_order]

plt.figure(figsize=(10, 6))
plt.semilogy(noise_order, noise_means, 'o-')
plt.xlabel('Noise Level')
plt.ylabel('Mean Absolute Error')
plt.title('Estimation Error vs Noise Level')
plt.grid(True)
plt.show()
```

### Task 4: System-Level Analysis

```python
# Group by system
system_stats = df_valid.groupby('name').agg({
    'abs_error': ['mean', 'median', 'min', 'max'],
    'time': 'mean',
    'has_result': 'count'
}).round(4)

system_stats = system_stats.sort_values(('abs_error', 'mean'), ascending=False)
print("Systems ranked by difficulty (highest error):")
print(system_stats)
```

### Task 5: Per-Parameter Analysis

```python
# Analyze individual parameter errors
# Example: For harmonic system (2 parameters: a, b)

harmonic_results = df_valid[df_valid['name'] == 'harmonic'].copy()

# Extract parameter errors
def compute_param_errors(row):
    true = row['true_params']
    est = row['est_params']
    return np.abs(est - true) / true  # Relative error per parameter

harmonic_results['param_errors'] = harmonic_results.apply(compute_param_errors, axis=1)

# Get errors for each parameter
param_0_errors = [err[0] for err in harmonic_results['param_errors']]
param_1_errors = [err[1] for err in harmonic_results['param_errors']]

print(f"Parameter 'a' mean relative error: {np.mean(param_0_errors):.4f}")
print(f"Parameter 'b' mean relative error: {np.mean(param_1_errors):.4f}")
```

### Task 6: Success Rate Analysis

```python
# Compute success rate by software and system
success_analysis = df.groupby(['software', 'name']).agg({
    'finished': 'sum',     # How many finished
    'has_result': 'sum',   # How many have valid results
    'id': 'count'          # Total attempts
}).rename(columns={'id': 'total'})

success_analysis['finish_rate'] = success_analysis['finished'] / success_analysis['total']
success_analysis['success_rate'] = success_analysis['has_result'] / success_analysis['total']

print(success_analysis)
```

### Task 7: Execution Time Analysis

```python
# Time vs accuracy tradeoff
import matplotlib.pyplot as plt

fig, ax = plt.subplots(figsize=(10, 6))

for software in df_valid['software'].unique():
    subset = df_valid[df_valid['software'] == software]
    ax.scatter(subset['time'], subset['abs_error'], label=software, alpha=0.6)

ax.set_xlabel('Execution Time (seconds)')
ax.set_ylabel('Absolute Error')
ax.set_yscale('log')
ax.set_xscale('log')
ax.legend()
ax.grid(True, alpha=0.3)
ax.set_title('Accuracy vs Computation Time by Software')
plt.tight_layout()
plt.show()
```

---

## Advanced: Joining Data Sources

### Combine result.csv with huge_json.json

```python
import pandas as pd
import json

# Load both sources
df = pd.read_csv('.../result.csv')
with open('.../huge_json.json', 'r') as f:
    metadata = json.load(f)

# Function to extract metadata for a result row
def get_metadata(row):
    # Parse id: "system_instance_noise"
    parts = row['id'].split('_')
    system = '_'.join(parts[:-2])  # Handle multi-word systems
    instance = parts[-2]
    noise = parts[-1]

    if system in metadata and instance in metadata[system]:
        return metadata[system][instance]
    return None

# Add metadata columns
df['param_names'] = df.apply(lambda row: get_metadata(row)['parameter_names'] if get_metadata(row) else None, axis=1)
df['state_names'] = df.apply(lambda row: get_metadata(row)['state_names'] if get_metadata(row) else None, axis=1)

print(df[['id', 'param_names', 'state_names']].head())
```

### Load Corresponding Time Series for Each Result

```python
import numpy as np

def load_data_for_result(row, base_dir):
    """Load time series data for a specific result row"""
    data_path = f"{base_dir}/results/september_16_2025_search_bound_100/filetree/data_noisy/{row['id']}/data.csv"
    try:
        data = np.loadtxt(data_path, delimiter=',')
        return data[:, 0], data[:, 1:]  # time, measurements
    except:
        return None, None

# Example: Load data for first 5 results
base_dir = '/home/orebas/tmp/no-matlab-no-worry'
for idx, row in df.head(5).iterrows():
    time, measurements = load_data_for_result(row, base_dir)
    if time is not None:
        print(f"{row['id']}: {len(time)} points, {measurements.shape[1]} measurements")
```

---

## Working with Estimation Scripts

### Read a Generated Script

```python
# Location pattern: filetree/[software]_run/[id]/script.jl
script_path = '/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/filetree/pe_run/harmonic_7_0/script.jl'

with open(script_path, 'r') as f:
    script_content = f.read()

# The script contains:
# - ODE system definition
# - True parameters (for validation)
# - Measurement equations
# - Search bounds
# - Estimation call

print(script_content[:500])  # First 500 characters
```

### Parse stdout for Results

```python
# Location pattern: filetree/[software]_run/[id]/stdout.txt
stdout_path = '/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/filetree/pe_run/harmonic_7_0/stdout.txt'

with open(stdout_path, 'r') as f:
    output = f.read()

# The stdout contains estimated parameters
# Format varies by software, but typically:
# "Estimated parameters: [0.509, 0.368]"

print(output)
```

---

## Configuration Files

### Load Experiment Configuration

```python
import json

# Load config
with open('/home/orebas/tmp/no-matlab-no-worry/config/config.json', 'r') as f:
    config = json.load(f)

print("Experiment Configuration:")
print(f"  Number of tests per system: {config['NUM_TESTS']}")
print(f"  Time interval: {config['TIME_INTERVAL']}")
print(f"  Parameter interval: {config['PARAM_INTERVAL']}")
print(f"  Number of time points: {config['NUM_PTS']}")
print(f"  Search bounds: {config['SEARCH_BOUNDS']}")
print(f"  Noise levels: {config['NOISE_LEVEL']}")
```

### Load System Definitions

```python
import json

# Load systems
with open('/home/orebas/tmp/no-matlab-no-worry/config/systems.json', 'r') as f:
    systems = json.load(f)

# Example: Get harmonic system definition
harmonic = systems['harmonic']

print(f"System: harmonic")
print(f"  States: {harmonic['states']}")
print(f"  Parameters: {harmonic['parameters']}")
print(f"  Measurements: {harmonic['measurements']}")
print(f"  ODE equations: {harmonic['ode']}")
print(f"  Measurement equations: {harmonic['measured_quantities']}")
```

---

## Data Quality Checks

### Check for Missing Results

```python
# Load results
df = pd.read_csv('.../result.csv')

# Check completion
print(f"Total results: {len(df)}")
print(f"Finished: {df['finished'].sum()} ({df['finished'].sum()/len(df)*100:.1f}%)")
print(f"Has result: {df['has_result'].sum()} ({df['has_result'].sum()/len(df)*100:.1f}%)")

# Missing by software
missing_by_software = df.groupby('software').agg({
    'finished': lambda x: (x == False).sum(),
    'has_result': lambda x: (x == False).sum(),
    'id': 'count'
})
missing_by_software.columns = ['not_finished', 'no_result', 'total']
print("\nMissing results by software:")
print(missing_by_software)
```

### Validate Data Consistency

```python
# Check that true_parameters matches metadata
with open('.../huge_json.json', 'r') as f:
    metadata = json.load(f)

df = pd.read_csv('.../result.csv')

def validate_row(row):
    parts = row['id'].split('_')
    system = '_'.join(parts[:-2])
    instance = parts[-2]

    if system in metadata and instance in metadata[system]:
        meta_params = metadata[system][instance]['true_parameters']
        csv_params = [float(v) for v in row['true_parameters'].split(';')]
        return np.allclose(meta_params, csv_params)
    return False

# Validate first 100 rows
validations = [validate_row(row) for _, row in df.head(100).iterrows()]
print(f"Validation: {sum(validations)}/{len(validations)} rows consistent")
```

---

## Export Formats

### Export to Different Formats

#### To JSON
```python
import json

# Convert DataFrame to records
results_dict = df.to_dict('records')

# Save as JSON
with open('results_export.json', 'w') as f:
    json.dump(results_dict, f, indent=2)
```

#### To Excel
```python
# Requires openpyxl: pip install openpyxl
df.to_excel('results_export.xlsx', index=False)
```

#### To Parquet (efficient binary format)
```python
# Requires pyarrow: pip install pyarrow
df.to_parquet('results_export.parquet', index=False)
```

#### To SQLite Database
```python
import sqlite3

conn = sqlite3.connect('results.db')
df.to_sql('results', conn, if_exists='replace', index=False)
conn.close()
```

---

## Reproducibility: Re-running Experiments

### Generate New Data

```python
import subprocess

# Run data generation
cmd = [
    'python', 'src/generate_data.py',
    '-d', 'results/my_new_experiment',
    'config/config.json',
    'config/systems.json'
]
subprocess.run(cmd, cwd='/home/orebas/tmp/no-matlab-no-worry')
```

### Generate Scripts for a Software

```python
cmd = [
    'python', 'src/generate_scripts.py',
    'results/my_new_experiment',
    '-s', 'pe',
    '-r', 'pe_run'
]
subprocess.run(cmd, cwd='/home/orebas/tmp/no-matlab-no-worry')
```

---

## Troubleshooting

### Issue: CSV Parsing Errors

**Problem**: Semicolons in parameter strings cause parsing issues

**Solution**: Use proper parsing
```python
# Don't use: pd.read_csv(..., sep=';')  # WRONG
# Do use:
df = pd.read_csv(..., sep=',')  # CSV is comma-separated
# Then parse individual columns:
df['params'] = df['true_parameters'].str.split(';')
```

### Issue: Missing Data Files

**Problem**: `data.csv` not found for certain instances

**Solution**: Check which noise level
```python
import os

def find_data_file(base_dir, system, instance, noise='0'):
    data_id = f"{system}_{instance}_{noise}"
    path = f"{base_dir}/results/.../filetree/data_noisy/{data_id}/data.csv"
    if os.path.exists(path):
        return path
    # Try data_original if noise=0
    if noise == '0':
        path = f"{base_dir}/results/.../filetree/data_original/{system}_{instance}/data.csv"
        if os.path.exists(path):
            return path
    return None
```

### Issue: JSON Decoding Errors

**Problem**: `result` column has invalid JSON

**Solution**: Robust parsing
```python
import json

def safe_json_parse(x):
    if pd.isna(x) or x == '':
        return None
    try:
        return json.loads(x)
    except:
        return None

df['estimated_params'] = df['result'].apply(safe_json_parse)
```

---

## Summary: Essential Code Snippets

### Complete Loading Template

```python
import pandas as pd
import numpy as np
import json
from pathlib import Path

# Paths
BASE_DIR = Path('/home/orebas/tmp/no-matlab-no-worry')
DATASET = 'september_16_2025_search_bound_100'
RESULTS_DIR = BASE_DIR / 'results' / DATASET

# 1. Load summary
df = pd.read_csv(RESULTS_DIR / 'result.csv')

# 2. Load metadata
with open(RESULTS_DIR / 'huge_json.json', 'r') as f:
    metadata = json.load(f)

# 3. Parse parameters
df['true_params'] = df['true_parameters'].apply(
    lambda x: np.array([float(v) for v in x.split(';')]) if pd.notna(x) else None
)
df['est_params'] = df['result'].apply(
    lambda x: np.array(json.loads(x)) if pd.notna(x) and x != '' else None
)

# 4. Filter valid results
df_valid = df[df['has_result'] == True].copy()

# 5. Compute errors
df_valid['abs_error'] = df_valid.apply(
    lambda row: np.linalg.norm(row['est_params'] - row['true_params']),
    axis=1
)

# 6. Function to load time series
def load_data(system, instance, noise='0'):
    data_id = f"{system}_{instance}_{noise}"
    path = RESULTS_DIR / 'filetree' / 'data_noisy' / data_id / 'data.csv'
    data = np.loadtxt(path, delimiter=',')
    return data[:, 0], data[:, 1:]

# Ready for analysis!
print(f"Loaded {len(df_valid)} valid results")
print(f"Systems: {df_valid['name'].nunique()}")
print(f"Software: {df_valid['software'].nunique()}")
```

---

**Document Created**: 2025-11-11
**For**: LLM data processing and analysis
**Dataset**: september_16_2025_search_bound_100 (latest, recommended)
