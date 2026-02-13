# ODE Parameter Estimation Benchmark Repository - Comprehensive Summary

**Repository**: `/home/orebas/tmp/no-matlab-no-worry/`
**Purpose**: Benchmarking parameter estimation methods for ODE systems from systems biology
**Last Updated**: 2025-11-11
**Created By**: Analysis agent for Oren

---

## Executive Summary

This repository contains a comprehensive benchmarking framework for comparing 4 different parameter estimation software tools across 11 ODE systems from systems biology and biochemistry. The framework generates synthetic data with varying noise levels, runs parameter estimation using multiple methods, and collects results for statistical analysis.

**Key Numbers**:
- **11 ODE systems** (from harmonic oscillator to HIV models)
- **10 test instances per system** (110 total instances)
- **5 noise levels** (0, 1e-8, 1e-6, 1e-4, 1e-2)
- **4 software tools** (pe, odepe, sciml, amigo2)
- **~2,750 results** per complete experiment
- **10 result directories** (different experimental runs)
- **Total size**: ~26 GB

---

## Directory Structure

```
/home/orebas/tmp/no-matlab-no-worry/
│
├── README.md                        # Main project documentation
├── .gitignore                       # Git ignore rules
│
├── config/                          # Configuration files
│   ├── config.json                 # Main experiment configuration
│   └── systems.json                # ODE system definitions (11 systems)
│
├── src/                             # Python source code
│   ├── generate_data.py            # Generate synthetic ODE data (9.1 KB)
│   ├── generate_scripts.py         # Create estimation scripts (7.0 KB)
│   ├── estimate.py                 # Run parameter estimation (4.9 KB)
│   ├── collect_results.py          # Aggregate results (7.0 KB)
│   ├── summarize_results.py        # Statistical analysis (38 KB)
│   ├── shared.py                   # Common utilities (5.5 KB)
│   ├── estimate.jl                 # Julia estimation logic (6.7 KB)
│   └── simple_fast_generate_data.jl # Fast data generation (3.0 KB)
│
├── templates/                       # Mustache templates for code generation
│   ├── julia_template_for_estimation_odepe.jl
│   ├── julia_template_for_estimation_pe.jl
│   ├── julia_template_for_estimation_sciml.jl
│   ├── amigo2.m.template
│   └── [other templates]
│
├── environments/                    # Julia/Python environment definitions
│   ├── julia_pe/                   # ParameterEstimation.jl environment
│   ├── julia_odepe/                # ODEParameterEstimation.jl environment
│   ├── julia_sciml/                # SciML environment
│   ├── setup_julia.s               # Julia setup script
│   └── setup_python.s              # Python setup script
│
├── hpc/                             # HPC job submission scripts
│   ├── array_job_odepe.s          # SLURM job for ODEParameterEstimation
│   ├── array_job_pe.s             # SLURM job for ParameterEstimation
│   ├── array_job_sciml.s          # SLURM job for SciML
│   ├── array_job_amigo2.s         # SLURM job for AMIGO2
│   ├── run_in_slurm.py            # Job submission manager
│   └── slurm_manager.py           # SLURM job monitor
│
├── scripts/                         # Main execution scripts
│   ├── run.s                       # Main pipeline script
│   ├── run_2.s                     # Alternative run script
│   └── uwu.s                       # Additional run script
│
├── results/                         # RESULTS DIRECTORIES (10 experiments)
│   ├── september_16_2025_search_bound_100/  # ★ LATEST (3.1 GB)
│   ├── october_5_2025/                      # ★ MOST COMPLETE (7.0 GB)
│   ├── september_16_2025_search_bound_10/   # (1.9 GB)
│   ├── september_15_2025_with_polishing/    # (2.1 GB)
│   ├── september_15_2025/                   # (1.7 GB)
│   ├── FINAL3/                              # (1.8 GB)
│   ├── FINAL2/                              # (1.5 GB)
│   ├── FINAL_LARGE/                         # (608 KB)
│   ├── FINAL6/                              # (3.7 MB)
│   └── EXAMPLE/                             # (334 MB)
│
├── archive/                         # Historical result summaries
│   ├── 2025_october_5.txt          # Latest archive (990 KB)
│   ├── 2025_september_16_search_bound_100.txt
│   └── [other archive files]
│
├── oren-analysis/                   # YOUR ANALYSIS DIRECTORY
│   ├── REPOSITORY_SUMMARY.md       # This document
│   ├── DATA_PROCESSING_GUIDE.md    # How to process the data
│   └── DATASETS_COMPARISON.md      # Dataset comparison table
│
└── .git/                            # Git repository metadata
```

