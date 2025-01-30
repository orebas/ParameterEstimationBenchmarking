using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

using GaussianProcesses
using Statistics
using Optim, LineSearches

solver = Vern9()

name = "crauste_1"
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
ic = [0.268, 0.249, 0.855, 0.692, 0.492]
p_true = [0.664, 0.125, 0.232, 0.597, 0.562, 0.29, 0.847, 0.591, 0.529, 0.572, 0.684, 0.35, 0.419]

time_interval = [-1.0, 1.0]
datasize = 1001

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-29-10-07/copy_1em8/data/crauste_1.csv", Tuple, header=false))

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

function test_gpr_function(xs::AbstractArray{T}, ys::AbstractArray{T}) where {T}
	# For 1D input data, we need a matrix of size 1 × (degree+1)
	# The +1 is because we include the constant term (degree 0)
	#degree = 2
	#β = zeros(1, degree + 1)  # Initialize coefficients matrix
	#poly_mean = MeanPoly(β)

	# Add small noise proportional to y standard deviation to avoid conditioning issues
	ys_std = Statistics.std(ys)
	noise_level = 1e-6 * ys_std
	ys_noisy = ys .+ noise_level * randn(length(ys))


	kernel = SEIso(log(std(xs) / 8), 0.0)
	gp = GP(xs, ys_noisy, MeanZero(), kernel, -2.0)
	optimize!(gp; method = LBFGS(linesearch = LineSearches.BackTracking()))

	# Create callable function
	gpr_func = x -> begin
		pred, _ = predict_f(gp, [x])
		return pred[1]
	end
	return gpr_func
end

res = analyze_parameter_estimation_problem(
    pep,
    test_mode = false,
    nooutput = true,
    interpolator = test_gpr_function
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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-29-10-07/copy_1em8/estimation_results/crauste_1.csv", table, header=string.(collect(keys(table))))

