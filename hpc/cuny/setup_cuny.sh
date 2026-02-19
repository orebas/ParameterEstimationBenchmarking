#!/bin/bash
# First-time setup for CUNY HPC benchmark
# Run from the login node after SSH'ing in.
#
# Usage: bash ParameterEstimationBenchmarking/hpc/cuny/setup_cuny.sh
#
# This script discovers available modules, partitions, and filesystem layout.

set -euo pipefail

echo "============================================"
echo "  CUNY HPC Environment Discovery"
echo "============================================"
echo "User:    $USER"
echo "Home:    $HOME"
echo "Scratch: $SCRATCH"
echo "Date:    $(date)"
echo ""

# --- Julia ---
echo "=== Julia check ==="
if [ -x "$HOME/julia-1.12.5/bin/julia" ]; then
    echo "Julia found: $HOME/julia-1.12.5/bin/julia"
    "$HOME/julia-1.12.5/bin/julia" --version
else
    echo "Julia NOT found at $HOME/julia-1.12.5/"
    echo "Install with:"
    echo "  cd ~ && curl -fsSL https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-1.12.5-linux-x86_64.tar.gz | tar xz"
fi
echo ""

# --- MATLAB ---
echo "=== MATLAB module ==="
module spider Utils/Matlab 2>&1 || echo "MATLAB not found"
echo "Expected: module load Utils/Matlab/R2024b"
echo ""

# --- Python ---
echo "=== Python ==="
python3 --version 2>&1 || echo "python3 not in PATH"
echo ""

# --- Filesystem ---
echo "=== Scratch filesystem ==="
df -h "$SCRATCH" 2>/dev/null || echo "Scratch not mounted"
echo ""
echo "=== Home filesystem ==="
df -h "$HOME" 2>/dev/null || echo "Cannot stat home directory"
echo ""

# --- SLURM ---
echo "=== SLURM partitions ==="
sinfo -s 2>&1 || echo "SLURM not available on this node"
echo ""

echo "=== SLURM account/QOS ==="
sacctmgr show assoc where user=$USER format=User,Account,QOS,DefaultQOS 2>&1 | head -10 || echo "Cannot query"
echo ""

# --- Summary ---
echo "============================================"
echo "  Next Steps"
echo "============================================"
echo "1. Install Julia 1.12.5 (if not done):"
echo "     cd ~ && curl -fsSL https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-1.12.5-linux-x86_64.tar.gz | tar xz"
echo ""
echo "2. Clone benchmark repo:"
echo "     cd \$SCRATCH"
echo "     git clone https://github.com/orebas/ParameterEstimationBenchmarking.git"
echo ""
echo "3. Read the handoff document:"
echo "     cat ParameterEstimationBenchmarking/hpc/cuny/HANDOFF.md"
echo ""
