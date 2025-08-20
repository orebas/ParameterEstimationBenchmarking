#! /usr/bin/env bash

# 1. Setup packages
source setup_python.s
source setup_julia.s

# 2. Generate data
python src/generate_data.py         \
    -d results/EXAMPLE              \
    config/config-small-test.json   \
    config/systems-small-test.json

# 3. Generate estimation scripts
python src/generate_scripts.py      \
    results/EXAMPLE

# 4. Run estimation scripts
python src/estimate.py              \
    results/EXAMPLE
    odepe
    0-1

# 5. Collect results and do basic analysis
python src/collect_results.py       \
    results/EXAMPLE
python src/summarize_results.py     \
    results/EXAMPLE

