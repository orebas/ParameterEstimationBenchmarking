#! /bin/bash

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
git checkout v0.4.3
git apply ../ParameterEstimation.jl.patch
cd ../

rm -rf mpfi.jl
git clone https://gitlab.inria.fr/ckatsama/mpfi.jl

rm -rf RationalUnivariateRepresentation.jl
git clone https://gitlab.inria.fr/newrur/RationalUnivariateRepresentation.jl

rm -rf SIAN-Julia
git clone https://github.com/alexeyovchinnikov/SIAN-Julia
cd SIAN-Julia
git checkout a95b6ada91461308ebbd467703fcb296ecacd040
git apply ../SIAN-Julia.patch
cd ../

rm -rf ODEParameterEstimation
git clone https://github.com/orebas/ODEParameterEstimation
cd ODEParameterEstimation
git apply ../ODEParameterEstimation.patch
cd ../

rm -rf julia_pe
rm -rf julia_odepe

julia -e "using Pkg; Pkg.activate(\"julia_pe\"); Pkg.add(\"MKL\"); Pkg.add(\"ParameterEstimation\"); Pkg.add(\"ModelingToolkit\"); Pkg.add(\"DifferentialEquations\"); Pkg.add(\"BenchmarkTools\"); Pkg.add(\"CSV\"); Pkg.resolve(); Pkg.instantiate()"
julia -e "using Pkg; Pkg.activate(\"julia_odepe\"); Pkg.add(\"MKL\"); Pkg.develop(path=\"ParameterEstimation.jl/\"); Pkg.develop(path=\"GaussianProcesses.jl/\"); Pkg.develop(path=\"mpfi.jl/\"); Pkg.develop(path=\"rs.jl/\"); Pkg.develop(path=\"RationalUnivariateRepresentation.jl/\"); Pkg.develop(path=\"SIAN-Julia/\"); Pkg.develop(path=\"ODEParameterEstimation/\"); Pkg.add(\"OrderedCollections\"); Pkg.add(\"ModelingToolkit\"); Pkg.add(\"DifferentialEquations\"); Pkg.add(\"BenchmarkTools\"); Pkg.add(\"CSV\"); Pkg.resolve(); Pkg.instantiate()"

