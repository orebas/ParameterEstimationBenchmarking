#!/usr/bin/env julia
#
# CSTR Interpolator Sweep
# =======================
# Tests 13 interpolators × 3 shooting points = 39 test cases.
# Measures derivative accuracy, HC solve success, and root recovery for each.
#
# Key question: which (if any) real interpolators provide accurate enough
# derivatives at t=0 for HC.jl to find the true CSTR root?
#
# Follows from cstr_hc_isolation.jl which proved:
#   - r_eff decays catastrophically: 0.384 at t=0 → 2.66e-5 at t=0.33
#   - Only t=0 works with perfect data (1/12 points)
#   - Production pipeline selects t≈10 via point_hint=0.5, guaranteeing failure
#
# Run: julia results/bilby_analysis/cstr_deep_dive/cstr_interpolator_sweep.jl

using ODEParameterEstimation
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using DifferentialEquations
using OrderedCollections
using LinearAlgebra
using Printf
using Symbolics

import HomotopyContinuation
const HC = HomotopyContinuation

# ═══════════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════════
INSTANCE_NAME = "cstr_0_0"
p_true_vals = [0.15, 0.439, 0.307, 0.779]    # [tau, Tin, dH_rhoCP, UA_VrhoCP]
ic_vals      = [0.127, 0.867, 0.384]          # [C, Temp, r_eff]

DATASIZE = 1501
TIME_INTERVAL = [0.0, 20.0]
N_SHOOTING = 12
WARP_BETA = 3.0
MAX_DERIV_ORDER = 20
N_TEST_POINTS = 3   # First 3 shooting points from warped grid

# Nondimensionalization constants
const ALPHA1 = 1.999863916554819
const ALPHA2 = 0.0285694845222117
const ALPHA3 = 0.8571428571428571
const ALPHA4 = 0.05714285714285714
const E_R_NONDIM = 12.5

# Interpolators to test (12 from bilby benchmark + PerfectInterpolant baseline)
const INTERPOLATOR_METHODS = [
	InterpolatorAAAD,
	InterpolatorAAADGPR,
	InterpolatorS2AAAMLE,
	InterpolatorAGPRobust,
	InterpolatorAGPRobustRQ,
	InterpolatorAGPRobustSEpRQ,
	InterpolatorAGPRobustSExRQ,
	InterpolatorS3SE,
	InterpolatorS3RQ,
	InterpolatorS3SEpRQ,
	InterpolatorS3SExRQ,
	InterpolatorFHD,
]

# HC distance threshold for "found"
const FOUND_THRESHOLD = 1e-3


# ═══════════════════════════════════════════════════════════════════════════════
# Helper functions (reused from cstr_hc_isolation.jl)
# ═══════════════════════════════════════════════════════════════════════════════

struct PerfectInterpolant
	t0::Float64
	coeffs::Vector{Float64}  # coeffs[k+1] = f^(k)(t0) / k!
end

function (p::PerfectInterpolant)(t_val)
	dt = t_val - p.t0
	result = p.coeffs[end]
	for k in (length(p.coeffs) - 1):-1:1
		result = result * dt + p.coeffs[k]
	end
	return result
end