---

## Configuration Files

### config/config.json

This file controls all experimental parameters:

```json
{
  "NUM_TESTS": 10,                    // Test instances per system
  "TIME_INTERVAL": [-1.0, 1.0],       // ODE integration time bounds
  "PARAM_INTERVAL": [0.1, 0.9],       // Parameter value bounds for generation
  "NUM_PTS": 1001,                    // Number of time points
  "ODEPE_POLISH": "true",             // Post-processing flag
  "NOISE_LEVEL": {                    // 5 noise levels
    "0": 0,
    "1em8": 1e-8,
    "1em6": 1e-6,
    "1em4": 1e-4,
    "1em2": 1e-2
  },
  "NOISE_TYPE": "MULTIPLICATIVE",
  "SEARCH_BOUNDS": [0.0, 1.0],        // Parameter search space
  "DATA_DIR": "data_original",        // Clean data location
  "DATA_DIR_NOISY": "data_noisy",     // Noisy data location
  "FILETREE": "filetree"              // Results structure
}
```

**Key Parameters**:
- Time interval: [-1.0, 1.0] (2 time units)
- Parameters generated in: [0.1, 0.9]
- Search space: [0.0, 1.0] (can vary between experiments)
- Data points: 1,001 per time series

### config/systems.json

Defines 11 ODE systems for benchmarking. Each system includes:
- State variables
- Parameter variables
- Measurement equations (observables)
- ODE equations
- Non-identifiable parameters list

**The 11 Systems**:

1. **biohydrogenation**
   - States: 4 (x1, x2, x3, x4)
   - Parameters: 6 (k5, k6, k7, k8, k9, k10)
   - Biochemical pathway model

2. **crauste**
   - States: 5 (N, E, S, M, P)
   - Parameters: 13 (mu_N, mu_EE, mu_LE, ..., delta_NE, delta_EL, rho_E, rho_P)
   - T-cell regulation model

3. **daisy_mamil3**
   - States: 3 (M, A, L)
   - Parameters: 5 (a1, a2, b1, b2, g1)
   - MAMIL compartmental model

4. **daisy_mamil4**
   - States: 4 (M, A, I, L)
   - Parameters: 7 (a1, a2, a3, b1, b2, b3, g1)
   - Extended MAMIL model

5. **fitzhugh_nagumo**
   - States: 2 (V, R)
   - Parameters: 3 (a, b, c)
   - Neuron excitability model

6. **harmonic**
   - States: 2 (x1, x2)
   - Parameters: 2 (a, b)
   - Simple harmonic oscillator

7. **hiv**
   - States: 5 (x, y, v, w, z)
   - Parameters: 10 (lm, d, beta, a, k, u, c, q, b, h)
   - HIV infection dynamics

8. **lotka_volterra**
   - States: 2 (r, w)
   - Parameters: 3 (a, b, c)
   - Predator-prey model

9. **seir**
   - States: 4 (S, E, I, R)
   - Parameters: 3 (a, b, g)
   - Epidemic model

10. **vanderpol**
    - States: 2 (x1, x2)
    - Parameters: 2 (a, b)
    - Van der Pol oscillator

11. **slowfast**
    - States: 5 (x1, x2, x3, x4, x5)
    - Parameters: 3 (k1, k2, k3)
    - Slow-fast dynamical system

---

## Software Tools Compared

The framework compares 4 parameter estimation implementations:

### 1. **pe** - ParameterEstimation.jl
- Language: Julia
- Method: Symbolic-numeric parameter estimation
- Environment: `environments/julia_pe/`

### 2. **odepe** - ODEParameterEstimation.jl
- Language: Julia
- Method: ODE-based parameter estimation with optimization
- Environment: `environments/julia_odepe/`
- Feature: Optional "polishing" post-processing

