#!/bin/bash -e
# Idempotent driver: run after any benchmark cells finish.
# Outputs land in independent_analysis/{tables,figures,REPORT.md,presentation.html}.

cd "$(dirname "$0")/../.."   # repo root

# Python deps live in PEB venv plus user-local site-packages
source environments/venv/bin/activate
export PYTHONPATH="/pfssfs1/scratch/oren-qc-13/.local/lib/python3.13/site-packages:${PYTHONPATH:-}"

echo "=== build_flat_metrics.py ==="
python3 results/numbat_analysis/build_flat_metrics.py

echo
echo "=== run_analysis.py ==="
python3 results/numbat_analysis/independent_analysis/run_analysis.py

echo
echo "=== make_presentation.py ==="
python3 results/numbat_analysis/independent_analysis/make_presentation.py

echo
echo "Open: $(pwd)/results/numbat_analysis/independent_analysis/presentation.html"
