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

name = "fitzhugh_nagumo"
parameters = @parameters g a b 
states = @variables  V(t) R(t)
observables = @variables  y1(t)
state_equations = [
    D(V) ~ g * (V - V^3 / 3 + R),
    D(R) ~ 1 / g * (V - a + b * R),
]
measured_quantities = [
    y1 ~ V,
]
ic = [0.571, 0.87]
p_true = [0.102, 0.618, 0.58]

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

