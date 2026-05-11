#!/bin/bash -e
#
# Setup Julia environments for the benchmark harness.
#
# The odepe environment needs ODEParameterEstimation + its dependencies (SIAN,
# StructuralIdentifiability). These packages' registered versions have [compat]
# bounds that pin ModelingToolkit to v10, but the current ODEPE code requires
# MTK v11. We clone these packages and strip their [compat] sections so the
# resolver can pick MTK v11.
#
# The sciml environment is independent (no ODEPE) and stays on MTK v10 with
# its own syntax.
#
# Usage: cd environments/ && bash setup_julia.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Pinned commits ──────────────────────────────────────────────────────────
ODEPE_REPO="https://github.com/orebas/ODEParameterEstimation.git"
ODEPE_COMMIT="5853a0719d730cf4a6364e2b435a458ef918b39e"

SIAN_REPO="https://github.com/alexeyovchinnikov/SIAN-Julia.git"
SIAN_COMMIT="d17262c5869eceb7fde431d82df9852262717b46"

SI_REPO="https://github.com/SciML/StructuralIdentifiability.jl.git"
SI_COMMIT="4b1c4093d864e40e536e29ce1a0e63dfe464d458"

# ── Helper: strip [compat] section from a Project.toml ─────────────────────
# Removes everything from "[compat]" up to (but not including) the next
# "[section]" header, or end-of-file if [compat] is the last section.
strip_compat() {
    local file="$1"
    python3 -c "
import re, sys
with open('$file', 'r') as f:
    content = f.read()
content = re.sub(r'\[compat\].*?(?=\n\[|\Z)', '[compat]\n', content, flags=re.DOTALL)
with open('$file', 'w') as f:
    f.write(content)
print('  Stripped [compat] from $file')
"
}

# ── Clone and patch dependencies ────────────────────────────────────────────
echo "=== Cloning ODEParameterEstimation at $ODEPE_COMMIT ==="
rm -rf ODEParameterEstimation
git clone "$ODEPE_REPO" ODEParameterEstimation
cd ODEParameterEstimation && git checkout "$ODEPE_COMMIT" && cd ..

echo "=== Cloning SIAN at $SIAN_COMMIT ==="
rm -rf SIAN-Julia
git clone "$SIAN_REPO" SIAN-Julia
cd SIAN-Julia && git checkout "$SIAN_COMMIT" && cd ..
strip_compat "SIAN-Julia/Project.toml"

echo "=== Cloning StructuralIdentifiability at $SI_COMMIT ==="
rm -rf StructuralIdentifiability.jl
git clone "$SI_REPO" StructuralIdentifiability.jl
cd StructuralIdentifiability.jl && git checkout "$SI_COMMIT" && cd ..
strip_compat "StructuralIdentifiability.jl/Project.toml"

# ── Create julia_odepe environment ──────────────────────────────────────────
# Order matters: dev SIAN and SI first (compat stripped), then ODEPE (which
# depends on them). This lets MTK resolve to v11.
echo ""
echo "=== Setting up julia_odepe environment ==="
rm -rf julia_odepe
julia -e '
using Pkg
Pkg.activate("julia_odepe")

# Dev the compat-stripped dependencies first
Pkg.develop(path="SIAN-Julia/")
Pkg.develop(path="StructuralIdentifiability.jl/")

# Dev ODEPE (depends on SIAN + SI — resolver uses the dev versions above)
Pkg.develop(path="ODEParameterEstimation/")

# Add remaining direct dependencies needed by the templates
Pkg.add([
    "MKL",
    "OrdinaryDiffEq",
    "BenchmarkTools",
    "OrderedCollections",
    "CSV",
    "GaussianProcesses",
    "Optim",
    "LineSearches",
    "Symbolics",
    "Distributions",
    "Statistics",
    "JSON",
])

Pkg.resolve()
Pkg.instantiate()

println("\n=== julia_odepe manifest (key packages) ===")
Pkg.status(mode=Pkg.PKGMODE_MANIFEST)
'

# ── Create julia_sciml environment ──────────────────────────────────────────
# SciML template also uses MTK v11 syntax (System, t_nounits, D_nounits).
# No ODEPE dependency, no compat issues.
echo ""
echo "=== Setting up julia_sciml environment ==="
rm -rf julia_sciml
julia -e '
using Pkg
Pkg.activate("julia_sciml")

Pkg.add([
    "MKL",
    "CSV",
    "Distributions",
    "ForwardDiff",
    "ModelingToolkit",
    "Optimization",
    "OptimizationOptimJL",
    "OptimizationPolyalgorithms",
    "OrdinaryDiffEq",
    "SciMLSensitivity",
    "StaticArrays",
])

Pkg.resolve()
Pkg.instantiate()

println("\n=== julia_sciml manifest (key packages) ===")
Pkg.status(mode=Pkg.PKGMODE_MANIFEST)
'

echo ""
echo "=== Setup complete ==="
echo "julia_odepe: MTK v11 + ODEPE (dev) + SIAN (dev, compat stripped) + SI (dev, compat stripped)"
echo "julia_sciml: MTK v11 + SciML optimization stack"
