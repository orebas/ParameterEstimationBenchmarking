#!/usr/bin/env julia
#
# CSTR HC.jl Isolation Script
# ============================
# Deep dive into CSTR failure modes across all 12 benchmark shooting points.
#
# Key hypothesis: r_eff (effective reaction rate) decays exponentially via
# Arrhenius kinetics. At late shooting points (t > 5), r_eff ≈ 0, making
# the true solution indistinguishable from the spurious "no reaction" branch.
#
# Structure:
#   STEP 1: Build model + show r_eff decay curve at all 12 shooting points
#   STEP 2: Build + print COMPLETE polynomial system at t≈1.33 (point #4)
#   STEP 3: Solve at t≈1.33 with HC.jl (production-identical + full HC stats)
#   STEP 4: Sweep all 12 benchmark shooting points
#   STEP 5: Alternative HC strategies (multiple seeds, monodromy, certify)
#   STEP 6: Summary + conclusions
#
# Run: julia results/bilby_analysis/cstr_deep_dive/cstr_hc_isolation.jl

using ODEParameterEstimation
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using DifferentialEquations
using OrderedCollections
using LinearAlgebra
using Printf
using Symbolics

# Import HomotopyContinuation carefully to avoid name collision with DifferentialEquations.solve
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

# Nondimensionalization constants
const ALPHA1 = 1.999863916554819      # ~ 2.0 (rate scaling)
const ALPHA2 = 0.0285694845222117     # heat generation coefficient
const ALPHA3 = 0.8571428571428571     # = 6/7 (coolant base term)
const ALPHA4 = 0.05714285714285714   # = 2/35 (coolant oscillation amplitude)
const E_R_NONDIM = 12.5              # nondimensionalized E/R


# ═══════════════════════════════════════════════════════════════════════════════
# PerfectInterpolant: exact derivatives from Taylor polynomial
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


# ═══════════════════════════════════════════════════════════════════════════════
# compute_taylor_coefficients: Taylor series for all states at t_eval
# ═══════════════════════════════════════════════════════════════════════════════
"""
    compute_taylor_coefficients(sol, t_eval, p_vals, max_order)

Compute Taylor coefficients for C, Temp, r_eff, sin(0.5t), cos(0.5t) at t_eval.
Returns Dict{String, Vector{Float64}} where coeffs[k+1] = f^(k)(t_eval) / k!
"""
function compute_taylor_coefficients(sol, t_eval, p_vals, max_order)
	tau_v, Tin_v, dH_v, UA_v = p_vals
	omega = 0.5

	state_at_t = sol(t_eval)

	tc_C    = zeros(Float64, max_order + 1)
	tc_Temp = zeros(Float64, max_order + 1)
	tc_reff = zeros(Float64, max_order + 1)
	tc_sin  = zeros(Float64, max_order + 1)
	tc_cos  = zeros(Float64, max_order + 1)

	# Order 0: state values at t_eval
	tc_C[1]    = state_at_t[1]
	tc_Temp[1] = state_at_t[2]
	tc_reff[1] = state_at_t[3]
	tc_sin[1]  = sin(omega * t_eval)
	tc_cos[1]  = cos(omega * t_eval)

	# Pre-compute sin/cos Taylor coefficients analytically
	for k in 1:max_order
		tc_sin[k+1] = Float64(omega^k * sin(omega * t_eval + k * π / 2) / factorial(big(k)))
		tc_cos[k+1] = Float64(omega^k * cos(omega * t_eval + k * π / 2) / factorial(big(k)))
	end

	# Storage for derived quantities
	tc_Temp2 = zeros(Float64, max_order + 1)
	tc_reff_over_Temp2 = zeros(Float64, max_order + 1)

	# Iteratively compute Taylor coefficients via ODE RHS recursion
	for k in 0:(max_order - 1)
		# Temp^2
		tc_Temp2[k+1] = sum(tc_Temp[j+1] * tc_Temp[k-j+1] for j in 0:k)

		# r_eff / Temp^2 via quotient recursion: h[k] = (f[k] - Σ h[j]*g[k-j]) / g[0]
		s = tc_reff[k+1]
		for j in 0:(k-1)
			s -= tc_reff_over_Temp2[j+1] * tc_Temp2[k-j+1]
		end
		tc_reff_over_Temp2[k+1] = s / tc_Temp2[1]

		# Products: r_eff * C
		reff_C_k = sum(tc_reff[j+1] * tc_C[k-j+1] for j in 0:k)

		delta_k0 = k == 0 ? 1.0 : 0.0

		# D(C) = (1-C)/(2τ) - α₁·r_eff·C
		rhs_C_k = (delta_k0 - tc_C[k+1]) / (2.0 * tau_v) - ALPHA1 * reff_C_k
		tc_C[k+2] = rhs_C_k / (k + 1)

		# D(Temp) = (Tin-Temp)/(2τ) + α₂·dH·r_eff·C - 2·UA·Temp + α₃·UA + α₄·UA·sin(0.5t)
		rhs_Temp_k = (delta_k0 * Tin_v - tc_Temp[k+1]) / (2.0 * tau_v) +
					 ALPHA2 * dH_v * reff_C_k -
					 2.0 * UA_v * tc_Temp[k+1] +
					 delta_k0 * ALPHA3 * UA_v +
					 ALPHA4 * UA_v * tc_sin[k+1]
		tc_Temp[k+2] = rhs_Temp_k / (k + 1)

		# D(r_eff) = E_R_NONDIM · (r_eff/Temp²) · D(Temp)
		# Taylor coeff of product: Σ q[j] · ((k-j+1)·T[k-j+1])
		rhs_reff_k = 0.0
		for j in 0:k
			dT_j = (k - j + 1) * tc_Temp[k-j+2]  # D(Temp) Taylor coeff at order (k-j)
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


