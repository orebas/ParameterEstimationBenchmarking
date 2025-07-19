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

name = "hiv"
parameters = @parameters lm d beta a k uu c q b h 
states = @variables  x(t) yy(t) vv(t) w(t) z(t)
observables = @variables  y1(t) y2(t) y3(t) y4(t)
state_equations = [
    D(x) ~ lm - d * x - beta * x * vv,
    D(yy) ~ beta * x * vv - a * yy,
    D(vv) ~ k * yy - uu * vv,
    D(w) ~ c * x * yy * w - c * q * yy * w - b * w,
    D(z) ~ c * q * yy * w - h * z,
]
measured_quantities = [
    y1 ~ w,
    y2 ~ z,
    y3 ~ x,
    y4 ~ yy+vv,
]
ic = [0.856, 0.894, 0.401, 0.873, 0.734]
p_true = [0.802, 0.398, 0.101, 0.298, 0.355, 0.787, 0.467, 0.456, 0.369, 0.805]

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

