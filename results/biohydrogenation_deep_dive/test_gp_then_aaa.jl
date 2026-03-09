#!/usr/bin/env julia
#
# Test: Does fitting AAA to the GP mean give better high-order derivatives?
#
# Compares:
#   1. Pure AAA (InterpolatorAAAD) — fits BaryRational.aaa to raw data
#   2. Pure GP (AGPRobust SE) — AbstractGPs SE kernel
#   3. GP-then-AAA — evaluate GP mean on a grid, fit AAA to that
#   4. Pure GPR (AAADGPR) — GaussianProcesses.jl SE kernel (misleadingly named)
#   5. GPR-then-AAA — evaluate old GPR mean on a grid, fit AAA to that
#
# Uses the same Taylor-recursion ground truth as interpolator_derivative_comparison.jl

using Printf
using Statistics
using LinearAlgebra

println("=" ^ 80)
println("  Test: GP-then-AAA derivative accuracy")
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
	using BaryRational
end
@printf("Loaded in %.1f s\n", t_load)

const PE = ODEParameterEstimation

# ─── Setup (same as main comparison script) ──────────────────────
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

model, mq = create_ordered_ode_system(
	"BioHydrogenation", states_def, parameters_def, state_equations, measured_quantities_def
)

data_path = expanduser("~/ParameterEstimationBenchmarking/benchmark_quokka_2026_03_05/filetree/data_noisy/biohydrogenation_0_0/data.csv")
csv_data = CSV.read(data_path, Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
	data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end
t_vector = data_sample["t"]

pep = ParameterEstimationProblem("biohydrogenation", model, mq, data_sample, [0.0, 10.0], nothing,
	OrderedDict(parameters_def .=> p_true), OrderedDict(states_def .=> ic), 0)

# ODE solution
prob = ODEProblem(
	(du, u, p, tv) -> begin
		x4v, x5v, x6v, x7v = u
		k5v, k6v, k7v, k8v, k9v, k10v = p
		du[1] = (-8.0*k5v*x4v) / (8.0*(4.0*k6v + 8.0*x4v))
		du[2] = ((-0.3*k7v*x5v) / (2.0*k8v + 0.5*x6v + 0.5*x5v) + (8.0*k5v*x4v) / (4.0*k6v + 8.0*x4v)) / 0.5
		du[3] = ((-0.2*(10.0*k10v - 0.5*x6v)*k9v*x6v) / (10.0*k10v) + (0.3*k7v*x5v) / (2.0*k8v + 0.5*x6v + 0.5*x5v)) / 0.5
		du[4] = (0.2*(10.0*k10v - 0.5*x6v)*k9v*x6v) / (5.0*k10v)
	end, ic, (0.0, 10.0), p_true)
sol = solve(prob, Vern9(); abstol=1e-14, reltol=1e-14, dense=true)

# ─── Taylor recursion (same as main script) ──────────────────────
function taylor_product(a::Vector{Float64}, b::Vector{Float64}, k::Int)
	s = 0.0
	for j in 0:k
		s += a[j+1] * b[k-j+1]
	end
	return s
end

function taylor_quotient!(c::Vector{Float64}, a::Vector{Float64}, b::Vector{Float64}, k::Int)
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
	x4 = zeros(N); x5 = zeros(N); x6 = zeros(N); x7 = zeros(N)
	x4[1] = u0[1]; x5[1] = u0[2]; x6[1] = u0[3]; x7[1] = u0[4]

	denom1 = zeros(N); num1 = zeros(N); q1 = zeros(N)
	denom2 = zeros(N); num2 = zeros(N); q2 = zeros(N)
	cap = zeros(N); prod_x6_cap = zeros(N)

	for k in 0:(max_order - 1)
		denom1[k+1] = (k == 0 ? 4.0*k6v : 0.0) + 8.0*x4[k+1]
		denom2[k+1] = (k == 0 ? 2.0*k8v : 0.0) + 0.5*x6[k+1] + 0.5*x5[k+1]
		num1[k+1] = -k5v * x4[k+1]
		num2[k+1] = -0.3*k7v * x5[k+1]
		cap[k+1] = (k == 0 ? 10.0*k10v : 0.0) - 0.5*x6[k+1]
		prod_x6_cap[k+1] = taylor_product(x6, cap, k)

		taylor_quotient!(q1, num1, denom1, k)
		taylor_quotient!(q2, num2, denom2, k)

		x4[k+2] = q1[k+1] / (k + 1)
		dx5_k = 2.0 * (q2[k+1] - 8.0 * q1[k+1])
		x5[k+2] = dx5_k / (k + 1)
		coeff_x6 = -0.02 * k9v / k10v
		dx6_k = 2.0 * (coeff_x6 * prod_x6_cap[k+1] + (-q2[k+1]))
		x6[k+2] = dx6_k / (k + 1)
		coeff_x7 = 0.04 * k9v / k10v
		dx7_k = coeff_x7 * prod_x6_cap[k+1]
		x7[k+2] = dx7_k / (k + 1)
	end
	return x4, x5, x6, x7
end

# ─── Build interpolants ──────────────────────────────────────────
println("\nBuilding interpolants...")
flush(stdout)

# Get raw data vectors for each observable
obs_data = Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}()
for (i, eq) in enumerate(mq)
	r = eq.rhs
	key = haskey(data_sample, r) ? r : Symbolics.wrap(eq.lhs)
	obs_data[i] = (t_vector, data_sample[key])