function compute_taylor_coefficients(sol, t_eval, p_vals, max_order)
	tau_v, Tin_v, dH_v, UA_v = p_vals
	omega = 0.5

	state_at_t = sol(t_eval)
	tc_C    = zeros(Float64, max_order + 1)
	tc_Temp = zeros(Float64, max_order + 1)
	tc_reff = zeros(Float64, max_order + 1)
	tc_sin  = zeros(Float64, max_order + 1)
	tc_cos  = zeros(Float64, max_order + 1)

	tc_C[1]    = state_at_t[1]
	tc_Temp[1] = state_at_t[2]
	tc_reff[1] = state_at_t[3]
	tc_sin[1]  = sin(omega * t_eval)
	tc_cos[1]  = cos(omega * t_eval)

	for k in 1:max_order
		tc_sin[k+1] = Float64(omega^k * sin(omega * t_eval + k * π / 2) / factorial(big(k)))
		tc_cos[k+1] = Float64(omega^k * cos(omega * t_eval + k * π / 2) / factorial(big(k)))
	end

	tc_Temp2 = zeros(Float64, max_order + 1)
	tc_reff_over_Temp2 = zeros(Float64, max_order + 1)

	for k in 0:(max_order - 1)
		tc_Temp2[k+1] = sum(tc_Temp[j+1] * tc_Temp[k-j+1] for j in 0:k)

		s = tc_reff[k+1]
		for j in 0:(k-1)
			s -= tc_reff_over_Temp2[j+1] * tc_Temp2[k-j+1]
		end
		tc_reff_over_Temp2[k+1] = s / tc_Temp2[1]

		reff_C_k = sum(tc_reff[j+1] * tc_C[k-j+1] for j in 0:k)
		delta_k0 = k == 0 ? 1.0 : 0.0

		rhs_C_k = (delta_k0 - tc_C[k+1]) / (2.0 * tau_v) - ALPHA1 * reff_C_k
		tc_C[k+2] = rhs_C_k / (k + 1)

		rhs_Temp_k = (delta_k0 * Tin_v - tc_Temp[k+1]) / (2.0 * tau_v) +
					 ALPHA2 * dH_v * reff_C_k -
					 2.0 * UA_v * tc_Temp[k+1] +
					 delta_k0 * ALPHA3 * UA_v +
					 ALPHA4 * UA_v * tc_sin[k+1]
		tc_Temp[k+2] = rhs_Temp_k / (k + 1)

		rhs_reff_k = 0.0
		for j in 0:k
			dT_j = (k - j + 1) * tc_Temp[k-j+2]
			rhs_reff_k += tc_reff_over_Temp2[j+1] * dT_j
		end
		rhs_reff_k *= E_R_NONDIM
		tc_reff[k+2] = rhs_reff_k / (k + 1)
	end

	return Dict(
		"C" => tc_C, "Temp" => tc_Temp, "r_eff" => tc_reff,
		"sin_0_5" => tc_sin, "cos_0_5" => tc_cos,
	)
end

function build_perfect_interpolants(taylor_coeffs, t_eval, mq_list, max_order)
	interps = Dict()
	for mq_eq in mq_list
		obs_rhs = ModelingToolkit.diff2term(mq_eq.rhs)
		obs_str = string(obs_rhs)
		if occursin("Temp", obs_str) && occursin("700", obs_str)
			coeffs = 700.0 .* taylor_coeffs["Temp"][1:max_order+1]
		elseif occursin("sin", obs_str) || occursin("_trfn_sin", obs_str)
			coeffs = taylor_coeffs["sin_0_5"][1:max_order+1]
		elseif occursin("cos", obs_str) || occursin("_trfn_cos", obs_str)
			coeffs = taylor_coeffs["cos_0_5"][1:max_order+1]
		else
			@warn "Unknown observable in build_perfect_interpolants: $obs_str"
			continue
		end
		interps[obs_rhs] = PerfectInterpolant(t_eval, collect(coeffs))
	end
	return interps
end

function build_true_substitution(vars, p_vals, taylor_coeffs, t_eval)
	param_map = Dict(
		"tau" => p_vals[1], "Tin" => p_vals[2],
		"dH_rhoCP" => p_vals[3], "UA_VrhoCP" => p_vals[4],
	)
	state_keys = Dict("C" => "C", "Temp" => "Temp", "r_eff" => "r_eff")

	sub_dict = Dict()
	for v in vars
		vname = string(v)
		parsed = ODEParameterEstimation.parse_derivative_variable_name(vname)
		isnothing(parsed) && continue

		base_name, deriv_order = parsed
		if haskey(param_map, base_name)
			sub_dict[v] = deriv_order == 0 ? param_map[base_name] : 0.0
		elseif haskey(state_keys, base_name)
			key = state_keys[base_name]
			sub_dict[v] = Float64(taylor_coeffs[key][deriv_order+1] * factorial(big(deriv_order)))
		else
			trfn_info = ODEParameterEstimation._parse_trfn_base_name(base_name)
			if !isnothing(trfn_info)
				func_type, frequency = trfn_info
				if func_type == :sin
					sub_dict[v] = frequency^deriv_order * sin(frequency * t_eval + deriv_order * π / 2)
				elseif func_type == :cos
					sub_dict[v] = frequency^deriv_order * cos(frequency * t_eval + deriv_order * π / 2)
				end
			end
		end
	end
	return sub_dict
end


