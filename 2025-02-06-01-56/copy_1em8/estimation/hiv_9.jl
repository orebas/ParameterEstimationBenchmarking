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

name = "hiv_9"
parameters = @parameters lm d beta a k uu c q b h 
states = @variables  x(t) yy(t) vv(t) w(t) z(t)
observables = @variables  y1(t) y2(t) y3(t) y4(t)
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
ic = [0.856, 0.894, 0.401, 0.873, 0.734]
p_true = [0.802, 0.398, 0.101, 0.298, 0.355, 0.787, 0.467, 0.456, 0.369, 0.805]

time_interval = [-1.0, 1.0]
datasize = 1001

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/orebas/julia/no-matlab-no-worry/2025-02-06-01-56/copy_1em8/data/hiv_9.csv", Tuple, header=false))

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

CSV.write("/home/orebas/julia/no-matlab-no-worry/2025-02-06-01-56/copy_1em8/estimation_results/hiv_9.csv", table, header=string.(collect(keys(table))))