### 3. **sciml** - SciML/DifferentialEquations.jl
- Language: Julia
- Method: SciML ecosystem optimization
- Environment: `environments/julia_sciml/`

### 4. **amigo2** - AMIGO2
- Language: MATLAB
- Method: Advanced Model Identification using Global Optimization
- Requires: MATLAB runtime

---

## Scripts Pipeline

The complete workflow is orchestrated by `run.s`:

### 1. **generate_data.py** - Data Generation
**Location**: `src/generate_data.py`
**Purpose**: Creates synthetic ODE solution data for all systems

**Usage**:
```bash
python src/generate_data.py -d DIRECTORY config/config.json config/systems.json
```

**Process**:
1. Reads system definitions from `systems.json`
2. Reads parameters from `config.json`
3. For each system (11 total):
   - Generates 10 random instances (NUM_TESTS)
   - Samples parameters uniformly in [0.1, 0.9]
   - Samples initial conditions
   - Solves ODE using Julia
   - Saves clean data (1001 time points)
   - Generates noisy versions at 5 noise levels
4. Creates `huge_json.json` with all instance metadata

**Outputs**:
- `filetree/data_original/[system]_[instance]/data.csv` (110 files)
- `filetree/data_noisy/[system]_[instance]_[noise]/data.csv` (550 files)
- `huge_json.json` (30 MB, all metadata)

### 2. **generate_scripts.py** - Script Generation
**Location**: `src/generate_scripts.py`
**Purpose**: Creates executable estimation scripts from templates

**Usage**:
```bash
python src/generate_scripts.py DIRECTORY -s SOFTWARE -c CONFIG -r RUN_NAME
```

**Parameters**:
- `DIRECTORY`: Results directory containing huge_json.json
- `-s SOFTWARE`: pe, odepe, sciml, or amigo2
- `-c CONFIG`: Path to config.json
- `-r RUN_NAME`: Subdirectory name (e.g., "pe_run")

**Process**:
1. Reads instances from `huge_json.json`
2. For each instance (110 total):
   - Loads appropriate template (Mustache format)
   - Fills in ODE equations, parameters, initial conditions
   - Generates executable script (.jl for Julia, .m for MATLAB)
3. Each script is self-contained with:
   - System definition
   - True parameter values (for validation)
   - Data loading code
   - Optimization setup
   - Search bounds

**Templates Used**:
- `templates/julia_template_for_estimation_odepe.jl`
- `templates/julia_template_for_estimation_pe.jl`
- `templates/julia_template_for_estimation_sciml.jl`
- `templates/amigo2.m.template`

**Outputs**:
- `filetree/[software]_[run]/[system]_[instance]_[noise]/script.jl` (or .m)

### 3. **estimate.py** - Parameter Estimation Execution
**Location**: `src/estimate.py`
**Purpose**: Runs parameter estimation scripts (locally or via HPC)

**Usage**:
```bash
python src/estimate.py DIRECTORY RUN_NAME SOFTWARE TASK_ID
```

**Parameters**:
- `DIRECTORY`: Results directory
- `RUN_NAME`: Which script set to run (e.g., "pe_run")
- `SOFTWARE`: pe, odepe, sciml, or amigo2
- `TASK_ID`: Job index (0-9 for array jobs)

**Process**:
1. Finds script at `filetree/[software]_[run]/[system]_[instance]_[noise]/script.jl`
2. Executes using appropriate runtime (julia or matlab)
3. Captures stdout and stderr
4. Records execution time
5. Saves outputs to same directory

**Outputs**:
- `stdout.txt` - Contains estimated parameters
- `stderr.txt` - Error messages and warnings
- Execution time logged

### 4. **collect_results.py** - Results Aggregation
**Location**: `src/collect_results.py`
**Purpose**: Aggregates individual results into summary files

**Usage**:
```bash
python src/collect_results.py DIRECTORY
```

**Process**:
1. Searches `filetree/` for all stdout.txt files
2. Parses parameter estimates from output
3. Loads true parameters from `huge_json.json`
4. Creates unified result table
5. Computes metadata (finished status, has_result flag)

