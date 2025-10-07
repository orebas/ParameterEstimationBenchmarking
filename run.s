#! /usr/bin/env -S bash -e

# 1. Setup packages
cd environments
source setup_python.s
source setup_julia.s
cd ..

# 2. Generate data
python src/generate_data.py         \
    -d results/EXAMPLE              \
    config/config.json              \
    config/systems.json

# 3. Generate estimation scripts
python src/generate_scripts.py results/EXAMPLE/ -s odepe -c config/config.json -r tmp

# 4. Run estimation scripts
python src/estimate.py results/EXAMPLE tmp odepe 0-1

# 5. Collect results and do basic analysis
python src/collect_results.py       \
    results/EXAMPLE
python src/summarize_results.py     \
    results/EXAMPLE

