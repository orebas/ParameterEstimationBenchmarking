#!/usr/bin/env python3
"""Strip the [compat] section from a Project.toml so Pkg's resolver can pick newer deps.

Used for the SIAN-Julia and StructuralIdentifiability.jl forks: their registered
[compat] bounds pin ModelingToolkit to v10, but current ODEParameterEstimation needs
v11. Mirrors the `strip_compat()` helper in environments/setup_julia.sh exactly so the
container reproduces the same env the local box resolves.

Usage: strip_compat.py <Project.toml> [<Project.toml> ...]
"""
import re
import sys

for path in sys.argv[1:]:
    with open(path) as f:
        content = f.read()
    # Replace everything from "[compat]" up to the next "[section]" (or EOF) with
    # an empty "[compat]" header.
    content = re.sub(r"\[compat\].*?(?=\n\[|\Z)", "[compat]\n", content, flags=re.DOTALL)
    with open(path, "w") as f:
        f.write(content)
    print(f"  stripped [compat] from {path}")