**Outputs**:
- `result.csv` - Summary table (2,750 rows × 16 columns)
- `result.json` - Structured result dictionary (611 KB)

### 5. **summarize_results.py** - Statistical Analysis
**Location**: `src/summarize_results.py` (38 KB)
**Purpose**: Comprehensive statistical analysis and visualization

**Features**:
- Computes accuracy metrics (error, relative error)
- Per-parameter statistics
- Per-system statistics
- Per-software comparisons
- Visualizations and tables

---

## Result Directory Structure

Each experiment creates a standardized directory structure:

```
results/[experiment_name]/
│
├── config/                          # Configuration snapshot
│   ├── config.json
│   └── systems.json
│
├── huge_json.json                   # ★ ALL INSTANCE METADATA (30 MB)
│   └── Contains:
│       - True parameters for all 110 instances
│       - Initial conditions
│       - System definitions
│       - Time intervals
│       - Instance IDs
│
├── result.csv                       # ★ MAIN SUMMARY TABLE (2,750 rows)
│   └── Columns:
│       - id: Instance identifier
│       - true_states: State variable values
│       - true_parameters: Ground truth parameters
│       - time_start, time_end, time_count
│       - name: System name
│       - non_identifiable: Non-identifiable params
│       - noise: Noise level (0, 1em8, 1em6, 1em4, 1em2)
│       - finished: Boolean (completed successfully)
│       - has_result: Boolean (has valid result)
│       - software: Tool used (pe, odepe, sciml, amigo2)
│       - result: Estimated parameters (JSON array)
│       - time: Execution time (seconds)
│
├── result.json                      # ★ STRUCTURED RESULTS (611 KB)
│   └── Nested dictionary format for programmatic access
│
└── filetree/                        # Detailed file tree
    │
    ├── data_original/               # Clean synthetic data
    │   └── [system]_[instance]/
    │       └── data.csv             # 1001 time points × measurements
    │                                 # Format: time,y1,y2,...
    │
    ├── data_noisy/                  # Noisy data (5 noise levels)
    │   └── [system]_[instance]_[noise]/
    │       └── data.csv             # Same format, with noise added
    │
    ├── data_generation/             # Generation logs
    │   └── [system]_[instance]/
    │       ├── script.jl
    │       ├── stdout.txt
    │       └── stderr.txt
    │
    ├── pe_run/                      # ParameterEstimation.jl results
    │   └── [system]_[instance]_[noise]/
    │       ├── script.jl            # Generated estimation script
    │       ├── stdout.txt           # Contains estimated params
    │       └── stderr.txt           # Errors/warnings
    │
    ├── odepe_run/                   # ODEParameterEstimation.jl results
    │   └── [same structure]
    │
    ├── sciml_run/                   # SciML results
    │   └── [same structure]
    │
    └── amigo2_run/                  # AMIGO2 results
        └── [same structure]
```

---

## Data Formats Specification

### 1. huge_json.json Format

**Size**: ~30 MB
**Structure**: Nested dictionary

```json
{
  "biohydrogenation": {
    "0": {
      "system_name": "biohydrogenation",
      "instance_id": 0,
      "true_parameters": [0.123, 0.456, ...],  // 6 values
      "parameter_names": ["k5", "k6", ...],
      "initial_conditions": [0.789, 0.234, ...],  // 4 values
      "state_names": ["x1", "x2", "x3", "x4"],
      "measurement_names": ["y1", "y2"],
      "time_interval": [-1.0, 1.0],
      "non_identifiable": ["k9"],
      "ode_equations": "...",
      "measurement_equations": "..."
    },
    "1": { ... },
    ...
    "9": { ... }
  },
  "crauste": { ... },
  ...
}
```

**Key Fields**:
- `true_parameters`: Ground truth parameter values
- `initial_conditions`: Starting state values
- `non_identifiable`: Parameters that cannot be uniquely determined

### 2. result.csv Format

**Size**: Varies (typically <100 MB)
**Rows**: 2,750 (1 header + 2,749 data rows for full experiment)
**Format**: Standard CSV, comma-separated

