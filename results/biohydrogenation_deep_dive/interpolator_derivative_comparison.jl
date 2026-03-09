#!/usr/bin/env julia
#
# Biohydrogenation: Interpolator Derivative Accuracy Comparison
# =============================================================
# Adapted from ERK deep dive (erk_feasibility_diagnostic.jl).
#
# For each of the 6 quokka interpolators, evaluates the observable derivatives
# that the SI template actually uses, and compares to ground truth computed
# via Taylor coefficient recursion on the ODE.
#
# Data variables needed (from SIAN analysis):
#   y1_0, y1_1, y1_2   (y1 = 8*x4, orders 0-2)
#   y2_0..y2_5          (y2 = 0.5*x5, orders 0-5)
#
# Run: julia results/biohydrogenation_deep_dive/interpolator_derivative_comparison.jl

using Printf
using Statistics
using LinearAlgebra

println("=" ^ 80)
println("  Biohydrogenation: Interpolator Derivative Accuracy Comparison")
println("=" ^ 80)

println("\nLoading packages...")
t_load = @elapsed begin
	using ODEParameterEstimation
	using ModelingToolkit
	using ModelingToolkit: t_nounits as t, D_nounits as D
	using OrderedCollections
	using Symbolics: Num
	using CSV
	using OrdinaryDiffEq
end
@printf("Loaded in %.1f s\n", t_load)

const PE = ODEParameterEstimation

# ═══════════════════════════════════════════════════════════════════
# STEP 1: Model Setup + Data
# ═══════════════════════════════════════════════════════════════════
println("\nSTEP 1: Setting up biohydrogenation...")
flush(stdout)

parameters_def = @parameters k5 k6 k7 k8 k9 k10
states_def = @variables x4(t) x5(t) x6(t) x7(t)
observables = @variables y1(t) y2(t)

state_equations = [
	D(x4) ~ (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4)),
	D(x5) ~ ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5,
	D(x6) ~ ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5,
	D(x7) ~ (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10),
]
measured_quantities_def = [y1 ~ 8.0*x4, y2 ~ 0.5*x5]

ic = [0.278, 0.862, 0.458, 0.777]
p_true = [0.688, 0.87, 0.299, 0.561, 0.574, 0.558]
time_interval = [0.0, 10.0]

model, mq = create_ordered_ode_system(
	"BioHydrogenation", states_def, parameters_def, state_equations, measured_quantities_def
)

