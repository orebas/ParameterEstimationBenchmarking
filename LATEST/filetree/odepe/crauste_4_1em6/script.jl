using Pkg; Pkg.activate(joinpath(dirname(dirname(dirname(dirname(@__DIR__)))), string(:julia_env)))

using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

using GaussianProcesses
using Statistics
using Optim, LineSearches

name = "crauste"
parameters = @parameters muN muEE muLE muLL muM muP muPE muPL deltaNE deltaEL deltaLM rhoE rhoP 
states = @variables  n(t) e(t) s(t) m(t) p(t)
observables = @variables  y1(t) y2(t) y3(t) y4(t)
state_equations = [
    D(n) ~ -1 * n * muN - n * p * deltaNE,
    D(e) ~ n * p * deltaNE - e * e * muEE - e * deltaEL + e * p * rhoE,
    D(s) ~ s * deltaEL - s * deltaLM - s * s * muLL - e * s * muLE,
    D(m) ~ s * deltaLM - muM * m,
    D(p) ~ p * p * rhoP - p * muP - e * p * muPE - s * p * muPL,
]
measured_quantities = [
    y1 ~ n,
    y2 ~ e,
    y3 ~ s+m,
    y4 ~ p,
]
ic = [0.417, 0.552, 0.247, 0.216, 0.49]
p_true = [0.515, 0.121, 0.266, 0.44, 0.399, 0.471, 0.322, 0.569, 0.791, 0.194, 0.514, 0.206, 0.673]

time_interval = [-1.0, 1.0]
datasize = 1001

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read(joinpath(@__DIR__, "data.csv"), Tuple, header=false))

pep = ParameterEstimationProblem(
    name,
    model,
    mq,
    data_sample,
    time_interval,
    nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0,
)
 
meta, results = analyze_parameter_estimation_problem(
    pep,
    nooutput = true,
    shooting_points = 1
)
 
(solutions_vector, besterror,
    best_min_error,
    best_mean_error,
    best_median_error,
    best_max_error,
    best_approximation_error,
    best_rms_error) = results
 
table = merge(
    Dict((string(x) => [each.states[x] for each in solutions_vector] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in solutions_vector] for x in parameters)),
)
 
CSV.write(joinpath(@__DIR__, "result.csv"), table, header = string.(collect(keys(table))))

