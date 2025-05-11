# Benchmarking parameter estimation software

## Installation

0. We use the following versions of software:
    - Julia: 1.11
    - Python: 3.9 or 3.10

1. Possibly create a new environment and install packages:

```
$ python -m venv venv
$ source venv/bin/activate   # On Windows: .\venv\Scripts\activate
$ python -m pip install -r requirements.txt
```

2. Install Julia packages:

```
$ julia hpc/setup_packages.jl
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
$ python src/generate_data.py config/config.json config/systems.json
```

- This creates a directory `[DATE]` with data.
- It is possible to modify `config.json` and `systems.json`.

### 2. Generation of scripts for estimation

Run

```
$ python src/generate_scripts.py "[DATE]" software
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
$ python src/estimate.py "[DATE]" software 0,1,5-19
```

where 0,1,5-19 is the array of job indices.

### 4. Analysis

Run

```
$ python src/analyze.py "[DATE]"
```

## Running on HPC

Two machines: `host` and `hpc`.

- On `host`:

```
$ git clone https://github.com/sumiya11/no-matlab-no-worry
$ cd no-matlab-no-worry

$ python src/generate_data.py config/config.json config/systems.json
$ ls
2025_05_11_18_49  config  hpc  README.md  requirements.txt  src  templates

$ python src/generate_scripts.py 2025_05_11_18_49 pe

$ git add . && git commit "Add data and scripts" && git push
```

- On `hpc`:

```
$ git clone https://github.com/sumiya11/no-matlab-no-worry
$ cd no-matlab-no-worry

$ bash hpc/setup_python.s
$ julia hpc/setup_packages.jl

$ sbatch hpc/array_job.s
```

and then, after jobs finish, (perhaps on a compute node)

```
$ python src/analyze.py 2025_05_11_18_49

$ git add . && git commit "Add results" && git push
```

### Notes

1. By default, .julia may be located in $HOME, and $HOME may limit the size/number of files.
   To change the location of .julia to $SCRATCH, run `export JULIA_DEPOT_PATH=$SCRATCH`.
   (and perhaps add the export to .bashrc).

2.



