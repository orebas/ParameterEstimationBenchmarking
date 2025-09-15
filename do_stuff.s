#! /usr/bin/env bash
set -e

source environments/venv/bin/activate

python src/generate_data_simple.py  \
    -d results/FINAL5               \
    config/config.json              \
    config/systems.json

python src/generate_scripts.py      \
    results/FINAL5

sbatch --array=0-549 hpc/array_job_odepe.s results/FINAL5
sbatch --array=0-549 hpc/array_job_amigo2.s results/FINAL5
sbatch --array=0-549 hpc/array_job_sciml.s results/FINAL5

python src/collect_results.py       \
    results/FINAL5
python src/summarize_results.py     \
    results/FINAL5

