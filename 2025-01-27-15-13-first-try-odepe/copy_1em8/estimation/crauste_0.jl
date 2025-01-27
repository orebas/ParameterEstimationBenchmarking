using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

solver = Vern9()

name = "crauste_0"
@parameters muN muEE muLE muLL muM muP muPE muPL deltaNE deltaEL deltaLM rhoE rhoP 
@variables n(t) e(t) s(t) m(t) p(t) y1(t) y2(t) y3(t) y4(t)
states = [n, e, s, m, p]
parameters = [muN, muEE, muLE, muLL, muM, muP, muPE, muPL, deltaNE, deltaEL, deltaLM, rhoE, rhoP]
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
ic = [0.724, 0.195, 0.612, 0.215, 0.856]
p_true = [0.733, 0.523, 0.554, 0.84, 0.157, 0.17, 0.116, 0.766, 0.723, 0.796, 0.883, 0.739, 0.469]

time_interval = [-1.0, 1.0]
datasize = 201

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em8/data/crauste_0.csv", Tuple))

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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-15-13/copy_1em8/estimation_results/crauste_0.csv", table, header=string.(collect(keys(table))))

