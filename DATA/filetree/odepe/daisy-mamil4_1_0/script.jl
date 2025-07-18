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

name = "daisy-mamil4"
parameters = @parameters k01 k12 k13 k14 k21 k31 k41 
states = @variables  x1(t) x2(t) x3(t) x4(t)
observables = @variables  y1(t) y2(t) y3(t)
state_equations = [
    D(x1) ~ -k01 * x1 + k12 * x2 + k13 * x3 + k14 * x4 - k21 * x1 - k31 * x1 - k41 * x1,
    D(x2) ~ -k12 * x2 + k21 * x1,
    D(x3) ~ -k13 * x3 + k31 * x1,
    D(x4) ~ -k14 * x4 + k41 * x1,
]
measured_quantities = [
    y1 ~ x1,
    y2 ~ x2,
    y3 ~ x3 + x4,
]
ic = [0.665, 0.432, 0.388, 0.763]
p_true = [0.63, 0.297, 0.633, 0.514, 0.439, 0.544, 0.33]

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