end

# 1. Pure AAA
print("  Pure AAA... ")
flush(stdout)
aaa_interps = Dict{Int, Any}()
t_aaa = @elapsed for (i, (xs, ys)) in obs_data
	aaa_interps[i] = BaryRational.aaa(xs, ys, verbose=false)
end
@printf("done in %.1f s\n", t_aaa)

# 2. AGPRobust (SE) — use ODEPE's built-in
print("  AGPRobust (SE)... ")
flush(stdout)
agp_interp_func = PE.get_interpolator_function(InterpolatorAGPRobust, nothing)
t_agp = @elapsed agp_interps = PE.create_interpolants(mq, data_sample, t_vector, agp_interp_func)
@printf("done in %.1f s\n", t_agp)

# 3. AGPRobust-then-AAA: evaluate GP mean on dense grid, fit AAA
print("  AGPRobust→AAA... ")
flush(stdout)
agp_aaa_interps = Dict{Int, Any}()
t_agp_aaa = @elapsed begin
	for (i, eq) in enumerate(mq)
		obs_rhs = ModelingToolkit.diff2term(eq.rhs)
		gp_interp = agp_interps[obs_rhs]
		# Evaluate GP mean on same grid (or denser)
		gp_ys = [gp_interp(tv) for tv in t_vector]
		agp_aaa_interps[i] = BaryRational.aaa(t_vector, gp_ys, verbose=false)
	end
end
@printf("done in %.1f s\n", t_agp_aaa)

# 4. Old GPR (AAADGPR — misleadingly named, it's just GaussianProcesses.jl)
print("  Old GPR (AAADGPR)... ")
flush(stdout)
gpr_interp_func = PE.get_interpolator_function(InterpolatorAAADGPR, nothing)
t_gpr = @elapsed gpr_interps = PE.create_interpolants(mq, data_sample, t_vector, gpr_interp_func)
@printf("done in %.1f s\n", t_gpr)

# 5. Old GPR-then-AAA
print("  Old GPR→AAA... ")
flush(stdout)
gpr_aaa_interps = Dict{Int, Any}()
t_gpr_aaa = @elapsed begin
	for (i, eq) in enumerate(mq)
		obs_rhs = ModelingToolkit.diff2term(eq.rhs)
		gpr_interp = gpr_interps[obs_rhs]
		gpr_ys = [gpr_interp(tv) for tv in t_vector]
		gpr_aaa_interps[i] = BaryRational.aaa(t_vector, gpr_ys, verbose=false)
	end
end
@printf("done in %.1f s\n", t_gpr_aaa)

println("  All interpolants ready.")
flush(stdout)

# ─── Derivative comparison ───────────────────────────────────────
println("\n" * "=" ^ 80)
println("  Derivative Accuracy Comparison")
println("=" ^ 80)

obs_info = [
	("y1", 1, 0:2, 8.0, 1),
	("y2", 2, 0:5, 0.5, 2),
]

n_pts = length(t_vector)
shooting_indices = [
	max(2, round(Int, n_pts * 0.05)),
	round(Int, n_pts * 0.25),
	round(Int, n_pts * 0.50),
	round(Int, n_pts * 0.75),
]