**Columns** (16 total):
```
id,true_states,true_parameters,time_start,time_end,time_count,name,
non_identifiable,noise,finished,has_result,software,result,time
```

**Example Row**:
```csv
harmonic_7_0,0.733;0.178,0.508;0.367,-1.0,1.0,1001,harmonic,
,0,True,True,pe,[0.509,0.368],12.34
```

**Field Details**:
- `id`: "[system]_[instance]_[noise]" (e.g., "harmonic_7_0")
- `true_states`: Initial conditions, semicolon-separated
- `true_parameters`: Ground truth, semicolon-separated
- `name`: System name
- `noise`: Noise level code (0, 1em8, 1em6, 1em4, 1em2)
- `finished`: "True" if completed without crash
- `has_result`: "True" if valid estimate obtained
- `software`: Tool used (pe, odepe, sciml, amigo2)
- `result`: Estimated parameters as JSON array
- `time`: Execution time in seconds

### 3. Individual Data CSV Format

**Location**: `filetree/data_[original|noisy]/[system]_[instance]_[noise]/data.csv`
**Size**: ~50-100 KB per file
**Rows**: 1,001 (matching NUM_PTS)
**Format**: No header, comma-separated floats

**Structure**:
```
Column 1: Time values (from TIME_INTERVAL)
Columns 2+: Measurement values (system-dependent)
```

**Example** (harmonic system, 2 measurements):
```csv
-1.0,0.733,0.178
-0.998,0.7328171229,0.1819940
-0.996,0.7326301884,0.1859871
...
1.0,0.589,0.412
```

**Number of Measurements by System**:
- biohydrogenation: 2
- crauste: 3
- daisy_mamil3: 2
- fitzhugh_nagumo: 2
- harmonic: 2
- hiv: 4
- lotka_volterra: 2
- seir: 3
- vanderpol: 1
- slowfast: 2

### 4. Estimation Script Format (script.jl)

**Location**: `filetree/[software]_[run]/[system]_[instance]_[noise]/script.jl`
**Language**: Julia
**Size**: 5-15 KB

**Structure**:
```julia
# Package imports
using ODEParameterEstimation, ModelingToolkit, DifferentialEquations

# System metadata
name = "harmonic"
datafile = "../../data_noisy/harmonic_7_0/data.csv"

# Model definition
@parameters a b
@variables t x1(t) x2(t)

# Initial conditions and true parameters
ic = [0.733, 0.178]
p_true = [0.508, 0.367]  # Ground truth for validation

# ODE system
eqs = [
    D(x1) ~ a * x2,
    D(x2) ~ -b * x1
]

# Measurement equations
measured_quantities = [x1, x2]

# Time and bounds
time_interval = [-1.0, 1.0]
search_bounds = [0.0, 1.0]

# Estimation call
result = estimate_parameters(...)
```

**Key Components**:
- Self-contained: Includes all necessary definitions
- True parameters: Included for post-hoc validation
- Search bounds: From config.json
- Data path: Relative path to noisy data file

---

## Dataset Identification

### LATEST DATASET (Most Recent)

**Name**: `september_16_2025_search_bound_100`
**Path**: `/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/`
**Modified**: 2025-11-11 16:02:08 (most recent)
**Size**: 3.1 GB
**Git Commit**: 0b6d8fbd7 (2025-10-08) "add sciml with larger bounds"

**Configuration**:
- Search bounds: [0.0, 1.0] (default, matches config.json)
- Time interval: [-1.0, 1.0]
- Noise levels: 5 (0, 1e-8, 1e-6, 1e-4, 1e-2)
- Systems: All 11
- Instances per system: 10

**Completeness**:
- `huge_json.json`: ✓ (30 MB)
- `result.csv`: ✓ (2,750 rows)
- `result.json`: ✓ (611 KB)
- Clean data: ✓ (110 instances)
- Noisy data: ✓ (550 instances)
- Estimation results: ✓ (multiple software)

**Recommendation**: **USE THIS DATASET** for current analysis
- Most recent
- Complete results
- Standard configuration
- Well-documented

### MOST COMPLETE DATASET (Largest)

