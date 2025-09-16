#! /bin/bash -e

rm -rf GaussianProcesses.jl
git clone https://github.com/STOR-i/GaussianProcesses.jl
cd GaussianProcesses.jl
git checkout v0.12.5
git apply ../GaussianProcesses.jl.patch
cd ../

rm -rf rs.jl
git clone https://gitlab.inria.fr/pace/rs.jl
cd rs.jl
git checkout 727d466b879aedf3db8265b78c3f6187c33fc85d
git apply ../rs.jl.patch
cd ../

rm -rf ParameterEstimation.jl
git clone https://github.com/iliailmer/ParameterEstimation.jl
cd ParameterEstimation.jl
git checkout v0.4.4
cd ../

rm -rf mpfi.jl
git clone https://gitlab.inria.fr/ckatsama/mpfi.jl

rm -rf RationalUnivariateRepresentation.jl
git clone https://gitlab.inria.fr/newrur/RationalUnivariateRepresentation.jl

rm -rf ODEParameterEstimation
git clone https://github.com/orebas/ODEParameterEstimation

rm -rf julia_pe
rm -rf julia_odepe

julia -e "using Pkg; Pkg.activate(\"julia_pe\"); Pkg.add(\"MKL\"); Pkg.add(name=\"ModelingToolkit\", version=\"10\"); Pkg.develop(path=\"ParameterEstimation.jl/\"); Pkg.add(\"DifferentialEquations\"); Pkg.add(\"BenchmarkTools\"); Pkg.add(\"CSV\"); Pkg.resolve(); Pkg.instantiate(); Pkg.status(mode=PKGMODE_MANIFEST);"

julia -e "using Pkg; Pkg.activate(\"julia_odepe\"); Pkg.add(\"MKL\"); Pkg.add(name=\"ModelingToolkit\", version=\"10\"); Pkg.develop(path=\"GaussianProcesses.jl/\"); Pkg.develop(path=\"mpfi.jl/\"); Pkg.develop(path=\"rs.jl/\"); Pkg.develop(path=\"RationalUnivariateRepresentation.jl/\"); Pkg.add(\"SIAN\"); Pkg.develop(path=\"ODEParameterEstimation/\"); Pkg.add(\"OrderedCollections\"); Pkg.add(\"DifferentialEquations\"); Pkg.add(\"BenchmarkTools\"); Pkg.add(\"Optim\"); Pkg.add(\"LineSearches\"); Pkg.add(\"CSV\"); Pkg.add(\"JSON\"); Pkg.resolve(); Pkg.instantiate(); Pkg.status(mode=PKGMODE_MANIFEST);"


