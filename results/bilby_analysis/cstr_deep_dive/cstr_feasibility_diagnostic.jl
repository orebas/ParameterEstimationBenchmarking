#!/usr/bin/env julia
#
# CSTR Polynomial System Feasibility Diagnostic
# ===============================================
# Diagnoses why CSTR fails 7/8 instances at noise=0 in the bilby benchmark.
# HC consistently finds a "no reaction" spurious branch where r_eff ~ 0.
#
# This script answers:
#   1. Does the true solution satisfy the SIAN polynomial system? (residual check)
#   2. Are interpolated derivatives accurate enough at the shooting point?
#   3. Can HC find the true solution with *perfect* data? (ground truth derivatives)
#   4. If so, why does it fail with interpolated data?
#   5. What does the polynomial system structure look like?
#
# Uses cstr_0_0 (failed, true r_eff=0.384) as primary instance.
# Switch to cstr_3_0 (succeeded, true r_eff=0.110) by changing the config block.
#
# Run: julia results/bilby_analysis/cstr_deep_dive/cstr_feasibility_diagnostic.jl

using ODEParameterEstimation
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using DifferentialEquations
using OrderedCollections
using LinearAlgebra
using Printf
using Symbolics

println("=" ^ 72)
println("  CSTR FEASIBILITY DIAGNOSTIC — PRODUCTION CODE PATH")
println("=" ^ 72)
println()
flush(stdout)

# ─────────────────────────────────────────────────────────────────────
# INSTANCE CONFIGURATION — Change here to switch between instances
# ─────────────────────────────────────────────────────────────────────
# cstr_0_0 (FAILED, 7/8 fail at noise=0)
INSTANCE_NAME = "cstr_0_0"
p_true_vals = [0.15, 0.439, 0.307, 0.779]    # [tau, Tin, dH_rhoCP, UA_VrhoCP]
ic_vals      = [0.127, 0.867, 0.384]          # [C, Temp, r_eff]

# Uncomment below for cstr_3_0 (SUCCEEDED, 1/8 that passed at noise=0)
# INSTANCE_NAME = "cstr_3_0"
# p_true_vals = [0.443, 0.154, 0.302, 0.277]
# ic_vals      = [0.303, 0.205, 0.11]

# ─────────────────────────────────────────────────────────────────────
# PerfectInterpolant: Returns exact derivatives via polynomial evaluation
# ─────────────────────────────────────────────────────────────────────
struct PerfectInterpolant
	t0::Float64
	coeffs::Vector{Float64}  # coeffs[k+1] = f^(k)(t0) / k!
end

function (p::PerfectInterpolant)(t)
	dt = t - p.t0
	result = p.coeffs[end]
	for k in (length(p.coeffs) - 1):-1:1
		result = result * dt + p.coeffs[k]
	end
	return result
end

# ═════════════════════════════════════════════════════════════════════
# STEP 1: CSTR Model Setup + High-Accuracy ODE Solution
# ═════════════════════════════════════════════════════════════════════
println("STEP 1: Setting up CSTR model ($INSTANCE_NAME) and generating data...")
flush(stdout)

# CSTR nondimensionalized model: 3 states, 4 parameters, 1 observable, sin(0.5*t) forcing
@parameters tau Tin dH_rhoCP UA_VrhoCP
@variables C(t) Temp(t) r_eff(t) y1(t)

states = [C, Temp, r_eff]
parameters = [tau, Tin, dH_rhoCP, UA_VrhoCP]

# Numeric coefficients from the nondimensionalization
alpha1 = 1.999863916554819    # ~ 2.0 (rate scaling)
alpha2 = 0.0285694845222117   # heat generation coefficient
alpha3 = 0.8571428571428571   # = 6/7 (coolant base term)
alpha4 = 0.05714285714285714  # = 2/35 (coolant oscillation)

eqs = [
	D(C) ~ (1.0 - C) / (2.0 * tau) - alpha1 * r_eff * C,
	D(Temp) ~ (Tin - Temp) / (2.0 * tau) + alpha2 * dH_rhoCP * r_eff * C -
			  2.0 * UA_VrhoCP * Temp + alpha3 * UA_VrhoCP + alpha4 * UA_VrhoCP * sin(0.5 * t),
	D(r_eff) ~ 12.5 * r_eff / (Temp^2) * (
		(Tin - Temp) / (2.0 * tau) + alpha2 * dH_rhoCP * r_eff * C -
		2.0 * UA_VrhoCP * Temp + alpha3 * UA_VrhoCP + alpha4 * UA_VrhoCP * sin(0.5 * t)
	),
]

measured_quantities = [y1 ~ 700.0 * Temp]

time_interval = [0.0, 20.0]
datasize = 1501

param_names = ["tau", "Tin", "dH_rhoCP", "UA_VrhoCP"]
state_names = ["C", "Temp", "r_eff"]

println("  Parameters: ", join(["$(param_names[i])=$(p_true_vals[i])" for i in 1:4], ", "))
println("  ICs: ", join(["$(state_names[i])=$(ic_vals[i])" for i in 1:3], ", "))