# Load quokka data
data_path = expanduser("~/ParameterEstimationBenchmarking/benchmark_quokka_2026_03_05/filetree/data_noisy/biohydrogenation_0_0/data.csv")
csv_data = CSV.read(data_path, Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
	data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end
t_vector = data_sample["t"]

pep = ParameterEstimationProblem("biohydrogenation", model, mq, data_sample, time_interval, nothing,
	OrderedDict(parameters_def .=> p_true), OrderedDict(states_def .=> ic), 0)

println("  Data: $(length(t_vector)) points, t=[$(t_vector[1]), $(t_vector[end])]")
flush(stdout)

# ═══════════════════════════════════════════════════════════════════
# STEP 2: ODE Solution (high accuracy, dense output)
# ═══════════════════════════════════════════════════════════════════
println("\nSTEP 2: Solving ODE with high accuracy...")
flush(stdout)

function bioh_rhs!(du, u, p, t_val)
	x4v, x5v, x6v, x7v = u
	k5v, k6v, k7v, k8v, k9v, k10v = p
	du[1] = (-8.0*k5v*x4v) / (8.0*(4.0*k6v + 8.0*x4v))
	du[2] = ((-0.3*k7v*x5v) / (2.0*k8v + 0.5*x6v + 0.5*x5v) + (8.0*k5v*x4v) / (4.0*k6v + 8.0*x4v)) / 0.5
	du[3] = ((-0.2*(10.0*k10v - 0.5*x6v)*k9v*x6v) / (10.0*k10v) + (0.3*k7v*x5v) / (2.0*k8v + 0.5*x6v + 0.5*x5v)) / 0.5
	du[4] = (0.2*(10.0*k10v - 0.5*x6v)*k9v*x6v) / (5.0*k10v)
end

prob = ODEProblem(bioh_rhs!, ic, (0.0, 10.0), p_true)
sol = solve(prob, Vern9(); abstol=1e-14, reltol=1e-14, dense=true)
println("  ODE solved: $(length(sol.t)) steps")
flush(stdout)

# ═══════════════════════════════════════════════════════════════════
# STEP 3: Ground-Truth Derivatives via Taylor Coefficient Recursion
# ═══════════════════════════════════════════════════════════════════
println("\nSTEP 3: Computing ground-truth derivatives via Taylor recursion...")
flush(stdout)

# Taylor series arithmetic helpers
function taylor_product(a::Vector{Float64}, b::Vector{Float64}, k::Int)
	# (a*b)_k = sum_{j=0}^{k} a_{j} * b_{k-j}
	s = 0.0
	for j in 0:k
		s += a[j+1] * b[k-j+1]
	end
	return s
end

function taylor_quotient!(c::Vector{Float64}, a::Vector{Float64}, b::Vector{Float64}, k::Int)
	# c = a/b, so a = b*c  =>  c_k = (a_k - sum_{j=1}^{k} b_j * c_{k-j}) / b_0
	s = a[k+1]
	for j in 1:k
		s -= b[j+1] * c[k-j+1]
	end
	c[k+1] = s / b[1]
end

function compute_taylor_at_t(sol, p_true, t0; max_order=10)
	k5v, k6v, k7v, k8v, k9v, k10v = p_true
	u0 = sol(t0)
	N = max_order + 1

	# Taylor coefficients: tc[i][k+1] = x_i^(k) / k!
	x4 = zeros(N); x5 = zeros(N); x6 = zeros(N); x7 = zeros(N)
	x4[1] = u0[1]; x5[1] = u0[2]; x6[1] = u0[3]; x7[1] = u0[4]

	# Intermediate series we'll need
	# For x4' = (-k5*x4) / (4*k6 + 8*x4)  [simplified from the equation]
	# x4' = (-8*k5*x4) / (8*(4*k6 + 8*x4)) = (-k5*x4) / (4*k6 + 8*x4)
	#
	# For x5' = 2*[ (-0.3*k7*x5)/(2*k8 + 0.5*x6 + 0.5*x5) + (k5*x4)/(4*k6 + 8*x4) ]
	#         = 2*[ term_A + term_B ]
	# where term_A = (-0.3*k7*x5) / (2*k8 + 0.5*x6 + 0.5*x5)
	#       term_B = (8*k5*x4) / (8*(4*k6 + 8*x4)) = k5*x4/(4*k6+8*x4)
	#
	# For x6' = 2*[ (-0.2*(10*k10 - 0.5*x6)*k9*x6)/(10*k10) + term_A_like ]
	#         = 2*[ (-0.02*k9*x6*(10*k10-0.5*x6))/k10 + (0.3*k7*x5)/(2*k8+0.5*x6+0.5*x5) ]

	# Pre-allocate intermediate Taylor series
	denom1 = zeros(N)   # 4*k6 + 8*x4
	num1 = zeros(N)     # -k5 * x4
	q1 = zeros(N)       # x4' = num1/denom1

	denom2 = zeros(N)   # 2*k8 + 0.5*x6 + 0.5*x5
	num2 = zeros(N)     # -0.3*k7 * x5
	q2 = zeros(N)       # term_A = num2/denom2

	num3 = zeros(N)     # k5 * x4 (same ratio as q1 but for x5 eq: 8*k5*x4 / (8*denom1))
	# Actually term_B = k5*x4 / (4*k6+8*x4) = same as -q1 * (-1) ... hmm no.
	# x4' = -k5*x4 / (4*k6+8*x4), so term_B = -x4' = k5*x4/(4*k6+8*x4)
	# So term_B = -q1. Let's just compute it directly.

	cap = zeros(N)      # 10*k10 - 0.5*x6
	prod_x6_cap = zeros(N)  # x6 * cap
	num4 = zeros(N)     # -0.2*k9/k10 * (x6 * cap)  ... actually let me be careful

	for k in 0:(max_order - 1)
		# Update denominators and numerators at order k
		denom1[k+1] = (k == 0 ? 4.0*k6v : 0.0) + 8.0*x4[k+1]
		denom2[k+1] = (k == 0 ? 2.0*k8v : 0.0) + 0.5*x6[k+1] + 0.5*x5[k+1]
		num1[k+1] = -k5v * x4[k+1]
		num2[k+1] = -0.3*k7v * x5[k+1]
		num3[k+1] = k5v * x4[k+1]
		cap[k+1] = (k == 0 ? 10.0*k10v : 0.0) - 0.5*x6[k+1]

		# x6 * cap at order k
		prod_x6_cap[k+1] = taylor_product(x6, cap, k)

		# Compute quotients at order k
		taylor_quotient!(q1, num1, denom1, k)   # x4' Taylor coeffs (before /k+1)
		taylor_quotient!(q2, num2, denom2, k)   # term_A Taylor coeffs

		# term_B = num3 / denom1  (same denominator as q1)
		# Actually term_B = -q1 since q1 = -k5*x4/denom1 and term_B = k5*x4/denom1
		# So term_B_k = -q1[k+1]. Let me verify:
		# q1 = (-k5*x4) / (4*k6+8*x4) = -k5*x4/denom1
		# term_B = k5*x4/denom1 = -q1
		# Yes.

		# x4^(k+1)/(k+1)! = q1_k ... wait, q1 IS the Taylor series of x4', so
		# q1_k = [x4']_k = x4_{k+1} * (k+1)
		# So x4_{k+1} = q1_k / (k+1)
		x4[k+2] = q1[k+1] / (k + 1)

		# x5' = (term_A + term_B) / 0.5 = 2*(q2_k + (-q1[k+1]))
		# x5' Taylor coeff at order k = 2*(q2[k+1] - q1[k+1])
		dx5_k = 2.0 * (q2[k+1] - 8.0 * q1[k+1])
		x5[k+2] = dx5_k / (k + 1)

		# x6' = 2*[ (-0.2*k9*x6*(10*k10-0.5*x6))/(10*k10) + (0.3*k7*x5)/(2*k8+0.5*x6+0.5*x5) ]
		# First term: -0.2*k9/(10*k10) * x6*(10*k10-0.5*x6) = -0.02*k9/k10 * prod_x6_cap
		# Second term: -(num2)/denom2 * (-1) = ... wait.
		# The second term inside x6' bracket is (0.3*k7*x5)/(2*k8+0.5*x6+0.5*x5)
		# = -num2/denom2 = -q2  (since num2 = -0.3*k7*x5, q2 = num2/denom2)
		# So second term = -q2
		coeff_x6 = -0.02 * k9v / k10v
		dx6_k = 2.0 * (coeff_x6 * prod_x6_cap[k+1] + (-q2[k+1]))
		x6[k+2] = dx6_k / (k + 1)

		# x7' = (0.2*k9*x6*(10*k10-0.5*x6)) / (5*k10)
		# = 0.04*k9/k10 * prod_x6_cap
		coeff_x7 = 0.04 * k9v / k10v
		dx7_k = coeff_x7 * prod_x6_cap[k+1]
		x7[k+2] = dx7_k / (k + 1)
	end

	return x4, x5, x6, x7
end

# Test at the midpoint first
t_test = t_vector[div(length(t_vector), 2)]
x4_tc, x5_tc, x6_tc, x7_tc = compute_taylor_at_t(sol, p_true, t_test; max_order=10)

# Cross-check: order-0 should match ODE solution
u_check = sol(t_test)
@printf("  Cross-check at t=%.4f:\n", t_test)
@printf("    x4: taylor=%.10f  ode=%.10f  diff=%.2e\n", x4_tc[1], u_check[1], abs(x4_tc[1]-u_check[1]))
@printf("    x5: taylor=%.10f  ode=%.10f  diff=%.2e\n", x5_tc[1], u_check[2], abs(x5_tc[1]-u_check[2]))
@printf("    x6: taylor=%.10f  ode=%.10f  diff=%.2e\n", x6_tc[1], u_check[3], abs(x6_tc[1]-u_check[3]))

# Cross-check: order-1 should match ODE RHS
du_check = similar(u_check)
bioh_rhs!(du_check, u_check, p_true, t_test)
# Taylor coeff order 1 = x^(1)/1! = x'
@printf("    x4': taylor=%.10f  rhs=%.10f  diff=%.2e\n", x4_tc[2], du_check[1], abs(x4_tc[2]-du_check[1]))
@printf("    x5': taylor=%.10f  rhs=%.10f  diff=%.2e\n", x5_tc[2], du_check[2], abs(x5_tc[2]-du_check[2]))
@printf("    x6': taylor=%.10f  rhs=%.10f  diff=%.2e\n", x6_tc[2], du_check[3], abs(x6_tc[2]-du_check[3]))

# Also cross-check via TaylorDiff on the ODE dense output for order 2
println("\n  Cross-check order 2 via TaylorDiff on ODE dense output:")
for (name, idx, tc) in [("x4", 1, x4_tc), ("x5", 2, x5_tc), ("x6", 3, x6_tc)]
	taylor_val = tc[3] * 2  # x^(2) = 2! * tc[3]
	td_val = try
		PE.nth_deriv(tt -> sol(tt)[idx], 2, t_test)
	catch
		NaN
	end
	@printf("    %s'': taylor=%.8e  TaylorDiff=%.8e  diff=%.2e\n",
		name, taylor_val, td_val, abs(taylor_val - td_val))
end

println("  STEP 3 DONE")
flush(stdout)

# ═══════════════════════════════════════════════════════════════════
# STEP 4: Create Interpolants for All 6 Quokka Interpolators
# ═══════════════════════════════════════════════════════════════════
println("\nSTEP 4: Creating interpolants for all 6 quokka interpolators...")
println("  (GP interpolators with 1501 points will be slow)")
flush(stdout)

interp_methods = [
	(InterpolatorAGPRobust,      "AGPRobust_SE"),
	(InterpolatorAGPRobustRQ,    "AGPRobust_RQ"),
	(InterpolatorAGPRobustSEpRQ, "AGP_SE+RQ"),
	(InterpolatorAGPRobustSExRQ, "AGP_SExRQ"),
	(InterpolatorAAADGPR,        "AAAD+GPR"),
	# InterpolatorFHD not available in this build (fhd5 undefined)
]

all_interpolants = Dict{String, Any}()  # name => Dict(obs_rhs => interpolant)

for (method, name) in interp_methods
	print("  Creating $name... ")
	flush(stdout)
	t_interp = @elapsed begin
		interp_func = PE.get_interpolator_function(method, nothing)
		interps = PE.create_interpolants(pep.measured_quantities, pep.data_sample, t_vector, interp_func)
	end
	all_interpolants[name] = interps
	@printf("done in %.1f s\n", t_interp)
	flush(stdout)
end

println("  STEP 4 DONE")
flush(stdout)

# ═══════════════════════════════════════════════════════════════════
# STEP 5: Derivative Comparison at Multiple Shooting Points
# ═══════════════════════════════════════════════════════════════════
println("\n" * "=" ^ 80)
println("  STEP 5: Derivative Accuracy Comparison")
println("=" ^ 80)
flush(stdout)

# Shooting points: early, quarter, midpoint, three-quarter
n_pts = length(t_vector)
shooting_indices = [
	max(2, round(Int, n_pts * 0.05)),   # near start (avoid exact boundary)
	round(Int, n_pts * 0.25),
	round(Int, n_pts * 0.50),
	round(Int, n_pts * 0.75),
]

# Data variables used by the SI template:
#   y1_k for k=0,1,2  (y1 = 8*x4)
#   y2_k for k=0..5   (y2 = 0.5*x5)
obs_info = [
	("y1", 1, 0:2),   # (name, mq_index, derivative_orders)
	("y2", 2, 0:5),
]

# Observable scaling: y1 = 8*x4, y2 = 0.5*x5
obs_scale = [8.0, 0.5]
obs_state_idx = [1, 2]  # x4 is state 1, x5 is state 2

interp_names = [name for (_, name) in interp_methods]

for tidx in shooting_indices
	t_val = t_vector[tidx]
	println("\n" * "-" ^ 80)
	@printf("  Shooting point: t[%d] = %.4f\n", tidx, t_val)
	println("-" ^ 80)

	# Compute true Taylor coefficients at this point
	x4_tc, x5_tc, x6_tc, x7_tc = compute_taylor_at_t(sol, p_true, t_val; max_order=10)
	state_tcs = [x4_tc, x5_tc, x6_tc, x7_tc]

	for (obs_name, mq_idx, orders) in obs_info
		obs_rhs = ModelingToolkit.diff2term(pep.measured_quantities[mq_idx].rhs)
		scale = obs_scale[mq_idx]
		si = obs_state_idx[mq_idx]
		tc = state_tcs[si]

		println()
		@printf("  %s = %.1f * x%d,  orders %s\n", obs_name, scale, si+3, string(orders))

		# Header
		@printf("  %-6s %20s", "Order", "TRUE")
		for iname in interp_names
			@printf(" %15s", iname[1:min(15,length(iname))])
		end
		println()
		@printf("  %-6s %20s", "─"^6, "─"^20)
		for _ in interp_names
			@printf(" %15s", "─"^15)
		end
		println()

		for k in orders
			# True derivative: y^(k) = scale * x^(k) = scale * k! * tc[k+1]
			true_val = scale * factorial(k) * tc[k+1]

			@printf("  d^%d    %20.10e", k, true_val)

			for iname in interp_names
				interps = all_interpolants[iname]
				interp_val = try
					PE.nth_deriv(x -> interps[obs_rhs](x), k, t_val)
				catch e
					NaN
				end

				# Relative error
				if abs(true_val) > 1e-15
					rel_err = abs(interp_val - true_val) / abs(true_val)
				else
					rel_err = abs(interp_val)
				end

				if rel_err < 1e-4
					@printf(" %14.8f%%", rel_err * 100)
				elseif rel_err < 0.01
					@printf(" %13.6f%% ", rel_err * 100)
				elseif rel_err < 1.0
					@printf(" %11.4f%%  *", rel_err * 100)
				else
					@printf(" %10.1f%%  **", rel_err * 100)
				end
			end
			println()
		end

		# Also print actual values for the highest order used
		k_max = maximum(orders)
		true_val = scale * factorial(k_max) * tc[k_max+1]
		println()
		@printf("  Values at order %d:  TRUE = %+.8e\n", k_max, true_val)
		for iname in interp_names
			interps = all_interpolants[iname]
			interp_val = try
				PE.nth_deriv(x -> interps[obs_rhs](x), k_max, t_val)
			catch
				NaN
			end
			@printf("    %-20s = %+.8e  (err = %.4e)\n", iname, interp_val, abs(interp_val - true_val))
		end
	end
end

# ═══════════════════════════════════════════════════════════════════
# STEP 6: Summary — Which interpolator is best at which order?
# ═══════════════════════════════════════════════════════════════════
println("\n" * "=" ^ 80)
println("  STEP 6: Summary — Mean Relative Error by Interpolator × Derivative Order")
println("=" ^ 80)

# Collect errors across all shooting points
err_by_interp_order = Dict{Tuple{String,String,Int}, Vector{Float64}}()

for tidx in shooting_indices
	t_val = t_vector[tidx]
	x4_tc, x5_tc, x6_tc, x7_tc = compute_taylor_at_t(sol, p_true, t_val; max_order=10)
	state_tcs = [x4_tc, x5_tc, x6_tc, x7_tc]

	for (obs_name, mq_idx, orders) in obs_info
		obs_rhs = ModelingToolkit.diff2term(pep.measured_quantities[mq_idx].rhs)
		scale = obs_scale[mq_idx]
		si = obs_state_idx[mq_idx]
		tc = state_tcs[si]

		for k in orders
			true_val = scale * factorial(k) * tc[k+1]

			for iname in interp_names
				interps = all_interpolants[iname]
				interp_val = try
					PE.nth_deriv(x -> interps[obs_rhs](x), k, t_val)
				catch
					NaN
				end

				if abs(true_val) > 1e-15
					rel_err = abs(interp_val - true_val) / abs(true_val)
				else
					rel_err = abs(interp_val)
				end

				key = (iname, obs_name, k)
				if !haskey(err_by_interp_order, key)
					err_by_interp_order[key] = Float64[]
				end
				push!(err_by_interp_order[key], isnan(rel_err) ? 1.0 : rel_err)
			end
		end
	end
end

# Print summary table
for (obs_name, _, orders) in obs_info
	println("\n  $obs_name derivatives:")
	@printf("  %-20s", "Interpolator")
	for k in orders
		@printf(" %12s", "d^$k")
	end
	println()
	@printf("  %-20s", "─"^20)
	for _ in orders
		@printf(" %12s", "─"^12)
	end
	println()

	for iname in interp_names
		@printf("  %-20s", iname[1:min(20,length(iname))])
		for k in orders
			key = (iname, obs_name, k)
			errs = get(err_by_interp_order, key, [NaN])
			mean_err = mean(errs)
			if mean_err < 1e-4
				@printf(" %11.6f%%", mean_err * 100)
			elseif mean_err < 0.01
				@printf(" %10.5f%% ", mean_err * 100)
			elseif mean_err < 1.0
				@printf(" %9.3f%%  ", mean_err * 100)
			else
				@printf(" %8.1f%%   ", mean_err * 100)
			end
		end
		println()
	end
end

println("\n" * "=" ^ 80)
println("  DONE")
println("=" ^ 80)
flush(stdout)
