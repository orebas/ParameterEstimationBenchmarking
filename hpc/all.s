#!/bin/bash

cd $SCRATCH

source no-matlab-no-worry/hpc/setup_python.s
julia no-matlab-no-worry/hpc/setup_packages.jl

python no-matlab-no-worry/src/generate_data.py no-matlab-no-worry/config/config.json no-matlab-no-worry/config/systems.json

python no-matlab-no-worry/src/generate_scipts.py ??? pe
python no-matlab-no-worry/src/generate_scipts.py ??? odepe
python no-matlab-no-worry/src/generate_scipts.py ??? iqm
python no-matlab-no-worry/src/generate_scipts.py ??? amigo2

python no-matlab-no-worry/src/estimate.py ??? pe 0-1
python no-matlab-no-worry/src/estimate.py ??? odepe 0-1
python no-matlab-no-worry/src/estimate.py ??? iqm 0-1
python no-matlab-no-worry/src/estimate.py ??? amigo2 0-1

python no-matlab-no-worry/src/collect_results.py ???

cat no-matlab-no-worry/???/results.json

