# Benchmarking parameter estimation software

## Running the scripts

0. We use the following versions of software:
    - Julia: 1.11.6
    - Python: 3.9 or 3.10

1. Run the following command:

```
./run.sh
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
$ python src/collect_results.py 2025_05_11_18_49

$ git add . && git commit "Add results" && git push
```

### Notes

1. By default, .julia may be located in $HOME, and $HOME may limit the size/number of files.
   To change the location of .julia to $SCRATCH, run `export JULIA_DEPOT_PATH=$SCRATCH`.
   (and perhaps add the export to .bashrc).

2.



