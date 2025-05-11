# Benchmarking parameter estimation software

## Installation

0. We use the following versions of software:
    - Julia: 1.11
    - Python: 3.10.0

1. Possibly create a new environment:

```
python -m venv venv
source venv/bin/activate   # On windows: .\venv\Scripts\activate
```

Install Python packages:

```
python -m pip install -r requirements.txt
```

2. Install Julia packages:

```
using Pkg;
Pkg.add("ModelingToolkit")
Pkg.add("DifferentialEquations")
Pkg.add("ParameterEstimation")
Pkg.add("Distributions")
Pkg.add("BenchmarkTools")
Pkg.add("CSV")
Pkg.add("OrderedCollections")
# Possibly also:
# Pkg.add("GaussianProcesses")
# Pkg.add("Optim")
# Pkg.add("LineSearches")
# Pkg.add("AbstractAlgebra")
# Pkg.add(url="https://github.com/orebas/ODEParameterEstimation")
```

Note: the Julia scripts use the global Julia environment.

## Usage Example

The pipeline consists of the following stages:
1. Generation of data
2. Generation of scripts for estimation
3. Estimation
4. Analysis

### 1. Generation of data

Run

```
python src/generate_data.py config/config.json config/systems.json
```

- This creates a directory `[DATE]` with data.
- It is possible to modify `config.json` and `systems.json`.

### 2. Generation of scripts for estimation

Run

```
python src/generate_scripts.py "[DATE]" software
```

- This generates runnable scripts for estimation for the `software`. 
    Possible choices of `software` are:
    - pe
    - odepe
    - amigo2
    - iqm
    - sciml

### 3. Estimation

Run

```
python src/estimate.py "[DATE]" software 0,1,5-19
```

where 0,1,5-19 is the array of job indices.

### 4. Analysis

Run

```
python src/analyze.py "[DATE]"
```

## Running on HPC

Two machines: `host` and `hpc`.

- On `host`:

```
git clone https://github.com/sumiya11/no-matlab-no-worry
cd no-matlab-no-worry

python src/generate_data.py config/config.json config/systems.json

python src/generate_scripts.py "[DATE]" odepe
python src/generate_scripts.py "[DATE]" amigo2

git add . && git commit "Add data and scripts" && git push
```

- On `hpc`:

```
git clone https://github.com/sumiya11/no-matlab-no-worry
cd no-matlab-no-worry

sbatch --array="0-20" hpc/array_job.s
```



