# Benchmarking parameter estimation software

## Installation

Possibly create a new environment:

```
python -m venv venv
source venv/bin/activate
```

Install Python packages:

```
python -m pip install -r requirements.txt
```

Install Julia packages:

```
using Pkg;
Pkg.add("ModelingToolkit")
Pkg.add("DifferentialEquations")
Pkg.add("ParameterEstimation")
Pkg.add("Distributions")
Pkg.add("BenchmarkTools")
Pkg.add("CSV")
```

Note: the Julia scripts use the global Julia environment.

## Usage Example

The pipeline consists of three stages:
- Generation
- Estimation
- Analysis

### Generation

Run

```
python generate.py config/config.json config/systems.json
```

- This creates directory `[DATE]` with data.
- The main file is `[DATE]/instances.json`.
- Possible to modify `config.json` and `systems.json`.

### Estimation

Run

```
python estimate.py "[DATE]" software
```

- This runs estimation for the `software`. Possible choices of `software` are:
    - pe
    - odepe
    - amigo2
    - iqm
    - sciml
- The main file is `[DATE]/software.json`.

### Analysis

Run

```
python analyze.py "[DATE]"
```

This will create the summary files in "[CURRENT_DATE]/results".

## Running on HPC