# ═══════════════════════════════════════════════════════════════════════════════
# build_perfect_interpolants: PerfectInterpolant dict for a time point
# ═══════════════════════════════════════════════════════════════════════════════
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


# ═══════════════════════════════════════════════════════════════════════════════
# build_true_substitution: map polynomial variables to true values at a time point
# ═══════════════════════════════════════════════════════════════════════════════
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
			# Convert Taylor coeff to derivative: x^(k)(t) = k! · tc[k+1]
			sub_dict[v] = Float64(taylor_coeffs[key][deriv_order+1] * factorial(big(deriv_order)))
		else
			# Check for _trfn_ transcendental state
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
# build_and_solve: build polynomial system at a shooting point and solve with HC
# ═══════════════════════════════════════════════════════════════════════════════
function build_and_solve(sol, t_pt, idx, p_vals, pep, ident_data, cached_si_template; verbose = false)
	# Compute Taylor coefficients
	tc = compute_taylor_coefficients(sol, t_pt, p_vals, MAX_DERIV_ORDER)

	# Build PerfectInterpolants
	pi = build_perfect_interpolants(tc, t_pt, pep.measured_quantities, MAX_DERIV_ORDER)

	# Build equation system
	eqs_pt, vars_pt = ODEParameterEstimation.construct_equation_system_from_si_template(
		pep.model.system,
		pep.measured_quantities,
		pep.data_sample,
		ident_data.good_deriv_level,
		ident_data.good_udict,
		ident_data.good_varlist,
		ident_data.good_DD;
		interpolator = ODEParameterEstimation.agp_gpr_robust,
		time_index_set = [idx],
		precomputed_interpolants = pi,
		diagnostics = verbose,
		si_template = cached_si_template,
	)

	# Verify residuals
	sub = build_true_substitution(vars_pt, p_vals, tc, t_pt)
	residuals = Float64[]
	for eq in eqs_pt
		val = try
			Float64(Symbolics.value(Symbolics.substitute(eq, sub)))
		catch
			NaN
		end
		push!(residuals, val)
	end
	max_res = maximum(abs.(filter(!isnan, residuals)))

	# Solve with HC (production-identical call)
	hc_result = ODEParameterEstimation.solve_with_hc(eqs_pt, vars_pt)
	solutions = hc_result[1]

	# Distance to truth
	tvec = Float64[get(sub, v, NaN) for v in vars_pt]
	closest = isempty(solutions) ? Inf : minimum(norm(s .- tvec) for s in solutions)
	found = closest < 1e-3

	# Count spurious r_eff≈0 solutions
	var_names = string.(vars_pt)
	ri = findfirst(vn -> occursin("r_eff", vn) && endswith(vn, "_d0"), var_names)
	n_spurious = isnothing(ri) ? 0 : count(s -> abs(s[ri]) < 1e-4, solutions)

	return (
		eqs = eqs_pt, vars = vars_pt, sub_dict = sub,
		taylor_coeffs = tc, residuals = residuals, max_residual = max_res,
		solutions = solutions, n_solutions = length(solutions),
		n_spurious = n_spurious, closest_dist = closest, found = found,
	)