# ═══════════════════════════════════════════════════════════════════════════════
# Utility
# ═══════════════════════════════════════════════════════════════════════════════
function mean_or_nan(vals)
	filtered = filter(!isnan, vals)
	isempty(filtered) ? NaN : sum(filtered) / length(filtered)
end


# ═══════════════════════════════════════════════════════════════════════════════
# Derivative accuracy: compute ground-truth k-th derivative for an observable
# ═══════════════════════════════════════════════════════════════════════════════
function observable_deriv_truth(obs_rhs, k, taylor_coeffs)
	obs_str = string(obs_rhs)
	if occursin("Temp", obs_str) && occursin("700", obs_str)
		return Float64(700.0 * factorial(big(k)) * taylor_coeffs["Temp"][k+1])
	elseif occursin("sin", obs_str) || occursin("_trfn_sin", obs_str)
		return Float64(factorial(big(k)) * taylor_coeffs["sin_0_5"][k+1])
	elseif occursin("cos", obs_str) || occursin("_trfn_cos", obs_str)
		return Float64(factorial(big(k)) * taylor_coeffs["cos_0_5"][k+1])
	end
	return NaN
end

"""
    compute_deriv_accuracy(interps, mq_list, deriv_level, taylor_coeffs, t_eval)

Compute max relative error of interpolant derivatives vs ground truth.
Returns (max_rel_err, worst_obs_idx, worst_order, detailed_errors).
"""
function compute_deriv_accuracy(interps, mq_list, deriv_level, taylor_coeffs, t_eval)
	max_rel_err = 0.0
	worst_obs_idx = 0
	worst_order = 0
	detailed = []

	for (obs_idx, mq_eq) in enumerate(mq_list)
		max_order = get(deriv_level, obs_idx, 0)
		obs_rhs = mq_eq.rhs
		obs_rhs_dt = ModelingToolkit.diff2term(obs_rhs)

		# Find interpolant — try both keying conventions
		interp = get(interps, obs_rhs, get(interps, obs_rhs_dt, nothing))
		if isnothing(interp)
			push!(detailed, (obs_idx = obs_idx, order = -1, interp_val = NaN,
				truth_val = NaN, rel_err = NaN, error = "interpolant not found"))
			continue
		end

		for k in 0:max_order
			truth_val = observable_deriv_truth(obs_rhs, k, taylor_coeffs)
			interp_val = try
				ODEParameterEstimation.nth_deriv(x -> interp(x), k, t_eval)
			catch e
				NaN
			end

			if isnan(interp_val) || isnan(truth_val)
				rel_err = NaN
			elseif abs(truth_val) > 1e-15
				rel_err = abs(interp_val - truth_val) / abs(truth_val)
			else
				rel_err = abs(interp_val - truth_val)
			end

			push!(detailed, (obs_idx = obs_idx, order = k, interp_val = interp_val,
				truth_val = truth_val, rel_err = rel_err, error = ""))

			if !isnan(rel_err) && rel_err > max_rel_err
				max_rel_err = rel_err
				worst_obs_idx = obs_idx
				worst_order = k
			end
		end
	end

	return (max_rel_err = max_rel_err, worst_obs_idx = worst_obs_idx,
		worst_order = worst_order, details = detailed)
end


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Setup — Model, ODE, PEP Transform, SIAN, SI Template
# ═══════════════════════════════════════════════════════════════════════════════
println("=" ^ 78)
println("  CSTR INTERPOLATOR SWEEP — $INSTANCE_NAME")
println("  13 interpolators × $N_TEST_POINTS shooting points = $(13 * N_TEST_POINTS) test cases")
println("=" ^ 78)
println()

println("STEP 1: Setup (model, ODE, PEP transform, SIAN, SI template)")
println("-" ^ 78)
flush(stdout)

# Define CSTR model
@parameters tau Tin dH_rhoCP UA_VrhoCP
@variables C(t) Temp(t) r_eff(t) y1(t)

states = [C, Temp, r_eff]
parameters = [tau, Tin, dH_rhoCP, UA_VrhoCP]

