#! /usr/bin/env -S bash -e

# 1. Setup packages

cd environments
source setup_python.s
source setup_julia.s
cd ..

DIR=september_16_2025_search_bound_10

# 2. Generate data
python src/generate_data.py -d results/$DIR config/config.json config/systems.json

# 3. Generate estimation scripts
python src/generate_scripts.py              results/$DIR

sbatch --array=0-549 hpc/array_job_pe.s     results/$DIR
sbatch --array=0-549 hpc/array_job_odepe.s  results/$DIR
sbatch --array=0-549 hpc/array_job_amigo2.s results/$DIR