end


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Build Model + Show r_eff Decay Curve
# ═══════════════════════════════════════════════════════════════════════════════
println("=" ^ 72)
println("  CSTR HC.jl ISOLATION SCRIPT — $INSTANCE_NAME")
println("=" ^ 72)
println()

println("STEP 1: Building model and showing r_eff decay curve")
println("-" ^ 72)
flush(stdout)

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

# Generate data sample + high-accuracy ODE solution
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

# Compute 12 benchmark shooting indices
shooting_indices = ODEParameterEstimation.compute_shooting_indices(
	N_SHOOTING, DATASIZE; warp = true, beta = WARP_BETA,
)
t_vector = data_sample["t"]

println("\n  r_eff DECAY CURVE at all $N_SHOOTING benchmark shooting points:")
println("  " * "-" ^ 70)
@printf("  %3s  %6s  %10s  %12s  %12s  %12s  %s\n",
	"#", "Index", "Time", "C(t)", "Temp(t)", "r_eff(t)", "Note")
println("  " * "-" ^ 70)

for (i, idx) in enumerate(shooting_indices)
	t_pt = t_vector[idx]
	s = sol(t_pt)
	note = if s[3] < 1e-6
		"r_eff≈0 (indistinguishable from spurious branch)"
	elseif s[3] < 1e-3
		"r_eff very small"
	elseif s[3] > 0.05
		"** GOOD — r_eff still meaningful"
	else
		"r_eff decaying"
	end
	@printf("  %3d  %6d  %10.4f  %12.6e  %12.6e  %12.6e  %s\n",
		i, idx, t_pt, s[1], s[2], s[3], note)
end