eqs = [
	D(C) ~ (1.0 - C) / (2.0 * tau) - ALPHA1 * r_eff * C,
	D(Temp) ~ (Tin - Temp) / (2.0 * tau) + ALPHA2 * dH_rhoCP * r_eff * C -
			  2.0 * UA_VrhoCP * Temp + ALPHA3 * UA_VrhoCP + ALPHA4 * UA_VrhoCP * sin(0.5 * t),
	D(r_eff) ~ E_R_NONDIM * r_eff / (Temp^2) * (
		(Tin - Temp) / (2.0 * tau) + ALPHA2 * dH_rhoCP * r_eff * C -
		2.0 * UA_VrhoCP * Temp + ALPHA3 * UA_VrhoCP + ALPHA4 * UA_VrhoCP * sin(0.5 * t)
	),
]

measured_quantities = [y1 ~ 700.0 * Temp]

# Generate data and high-accuracy ODE solution
p_true_dict = Dict(parameters .=> p_true_vals)
ic_dict = Dict(states .=> ic_vals)

@named cstr_model = ODESystem(eqs, t, states, parameters)
data_sample = ODEParameterEstimation.sample_data(
	cstr_model, measured_quantities, TIME_INTERVAL,
	p_true_dict, ic_dict, DATASIZE;
	solver = AutoVern9(Rodas4P()),
)

sys_complete = complete(cstr_model)
prob = ODEProblem(
	sys_complete,
	merge(Dict(ModelingToolkit.unknowns(sys_complete) .=> ic_vals),
		Dict(ModelingToolkit.parameters(sys_complete) .=> p_true_vals)),
	TIME_INTERVAL,
)
sol = DifferentialEquations.solve(prob, AutoVern9(Rodas4P()); abstol = 1e-14, reltol = 1e-14, dense = true)
println("  ODE solution: retcode=$(sol.retcode)")

# Compute shooting indices and select test points
shooting_indices = ODEParameterEstimation.compute_shooting_indices(
	N_SHOOTING, DATASIZE; warp = true, beta = WARP_BETA,
)
t_vector = data_sample["t"]

test_points = []
println("\n  Test shooting points (first $N_TEST_POINTS from warped grid):")
println("  " * "-" ^ 65)
@printf("  %3s  %6s  %10s  %12s  %s\n", "#", "Index", "Time", "r_eff", "Notes")
println("  " * "-" ^ 65)
for i in 1:N_TEST_POINTS
	idx = shooting_indices[i]
	t_pt = t_vector[idx]
	s = sol(t_pt)
	reff = s[3]
	note = reff > 0.05 ? "** GOOD — r_eff meaningful" :
		   reff > 1e-3 ? "r_eff decaying" :
		   reff > 1e-6 ? "r_eff very small" : "r_eff ≈ 0"
	@printf("  %3d  %6d  %10.4f  %12.4e  %s\n", i, idx, t_pt, reff, note)
	push!(test_points, (label = "pt$i", idx = idx, time = t_pt, reff = reff))
end

# Transform PEP for transcendentals
ordered_model, mq = create_ordered_ode_system(
	"CSTR_sweep", states, parameters, eqs, measured_quantities,
)
pep_original = ParameterEstimationProblem(
	"CSTR_sweep", ordered_model, mq, data_sample, TIME_INTERVAL,
	nothing,
	OrderedDict(parameters .=> p_true_vals),
	OrderedDict(states .=> ic_vals),
	0,
)

t_var = ModelingToolkit.get_iv(pep_original.model.system)
pep, tr_info = ODEParameterEstimation.transform_pep_for_estimation(pep_original, t_var)

if !isnothing(tr_info)
	println("\n  Transcendental transform: $(length(tr_info.entries)) expression(s)")
	for entry in tr_info.entries
		println("    $(entry.func_type)($(entry.frequency)*t) → $(entry.input_variable)")
	end
end

println("  Transformed: $(length(ModelingToolkit.unknowns(pep.model.system))) states, " *
	"$(length(ModelingToolkit.parameters(pep.model.system))) params, " *
	"$(length(pep.measured_quantities)) measured quantities")

# SIAN analysis (computed once — the expensive part)
println("\n  Running SIAN analysis...")
flush(stdout)
ident_data = ODEParameterEstimation.setup_identifiability(pep; max_num_points = 1)

println("  SIAN results:")
println("    good_deriv_level: $(ident_data.good_deriv_level)")
println("    all_unidentifiable: $(ident_data.all_unidentifiable)")

