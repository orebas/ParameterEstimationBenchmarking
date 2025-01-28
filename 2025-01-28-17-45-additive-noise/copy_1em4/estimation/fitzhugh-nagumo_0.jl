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
datasize = 1001

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-28-17-45/copy_1em4/data/fitzhugh-nagumo_0.csv", Tuple, header=false))

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

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-28-17-45/copy_1em4/estimation_results/fitzhugh-nagumo_0.csv", table, header=string.(collect(keys(table))))

