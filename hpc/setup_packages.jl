using Pkg;

Pkg.activate(joinpath(@__DIR__, "..", "julia_env"))

Pkg.add("ModelingToolkit")
Pkg.add("DifferentialEquations")
Pkg.add("ParameterEstimation")
Pkg.add("Distributions")
Pkg.add("BenchmarkTools")
Pkg.add("CSV")
Pkg.add("OrderedCollections")
Pkg.add("GaussianProcesses")
Pkg.add("Optim")
Pkg.add("LineSearches")
Pkg.add("AbstractAlgebra")

Pkg.add(url="https://gitlab.inria.fr/ckatsama/mpfi.jl")
Pkg.add(url="https://gitlab.inria.fr/pace/rs.jl")
Pkg.add(url="https://gitlab.inria.fr/newrur/RationalUnivariateRepresentation.jl")
Pkg.add(url="https://github.com/orebas/ODEParameterEstimation")