# Cache SI template (computed once — purely symbolic)
println("  Computing SI template...")
flush(stdout)
si_template_eqs, si_deriv_dict, si_unident, _ =
	ODEParameterEstimation.get_si_equation_system(
		pep.model, pep.measured_quantities, pep.data_sample;
		DD = ident_data.good_DD, infolevel = 1,
	)

cached_si_template = (
	equations = si_template_eqs,
	deriv_dict = si_deriv_dict,
	unidentifiable = si_unident,
)
println("  SI template: $(length(si_template_eqs)) equations (cached)")

# Precompute Taylor coefficients at each test point
taylor_at_points = Dict()
for tp in test_points
	taylor_at_points[tp.idx] = compute_taylor_coefficients(sol, tp.time, p_true_vals, MAX_DERIV_ORDER)
end

println("\n  STEP 1 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Interpolator × Shooting Point Sweep
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 2: Interpolator sweep (13 × $N_TEST_POINTS = $(13 * N_TEST_POINTS) test cases)")
println("-" ^ 78)
flush(stdout)

# Results storage
all_results = []

# ─── PerfectInterpolant (baseline) ────────────────────────────────────────────
println("\n  [1/13] PerfectInterpolant (exact Taylor — ceiling/control)")
flush(stdout)

for tp in test_points
	tc = taylor_at_points[tp.idx]
	perfect_interps = build_perfect_interpolants(tc, tp.time, pep.measured_quantities, MAX_DERIV_ORDER)

	# Derivative accuracy
	deriv_acc = compute_deriv_accuracy(
		perfect_interps, pep.measured_quantities, ident_data.good_deriv_level, tc, tp.time,
	)

	# Build polynomial system
	eqs_pt, vars_pt = try
		ODEParameterEstimation.construct_equation_system_from_si_template(
			pep.model.system, pep.measured_quantities, pep.data_sample,
			ident_data.good_deriv_level, ident_data.good_udict,
			ident_data.good_varlist, ident_data.good_DD;
			interpolator = ODEParameterEstimation.agp_gpr_robust,
			time_index_set = [tp.idx],
			precomputed_interpolants = perfect_interps,
			si_template = cached_si_template,
		)
	catch e
		@printf("    %s: BUILD FAILED: %s\n", tp.label, string(e)[1:min(80, length(string(e)))])
		push!(all_results, (
			interp_name = "PerfectInterpolant", point_label = tp.label,
			point_idx = tp.idx, point_time = tp.time, reff = tp.reff,
			max_deriv_err = deriv_acc.max_rel_err, worst_obs = deriv_acc.worst_obs_idx,
			worst_order = deriv_acc.worst_order, deriv_details = deriv_acc.details,
			n_solutions = 0, closest_dist = Inf, found = false,
			error_msg = "build_failed: $(string(e)[1:min(80, length(string(e)))])",
		))
		continue
	end

	# Verify residuals
	sub = build_true_substitution(vars_pt, p_true_vals, tc, tp.time)

	# Solve with HC
	hc_result = try
		ODEParameterEstimation.solve_with_hc(eqs_pt, vars_pt)
	catch e
		(Vector{Vector{Float64}}(), vars_pt, Dict(), vars_pt)
	end
	solutions = hc_result[1]

	# Distance to truth
	tvec = Float64[get(sub, v, NaN) for v in vars_pt]
	closest = isempty(solutions) ? Inf : minimum(norm(s .- tvec) for s in solutions)
	found = closest < FOUND_THRESHOLD

	status = found ? "FOUND" : (isempty(solutions) ? "NO_SOLS" : "MISSED")
	@printf("    %s (t=%6.3f, r_eff=%.2e): %d sols, closest=%.2e, deriv_err=%.2e  [%s]\n",
		tp.label, tp.time, tp.reff, length(solutions), closest, deriv_acc.max_rel_err, status)

	push!(all_results, (
		interp_name = "PerfectInterpolant", point_label = tp.label,
		point_idx = tp.idx, point_time = tp.time, reff = tp.reff,
		max_deriv_err = deriv_acc.max_rel_err, worst_obs = deriv_acc.worst_obs_idx,
		worst_order = deriv_acc.worst_order, deriv_details = deriv_acc.details,
		n_solutions = length(solutions), closest_dist = closest, found = found,
		error_msg = "",
	))
end

# ─── Real interpolators ──────────────────────────────────────────────────────
for (interp_num, method) in enumerate(INTERPOLATOR_METHODS)
	interp_sym = ODEParameterEstimation.interpolator_method_to_symbol(method)
	println("\n  [$(interp_num + 1)/13] $interp_sym ($method)")
	flush(stdout)

	# Build interpolants once from data
	real_interps = try
		interp_func = ODEParameterEstimation.get_interpolator_function(method)
		t_vec = pep.data_sample["t"]
		ODEParameterEstimation.create_interpolants(
			pep.measured_quantities, pep.data_sample, t_vec, interp_func,
		)
	catch e
		@printf("    BUILD FAILED: %s\n", string(e)[1:min(120, length(string(e)))])
		# Record failure for all test points
		for tp in test_points
			push!(all_results, (
				interp_name = string(interp_sym), point_label = tp.label,
				point_idx = tp.idx, point_time = tp.time, reff = tp.reff,
				max_deriv_err = NaN, worst_obs = 0, worst_order = 0,
				deriv_details = [], n_solutions = 0, closest_dist = Inf, found = false,
				error_msg = "interp_build_failed: $(string(e)[1:min(80, length(string(e)))])",
			))
		end
		continue
	end

	for tp in test_points
		tc = taylor_at_points[tp.idx]

		# Derivative accuracy
		deriv_acc = try
			compute_deriv_accuracy(
				real_interps, pep.measured_quantities, ident_data.good_deriv_level, tc, tp.time,
			)
		catch e
			(max_rel_err = NaN, worst_obs_idx = 0, worst_order = 0, details = [])
		end

		# Build polynomial system
		eqs_pt, vars_pt = try
			ODEParameterEstimation.construct_equation_system_from_si_template(
				pep.model.system, pep.measured_quantities, pep.data_sample,
				ident_data.good_deriv_level, ident_data.good_udict,
				ident_data.good_varlist, ident_data.good_DD;
				interpolator = ODEParameterEstimation.agp_gpr_robust,
				time_index_set = [tp.idx],
				precomputed_interpolants = real_interps,
				si_template = cached_si_template,
			)
		catch e
			@printf("    %s: BUILD FAILED: %s\n", tp.label, string(e)[1:min(80, length(string(e)))])
			push!(all_results, (
				interp_name = string(interp_sym), point_label = tp.label,
				point_idx = tp.idx, point_time = tp.time, reff = tp.reff,
				max_deriv_err = deriv_acc.max_rel_err, worst_obs = deriv_acc.worst_obs_idx,
				worst_order = deriv_acc.worst_order, deriv_details = deriv_acc.details,
				n_solutions = 0, closest_dist = Inf, found = false,
				error_msg = "sys_build_failed: $(string(e)[1:min(80, length(string(e)))])",
			))
			continue
		end

		# Verify residuals with true values
		sub = build_true_substitution(vars_pt, p_true_vals, tc, tp.time)

		# Solve with HC
		hc_result = try
			ODEParameterEstimation.solve_with_hc(eqs_pt, vars_pt)
		catch e
			(Vector{Vector{Float64}}(), vars_pt, Dict(), vars_pt)
		end
		solutions = hc_result[1]

		# Distance to truth
		tvec = Float64[get(sub, v, NaN) for v in vars_pt]
		closest = isempty(solutions) ? Inf : minimum(norm(s .- tvec) for s in solutions)
		found = closest < FOUND_THRESHOLD

		status = found ? "FOUND" : (isempty(solutions) ? "NO_SOLS" : "MISSED")
		@printf("    %s (t=%6.3f, r_eff=%.2e): %d sols, closest=%.2e, deriv_err=%.2e  [%s]\n",
			tp.label, tp.time, tp.reff, length(solutions), closest, deriv_acc.max_rel_err, status)

		push!(all_results, (
			interp_name = string(interp_sym), point_label = tp.label,
			point_idx = tp.idx, point_time = tp.time, reff = tp.reff,
			max_deriv_err = deriv_acc.max_rel_err, worst_obs = deriv_acc.worst_obs_idx,
			worst_order = deriv_acc.worst_order, deriv_details = deriv_acc.details,
			n_solutions = length(solutions), closest_dist = closest, found = found,
			error_msg = "",
		))
	end
end

println("\n  STEP 2 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Summary Tables
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 3: Summary Tables")
println("=" ^ 78)
flush(stdout)

# Collect unique interpolator names (preserving order)
interp_names = unique([r.interp_name for r in all_results])
point_labels = [tp.label for tp in test_points]
point_times = [tp.time for tp in test_points]

# Helper to look up a result
function get_result(name, label)
	idx = findfirst(r -> r.interp_name == name && r.point_label == label, all_results)
	isnothing(idx) ? nothing : all_results[idx]
end

# ─── Table 1: Derivative Accuracy ────────────────────────────────────────────
println("\n  TABLE 1: Derivative Accuracy (max relative error per interpolator × point)")
println("  " * "=" ^ 74)
println(@sprintf("  %-22s", "Interpolator") *
	join([@sprintf(" | %-16s", "t=$(round(tp.time, digits=2))") for tp in test_points]))
println("  " * "-" ^ 74)

for name in interp_names
	row = @sprintf("  %-22s", name[1:min(22, length(name))])
	for label in point_labels
		r = get_result(name, label)
		if isnothing(r)
			row *= @sprintf(" | %-16s", "---")
		elseif !isempty(r.error_msg)
			row *= @sprintf(" | %-16s", "FAIL")
		elseif isnan(r.max_deriv_err)
			row *= @sprintf(" | %-16s", "NaN")
		else
			row *= @sprintf(" | %16.2e", r.max_deriv_err)
		end
	end
	println(row)
end
println("  " * "=" ^ 74)

# ─── Table 2: HC Solve Results ───────────────────────────────────────────────
println("\n  TABLE 2: HC Solve Results (#solutions, closest L2 distance, FOUND/MISSED)")
println("  " * "=" ^ 74)
println(@sprintf("  %-22s", "Interpolator") *
	join([@sprintf(" | %-16s", "t=$(round(tp.time, digits=2))") for tp in test_points]))
println("  " * "-" ^ 74)

for name in interp_names
	row = @sprintf("  %-22s", name[1:min(22, length(name))])
	for label in point_labels
		r = get_result(name, label)
		if isnothing(r)
			row *= @sprintf(" | %-16s", "---")
		elseif !isempty(r.error_msg)
			row *= @sprintf(" | %-16s", "FAIL")
		elseif r.n_solutions == 0
			row *= @sprintf(" | %-16s", "0 sol")
		else
			tag = r.found ? "Y" : "N"
			cell = @sprintf("%d sol %.1e %s", r.n_solutions, r.closest_dist, tag)
			row *= @sprintf(" | %-16s", cell[1:min(16, length(cell))])
		end
	end
	println(row)
end
println("  " * "=" ^ 74)

# ─── Table 3: Threshold Analysis ─────────────────────────────────────────────
println("\n  TABLE 3: Derivative Error vs HC Success — Is there a threshold?")
println("  " * "=" ^ 78)
@printf("  %-22s  %-8s  %12s  %12s  %6s  %s\n",
	"Interpolator", "Point", "Deriv Err", "HC Dist", "Found", "Error")
println("  " * "-" ^ 78)

# Sort by derivative error for threshold analysis
sorted_results = sort(filter(r -> !isnan(r.max_deriv_err) && isempty(r.error_msg), all_results),
	by = r -> r.max_deriv_err)

for r in sorted_results
	@printf("  %-22s  %-8s  %12.2e  %12.2e  %6s\n",
		r.interp_name[1:min(22, length(r.interp_name))],
		r.point_label, r.max_deriv_err, r.closest_dist,
		r.found ? "YES" : "no")
end

# Also include failed cases at the end
failed_results = filter(r -> isnan(r.max_deriv_err) || !isempty(r.error_msg), all_results)
for r in failed_results
	err_msg = isempty(r.error_msg) ? "NaN deriv" : r.error_msg[1:min(30, length(r.error_msg))]
	@printf("  %-22s  %-8s  %12s  %12s  %6s  %s\n",
		r.interp_name[1:min(22, length(r.interp_name))],
		r.point_label, "---", "---", "---", err_msg)
end

println("  " * "=" ^ 78)

# Threshold analysis summary
successful = filter(r -> r.found && isempty(r.error_msg), all_results)
failed_hc = filter(r -> !r.found && isempty(r.error_msg) && !isnan(r.max_deriv_err), all_results)

if !isempty(successful)
	max_err_success = maximum(r.max_deriv_err for r in successful)
	println("\n  Threshold analysis:")
	@printf("    Max deriv error among SUCCESSFUL cases: %.2e\n", max_err_success)
	if !isempty(failed_hc)
		min_err_fail = minimum(r.max_deriv_err for r in failed_hc)
		@printf("    Min deriv error among FAILED cases:     %.2e\n", min_err_fail)
		if max_err_success < min_err_fail
			@printf("    Clean separation! Threshold ≈ %.2e\n", sqrt(max_err_success * min_err_fail))
		else
			println("    No clean separation — derivative error alone doesn't predict HC success")
		end
	end
else
	println("\n  No successful cases — cannot determine threshold")
end

println("\n  STEP 3 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Conclusions
# ═══════════════════════════════════════════════════════════════════════════════
println("=" ^ 78)
println("  CONCLUSIONS")
println("=" ^ 78)
println()

n_total = length(all_results)
n_found = count(r -> r.found, all_results)
n_error = count(r -> !isempty(r.error_msg), all_results)

println("1. OVERALL SCORE: $n_found / $n_total test cases found the true root")
println("   ($n_error test cases had errors)")
println()

# Per-point summary
for tp in test_points
	pt_results = filter(r -> r.point_label == tp.label, all_results)
	pt_found = count(r -> r.found, pt_results)
	pt_total = length(pt_results)
	@printf("   %s (t=%.3f, r_eff=%.2e): %d/%d interpolators found the root\n",
		tp.label, tp.time, tp.reff, pt_found, pt_total)
end
println()

# Per-interpolator summary
println("2. PER-INTERPOLATOR RESULTS:")
for name in interp_names
	interp_results = filter(r -> r.interp_name == name, all_results)
	n_f = count(r -> r.found, interp_results)
	n_t = length(interp_results)
	avg_err = mean_or_nan([r.max_deriv_err for r in interp_results if !isnan(r.max_deriv_err)])
	@printf("   %-22s: %d/%d found, avg deriv err = %.2e\n",
		name[1:min(22, length(name))], n_f, n_t, avg_err)
end
println()

# Key questions answered
n_real_at_t0 = count(r -> r.point_label == "pt1" && r.interp_name != "PerfectInterpolant" && r.found, all_results)
n_real_total_at_t0 = count(r -> r.point_label == "pt1" && r.interp_name != "PerfectInterpolant", all_results)
perfect_at_t0 = get_result("PerfectInterpolant", "pt1")

println("3. KEY QUESTIONS:")
println()

println("   Q: Do real interpolators work at t=0?")
println("   A: $n_real_at_t0 / $n_real_total_at_t0 real interpolators found the root at t=0")
println()

if !isnothing(perfect_at_t0)
	println("   Q: Does PerfectInterpolant work at t=0? (baseline)")
	println("   A: $(perfect_at_t0.found ? "YES" : "NO") " *
		"($(perfect_at_t0.n_solutions) sols, closest=$(round(perfect_at_t0.closest_dist, sigdigits=3)))")
	println()
end

n_any_at_later = count(r -> r.point_label != "pt1" && r.found, all_results)
n_total_later = count(r -> r.point_label != "pt1", all_results)
println("   Q: Is failure at t≥0.33 universal (structural) or interpolation-dependent?")
println("   A: $n_any_at_later / $n_total_later found at t≥0.33 → " *
	(n_any_at_later == 0 ? "UNIVERSAL structural failure" : "interpolation-dependent"))
println()

println("   Q: Does derivative accuracy predict HC success?")
if !isempty(successful)
	max_err_s = maximum(r.max_deriv_err for r in successful)
	@printf("   A: All successful cases had deriv error ≤ %.2e\n", max_err_s)
	above_threshold = count(r -> !r.found && r.max_deriv_err <= max_err_s &&
		isempty(r.error_msg) && !isnan(r.max_deriv_err), all_results)
	if above_threshold > 0
		println("      But $above_threshold cases with deriv error ≤ threshold still FAILED")
		println("      → Derivative accuracy is NECESSARY but NOT SUFFICIENT")
	else
		println("      → Derivative accuracy appears to be the deciding factor")
	end
else
	println("   A: No successful cases to analyze — derivative accuracy may be irrelevant")
	println("      (the failure is structural, not interpolation-related)")
end

println()
println("-" ^ 78)
println("Done!")
flush(stdout)
