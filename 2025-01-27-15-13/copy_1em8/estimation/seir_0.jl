using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

solver = Vern9()

name = "seir_0"
@parameters a b nu 
@variables S(t) E(t) In(t) NN(t) y1(t) y2(t)
states = [S, E, In, NN]
parameters = [a, b, nu]
state_equations = [
    D(S) ~ -b * S * In / NN,
    D(E) ~ b * S * In / NN - nu * E,
    D(In) ~ nu * E - a * In,
    D(NN) ~ 0,
]
measured_quantities = [
    y1 ~ In,
    y2 ~ NN,
]
ic = [0.195, 0.354, 0.431, 0.151]
p_true = [0.326, 0.196, 0.337]

time_interval = [-1.0, 1.0]
datasize = 201

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em8/data/seir_0.csv", Tuple))

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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em8/estimation_results/seir_0.csv", table, header=string.(collect(keys(table))))

