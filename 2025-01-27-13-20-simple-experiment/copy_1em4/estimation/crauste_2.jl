using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "crauste_2"
@parameters muN muEE muLE muLL muM muP muPE muPL deltaNE deltaEL deltaLM rhoE rhoP
@variables t n(t) e(t) s(t) m(t) p(t) y1(t) y2(t) y3(t) y4(t)
D = Differential(t)
states = [n, e, s, m, p]
parameters = [muN, muEE, muLE, muLL, muM, muP, muPE, muPL, deltaNE, deltaEL, deltaLM, rhoE, rhoP]
@named model = ODESystem([
                             D(n) ~ -1 * n * muN - n * p * deltaNE,
                             D(e) ~ n * p * deltaNE - e * e * muEE - e * deltaEL + e * p * rhoE,
                             D(s) ~ s * deltaEL - s * deltaLM - s * s * muLL - e * s * muLE,
                             D(m) ~ s * deltaLM - muM * m,
                             D(p) ~ p * p * rhoP - p * muP - e * p * muPE - s * p * muPL,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ n,
        y2 ~ e,
        y3 ~ s+m,
        y4 ~ p,
]
ic = [0.843, 0.355, 0.634, 0.205, 0.673]
p_true = [0.326, 0.196, 0.337, 0.195, 0.354, 0.431, 0.151, 0.654, 0.553, 0.312, 0.519, 0.175, 0.561]

p_constraints = Dict((muN=>(-3.0, 3.0)), (muEE=>(-3.0, 3.0)), (muLE=>(-3.0, 3.0)), (muLL=>(-3.0, 3.0)), (muM=>(-3.0, 3.0)), (muP=>(-3.0, 3.0)), (muPE=>(-3.0, 3.0)), (muPL=>(-3.0, 3.0)), (deltaNE=>(-3.0, 3.0)), (deltaEL=>(-3.0, 3.0)), (deltaLM=>(-3.0, 3.0)), (rhoE=>(-3.0, 3.0)), (rhoP=>(-3.0, 3.0)))
ic_constraints = Dict((n=>(-3.0, 3.0)), (e=>(-3.0, 3.0)), (s=>(-3.0, 3.0)), (m=>(-3.0, 3.0)), (p=>(-3.0, 3.0)))
 
time_interval = [-1.0, 1.0]
datasize = 201

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-13-20/copy_1em4/data/crauste_2.csv", Tuple))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-13-20/copy_1em4/estimation_results/crauste_2.csv", table, header=string.(collect(keys(table))))

