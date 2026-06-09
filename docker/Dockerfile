# syntax=docker/dockerfile:1.7
# ─────────────────────────────────────────────────────────────────────────────
# Julia-only, reproducible image for the PEB + ODEParameterEstimation benchmark.
#
# Strategy: FREEZE the dependency stack (212 JLLs + MTK-v11 + the compat-stripped
# SIAN/SI forks), precompiled once; INJECT the ODEPE source at run-time (it's the
# code under test). amigo2/MATLAB is intentionally NOT in this image — it runs on
# CUNY. See docker/entrypoint.sh + docker/run-benchmark.sh for usage.
#
# Build (context MUST be the PEB repo root):
#   docker build -f docker/Dockerfile -t odepe-bench:latest .
# Immutable/archival variant pinned to a specific ODEPE commit:
#   docker build -f docker/Dockerfile --build-arg ODEPE_REF=<sha> -t odepe-bench:<sha> .
# OpenBLAS instead of MKL (e.g. to A/B on AMD):  --build-arg BLAS=openblas (TODO: alt env)
# ─────────────────────────────────────────────────────────────────────────────
ARG JULIA_VERSION=1.12.5

# ── base: OS + system libraries ──────────────────────────────────────────────
FROM julia:${JULIA_VERSION}-bookworm AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates build-essential gfortran libgomp1 \
        python3 python3-venv python3-pip rsync procps \
 && rm -rf /var/lib/apt/lists/*

# Fixed layout. MUST match what generate_scripts.py bakes at render time
# (Pkg.activate(raw"<peb_root>/environments/julia_odepe") + harness_root), which is
# why the whole pipeline runs in-container with peb_root == /opt/peb.
ENV PEB_ROOT=/opt/peb \
    ODEPE_DIR=/opt/odepe \
    JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PKG_PRECOMPILE_AUTO=0 \
    JULIA_CPU_TARGET="generic;x86-64-v3,clone_all" \
    MKL_ENABLE_INSTRUCTIONS=AVX2
RUN mkdir -p /opt/peb/environments /opt/odepe /opt/julia-depot /work/results

# ── deps: clone the 3 pinned trees, instantiate the FROZEN manifest, precompile ─
FROM base AS deps
ARG ODEPE_REPO=https://github.com/orebas/ODEParameterEstimation.git
ARG ODEPE_REF=quoll-v1
ARG SIAN_REPO=https://github.com/alexeyovchinnikov/SIAN-Julia.git
ARG SIAN_COMMIT=d17262c5869eceb7fde431d82df9852262717b46
ARG SI_REPO=https://github.com/SciML/StructuralIdentifiability.jl.git
ARG SI_COMMIT=4b1c4093d864e40e536e29ce1a0e63dfe464d458
ARG GROEBNER_REPO=https://github.com/orebas/Groebner.jl.git
ARG GROEBNER_REF=fix-generic-alignment
WORKDIR /opt/peb

# SIAN + SI forks (compat-stripped so MTK resolves to v11) at their pinned commits.
COPY docker/strip_compat.py /tmp/strip_compat.py
RUN git clone "$SIAN_REPO" environments/SIAN-Julia \
 && git -C environments/SIAN-Julia checkout --quiet "$SIAN_COMMIT" \
 && python3 /tmp/strip_compat.py environments/SIAN-Julia/Project.toml \
 && git clone "$SI_REPO" environments/StructuralIdentifiability.jl \
 && git -C environments/StructuralIdentifiability.jl checkout --quiet "$SI_COMMIT" \
 && python3 /tmp/strip_compat.py environments/StructuralIdentifiability.jl/Project.toml

# Groebner PR #218 fixes non-power-of-two alignment in learn-and-apply batching.
RUN git clone "$GROEBNER_REPO" environments/Groebner \
 && git -C environments/Groebner checkout --quiet "$GROEBNER_REF"

# ODEPE at a build-time ref = the precompile target. At RUN, inject-odepe.sh swaps
# /opt/odepe to the desired ref and re-warms incrementally. Default = quoll-v1, the
# ref the committed Manifest below is known-compatible with (the live local env).
RUN git clone "$ODEPE_REPO" /opt/odepe \
 && git -C /opt/odepe checkout --quiet "$ODEPE_REF" \
 && ln -s /opt/odepe environments/ODEParameterEstimation

# The reproducibility anchor: instantiate the COMMITTED manifest (do NOT resolve —
# setup_julia.sh re-resolves, which we must avoid in the image).
COPY environments/julia_odepe/Project.toml environments/julia_odepe/Manifest.toml \
     environments/julia_odepe/
RUN julia --startup-file=no --project=/opt/peb/environments/julia_odepe \
        -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# Python harness deps in a venv.
COPY environments/requirements.txt environments/requirements.txt
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir -r environments/requirements.txt

# ── runtime: add the harness code + helper scripts ───────────────────────────
FROM deps AS runtime
COPY src/       /opt/peb/src/
COPY templates/ /opt/peb/templates/
COPY config/    /opt/peb/config/
COPY docker/    /opt/peb/docker/
ENV PATH=/opt/venv/bin:$PATH
WORKDIR /opt/peb
RUN chmod +x /opt/peb/docker/*.sh
ENTRYPOINT ["/opt/peb/docker/entrypoint.sh"]
CMD ["selftest"]
