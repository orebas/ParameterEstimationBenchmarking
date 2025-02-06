 using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

using GaussianProcesses
using Statistics
using Optim, LineSearches


using AbstractAlgebra
using RationalUnivariateRepresentation
using RS


"""
	exprs_to_AA_polys(exprs, vars)

Convert each symbolic expression in `exprs` into a polynomial in an
AbstractAlgebra polynomial ring in the variables `vars`. This returns
both the ring `R` and the vector of polynomials in `R`.
"""
function exprs_to_AA_polys(exprs, vars)
	# Create a polynomial ring over QQ, using the variable names

	M = Module()
	Base.eval(M, :(using AbstractAlgebra))
	#Base.eval(M, :(using Nemo))
	#	Base.eval(M, :(using RationalUnivariateRepresentation))
	#	Base.eval(M, :(using RS))

	var_names = string.(vars)
	ring_command = "R = @polynomial_ring(QQ, $var_names)"
	#approximation_command = "R(expr::Float64) = R(Nemo.rational_approx(expr, 1e-4))"
	ring_object = Base.eval(M, Meta.parse(ring_command))
	#display(temp)
	#Base.eval(M, Meta.parse(approximation_command))


	a = string.(exprs)
	AA_polys = []
	for expr in exprs
		push!(AA_polys, Base.eval(M, Meta.parse(string(expr))))
	end
	return ring_object, AA_polys

end





function solve_with_rs(poly_system, varlist;
	start_point = nothing,  # Not used but kept for interface consistency
	options = Dict())

	#try
	# Convert symbolic expressions to AA polynomials using existing infrastructure
	R, aa_system = exprs_to_AA_polys(poly_system, varlist)

	println("aa_system")
	println(aa_system)
	println("R")
	println(R)
	# Compute RUR and get separating element
	rur, sep = zdim_parameterization(aa_system, get_separating_element = true)

	# Find solutions
	output_precision = get(options, :output_precision, Int32(20))
	sol = RS.rs_isolate(rur, sep, output_precision = output_precision)

	# Convert solutions back to our format
	solutions = []
	display(sol)
	for s in sol
		# Extract real solutions
		#display(s)
		real_sol = [convert(Float64, real(v[1])) for v in s]
		push!(solutions, real_sol)
	end

	#return solutions, varlist, Dict(), varlist
	return solutions, varlist, Dict(), varlist
end




solver = Vern9()

name = "daisy-mamil4_6"
parameters = @parameters k01 k12 k13 k14 k21 k31 k41 
states = @variables  x1(t) x2(t) x3(t) x4(t)
observables = @variables  y1(t) y2(t) y3(t)
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
ic = [0.425, 0.542, 0.317, 0.464]
p_true = [0.406, 0.816, 0.874, 0.538, 0.32, 0.574, 0.817]

time_interval = [-1.0, 1.0]
datasize = 1001

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/orebas/julia/no-matlab-no-worry/2025-02-06-01-56/copy_1em2/data/daisy-mamil4_6.csv", Tuple, header=false))

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
    nooutput = true,
    system_solver = solve_with_rs
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

CSV.write("/home/orebas/julia/no-matlab-no-worry/2025-02-06-01-56/copy_1em2/estimation_results/daisy-mamil4_6.csv", table, header=string.(collect(keys(table))))

