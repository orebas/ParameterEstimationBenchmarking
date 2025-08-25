#! /bin/bash

rm -rf GaussianProcesses.jl
git clone https://github.com/STOR-i/GaussianProcesses.jl
cd GaussianProcesses.jl
git checkout v0.12.5
git apply ../GaussianProcesses.jl.patch
cd ../

rm -rf rs.jl
git clone https://gitlab.inria.fr/pace/rs.jl

rm -rf mpfi.jl
git clone https://gitlab.inria.fr/ckatsama/mpfi.jl

rm -rf RationalUnivariateRepresentation.jl
git clone https://gitlab.inria.fr/newrur/RationalUnivariateRepresentation.jl

rm -rf ODEParameterEstimation
git clone https://github.com/orebas/ODEParameterEstimation

julia -e "using Pkg; Pkg.activate(\"julia_pe\"); Pkg.instantiate()"
julia -e "using Pkg; Pkg.activate(\"julia_odepe\"); Pkg.instantiate()"

