using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

solver = Vern9()

name = "fitzhugh-nagumo_0"
@parameters g a b 
@variables V(t) R(t) y1(t)
states = [V, R]
parameters = [g, a, b]
state_equations = [
    D(V) ~ g * (V - V^3 / 3 + R),
    D(R) ~ 1 / g * (V - a + b * R),
]
measured_quantities = [
    y1 ~ V,
]
ic = [0.556, 0.451]
p_true = [0.203, 0.352, 0.391]

time_interval = [-1.0, 1.0]
datasize = 201

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em6/data/fitzhugh-nagumo_0.csv", Tuple))

pep = ParameterEstimationProblem(
    name,
    model,
    mq,
    data_sample,
    time_interval,
    nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0
)

res = analyze_parameter_estimation_problem(
    pep,
    test_mode = false,
    nooutput = true,
    interpolator = aaad
)

analysis_result, besterror = analyze_estimation_result(
    pep,
    res,
    nooutput = true
)

table = merge(
    Dict((string(x) => [each.states[x] for each in analysis_result] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in analysis_result] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em6/estimation_results/fitzhugh-nagumo_0.csv", table, header=string.(collect(keys(table))))

