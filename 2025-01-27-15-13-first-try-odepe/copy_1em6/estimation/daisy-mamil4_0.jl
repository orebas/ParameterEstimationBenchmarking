using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

solver = Vern9()

name = "daisy-mamil4_0"
@parameters k01 k12 k13 k14 k21 k31 k41 
@variables x1(t) x2(t) x3(t) x4(t) y1(t) y2(t) y3(t)
states = [x1, x2, x3, x4]
parameters = [k01, k12, k13, k14, k21, k31, k41]
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
ic = [0.148, 0.633, 0.637, 0.268]
p_true = [0.59, 0.594, 0.855, 0.645, 0.388, 0.45, 0.658]

time_interval = [-1.0, 1.0]
datasize = 201

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em6/data/daisy-mamil4_0.csv", Tuple))

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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em6/estimation_results/daisy-mamil4_0.csv", table, header=string.(collect(keys(table))))

