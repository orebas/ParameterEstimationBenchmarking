#!/bin/bash -e
#SBATCH --job-name=gen_data
#SBATCH --partition=partnsf
#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=4
#SBATCH --mem=16GB --time=02:00:00
#SBATCH --output=output/gen_data_%j.out
#SBATCH --error=output/gen_data_%j.err

# Generate benchmark data + estimation scripts for all 4 estimators.
# Must run AFTER Julia environments are set up (setup_julia_cuny.s).

export SCRATCH="/scratch/oren-qc-13"
export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH"
export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia"

cd $SCRATCH/ParameterEstimationBenchmarking
source environments/venv/bin/activate

BENCH=benchmark_2026_02

# Step 1: Generate synthetic data (calls Julia for ODE solving)
# generate_data.py runs `julia src/simple_fast_generate_data.jl` relative to CWD,
# so we must be in the repo root.
echo "=== Generating synthetic data ==="
python src/generate_data.py \
    config/config.json \
    config/systems.json \
    -d $BENCH

# Step 2: Generate scripts for each estimator

# AMIGO2
echo "=== Generating AMIGO2 scripts ==="
python src/generate_scripts.py $BENCH -s amigo2 -r amigo2_run

# SciML
echo "=== Generating SciML scripts ==="
python src/generate_scripts.py $BENCH -s sciml -r sciml_run

# ODEPE no-polish
echo "=== Generating ODEPE no-polish scripts ==="
python -c "
import json
with open('$BENCH/config/config.json') as f: cfg = json.load(f)
cfg['ODEPE_POLISH'] = 'false'
with open('$BENCH/config/config.json', 'w') as f: json.dump(cfg, f, indent=2)
"
python src/generate_scripts.py $BENCH -s odepe -r odepe_nopolish

# ODEPE polish
echo "=== Generating ODEPE polish scripts ==="
python -c "
import json
with open('$BENCH/config/config.json') as f: cfg = json.load(f)
cfg['ODEPE_POLISH'] = 'true'
with open('$BENCH/config/config.json', 'w') as f: json.dump(cfg, f, indent=2)
"
python src/generate_scripts.py $BENCH -s odepe -r odepe_polish

echo ""
echo "=== Data generation complete ==="
echo "Benchmark dir: $BENCH"
ls -la $BENCH/filetree/ 2>/dev/null