# Generate data sample (1501 points, same as production)
p_true_dict = Dict(parameters .=> p_true_vals)
ic_dict = Dict(states .=> ic_vals)

@named cstr_model = ODESystem(eqs, t, states, parameters)
data_sample = ODEParameterEstimation.sample_data(
	cstr_model, measured_quantities, time_interval,
	p_true_dict, ic_dict, datasize;
	solver = AutoVern9(Rodas4P()),
)
println("  Data sample: $(length(data_sample["t"])) points over $time_interval")

# High-accuracy ODE solution for ground truth (dense output)
sys_complete = complete(cstr_model)
prob = ODEProblem(
	sys_complete,
	merge(Dict(ModelingToolkit.unknowns(sys_complete) .=> ic_vals),
		Dict(ModelingToolkit.parameters(sys_complete) .=> p_true_vals)),
	time_interval,
)
sol = solve(prob, AutoVern9(Rodas4P()); abstol = 1e-14, reltol = 1e-14, dense = true)

println("  ODE solution: retcode=$(sol.retcode)")
println("  STEP 1 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 2: Transform PEP + Production Setup (SIAN + Interpolants)
# ═════════════════════════════════════════════════════════════════════
println("STEP 2: Transforming PEP for transcendentals + running SIAN analysis...")
flush(stdout)

# Create PEP with the original (transcendental-containing) model
ordered_model, mq = create_ordered_ode_system(
	"CSTR_diag", states, parameters, eqs, measured_quantities,
)
pep_original = ParameterEstimationProblem(
	"CSTR_diag", ordered_model, mq, data_sample, time_interval,
	nothing,
	OrderedDict(parameters .=> p_true_vals),
	OrderedDict(states .=> ic_vals),
	0,
)

# Transform PEP: sin(0.5*t) -> _trfn_ oscillator states
t_var = ModelingToolkit.get_iv(pep_original.model.system)
pep, tr_info = ODEParameterEstimation.transform_pep_for_estimation(pep_original, t_var)

if !isnothing(tr_info)
	println("  Transcendental transform: $(length(tr_info.entries)) expression(s) polynomialized")
	for entry in tr_info.entries
		println("    $(entry.func_type)($(entry.frequency)*t) -> $(entry.input_variable)")
	end
else
	println("  No transcendentals detected (unexpected for CSTR!)")
end

# Get transformed model info
transformed_states = ModelingToolkit.unknowns(pep.model.system)
transformed_params = ModelingToolkit.parameters(pep.model.system)
println("  Transformed model: $(length(transformed_states)) states, $(length(transformed_params)) params")
println("  States: ", [string(s) for s in transformed_states])
println("  Params: ", [string(p) for p in transformed_params])
println("  Measured quantities: $(length(pep.measured_quantities))")
for (i, mq_eq) in enumerate(pep.measured_quantities)
	println("    mq[$i]: $(mq_eq.lhs) ~ $(mq_eq.rhs)")
end

# Run SIAN analysis + create interpolants on the TRANSFORMED PEP
setup_data = ODEParameterEstimation.setup_parameter_estimation(
	pep;
	max_num_points = 1,
	point_hint = 0.5,
	interpolator = ODEParameterEstimation.agp_gpr_robust,
)

t_eval_idx = setup_data.time_index_set[1]
t_eval = data_sample["t"][t_eval_idx]

println("\n  SIAN derivative levels: $(setup_data.good_deriv_level)")
println("  Unidentifiable params: $(setup_data.all_unidentifiable)")
println("  DD.obs_lhs levels: $(length(setup_data.good_DD.obs_lhs))")
println("  Time index: $t_eval_idx  =>  t_eval = $t_eval")
println("  # varlist entries: $(length(setup_data.good_varlist))")
println("  STEP 2 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 3: Ground-Truth Taylor Coefficients at t_eval
# ═════════════════════════════════════════════════════════════════════
println("STEP 3: Computing ground-truth Taylor coefficients at t=$t_eval...")
flush(stdout)

state_at_t = sol(t_eval)
max_deriv_order = 20

# Taylor coefficients for the ORIGINAL 3 states + sin(0.5*t), cos(0.5*t)
n_orig_states = 3
taylor_C    = zeros(Float64, max_deriv_order + 1)  # c[k+1] = C^(k)(t_eval)/k!
taylor_Temp = zeros(Float64, max_deriv_order + 1)
taylor_reff = zeros(Float64, max_deriv_order + 1)
taylor_sin  = zeros(Float64, max_deriv_order + 1)  # sin(0.5*t)
taylor_cos  = zeros(Float64, max_deriv_order + 1)  # cos(0.5*t)

# Order 0: state values at t_eval
taylor_C[1]    = state_at_t[1]  # C
taylor_Temp[1] = state_at_t[2]  # Temp
taylor_reff[1] = state_at_t[3]  # r_eff
taylor_sin[1]  = sin(0.5 * t_eval)
taylor_cos[1]  = cos(0.5 * t_eval)

# Pre-compute Taylor coefficients for sin(0.5*t) and cos(0.5*t)
# d^k/dt^k sin(ωt) = ω^k sin(ωt + kπ/2)
# Taylor coeff = ω^k sin(ωt + kπ/2) / k!
omega = 0.5
for k in 1:max_deriv_order
	taylor_sin[k+1] = omega^k * sin(omega * t_eval + k * π / 2) / factorial(big(k))
	taylor_cos[k+1] = omega^k * cos(omega * t_eval + k * π / 2) / factorial(big(k))
end

# Helper: Taylor product (a*b)_k = sum_{j=0}^{k} a_j * b_{k-j}
function taylor_product_coeff(a, b, k)
	s = 0.0
	for j in 0:k
		s += a[j+1] * b[k-j+1]
	end
	return s
end

# Helper: Taylor quotient h = f/g, computing h[k] given h[0..k-1], f[0..k], g[0..k]
# h[k] = (1/g[0]) * (f[k] - sum_{j=0}^{k-1} h[j] * g[k-j])
function taylor_quotient_coeff!(h, f, g, k)
	s = f[k+1]
	for j in 0:(k-1)
		s -= h[j+1] * g[k-j+1]
	end
	h[k+1] = s / g[1]
	return h[k+1]
end

# Storage for derived quantities
taylor_Temp2 = zeros(Float64, max_deriv_order + 1)  # Temp^2
taylor_reff_over_Temp2 = zeros(Float64, max_deriv_order + 1)  # r_eff / Temp^2

# Extract parameter values
tau_v, Tin_v, dH_v, UA_v = p_true_vals

# Iteratively compute Taylor coefficients via ODE RHS recursion
for k in 0:(max_deriv_order - 1)
	# Compute Temp^2 Taylor coefficients up to order k
	taylor_Temp2[k+1] = taylor_product_coeff(taylor_Temp[1:k+1], taylor_Temp[1:k+1], k)

	# Compute r_eff/Temp^2 Taylor coefficients up to order k (via quotient)
	taylor_quotient_coeff!(taylor_reff_over_Temp2, taylor_reff[1:k+1], taylor_Temp2[1:k+1], k)

	# Products needed: r_eff*C
	reff_C_k = taylor_product_coeff(taylor_reff[1:k+1], taylor_C[1:k+1], k)

	# Kronecker delta for constants (1.0, Tin are constants)
	delta_k0 = k == 0 ? 1.0 : 0.0

	# RHS of D(C) at order k:
	# (1 - C)/(2τ) - α₁*r_eff*C
	rhs_C_k = (delta_k0 - taylor_C[k+1]) / (2.0 * tau_v) - alpha1 * reff_C_k

	# RHS of D(Temp) at order k:
	# (Tin - Temp)/(2τ) + α₂*dH*r_eff*C - 2*UA*Temp + α₃*UA*δ + α₄*UA*sin
	rhs_Temp_k = (delta_k0 * Tin_v - taylor_Temp[k+1]) / (2.0 * tau_v) +
				 alpha2 * dH_v * reff_C_k -
				 2.0 * UA_v * taylor_Temp[k+1] +
				 delta_k0 * alpha3 * UA_v +
				 alpha4 * UA_v * taylor_sin[k+1]

	# Update C and Temp Taylor coefficients
	taylor_C[k+2] = rhs_C_k / (k + 1)
	taylor_Temp[k+2] = rhs_Temp_k / (k + 1)

	# RHS of D(r_eff) at order k:
	# D(r_eff) = 12.5 * (r_eff/Temp^2) * D(Temp)
	# Taylor coeff of D(Temp) at order j is (j+1)*taylor_Temp[j+2]
	# So (r_eff/Temp^2 * D(Temp))_k = sum_{j=0}^{k} q_j * (k-j+1)*T_{k-j+1}
	# where q = r_eff/Temp^2
	rhs_reff_k = 0.0
	for j in 0:k
		dT_j = (k - j + 1) * taylor_Temp[k-j+2]  # Taylor coeff of D(Temp) at order (k-j)
		rhs_reff_k += taylor_reff_over_Temp2[j+1] * dT_j
	end
	rhs_reff_k *= 12.5

	taylor_reff[k+2] = rhs_reff_k / (k + 1)
end

# Convert Taylor coefficients to derivatives: x^(k) = k! * x_k
truth_state_derivs = Dict{String, Vector{Float64}}()
for (name, tc) in [("C", taylor_C), ("Temp", taylor_Temp), ("r_eff", taylor_reff),
					("sin_0_5", taylor_sin), ("cos_0_5", taylor_cos)]
	truth_state_derivs[name] = Float64[]
	for k in 0:max_deriv_order
		push!(truth_state_derivs[name], Float64(tc[k+1] * factorial(big(k))))
	end
end

# Observable y1 = 700*Temp: derivatives are 700 * Temp^(k)
truth_obs_y1_derivs = 700.0 .* truth_state_derivs["Temp"]

# Cross-check low orders against ODE interpolant
println("  Cross-check (orders 0-4) Taylor vs ODE interpolant at t=$t_eval:")
for (si, name) in enumerate(state_names)
	for k in 0:4
		taylor_val = truth_state_derivs[name][k+1]
		ode_val = try
			ODEParameterEstimation.nth_deriv(tt -> sol(tt)[si], k, t_eval)
		catch
			NaN
		end
		match = abs(taylor_val) > 1e-10 ?
				abs((ode_val - taylor_val) / taylor_val) : abs(ode_val - taylor_val)
		@printf("    %6s order %d: taylor=%15.8e  ode=%15.8e  rel_diff=%.2e\n",
			name, k, taylor_val, ode_val, match)
	end
end
println("  STEP 3 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 4: Build PerfectInterpolant Objects + Derivative Comparison
# ═════════════════════════════════════════════════════════════════════
println("STEP 4: Building PerfectInterpolants for ALL observables (including _trfn_)...")
flush(stdout)

# Build PerfectInterpolants keyed by diff2term(mq.rhs) for each observable
# in the TRANSFORMED PEP
perfect_interps = Dict()

for (i, mq_eq) in enumerate(pep.measured_quantities)
	obs_rhs = ModelingToolkit.diff2term(mq_eq.rhs)
	obs_rhs_str = string(obs_rhs)

	# Determine which Taylor coefficients to use
	if occursin("Temp", obs_rhs_str) && occursin("700", obs_rhs_str)
		# y1 ~ 700*Temp: Taylor coefficients are 700 * taylor_Temp
		coeffs = 700.0 .* collect(taylor_Temp[1:max_deriv_order+1])
		println("  mq[$i] ($obs_rhs_str) -> 700*Temp PerfectInterpolant")
	elseif occursin("sin", obs_rhs_str) || occursin("_trfn_sin", obs_rhs_str)
		# _trfn_sin observable
		coeffs = collect(taylor_sin[1:max_deriv_order+1])
		println("  mq[$i] ($obs_rhs_str) -> sin(0.5t) PerfectInterpolant")
	elseif occursin("cos", obs_rhs_str) || occursin("_trfn_cos", obs_rhs_str)
		# _trfn_cos observable
		coeffs = collect(taylor_cos[1:max_deriv_order+1])
		println("  mq[$i] ($obs_rhs_str) -> cos(0.5t) PerfectInterpolant")
	else
		@warn "Unknown observable: $obs_rhs_str — skipping PerfectInterpolant"
		continue
	end

	perfect_interps[obs_rhs] = PerfectInterpolant(t_eval, coeffs)
end

# Verify PerfectInterpolant gives correct derivatives via nth_deriv
println("\n  Verification: PerfectInterpolant vs Truth via nth_deriv:")
max_perf_err = 0.0
for (i, mq_eq) in enumerate(pep.measured_quantities)
	obs_rhs = ModelingToolkit.diff2term(mq_eq.rhs)
	if !haskey(perfect_interps, obs_rhs)
		continue
	end
	pi = perfect_interps[obs_rhs]
	obs_rhs_str = string(obs_rhs)
	for k in [0, 1, 2, 5, 10, 15]
		perf_val = ODEParameterEstimation.nth_deriv(x -> pi(x), k, t_eval)
		# Determine ground truth
		if occursin("Temp", obs_rhs_str) && occursin("700", obs_rhs_str)
			truth_val = truth_obs_y1_derivs[k+1]
		elseif occursin("sin", obs_rhs_str)
			truth_val = truth_state_derivs["sin_0_5"][k+1]
		elseif occursin("cos", obs_rhs_str)
			truth_val = truth_state_derivs["cos_0_5"][k+1]
		else
			truth_val = NaN
		end
		rel_err = abs(truth_val) > 1e-15 ? abs((perf_val - truth_val) / truth_val) : abs(perf_val)
		global max_perf_err = max(max_perf_err, rel_err)
		@printf("    mq%d order %2d: perfect=%15.8e  truth=%15.8e  rel_err=%.2e\n",
			i, k, perf_val, truth_val, rel_err)
	end
end
if max_perf_err < 1e-6
	println("  >> PerfectInterpolant is EXACT (max rel_err=", @sprintf("%.2e", max_perf_err), ")")
else
	println("  >> WARNING: PerfectInterpolant has errors up to ", @sprintf("%.2e", max_perf_err))
end

# Derivative comparison: Truth vs AGPRobust
println("\n  Derivative accuracy comparison: AGPRobust vs Truth at t=$t_eval")
println("  " * "-" ^ 90)
@printf("  %-12s %-5s %20s %20s %12s\n", "Observable", "Order", "Truth", "AGPRobust", "AGPR err%")
println("  " * "-" ^ 90)

for (i, mq_eq) in enumerate(pep.measured_quantities)
	obs_rhs = ModelingToolkit.diff2term(mq_eq.rhs)
	obs_rhs_str = string(obs_rhs)
	if !haskey(setup_data.interpolants, obs_rhs)
		println("  mq[$i] ($obs_rhs_str): no AGPRobust interpolant found")
		continue
	end
	agpr_interp = setup_data.interpolants[obs_rhs]

	for k in 0:15
		# Determine ground truth
		if occursin("Temp", obs_rhs_str) && occursin("700", obs_rhs_str)
			truth_val = truth_obs_y1_derivs[k+1]
		elseif occursin("sin", obs_rhs_str)
			truth_val = truth_state_derivs["sin_0_5"][k+1]
		elseif occursin("cos", obs_rhs_str)
			truth_val = truth_state_derivs["cos_0_5"][k+1]
		else
			truth_val = NaN
		end

		agpr_val = try
			ODEParameterEstimation.nth_deriv(x -> agpr_interp(x), k, t_eval)
		catch
			NaN
		end
		agpr_err = abs(truth_val) > 1e-15 ? abs((agpr_val - truth_val) / truth_val) * 100 : abs(agpr_val)
		@printf("  %-12s %5d %20.8e %20.8e %11.4f%%\n",
			obs_rhs_str[1:min(12, length(obs_rhs_str))], k, truth_val, agpr_val, agpr_err)
	end
end

println("  STEP 4 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 5: Get SIAN Template + Build System Structure
# ═════════════════════════════════════════════════════════════════════
println("STEP 5: Getting SIAN template + building polynomial system structure...")
flush(stdout)

# Call get_si_equation_system on the TRANSFORMED PEP
si_template_eqs, si_deriv_dict, si_unident, _si_id_funcs =
	ODEParameterEstimation.get_si_equation_system(
		pep.model, pep.measured_quantities, pep.data_sample;
		DD = setup_data.good_DD, infolevel = 1,
	)

cached_si_template = (
	equations = si_template_eqs,
	deriv_dict = si_deriv_dict,
	unidentifiable = si_unident,
)

println("  SIAN template: $(length(si_template_eqs)) equations")
println("  Derivative dict: $si_deriv_dict")
println("  Max derivative order: $(isempty(si_deriv_dict) ? 0 : maximum(values(si_deriv_dict)))")
println("  Unidentifiable: $si_unident")

# Print template equations (symbolic form before numerical substitution)
println("\n  Template equations (symbolic):")
for (i, eq) in enumerate(si_template_eqs)
	eq_str = string(eq)
	if length(eq_str) > 200
		eq_str = eq_str[1:200] * "..."
	end
	println("    Eq$i: $eq_str")
end

# Build equations with PERFECT interpolants via the production function
println("\n  Building equation system with PERFECT data...")
flush(stdout)
eqs_perfect, vars_perfect = ODEParameterEstimation.construct_equation_system_from_si_template(
	pep.model.system,
	pep.measured_quantities,
	pep.data_sample,
	setup_data.good_deriv_level,
	setup_data.good_udict,
	setup_data.good_varlist,
	setup_data.good_DD;
	interpolator = ODEParameterEstimation.agp_gpr_robust,
	time_index_set = setup_data.time_index_set,
	precomputed_interpolants = perfect_interps,
	diagnostics = true,
	si_template = cached_si_template,
)

println("\n  PERFECT DATA system: $(length(eqs_perfect)) equations, $(length(vars_perfect)) variables")
is_square = length(eqs_perfect) == length(vars_perfect)
println("  Square: ", is_square ? "YES" : "NO ($(length(eqs_perfect)) eq, $(length(vars_perfect)) var)")
println("  Variables: ", [string(v) for v in vars_perfect])

# Print the numerical equations
println("\n  Numerical equations (perfect data):")
for (i, eq) in enumerate(eqs_perfect)
	eq_str = string(eq)
	if length(eq_str) > 200
		eq_str = eq_str[1:200] * "..."
	end
	println("    Eq$i: $eq_str")
end

println("  STEP 5 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 6: Residual Check — Does True Solution Satisfy the System?
# ═════════════════════════════════════════════════════════════════════
println("STEP 6: Substituting TRUE values into perfect-data system...")
flush(stdout)

# Build substitution dict: map each variable to its true value
# Parameters
param_name_to_val = Dict(
	"tau" => p_true_vals[1], "Tin" => p_true_vals[2],
	"dH_rhoCP" => p_true_vals[3], "UA_VrhoCP" => p_true_vals[4],
)
# State name -> truth_state_derivs key
state_name_to_truth_key = Dict(
	"C" => "C", "Temp" => "Temp", "r_eff" => "r_eff",
)
# _trfn_ states: detect via name pattern
trfn_truth_map = Dict(
	"sin" => "sin_0_5",
	"cos" => "cos_0_5",
)

sub_dict = Dict()
unmapped_vars = []

println("  Mapping $(length(vars_perfect)) variables to true values:")
for v in vars_perfect
	vname = string(v)
	parsed = ODEParameterEstimation.parse_derivative_variable_name(vname)

	if !isnothing(parsed)
		base_name, deriv_order = parsed

		# Check if it's a parameter
		if haskey(param_name_to_val, base_name)
			if deriv_order == 0
				sub_dict[v] = param_name_to_val[base_name]
				@printf("    %-30s -> param %s = %.6f\n", vname, base_name, sub_dict[v])
			else
				sub_dict[v] = 0.0
				@printf("    %-30s -> d^%d(%s)/dt^%d = 0\n", vname, deriv_order, base_name, deriv_order)
			end
		# Check if it's an original state
		elseif haskey(state_name_to_truth_key, base_name)
			truth_key = state_name_to_truth_key[base_name]
			if deriv_order + 1 <= length(truth_state_derivs[truth_key])
				sub_dict[v] = truth_state_derivs[truth_key][deriv_order+1]
				@printf("    %-30s -> d^%d(%s)/dt^%d = %.6e\n",
					vname, deriv_order, base_name, deriv_order, sub_dict[v])
			else
				sub_dict[v] = NaN
				push!(unmapped_vars, (v, vname, "order $deriv_order > max $max_deriv_order"))
			end
		else
			# Try _trfn_ pattern
			matched_trfn = false
			trfn_info = ODEParameterEstimation._parse_trfn_base_name(base_name)
			if !isnothing(trfn_info)
				func_type, frequency = trfn_info
				# Compute k-th derivative of func_type(frequency * t) at t_eval
				if func_type == :sin
					sub_dict[v] = frequency^deriv_order * sin(frequency * t_eval + deriv_order * π / 2)
				elseif func_type == :cos
					sub_dict[v] = frequency^deriv_order * cos(frequency * t_eval + deriv_order * π / 2)
				elseif func_type == :exp
					sub_dict[v] = frequency^deriv_order * exp(frequency * t_eval)
				end
				@printf("    %-30s -> _trfn_ %s(%g*t)^(%d) = %.6e\n",
					vname, func_type, frequency, deriv_order, sub_dict[v])
				matched_trfn = true
			end
			if !matched_trfn
				push!(unmapped_vars, (v, vname, "unknown base '$base_name'"))
			end
		end
	else
		push!(unmapped_vars, (v, vname, "parse failed"))
	end
end

if !isempty(unmapped_vars)
	println("\n  UNMAPPED variables ($(length(unmapped_vars))):")
	for (v, vname, reason) in unmapped_vars
		println("    $vname - $reason")
	end
end

# Evaluate residuals equation by equation
residuals = Float64[]
println("\n  Residuals (equation by equation):")
for (i, eq) in enumerate(eqs_perfect)
	val = try
		Float64(Symbolics.value(Symbolics.substitute(eq, sub_dict)))
	catch e
		@printf("    Eq%2d: SUBSTITUTION FAILED: %s\n", i, string(e)[1:min(80, length(string(e)))])
		NaN
	end
	push!(residuals, val)
	flag = abs(val) > 1e-6 ? " <-- LARGE" : ""
	@printf("    Eq%2d: |residual| = %20.10e%s\n", i, abs(val), flag)
end

valid_residuals = filter(!isnan, residuals)
max_resid = isempty(valid_residuals) ? NaN : maximum(abs.(valid_residuals))
println("\n  MAX |residual|: ", @sprintf("%.10e", max_resid))
if max_resid < 1e-6
	println("  >> TRUE SOLUTION SATISFIES THE SYSTEM (residuals ~ 0)")
elseif max_resid < 1e-2
	println("  >> Residuals small-ish - possible numerical precision issue")
else
	println("  >> TRUE SOLUTION DOES NOT SATISFY THE SYSTEM!")
end
println("  STEP 6 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 7: Solve with HC.jl Using Ground-Truth (Perfect) Data
# ═════════════════════════════════════════════════════════════════════
println("STEP 7: Solving polynomial system with HC.jl (PERFECT data)...")
flush(stdout)

_result_perfect = ODEParameterEstimation.solve_with_hc(
	eqs_perfect, vars_perfect; display_system = true,
)
solutions_perfect = _result_perfect[1]
println("  HC.jl found $(length(solutions_perfect)) solutions (perfect data)")

println("  STEP 7 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 8: Solve with Interpolated Data (AGPRobust)
# ═════════════════════════════════════════════════════════════════════
println("STEP 8: Building + solving with AGPRobust data...")
flush(stdout)

eqs_agpr, vars_agpr = ODEParameterEstimation.construct_equation_system_from_si_template(
	pep.model.system,
	pep.measured_quantities,
	pep.data_sample,
	setup_data.good_deriv_level,
	setup_data.good_udict,
	setup_data.good_varlist,
	setup_data.good_DD;
	interpolator = ODEParameterEstimation.agp_gpr_robust,
	time_index_set = setup_data.time_index_set,
	precomputed_interpolants = setup_data.interpolants,
	diagnostics = true,
	si_template = cached_si_template,
)

println("  AGPRobust DATA system: $(length(eqs_agpr)) equations, $(length(vars_agpr)) variables")

println("  Solving with HC.jl (AGPRobust data)...")
flush(stdout)
_result_agpr = ODEParameterEstimation.solve_with_hc(eqs_agpr, vars_agpr)
solutions_agpr = _result_agpr[1]
println("  HC.jl found $(length(solutions_agpr)) solutions (AGPRobust data)")

# Also try building with AAAD interpolants
println("\n  Building + solving with AAAD data...")
flush(stdout)
aaad_interpolants = nothing
try
	aaad_interpolants = ODEParameterEstimation.create_interpolants(
		pep.measured_quantities, pep.data_sample,
		pep.data_sample["t"], ODEParameterEstimation.aaad,
	)
catch e
	println("  WARNING: AAAD interpolant creation failed: ", string(e)[1:min(80, length(string(e)))])
end

solutions_aaad = Vector[]
if !isnothing(aaad_interpolants)
	eqs_aaad, vars_aaad = ODEParameterEstimation.construct_equation_system_from_si_template(
		pep.model.system,
		pep.measured_quantities,
		pep.data_sample,
		setup_data.good_deriv_level,
		setup_data.good_udict,
		setup_data.good_varlist,
		setup_data.good_DD;
		interpolator = ODEParameterEstimation.aaad,
		time_index_set = setup_data.time_index_set,
		precomputed_interpolants = aaad_interpolants,
		diagnostics = true,
		si_template = cached_si_template,
	)
	println("  AAAD DATA system: $(length(eqs_aaad)) equations, $(length(vars_aaad)) variables")
	_result_aaad = ODEParameterEstimation.solve_with_hc(eqs_aaad, vars_aaad)
	solutions_aaad = _result_aaad[1]
	println("  HC.jl found $(length(solutions_aaad)) solutions (AAAD data)")
end

println("  STEP 8 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 9: Solution Analysis — Compare HC.jl results to truth
# ═════════════════════════════════════════════════════════════════════
println("STEP 9: Comparing HC.jl solutions to true values...")
flush(stdout)

function analyze_solutions(solutions, label, vars, sub_dict)
	println("\n  --- $label ---")
	println("  # solutions: $(length(solutions))")

	if isempty(solutions)
		println("  NO SOLUTIONS from HC.jl")
		return Inf
	end

	# Build true-value vector in variable order
	true_vec = Float64[get(sub_dict, v, NaN) for v in vars]
	var_names = [string(v) for v in vars]

	# Count solutions near r_eff ~ 0 (spurious "no reaction" branch)
	# Find the index of the r_eff_d0 variable (0th derivative of r_eff)
	reff_idx = findfirst(vn -> occursin("r_eff", vn) && endswith(vn, "_d0"), var_names)
	n_spurious = 0
	n_real = 0
	for (i, s) in enumerate(solutions)
		if !isnothing(reff_idx) && abs(real(s[reff_idx])) < 1e-4
			n_spurious += 1
		end
		if all(x -> abs(imag(x)) < 1e-6, s)
			n_real += 1
		end
	end
	println("  Real solutions: $n_real / $(length(solutions))")
	println("  Spurious (r_eff~0): $n_spurious / $(length(solutions))")

	best_dist = Inf
	best_idx = 0
	for (i, s) in enumerate(solutions)
		s_real = real.(s)
		dist = norm(s_real .- true_vec)
		rel_err = norm((s_real .- true_vec) ./ max.(abs.(true_vec), 1e-10))
		if i <= 10 || dist < 1.0  # Print first 10 + any close ones
			@printf("    Solution %3d: L2_dist=%.4e, rel_L2_err=%.4e%s\n",
				i, dist, rel_err, all(x -> abs(imag(x)) < 1e-6, s) ? "" : " [complex]")
		end
		if dist < best_dist
			best_dist = dist
			best_idx = i
		end
	end

	if length(solutions) > 10
		println("    ... ($(length(solutions) - 10) more solutions)")
	end

	# Print best solution in detail
	if best_idx > 0
		println("\n    CLOSEST solution (#$best_idx):")
		s = real.(solutions[best_idx])
		for (j, vn) in enumerate(var_names)
			s_val = s[j]
			t_val = true_vec[j]
			err_pct = abs(t_val) > 1e-10 ? abs((s_val - t_val) / t_val) * 100 : abs(s_val) * 100
			@printf("      %-30s: sol=%15.6e  true=%15.6e  err=%8.2f%%\n", vn, s_val, t_val, err_pct)
		end
	end

	return best_dist
end

best_dist_perfect = analyze_solutions(solutions_perfect, "PERFECT DATA", vars_perfect, sub_dict)
best_dist_agpr = analyze_solutions(solutions_agpr, "AGPRobust DATA", vars_agpr, sub_dict)
if !isempty(solutions_aaad)
	best_dist_aaad = analyze_solutions(solutions_aaad, "AAAD DATA", vars_aaad, sub_dict)
else
	best_dist_aaad = Inf
end

println("\n  STEP 9 DONE")
println()
flush(stdout)

# ═════════════════════════════════════════════════════════════════════
# STEP 10: Summary Report
# ═════════════════════════════════════════════════════════════════════
println("=" ^ 72)
println("  DIAGNOSTIC SUMMARY — CSTR $INSTANCE_NAME")
println("=" ^ 72)
println()

println("1. SYSTEM SIZE (production path, transformed model):")
@printf("   Original model: 3 states, 4 params, 1 observable\n")
@printf("   Transformed model: %d states, %d params, %d observables\n",
	length(transformed_states), length(transformed_params), length(pep.measured_quantities))
@printf("   Polynomial system: %d equations, %d variables\n", length(eqs_perfect), length(vars_perfect))
println("   Square: ", is_square ? "YES" : "NO")
println()

println("2. RESIDUAL CHECK (true solution + perfect data):")
@printf("   Max |residual|: %.4e\n", max_resid)
if max_resid < 1e-6
	println("   -> True solution IS a root of the production system")
else
	println("   -> PROBLEM: true solution does NOT satisfy the system")
end
println()

println("3. HC.jl WITH PERFECT DATA:")
@printf("   # solutions: %d\n", length(solutions_perfect))
@printf("   Closest distance to truth: %.4e\n", best_dist_perfect)
if !isempty(solutions_perfect) && best_dist_perfect < 1e-3
	println("   -> HC.jl RECOVERS the true solution with perfect data")
elseif !isempty(solutions_perfect)
	println("   -> HC.jl finds solutions but NONE are close to truth")
else
	println("   -> HC.jl finds NO solutions")
end
println()

println("4. HC.jl WITH AGPRobust DATA:")
@printf("   # solutions: %d\n", length(solutions_agpr))
@printf("   Closest distance to truth: %.4e\n", best_dist_agpr)
println()

if !isempty(solutions_aaad)
	println("5. HC.jl WITH AAAD DATA:")
	@printf("   # solutions: %d\n", length(solutions_aaad))
	@printf("   Closest distance to truth: %.4e\n", best_dist_aaad)
	println()
end

println("6. DERIVATIVE ACCURACY SUMMARY (key orders for y1=700*Temp at t=$t_eval):")
for (i, mq_eq) in enumerate(pep.measured_quantities)
	obs_rhs = ModelingToolkit.diff2term(mq_eq.rhs)
	obs_rhs_str = string(obs_rhs)
	if !haskey(setup_data.interpolants, obs_rhs)
		continue
	end
	agpr_interp = setup_data.interpolants[obs_rhs]

	for k in [0, 3, 6, 10]
		# Determine ground truth
		if occursin("Temp", obs_rhs_str) && occursin("700", obs_rhs_str)
			truth = truth_obs_y1_derivs[k+1]
		elseif occursin("sin", obs_rhs_str)
			truth = truth_state_derivs["sin_0_5"][k+1]
		elseif occursin("cos", obs_rhs_str)
			truth = truth_state_derivs["cos_0_5"][k+1]
		else
			continue
		end
		agpr_val = try
			ODEParameterEstimation.nth_deriv(x -> agpr_interp(x), k, t_eval)
		catch
			NaN
		end
		agpr_err = abs(truth) > 1e-15 ? abs((agpr_val - truth) / truth) * 100 : abs(agpr_val)
		@printf("   %-12s order %2d: AGPR err=%8.3f%%\n",
			obs_rhs_str[1:min(12, length(obs_rhs_str))], k, agpr_err)
	end
end
println()

# Final Conclusion
println("-" ^ 72)
if max_resid < 1e-6 && !isempty(solutions_perfect)
	if best_dist_perfect < 1e-3
		println("CONCLUSION: System is FEASIBLE - HC.jl finds the true solution with perfect data.")
		if isempty(solutions_agpr) || best_dist_agpr > 10.0
			println("  -> INTERPOLATION is the bottleneck (AGPRobust derivatives too inaccurate).")
		elseif best_dist_agpr < 1e-1
			println("  -> AGPRobust solutions are reasonably close - interpolation is adequate.")
		else
			println("  -> AGPRobust solutions exist but are far from truth - interpolation degrades quality.")
		end
	else
		println("CONCLUSION: System is correct but HC.jl MISSES the true root even with perfect data.")
		println("  -> Path-tracking / total-degree homotopy coverage problem.")
		println("  -> The r_eff/Temp^2 rational structure creates a degenerate r_eff=0 branch that")
		println("     may attract homotopy paths away from the true solution.")
	end
elseif max_resid < 1e-6 && isempty(solutions_perfect)
	println("CONCLUSION: System is correct (true solution satisfies it) but HC.jl finds 0 solutions.")
	println("  -> Polynomial structure/degree prevents total-degree homotopy from working.")
elseif max_resid >= 1e-6
	println("CONCLUSION: SYSTEM IS STRUCTURALLY WRONG - true solution doesn't satisfy it.")
	println("  -> Fundamental issue with SIAN template or variable mapping.")
end
println("-" ^ 72)
println()
println("Done!")
flush(stdout)