**Name**: `october_5_2025`
**Path**: `/home/orebas/tmp/no-matlab-no-worry/results/october_5_2025/`
**Modified**: 2025-11-11 15:59:30
**Size**: 7.0 GB (largest dataset)

**Why Larger**:
- Possibly more extensive software comparisons
- May include additional runs or re-runs
- Could have more detailed logs

**Recommendation**: Consider if you need maximum data coverage

### Other Notable Datasets

**september_16_2025_search_bound_10**:
- Search bounds: [0.0, 10.0] (wider search space)
- Good for comparing effect of search bounds

**september_15_2025_with_polishing**:
- Uses ODEPE post-processing ("polishing")
- Useful for comparing with/without refinement

---

## Key Statistics

### Systems
- **Total systems**: 11
- **State dimensions**: 2-5
- **Parameter counts**: 2-13
- **Application domains**: Biochemistry, epidemiology, physics, biology

### Experimental Design
- **Instances per system**: 10
- **Total instances**: 110
- **Noise levels**: 5
- **Data points per instance**: 1,001
- **Total time series files**: ~660 (110 clean + 550 noisy)

### Software Comparisons
- **Tools tested**: 4 (pe, odepe, sciml, amigo2)
- **Results per full run**: ~2,750
- **Typical execution time**: Minutes to hours per instance

### Storage
- **Repository size**: ~26 GB
- **Largest dataset**: 7.0 GB (october_5_2025)
- **Latest dataset**: 3.1 GB (september_16_2025_search_bound_100)
- **huge_json.json**: ~30 MB
- **result.csv**: <100 MB typically

---

## HPC Workflow

The repository is designed for High-Performance Computing:

### Setup on HPC
```bash
# 1. Clone repository
git clone [repo-url]
cd no-matlab-no-worry

# 2. Setup environments
bash environments/setup_python.s
bash environments/setup_julia.s

# 3. Generate data (locally or on login node)
python src/generate_data.py -d results/my_experiment config/config.json config/systems.json

# 4. Generate scripts
python src/generate_scripts.py results/my_experiment -s pe -r pe_run
python src/generate_scripts.py results/my_experiment -s odepe -r odepe_run
python src/generate_scripts.py results/my_experiment -s sciml -r sciml_run

# 5. Submit array jobs
sbatch hpc/array_job_pe.s
sbatch hpc/array_job_odepe.s
sbatch hpc/array_job_sciml.s

# 6. Collect results (after jobs complete)
python src/collect_results.py results/my_experiment

# 7. Analyze
python src/summarize_results.py results/my_experiment
```

### SLURM Array Job Configuration

**Parameters** (from hpc/array_job_*.s):
- Nodes: 1
- CPUs per task: 2
- Memory: 16 GB
- Time limit: 6 hours
- Array indices: 0-9 (10 parallel jobs)

**Job Distribution**:
- Each array task processes one instance across all systems
- Task 0: biohydrogenation_0, crauste_0, ..., slowfast_0
- Task 1: biohydrogenation_1, crauste_1, ..., slowfast_1
- ...
- Task 9: biohydrogenation_9, crauste_9, ..., slowfast_9

---

## Git History Summary

### Recent Commits (Newest to Oldest)
```
0b6d8fbd7 (2025-10-08) add sciml with larger bounds
039a4209a (2025-10-07) Add new results
e1cd81217 (2025-09-17) uwu
115727c00 (2025-09-17) add experiment result with search bound from 0 to 10
1e47ddeb3 (2025-09-16) Update 2025_september_15.txt
```

### Archive Directory

Location: `/home/orebas/tmp/no-matlab-no-worry/archive/`

**Text Summaries** (from summarize_results.py):
- `2025_october_5.txt` (990 KB) - Latest
- `2025_september_16_search_bound_100.txt` (836 KB)
- `2025_september_16_search_bound_10.txt` (813 KB)
- `2025_september_15_with_polishing.txt` (818 KB)
- `2025_september_15.txt` (804 KB)
- Earlier August results

These contain human-readable statistical summaries of each experiment.

---

## Quick Reference: File Locations

### For LLM Processing

**Primary Entry Points**:
1. **Summary Table**: `results/september_16_2025_search_bound_100/result.csv`
   - Start here for quick overview of all results

