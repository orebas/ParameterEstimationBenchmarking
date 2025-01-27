using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

solver = Vern9()

name = "biohydrogenation_0"
@parameters k5 k6 k7 k8 k9 k10 
@variables x4(t) x5(t) x6(t) x7(t) y1(t) y2(t)
states = [x4, x5, x6, x7]
parameters = [k5, k6, k7, k8, k9, k10]
state_equations = [
    D(x4) ~ - k5 * x4 / (k6 + x4),
    D(x5) ~ k5 * x4 / (k6 + x4) - k7 * x5/(k8 + x5 + x6),
    D(x6) ~ k7 * x5 / (k8 + x5 + x6) - k9 * x6 * (k10 - x6) / k10,
    D(x7) ~ k9 * x6 * (k10 - x6) / k10,
]
measured_quantities = [
    y1 ~ x4,
    y2 ~ x5,
]
ic = [0.45, 0.813, 0.871, 0.407]
p_true = [0.539, 0.672, 0.582, 0.536, 0.439, 0.617]

time_interval = [-1.0, 1.0]
datasize = 201

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em2/data/biohydrogenation_0.csv", Tuple))

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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em2/estimation_results/biohydrogenation_0.csv", table, header=string.(collect(keys(table))))

