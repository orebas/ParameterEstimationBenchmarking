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

## Usage Example

The pipeline consists of three stages:
- Generation of synthetic data
- Estimation
- Analysis

### Generation

Run

```
python generate.py
```

This will create directory "[CURRENT_DATE]" with synthetic data.

### Estimation

Run

```
python estimate.py "[CURRENT_DATE]"
```

### Analysis

Run

```
python analyze.py "[CURRENT_DATE]"
```

This will create the summary file in "[CURRENT_DATE]/results".

