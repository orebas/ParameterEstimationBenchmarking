using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

solver = Vern9()

name = "hiv_0"
@parameters lm d beta a k uu c q b h 
@variables x(t) yy(t) vv(t) w(t) z(t) y1(t) y2(t) y3(t) y4(t)
states = [x, yy, vv, w, z]
parameters = [lm, d, beta, a, k, uu, c, q, b, h]
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
ic = [0.757, 0.178, 0.77, 0.177, 0.881]
p_true = [0.622, 0.303, 0.473, 0.296, 0.227, 0.188, 0.625, 0.211, 0.257, 0.395]

time_interval = [-1.0, 1.0]
datasize = 201

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em2/data/hiv_0.csv", Tuple))

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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em2/estimation_results/hiv_0.csv", table, header=string.(collect(keys(table))))