interp_labels = ["PureAAA", "AGP_SE", "AGP→AAA", "OldGPR", "GPR→AAA"]

# Function to evaluate nth derivative for each interpolant type
function eval_deriv(interp_type, interp_obj, k, t_val)
	if interp_type in [:aaa, :agp_aaa, :gpr_aaa]
		# BaryRational.aaa object — wrap in function for nth_deriv
		return PE.nth_deriv(x -> interp_obj(x), k, t_val)
	else
		# ODEPE interpolator (AbstractInterpolator subtype)
		return PE.nth_deriv(x -> interp_obj(x), k, t_val)
	end
end

# Collect errors for summary
err_collect = Dict{Tuple{String, String, Int}, Vector{Float64}}()

for tidx in shooting_indices
	t_val = t_vector[tidx]
	println("\n" * "-" ^ 90)
	@printf("  t[%d] = %.4f\n", tidx, t_val)
	println("-" ^ 90)

	local x4_tc, x5_tc, x6_tc, x7_tc = compute_taylor_at_t(sol, p_true, t_val; max_order=10)
	state_tcs = [x4_tc, x5_tc, x6_tc, x7_tc]

	for (obs_name, mq_idx, orders, scale, si) in obs_info
		tc = state_tcs[si]
		obs_rhs = ModelingToolkit.diff2term(mq[mq_idx].rhs)

		# Build interpolant lookup for this observable
		interp_objs = [
			(:aaa,     aaa_interps[mq_idx]),
			(:agp,     agp_interps[obs_rhs]),
			(:agp_aaa, agp_aaa_interps[mq_idx]),
			(:gpr,     gpr_interps[obs_rhs]),
			(:gpr_aaa, gpr_aaa_interps[mq_idx]),
		]

		println()
		@printf("  %s (orders %s):\n", obs_name, string(orders))
		@printf("  %-6s %18s", "Order", "TRUE")
		for lbl in interp_labels
			@printf("  %12s", lbl)
		end
		println()
		@printf("  %-6s %18s", "─"^6, "─"^18)
		for _ in interp_labels
			@printf("  %12s", "─"^12)
		end
		println()

		for k in orders
			true_val = scale * factorial(k) * tc[k+1]
			@printf("  d^%-3d %18.8e", k, true_val)

			for (li, (itype, iobj)) in enumerate(interp_objs)
				lbl = interp_labels[li]
				interp_val = try
					eval_deriv(itype, iobj, k, t_val)
				catch
					NaN
				end

				rel_err = abs(true_val) > 1e-15 ?
					abs(interp_val - true_val) / abs(true_val) : abs(interp_val)

				key = (lbl, obs_name, k)
				if !haskey(err_collect, key)
					err_collect[key] = Float64[]
				end
				push!(err_collect[key], isnan(rel_err) ? 1.0 : rel_err)

				if rel_err < 1e-4
					@printf("  %10.6f%%", rel_err * 100)
				elseif rel_err < 0.01
					@printf("  %9.5f%% ", rel_err * 100)
				elseif rel_err < 1.0
					@printf("  %8.3f%% *", rel_err * 100)
				else
					@printf("  %7.1f%% **", rel_err * 100)
				end
			end
			println()
		end
	end
end

# ─── Summary table ───────────────────────────────────────────────
println("\n" * "=" ^ 80)
println("  Summary: Mean Relative Error by Interpolator × Derivative Order")
println("=" ^ 80)

for (obs_name, _, orders, _, _) in obs_info
	println("\n  $obs_name:")
	@printf("  %-12s", "Interpolator")
	for k in orders
		@printf("  %12s", "d^$k")
	end
	println()
	@printf("  %-12s", "─"^12)
	for _ in orders
		@printf("  %12s", "─"^12)
	end
	println()

	for lbl in interp_labels
		@printf("  %-12s", lbl)
		for k in orders
			key = (lbl, obs_name, k)
			errs = get(err_collect, key, [NaN])
			me = mean(errs)
			if me < 1e-4
				@printf("  %10.6f%%", me * 100)
			elseif me < 0.01
				@printf("  %9.5f%% ", me * 100)
			elseif me < 1.0
				@printf("  %8.3f%% *", me * 100)
			else
				@printf("  %7.1f%% **", me * 100)
			end
		end
		println()
	end
end

println("\n" * "=" ^ 80)
println("  DONE")
println("=" ^ 80)
flush(stdout)