println("\n  STEP 1 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1b: Transform PEP + SIAN Analysis (ONCE — shared across all points)
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 1b: Transform PEP + SIAN analysis (computed once, shared across all points)")
println("-" ^ 72)
flush(stdout)

ordered_model, mq = create_ordered_ode_system(
	"CSTR_iso", states, parameters, eqs, measured_quantities,
)
pep_original = ParameterEstimationProblem(
	"CSTR_iso", ordered_model, mq, data_sample, TIME_INTERVAL,
	nothing,
	OrderedDict(parameters .=> p_true_vals),
	OrderedDict(states .=> ic_vals),
	0,
)

t_var = ModelingToolkit.get_iv(pep_original.model.system)
pep, tr_info = ODEParameterEstimation.transform_pep_for_estimation(pep_original, t_var)

if !isnothing(tr_info)
	println("  Transcendental transform: $(length(tr_info.entries)) expression(s) polynomialized")
	for entry in tr_info.entries
		println("    $(entry.func_type)($(entry.frequency)*t) -> $(entry.input_variable)")
	end
end

transformed_states = ModelingToolkit.unknowns(pep.model.system)
transformed_params = ModelingToolkit.parameters(pep.model.system)
println("  Transformed model: $(length(transformed_states)) states, $(length(transformed_params)) params")
println("  States: ", [string(s) for s in transformed_states])
println("  Params: ", [string(p) for p in transformed_params])
println("  Measured quantities: $(length(pep.measured_quantities))")
for (i, mq_eq) in enumerate(pep.measured_quantities)
	println("    mq[$i]: $(mq_eq.lhs) ~ $(mq_eq.rhs)")
end

# SIAN analysis (time-independent — this is the expensive part that runs ONCE)
ident_data = ODEParameterEstimation.setup_identifiability(pep; max_num_points = 1)

println("\n  SIAN results:")
println("    good_num_points: $(ident_data.good_num_points)")
println("    good_deriv_level: $(ident_data.good_deriv_level)")
println("    all_unidentifiable: $(ident_data.all_unidentifiable)")
println("    # varlist entries: $(length(ident_data.good_varlist))")

# Cache SI template (computed once — the template is purely symbolic, no numeric data)
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

println("  SI template: $(length(si_template_eqs)) equations (cached for reuse)")

# Print template equations (symbolic form before numerical substitution)
println("\n  Template equations (symbolic form):")
for (i, eq) in enumerate(si_template_eqs)
	eq_str = string(eq)
	if length(eq_str) > 300
		eq_str = eq_str[1:300] * "..."
	end
	println("    Eq$i: $eq_str")
end

println("\n  STEP 1b DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Build + Print COMPLETE System at t≈1.33 (Benchmark Point #4)
# ═══════════════════════════════════════════════════════════════════════════════
PRIMARY_POINT = 4  # Point #4: past initial transient, r_eff still large
primary_idx = shooting_indices[PRIMARY_POINT]
primary_t = t_vector[primary_idx]

println("STEP 2: Complete system at t=$(round(primary_t, digits=4)) (point #$PRIMARY_POINT, index $primary_idx)")
println("-" ^ 72)
flush(stdout)

# Compute Taylor coefficients at primary point
tc_primary = compute_taylor_coefficients(sol, primary_t, p_true_vals, MAX_DERIV_ORDER)

state_at_primary = sol(primary_t)
println("  State values at t=$(round(primary_t, digits=4)):")
@printf("    C(t)     = %.10e\n", state_at_primary[1])
@printf("    Temp(t)  = %.10e\n", state_at_primary[2])
@printf("    r_eff(t) = %.10e\n", state_at_primary[3])

println("\n  Taylor coefficients (orders 0-5) for r_eff:")
for k in 0:5
	deriv_val = Float64(tc_primary["r_eff"][k+1] * factorial(big(k)))
	tc_val = tc_primary["r_eff"][k+1]
	@printf("    order %d: r_eff^(%d) = %15.8e  (Taylor coeff = %15.8e)\n", k, k, deriv_val, tc_val)
end

# Build PerfectInterpolants
perfect_interps = build_perfect_interpolants(tc_primary, primary_t, pep.measured_quantities, MAX_DERIV_ORDER)
println("\n  Built $(length(perfect_interps)) PerfectInterpolants")

# Build equation system (verbose mode for diagnostics)
eqs_sys, vars_sys = ODEParameterEstimation.construct_equation_system_from_si_template(
	pep.model.system,
	pep.measured_quantities,
	pep.data_sample,
	ident_data.good_deriv_level,
	ident_data.good_udict,
	ident_data.good_varlist,
	ident_data.good_DD;
	interpolator = ODEParameterEstimation.agp_gpr_robust,
	time_index_set = [primary_idx],
	precomputed_interpolants = perfect_interps,
	diagnostics = true,
	si_template = cached_si_template,
)

println("\n  System: $(length(eqs_sys)) equations, $(length(vars_sys)) variables")
println("  Square: ", length(eqs_sys) == length(vars_sys) ? "YES" : "NO")

println("\n  VARIABLES:")
for (i, v) in enumerate(vars_sys)
	println("    [$i] $(string(v))")
end

println("\n  FULL EQUATIONS (no truncation):")
for (i, eq) in enumerate(eqs_sys)
	println("    Eq$i: $(string(eq))")
end

# Verify residuals with true values
sub_dict_primary = build_true_substitution(vars_sys, p_true_vals, tc_primary, primary_t)

println("\n  TRUE VALUES for each variable:")
for v in vars_sys
	@printf("    %-40s = %18.10e\n", string(v), get(sub_dict_primary, v, NaN))
end

println("\n  RESIDUALS (equation by equation):")
max_resid = 0.0
for (i, eq) in enumerate(eqs_sys)
	val = try
		Float64(Symbolics.value(Symbolics.substitute(eq, sub_dict_primary)))
	catch e
		@printf("    Eq%2d: SUBSTITUTION FAILED: %s\n", i, string(e)[1:min(80, length(string(e)))])
		NaN
	end
	global max_resid = max(max_resid, abs(val))
	flag = abs(val) > 1e-6 ? " <-- LARGE" : ""
	@printf("    Eq%2d: |residual| = %20.10e%s\n", i, abs(val), flag)
end
@printf("\n  MAX |residual|: %.4e\n", max_resid)
if max_resid < 1e-6
	println("  >> TRUE SOLUTION SATISFIES THE SYSTEM (residuals ~ 0)")
else
	println("  >> WARNING: Residuals are large — system may be wrong")
end

println("\n  STEP 2 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Solve at t≈1.33 with HC.jl (Production-Identical + Full HC Stats)
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 3: HC.jl solve at t=$(round(primary_t, digits=4)) (production-identical call)")
println("-" ^ 72)
flush(stdout)

# First: production-identical call via ODEPE's solve_with_hc
println("  3a. Production-identical call (ODEParameterEstimation.solve_with_hc):")
hc_result = ODEParameterEstimation.solve_with_hc(eqs_sys, vars_sys; display_system = true)
solutions_prod = hc_result[1]
println("  Production result: $(length(solutions_prod)) solutions")

# Second: direct HC call for full statistics
println("\n  3b. Direct HC.jl call (full statistics):")
hc_sys, hc_vars = ODEParameterEstimation.convert_to_hc_format(eqs_sys, vars_sys)
hc_res = HC.solve(hc_sys; show_progress = false)

n_total = HC.nresults(hc_res)
real_sols = HC.solutions(hc_res; only_real = true, real_tol = 1e-9)
all_sols = HC.solutions(hc_res)
singular_sols = HC.singular(hc_res)
n_singular = length(singular_sols)

@printf("    Converged results:   %d\n", n_total)
@printf("    Real solutions:      %d\n", length(real_sols))
@printf("    Complex solutions:   %d\n", length(all_sols) - length(real_sols))
@printf("    Singular:            %d\n", n_singular)

# Compare solutions to truth
true_vec = Float64[get(sub_dict_primary, v, NaN) for v in vars_sys]
var_names = string.(vars_sys)

# Find r_eff_d0 variable index for spurious detection
reff_idx = findfirst(vn -> occursin("r_eff", vn) && endswith(vn, "_d0"), var_names)

println("\n  ALL REAL solutions (L2 distance to truth):")
best_dist = Inf
best_idx = 0
for (i, s) in enumerate(real_sols)
	s_real = real.(s)
	dist = norm(s_real .- true_vec)
	is_spurious = !isnothing(reff_idx) && abs(s_real[reff_idx]) < 1e-4
	tag = is_spurious ? " [SPURIOUS r_eff≈0]" : ""
	@printf("    RealSol %3d: L2=%.4e%s\n", i, dist, tag)
	if dist < best_dist
		global best_dist = dist
		global best_idx = i
	end
end

if isempty(real_sols)
	println("    (no real solutions — checking all solutions)")
	for (i, s) in enumerate(all_sols)
		s_real = real.(s)
		max_imag = maximum(abs.(imag.(s)))
		dist = norm(s_real .- true_vec)
		@printf("    Sol %3d: L2=%.4e  max|imag|=%.4e\n", i, dist, max_imag)
		if dist < best_dist
			global best_dist = dist
			global best_idx = i
		end
	end
end

if best_idx > 0
	source = isempty(real_sols) ? all_sols : real_sols
	println("\n  CLOSEST solution (#$best_idx, L2=$(round(best_dist, sigdigits=4))):")
	s = real.(source[best_idx])
	for (j, vn) in enumerate(var_names)
		err_pct = abs(true_vec[j]) > 1e-10 ?
				  abs((s[j] - true_vec[j]) / true_vec[j]) * 100 : abs(s[j]) * 100
		@printf("    %-40s: sol=%15.6e  true=%15.6e  err=%8.2f%%\n",
			vn, s[j], true_vec[j], err_pct)
	end
end

found_primary = best_dist < 1e-3
println("\n  VERDICT: HC.jl ", found_primary ? "FOUND" : "MISSED",
	" the true root at t=$(round(primary_t, digits=4))")
println("  (closest L2 distance: $(round(best_dist, sigdigits=4)))")

println("\n  STEP 3 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Sweep All 12 Benchmark Shooting Points
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 4: Sweeping all $N_SHOOTING benchmark shooting points")
println("-" ^ 72)
flush(stdout)

sweep_results = []

for (pt_num, idx) in enumerate(shooting_indices)
	t_pt = t_vector[idx]
	state_at_t = sol(t_pt)
	reff_true = state_at_t[3]

	@printf("  Point %2d (idx=%4d, t=%7.3f, r_eff=%.4e): ", pt_num, idx, t_pt, reff_true)
	flush(stdout)

	result = build_and_solve(sol, t_pt, idx, p_true_vals, pep, ident_data, cached_si_template)

	status = result.found ? "FOUND" : (result.n_solutions == 0 ? "NO SOLS" : "MISSED")
	@printf("%d sols, %d spurious, closest=%.2e, resid=%.2e  [%s]\n",
		result.n_solutions, result.n_spurious, result.closest_dist,
		result.max_residual, status)

	push!(sweep_results, merge(result, (
		point = pt_num, index = idx, time = t_pt, reff = reff_true,
	)))
end

println("\n  SWEEP SUMMARY:")
println("  " * "-" ^ 90)
@printf("  %3s  %6s  %8s  %12s  %5s  %5s  %12s  %12s  %8s\n",
	"#", "Index", "Time", "r_eff", "#Sol", "#Spur", "Closest", "MaxResid", "Status")
println("  " * "-" ^ 90)
for r in sweep_results
	@printf("  %3d  %6d  %8.4f  %12.4e  %5d  %5d  %12.4e  %12.4e  %8s\n",
		r.point, r.index, r.time, r.reff, r.n_solutions, r.n_spurious,
		r.closest_dist, r.max_residual, r.found ? "FOUND" : "MISSED")
end

n_found = count(r -> r.found, sweep_results)
println("\n  Score: $n_found / $N_SHOOTING shooting points recovered the true root")

println("\n  STEP 4 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Alternative HC Strategies at t≈1.33
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 5: Alternative HC strategies at t=$(round(primary_t, digits=4))")
println("-" ^ 72)
flush(stdout)

# Re-use the primary point system from the sweep
primary_sweep = sweep_results[PRIMARY_POINT]

# Convert to HC format for direct HC API access
hc_sys_primary, hc_vars_primary = ODEParameterEstimation.convert_to_hc_format(
	primary_sweep.eqs, primary_sweep.vars,
)

# True solution vector in varlist order (same as hc_vars order per convert_to_hc_format)
true_vec_primary = Float64[get(primary_sweep.sub_dict, v, NaN) for v in primary_sweep.vars]

# ─── Strategy A: Multiple random seeds ───────────────────────────────────────
println("\n  Strategy A: Multiple random seeds (5 runs of total-degree homotopy)")
println("  " * "-" ^ 60)

for run in 1:5
	res = HC.solve(hc_sys_primary; show_progress = false, seed = UInt32(run * 12345))
	real_sols = HC.solutions(res; only_real = true, real_tol = 1e-9)
	all_sols = HC.solutions(res)

	closest = Inf
	if !isempty(real_sols)
		closest = minimum(norm(real.(s) .- true_vec_primary) for s in real_sols)
	elseif !isempty(all_sols)
		closest = minimum(norm(real.(s) .- true_vec_primary) for s in all_sols)
	end

	n_converged = HC.nresults(res)
	n_real = length(real_sols)
	n_singular = length(HC.singular(res))

	@printf("    Seed %d: %d converged, %d real, %d singular, closest=%.4e%s\n",
		run, n_converged, n_real, n_singular, closest,
		closest < 1e-3 ? " [FOUND!]" : "")
end

# ─── Strategy B: Monodromy solve ─────────────────────────────────────────────
println("\n  Strategy B: Monodromy solve (seeded with true solution)")
println("  " * "-" ^ 60)

try
	# monodromy_solve needs a start solution that satisfies the system
	# The true solution should satisfy it (we verified residuals ≈ 0 in Step 2)
	mono_res = HC.monodromy_solve(
		hc_sys_primary, [true_vec_primary];
		show_progress = false, max_loops_no_progress = 10,
	)
	mono_sols = HC.solutions(mono_res)
	println("    Monodromy found $(length(mono_sols)) solutions")

	for (i, s) in enumerate(mono_sols)
		dist = norm(real.(s) .- true_vec_primary)
		# Check if this is the spurious r_eff≈0 branch
		ri = findfirst(vn -> occursin("r_eff", string(vn)) && endswith(string(vn), "_d0"),
			primary_sweep.vars)
		tag = (!isnothing(ri) && abs(real(s[ri])) < 1e-4) ? " [SPURIOUS]" : ""
		@printf("      Sol %2d: L2=%.4e%s\n", i, dist, tag)
	end
catch e
	println("    Monodromy failed: ", string(e)[1:min(150, length(string(e)))])
end

# ─── Strategy C: Certify (interval arithmetic) ───────────────────────────────
println("\n  Strategy C: Certify solutions (interval arithmetic)")
println("  " * "-" ^ 60)

try
	std_res = HC.solve(hc_sys_primary; show_progress = false)
	cert = HC.certify(hc_sys_primary, std_res)
	n_cert = HC.ncertified(cert)
	n_distinct = HC.ndistinct_certified(cert)
	n_real_cert = HC.nreal_certified(cert)
	n_total_res = HC.nresults(std_res)
	@printf("    Results:  %d total, %d certified, %d distinct, %d real certified\n",
		n_total_res, n_cert, n_distinct, n_real_cert)
	println("    (Certification confirms these are true isolated roots of the system)")
catch e
	println("    Certify failed: ", string(e)[1:min(150, length(string(e)))])
end

# ─── Strategy D: Solve at all "good" points that passed in Step 4 ────────────
good_points = filter(r -> r.found, sweep_results)
bad_points = filter(r -> !r.found, sweep_results)

if !isempty(good_points) && !isempty(bad_points)
	println("\n  Strategy D: Compare equation structure at best vs worst points")
	println("  " * "-" ^ 60)

	best_pt = good_points[1]
	worst_pt = bad_points[end]

	println("    Best point:  #$(best_pt.point) (t=$(round(best_pt.time, digits=3)), r_eff=$(round(best_pt.reff, sigdigits=3)))")
	println("    Worst point: #$(worst_pt.point) (t=$(round(worst_pt.time, digits=3)), r_eff=$(round(worst_pt.reff, sigdigits=3)))")

	# Compare equation coefficient magnitudes
	for label in ["best", "worst"]
		pt = label == "best" ? best_pt : worst_pt
		println("\n    $label point equation magnitudes:")
		for (i, eq) in enumerate(pt.eqs)
			eq_str = string(eq)
			# Count terms by splitting on + and -
			n_terms = count(c -> c in ['+', '-'], eq_str) + 1
			println("      Eq$i: $(min(length(eq_str), 120)) chars, ~$n_terms terms")
		end
	end
end

println("\n  STEP 5 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Summary
# ═══════════════════════════════════════════════════════════════════════════════
println("=" ^ 72)
println("  SUMMARY — CSTR HC.jl ISOLATION ($INSTANCE_NAME)")
println("=" ^ 72)
println()

println("1. r_eff DECAY CURVE:")
println("   r_eff(0) = $(ic_vals[3])  (initial)")
reff_at_primary = sol(primary_t)[3]
@printf("   r_eff(%.2f) = %.4e  (primary point #%d — past transient)\n",
	primary_t, reff_at_primary, PRIMARY_POINT)
reff_at_10 = sol(10.0)[3]
@printf("   r_eff(10.0) = %.4e  (midpoint)\n", reff_at_10)
reff_at_20 = sol(20.0)[3]
@printf("   r_eff(20.0) = %.4e  (endpoint)\n", reff_at_20)
println()

println("2. SYSTEM STRUCTURE:")
@printf("   Original model: 3 states, 4 params, 1 observable\n")
@printf("   Transformed: %d states, %d params, %d observables\n",
	length(transformed_states), length(transformed_params), length(pep.measured_quantities))
@printf("   Polynomial system: %d equations, %d variables\n", length(eqs_sys), length(vars_sys))
@printf("   Residual check: max|resid| = %.4e %s\n", max_resid,
	max_resid < 1e-6 ? "(system is correct)" : "(PROBLEM)")
println()

println("3. SHOOTING POINT RESULTS:")
println("   " * "-" ^ 65)
for r in sweep_results
	status = r.found ? "SUCCESS" : "FAIL"
	@printf("   Point %2d  t=%6.2f  r_eff=%10.3e  %d sols  %d spur  %7s\n",
		r.point, r.time, r.reff, r.n_solutions, r.n_spurious, status)
end
println("   " * "-" ^ 65)
println()

n_found = count(r -> r.found, sweep_results)
n_total_pts = length(sweep_results)
n_with_reff_large = count(r -> r.reff > 0.01, sweep_results)
n_found_large = count(r -> r.found && r.reff > 0.01, sweep_results)
n_found_small = count(r -> r.found && r.reff <= 0.01, sweep_results)
n_with_reff_small = n_total_pts - n_with_reff_large

println("4. CORRELATION — r_eff magnitude vs HC success:")
@printf("   Points with r_eff > 0.01:  %d/%d found true root\n", n_found_large, n_with_reff_large)
@printf("   Points with r_eff ≤ 0.01:  %d/%d found true root\n", n_found_small, n_with_reff_small)
@printf("   Overall:                    %d/%d found true root\n", n_found, n_total_pts)
println()

println("5. CONCLUSION:")
println("-" ^ 72)
if n_found == 0
	println("HC.jl NEVER finds the true root — even with perfect data at ANY shooting point.")
	println("The polynomial system structure is fundamentally challenging for")
	println("total-degree homotopy. The r_eff/Temp² rational structure creates a")
	println("degenerate r_eff=0 branch that dominates the solution landscape.")
	println()
	println("RECOMMENDED ACTIONS:")
	println("  1. Try parameter homotopy (seed from a nearby easier system)")
	println("  2. Try monodromy solve (if seeding from known solution works)")
	println("  3. Consider reformulating CSTR to eliminate the r_eff=0 branch")
	println("  4. Use multiple shooting points with voting/consensus")
elseif n_found == n_total_pts
	println("HC.jl ALWAYS finds the true root — the benchmark failure is NOT")
	println("due to shooting point selection. The issue must be interpolation errors.")
elseif n_found_large > 0 && n_found_small == 0
	println("HC success STRONGLY CORRELATES with r_eff magnitude:")
	println("  - Early points (r_eff > 0.01): HC distinguishes the reactive branch")
	println("  - Late points (r_eff → 0): true solution merges with spurious r_eff=0")
	println()
	println("The failure is SHOOTING-POINT-DEPENDENT. The benchmark should")
	println("prefer early-to-mid time points where r_eff is still meaningful.")
	println()
	println("RECOMMENDED ACTIONS:")
	println("  1. Bias shooting points toward early times for CSTR-like systems")
	println("  2. Detect Arrhenius-style decay and adapt point selection")
	println("  3. Use r_eff magnitude as a quality metric for point selection")
elseif n_found_large > n_found_small
	println("HC success CORRELATES with r_eff magnitude:")
	@printf("  r_eff > 0.01: %d/%d found  vs  r_eff ≤ 0.01: %d/%d found\n",
		n_found_large, n_with_reff_large, n_found_small, n_with_reff_small)
	println()
	println("Shooting point selection matters, but is not the only factor.")
	println("Both system conditioning and interpolation quality play a role.")
else
	println("Mixed results — HC success does not clearly correlate with r_eff magnitude.")
	println("Further investigation into system conditioning needed.")
end
println("-" ^ 72)
println()
println("Done!")
flush(stdout)
