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

