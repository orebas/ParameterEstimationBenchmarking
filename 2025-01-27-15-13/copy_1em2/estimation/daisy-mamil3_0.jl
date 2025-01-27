using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

solver = Vern9()

name = "daisy-mamil3_0"
@parameters a12 a13 a21 a31 a01 
@variables x1(t) x2(t) x3(t) y1(t) y2(t)
states = [x1, x2, x3]
parameters = [a12, a13, a21, a31, a01]
state_equations = [
    D(x1) ~ -(a21 + a31 + a01) * x1 + a12 * x2 + a13 * x3,
    D(x2) ~ a21 * x1 - a12 * x2,
    D(x3) ~ a31 * x1 - a13 * x3,
]
measured_quantities = [
    y1 ~ x1,
    y2 ~ x2,
]
ic = [0.555, 0.115, 0.594]
p_true = [0.517, 0.432, 0.312, 0.719, 0.465]

time_interval = [-1.0, 1.0]
datasize = 201

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em2/data/daisy-mamil3_0.csv", Tuple))

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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em2/estimation_results/daisy-mamil3_0.csv", table, header=string.(collect(keys(table))))