2. **Metadata**: `results/september_16_2025_search_bound_100/huge_json.json`
   - Complete instance definitions and true parameters

3. **Configuration**: `config/config.json` and `config/systems.json`
   - Experimental setup and system definitions

**Data Access Patterns**:
- Clean data: `results/[exp]/filetree/data_original/[system]_[instance]/data.csv`
- Noisy data: `results/[exp]/filetree/data_noisy/[system]_[instance]_[noise]/data.csv`
- Scripts: `results/[exp]/filetree/[software]_run/[system]_[instance]_[noise]/script.jl`
- Results: Parse from `stdout.txt` in same directory as scripts

---

## System Requirements

### Python Dependencies
- Python 3.7+
- Required packages: numpy, pandas, json, chevron (Mustache templates)
- Virtual environment setup: `environments/setup_python.s`

### Julia Dependencies
- Julia 1.6+
- Packages: ODEParameterEstimation, ModelingToolkit, DifferentialEquations, DataFrames, CSV, JSON
- Environment setup: `environments/setup_julia.s`

### MATLAB Dependencies (for AMIGO2/IQM)
- MATLAB R2019a or later
- AMIGO2 toolbox
- IQM toolbox (optional)

---

## Common Analysis Tasks

### Load Summary Results
```python
import pandas as pd
df = pd.read_csv('results/september_16_2025_search_bound_100/result.csv')
```

### Parse Instance Metadata
```python
import json
with open('results/september_16_2025_search_bound_100/huge_json.json') as f:
    metadata = json.load(f)
```

### Access Time Series Data
```python
import numpy as np
data = np.loadtxt('results/.../filetree/data_noisy/harmonic_7_0/data.csv', delimiter=',')
time = data[:, 0]
measurements = data[:, 1:]
```

### Compare True vs Estimated Parameters
```python
# From result.csv
true_params = df['true_parameters'].apply(lambda x: [float(v) for v in x.split(';')])
est_params = df['result'].apply(json.loads)
errors = est_params - true_params
```

---

## Notes for LLM Analysis

### What to Focus On
1. **result.csv**: Primary data source for statistical analysis
2. **huge_json.json**: Ground truth and metadata
3. **System definitions**: Understand what each ODE represents
4. **Noise levels**: Analysis stratified by noise (0, 1e-8, ..., 1e-2)
5. **Software comparison**: Performance across pe, odepe, sciml, amigo2

### Key Questions to Answer
- Which software is most accurate per system?
- How does noise affect estimation quality?
- Which parameters are hardest to estimate?
- Which systems are most challenging?
- What's the computation time vs accuracy tradeoff?
- Impact of search bounds on results?

### Caveats
- Some instances may not have results (check `has_result` column)
- Non-identifiable parameters cannot be uniquely determined
- Execution times vary by HPC load
- AMIGO2 requires MATLAB (may have fewer results)

---

## Summary for LLM Handoff

**Repository Purpose**: Benchmark parameter estimation methods for ODE systems

**Latest/Recommended Dataset**: `results/september_16_2025_search_bound_100/`
- Path: `/home/orebas/tmp/no-matlab-no-worry/results/september_16_2025_search_bound_100/`
- Size: 3.1 GB
- Modified: 2025-11-11 16:02:08
- Results: 2,750 experiments (11 systems × 10 instances × 5 noise levels × ~5 software runs)

**Primary Data Files**:
1. `result.csv` - Main summary table (2,750 rows)
2. `huge_json.json` - Complete metadata (30 MB)
3. `filetree/data_noisy/*/data.csv` - Time series data (1001 points each)

**Data Format**: CSV (time series), CSV (results table), JSON (metadata)

**Systems**: 11 ODE models from biology/chemistry (2-5 states, 2-13 parameters)

**Software**: pe, odepe, sciml, amigo2 (Julia and MATLAB tools)

**Analysis Ready**: Yes - result.csv contains all estimates, true parameters, execution times

---

*Document created: 2025-11-11*
*For: Oren's analysis and LLM handoff*
*Repository: /home/orebas/tmp/no-matlab-no-worry/*
