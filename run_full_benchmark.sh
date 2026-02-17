#!/bin/bash
# Full benchmark pipeline: generate data → generate scripts → run estimation → collect results
# Expected runtime: many hours (1300 instances across ODEPE and SciML solvers)

set -e

cd "$(dirname "$0")"
BENCHMARK_DIR="full_benchmark_2026_02_13"
LOG_DIR="benchmark_logs"
mkdir -p "$LOG_DIR"

LOGFILE="$LOG_DIR/benchmark_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== Full Benchmark Pipeline ==="
echo "Started: $(date)"
echo "Output directory: $BENCHMARK_DIR"
echo "Log file: $LOGFILE"
echo ""

# Step 1: Generate synthetic data (includes ODE solving via Julia)
echo "=== STEP 1: Generating synthetic data ==="
echo "Started: $(date)"
if [ -d "$BENCHMARK_DIR" ]; then
    echo "Directory $BENCHMARK_DIR already exists, removing..."
    rm -rf "$BENCHMARK_DIR"
fi
python3 src/generate_data.py config/config.json config/systems.json -d "$BENCHMARK_DIR"
echo "Step 1 completed: $(date)"
echo ""

# Step 2: Generate ODEPE estimation scripts
echo "=== STEP 2: Generating ODEPE estimation scripts ==="
echo "Started: $(date)"
python3 src/generate_scripts.py "$BENCHMARK_DIR" -s odepe -r odepe_run
echo "Step 2 completed: $(date)"
echo ""

# Step 3: Generate SciML estimation scripts
echo "=== STEP 3: Generating SciML estimation scripts ==="
echo "Started: $(date)"
python3 src/generate_scripts.py "$BENCHMARK_DIR" -s sciml -r sciml_run
echo "Step 3 completed: $(date)"
echo ""

# Step 4: Run ODEPE estimation (this is the long part)
echo "=== STEP 4: Running ODEPE estimation ==="
echo "Started: $(date)"
python3 src/estimate.py "$BENCHMARK_DIR" odepe_run odepe all
echo "Step 4 completed: $(date)"
echo ""

# Step 5: Run SciML estimation
echo "=== STEP 5: Running SciML estimation ==="
echo "Started: $(date)"
python3 src/estimate.py "$BENCHMARK_DIR" sciml_run sciml all
echo "Step 5 completed: $(date)"
echo ""

# Step 6: Collect results
echo "=== STEP 6: Collecting results ==="
echo "Started: $(date)"
python3 src/collect_results.py "$BENCHMARK_DIR" || echo "WARNING: collect_results had errors (some instances may have failed)"
echo "Step 6 completed: $(date)"
echo ""

echo "=== Benchmark pipeline complete ==="
echo "Finished: $(date)"
echo "Results in: $BENCHMARK_DIR"
echo "Log: $LOGFILE"
