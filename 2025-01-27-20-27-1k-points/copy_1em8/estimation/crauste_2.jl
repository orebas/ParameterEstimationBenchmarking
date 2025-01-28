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

name = "crauste_2"
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
ic = [0.843, 0.355, 0.634, 0.205, 0.673]
p_true = [0.326, 0.196, 0.337, 0.195, 0.354, 0.431, 0.151, 0.654, 0.553, 0.312, 0.519, 0.175, 0.561]

time_interval = [-1.0, 1.0]
datasize = 1001

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-20-27/copy_1em8/data/crauste_2.csv", Tuple))

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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-20-27/copy_1em8/estimation_results/crauste_2.csv", table, header=string.(collect(keys(table))))

