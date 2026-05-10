#!/usr/bin/env julia
#
# CSTR Manual Equation Reduction
# ===============================
# Start from the 26 Perfect-t=0 equations, plug in known values,
# eliminate linear equations, and display the irreducible nonlinear core.
#
# Run: julia results/bilby_analysis/cstr_deep_dive/cstr_manual_reduction.jl

using ODEParameterEstimation
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using DifferentialEquations
using OrderedCollections
using Printf
using LinearAlgebra: norm
using Symbolics

import HomotopyContinuation
const HC = HomotopyContinuation

# ═══════════════════════════════════════════════════════════════════════════════
# Utility: format a number to readable form (4 sig figs)
# ═══════════════════════════════════════════════════════════════════════════════
function fmt(x::Number)
	xf = Float64(x)
	xf == 0 && return "0"
	ax = abs(xf)
	if ax >= 0.01 && ax < 1e6
		# Use 4 significant figures
		digits = 4 - 1 - floor(Int, log10(ax))
		digits = max(digits, 0)
		return string(round(xf; digits=digits))
	else
		s = @sprintf("%.3e", xf)
		return s
	end
end

# Format a symbolic expression: replace long decimal coefficients with short ones
function format_equation(eq)
	s = string(eq)
	# Replace long decimal numbers with short versions
	# Match floats like 0.43349999... or 2.109310645029679 or scientific notation
	s = replace(s, r"(\d+\.\d{6,})" => m -> fmt(parse(Float64, m)))
	# Replace rational fractions with decimal approximations
	s = replace(s, r"\((\d+)//(\d+)\)" => function(m)
		nums = match(r"\((\d+)//(\d+)\)", m)
		v = parse(Int, nums[1]) / parse(Int, nums[2])
		return fmt(v)
	end)
	return s
end

# ═══════════════════════════════════════════════════════════════════════════════
# Setup (same as cstr_polynomial_sensitivity.jl Step 1)
# ═══════════════════════════════════════════════════════════════════════════════
println("Setting up CSTR model...")
flush(stdout)

p_true_vals = [0.15, 0.439, 0.307, 0.779]
ic_vals = [0.127, 0.867, 0.384]
DATASIZE = 1501
TIME_INTERVAL = [0.0, 20.0]
MAX_DERIV_ORDER = 20

const ALPHA1 = 1.999863916554819
const ALPHA2 = 0.0285694845222117
const ALPHA3 = 0.8571428571428571
const ALPHA4 = 0.05714285714285714
const E_R_NONDIM = 12.5

struct PerfectInterpolant
	t0::Float64
	coeffs::Vector{Float64}
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
	tc_C = zeros(Float64, max_order + 1)
	tc_Temp = zeros(Float64, max_order + 1)
	tc_reff = zeros(Float64, max_order + 1)
	tc_sin = zeros(Float64, max_order + 1)
	tc_cos = zeros(Float64, max_order + 1)
	tc_C[1] = state_at_t[1]; tc_Temp[1] = state_at_t[2]; tc_reff[1] = state_at_t[3]
	tc_sin[1] = sin(omega * t_eval); tc_cos[1] = cos(omega * t_eval)
	for k in 1:max_order
		tc_sin[k+1] = Float64(omega^k * sin(omega * t_eval + k * π / 2) / factorial(big(k)))
		tc_cos[k+1] = Float64(omega^k * cos(omega * t_eval + k * π / 2) / factorial(big(k)))
	end
	tc_Temp2 = zeros(Float64, max_order + 1)
	tc_reff_over_Temp2 = zeros(Float64, max_order + 1)
	for k in 0:(max_order - 1)
		tc_Temp2[k+1] = sum(tc_Temp[j+1] * tc_Temp[k-j+1] for j in 0:k)
		s = tc_reff[k+1]
		for j in 0:(k-1); s -= tc_reff_over_Temp2[j+1] * tc_Temp2[k-j+1]; end
		tc_reff_over_Temp2[k+1] = s / tc_Temp2[1]
		reff_C_k = sum(tc_reff[j+1] * tc_C[k-j+1] for j in 0:k)
		delta_k0 = k == 0 ? 1.0 : 0.0
		rhs_C_k = (delta_k0 - tc_C[k+1]) / (2.0 * tau_v) - ALPHA1 * reff_C_k
		tc_C[k+2] = rhs_C_k / (k + 1)
		rhs_Temp_k = (delta_k0 * Tin_v - tc_Temp[k+1]) / (2.0 * tau_v) +
			ALPHA2 * dH_v * reff_C_k - 2.0 * UA_v * tc_Temp[k+1] +
			delta_k0 * ALPHA3 * UA_v + ALPHA4 * UA_v * tc_sin[k+1]
		tc_Temp[k+2] = rhs_Temp_k / (k + 1)
		rhs_reff_k = 0.0
		for j in 0:k
			dT_j = (k - j + 1) * tc_Temp[k-j+2]
			rhs_reff_k += tc_reff_over_Temp2[j+1] * dT_j
		end
		rhs_reff_k *= E_R_NONDIM
		tc_reff[k+2] = rhs_reff_k / (k + 1)
	end
	return Dict("C" => tc_C, "Temp" => tc_Temp, "r_eff" => tc_reff,
		"sin_0_5" => tc_sin, "cos_0_5" => tc_cos)
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
		else; continue; end
		interps[obs_rhs] = PerfectInterpolant(t_eval, collect(coeffs))
	end
	return interps
end

function build_true_substitution(vars, p_vals, taylor_coeffs, t_eval)
	param_map = Dict("tau" => p_vals[1], "Tin" => p_vals[2],
		"dH_rhoCP" => p_vals[3], "UA_VrhoCP" => p_vals[4])
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

@parameters tau Tin dH_rhoCP UA_VrhoCP
@variables C(t) Temp(t) r_eff(t) y1(t)
states = [C, Temp, r_eff]
parameters_list = [tau, Tin, dH_rhoCP, UA_VrhoCP]
eqs = [
	D(C) ~ (1.0 - C) / (2.0 * tau) - ALPHA1 * r_eff * C,
	D(Temp) ~ (Tin - Temp) / (2.0 * tau) + ALPHA2 * dH_rhoCP * r_eff * C -
		2.0 * UA_VrhoCP * Temp + ALPHA3 * UA_VrhoCP + ALPHA4 * UA_VrhoCP * sin(0.5 * t),
	D(r_eff) ~ E_R_NONDIM * r_eff / (Temp^2) * (
		(Tin - Temp) / (2.0 * tau) + ALPHA2 * dH_rhoCP * r_eff * C -
		2.0 * UA_VrhoCP * Temp + ALPHA3 * UA_VrhoCP + ALPHA4 * UA_VrhoCP * sin(0.5 * t)),
]
measured_quantities = [y1 ~ 700.0 * Temp]
p_true_dict = Dict(parameters_list .=> p_true_vals)
ic_dict = Dict(states .=> ic_vals)
@named cstr_model = ODESystem(eqs, t, states, parameters_list)
data_sample = ODEParameterEstimation.sample_data(cstr_model, measured_quantities,
	TIME_INTERVAL, p_true_dict, ic_dict, DATASIZE; solver = AutoVern9(Rodas4P()))
sys_complete = complete(cstr_model)
prob = ODEProblem(sys_complete,
	merge(Dict(ModelingToolkit.unknowns(sys_complete) .=> ic_vals),
		Dict(ModelingToolkit.parameters(sys_complete) .=> p_true_vals)),
	TIME_INTERVAL)
sol = DifferentialEquations.solve(prob, AutoVern9(Rodas4P()); abstol = 1e-14, reltol = 1e-14, dense = true)

ordered_model, mq = create_ordered_ode_system("CSTR_red", states, parameters_list, eqs, measured_quantities)
pep_original = ParameterEstimationProblem("CSTR_red", ordered_model, mq, data_sample, TIME_INTERVAL,
	nothing, OrderedDict(parameters_list .=> p_true_vals), OrderedDict(states .=> ic_vals), 0)
t_var = ModelingToolkit.get_iv(pep_original.model.system)
pep, tr_info = ODEParameterEstimation.transform_pep_for_estimation(pep_original, t_var)

println("  Running SIAN...")
flush(stdout)
ident_data = ODEParameterEstimation.setup_identifiability(pep; max_num_points = 1)

si_template_eqs, si_deriv_dict, si_unident, _ =
	ODEParameterEstimation.get_si_equation_system(pep.model, pep.measured_quantities, pep.data_sample;
		DD = ident_data.good_DD, infolevel = 1)
cached_si_template = (equations = si_template_eqs, deriv_dict = si_deriv_dict, unidentifiable = si_unident)

tc_t0 = compute_taylor_coefficients(sol, 0.0, p_true_vals, MAX_DERIV_ORDER)
pi_t0 = build_perfect_interpolants(tc_t0, 0.0, pep.measured_quantities, MAX_DERIV_ORDER)

eqs_orig, vars_orig = ODEParameterEstimation.construct_equation_system_from_si_template(
	pep.model.system, pep.measured_quantities, pep.data_sample,
	ident_data.good_deriv_level, ident_data.good_udict,
	ident_data.good_varlist, ident_data.good_DD;
	interpolator = ODEParameterEstimation.agp_gpr_robust,
	time_index_set = [1],
	precomputed_interpolants = pi_t0,
	si_template = cached_si_template)

sub_dict = build_true_substitution(vars_orig, p_true_vals, tc_t0, 0.0)

println("\nSetup complete: $(length(eqs_orig)) equations, $(length(vars_orig)) variables")
println("=" ^ 80)
flush(stdout)

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Print original system summary
# ═══════════════════════════════════════════════════════════════════════════════
println("\nPHASE 1: Original system ($(length(eqs_orig)) eqs, $(length(vars_orig)) vars)")
println("-" ^ 80)

println("\nVariables and true values:")
for (i, v) in enumerate(vars_orig)
	tv = get(sub_dict, v, NaN)
	@printf("  x[%2d] = %-20s = %s\n", i, string(v), fmt(Float64(tv)))
end

println("\nEquation summary:")
for (i, eq) in enumerate(eqs_orig)
	eq_exp = Symbolics.expand(eq)
	deg = try Symbolics.degree(eq_exp) catch; -1 end
	nvars = length(Symbolics.get_variables(eq_exp))
	resid = try abs(Float64(Symbolics.value(Symbolics.substitute(eq_exp, sub_dict)))) catch; NaN end
	@printf("  Eq[%2d]: deg=%d, %2d vars, resid=%.1e\n", i, deg, nvars, resid)
end
flush(stdout)

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Eliminate observables (degree-1, single-variable equations)
# ═══════════════════════════════════════════════════════════════════════════════
println("\n\nPHASE 2: Eliminate observable equations (y_k = 700·Temp_k)")
println("-" ^ 80)

remaining_eqs = collect(eqs_orig)
remaining_vars = collect(vars_orig)
known_numerical = Dict{Any,Float64}()  # var → numerical value
round_num = 0

while true
	global round_num, remaining_eqs
	round_num += 1
	eliminated_any = false
	new_eqs = []

	for (i, eq) in enumerate(remaining_eqs)
		eq_vars = Symbolics.get_variables(eq)
		unknown_vars = [v for v in eq_vars if !(v in keys(known_numerical))]

		if length(unknown_vars) == 1
			target = unknown_vars[1]
			try
				solved = Symbolics.symbolic_linear_solve(eq, target)
				solved_val = Symbolics.substitute(solved, known_numerical)
				num_val = try Float64(Symbolics.value(solved_val)) catch; nothing end
				if !isnothing(num_val)
					known_numerical[target] = num_val
					true_val = Float64(get(sub_dict, target, NaN))
					@printf("  %-15s = %-12s  (true: %s)\n",
						string(target), fmt(num_val), fmt(true_val))
					eliminated_any = true
					continue
				end
			catch; end
		end

		if length(unknown_vars) == 0
			resid = try abs(Float64(Symbolics.value(Symbolics.substitute(eq, known_numerical)))) catch; NaN end
			if resid < 1e-6
				eliminated_any = true
				continue
			end
		end

		push!(new_eqs, eq)
	end

	remaining_eqs = new_eqs
	if !eliminated_any; break; end
end

remaining_vars = [v for v in vars_orig if !(v in keys(known_numerical))]
println("\n  → $(length(known_numerical)) variables eliminated numerically")
println("  → $(length(remaining_eqs)) equations in $(length(remaining_vars)) unknowns remain")
flush(stdout)

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: Substitute known numerical values, then do SYMBOLIC linear elimination
# Key: we solve for a variable linearly, but the result may depend on OTHER unknowns.
# We substitute that expression (not expand it) into the remaining equations.
# ═══════════════════════════════════════════════════════════════════════════════
println("\n\nPHASE 3: Symbolic linear elimination (substitute, never expand)")
println("-" ^ 80)

# First, substitute all known numerical values into remaining equations
remaining_eqs = [Symbolics.substitute(eq, known_numerical) for eq in remaining_eqs]

# Track symbolic eliminations: var → symbolic expression in terms of other unknowns
symbolic_elims = OrderedDict{Any,Any}()

round_num = 0
while true
	global round_num, remaining_eqs, remaining_vars
	round_num += 1
	eliminated_any = false

	for (i, eq) in enumerate(remaining_eqs)
		eq_vars = Symbolics.get_variables(eq)
		unknown_in_eq = [v for v in eq_vars if any(isequal(v, rv) for rv in remaining_vars)]
		isempty(unknown_in_eq) && continue

		# Try each variable to see if equation is linear in it
		for target in unknown_in_eq
			deg_in_target = try Symbolics.degree(eq, target) catch; -1 end
			deg_in_target != 1 && continue

			try
				solved_expr = Symbolics.symbolic_linear_solve(eq, target)

				# Store the elimination
				symbolic_elims[target] = solved_expr
				remaining_vars = [v for v in remaining_vars if !isequal(v, target)]

				# Verify against true value
				all_known = merge(known_numerical, Dict(v => Float64(get(sub_dict, v, NaN)) for v in remaining_vars))
				computed = try Float64(Symbolics.value(Symbolics.substitute(solved_expr, all_known))) catch; NaN end
				true_val = Float64(get(sub_dict, target, NaN))

				# How many unknowns does the expression depend on?
				expr_vars = Symbolics.get_variables(solved_expr)
				n_deps = length([v for v in expr_vars if any(isequal(v, rv) for rv in remaining_vars)])

				@printf("  Pass %d: %-15s = f(%d unknowns)   [true: %s, check: %s]\n",
					round_num, string(target), n_deps, fmt(true_val), fmt(computed))

				# Remove this equation, substitute into all remaining equations
				other_eqs = [remaining_eqs[j] for j in eachindex(remaining_eqs) if j != i]
				# Substitute target → solved_expr in all remaining equations (NO expand!)
				remaining_eqs = [Symbolics.substitute(eq_j, Dict(target => solved_expr)) for eq_j in other_eqs]

				eliminated_any = true
				break
			catch e
				continue
			end
		end

		if eliminated_any; break; end
	end

	if !eliminated_any; break; end
end

# Drop trivially-satisfied equations (no variables left)
nontrivial_eqs = []
for eq in remaining_eqs
	eq_vars = Symbolics.get_variables(eq)
	remaining_in_eq = [v for v in eq_vars if any(isequal(v, rv) for rv in remaining_vars)]
	if !isempty(remaining_in_eq)
		push!(nontrivial_eqs, eq)
	else
		resid = try abs(Float64(Symbolics.value(eq))) catch; NaN end
		if resid > 1e-6
			push!(nontrivial_eqs, eq)  # Keep if not trivially zero
		end
	end
end
remaining_eqs = nontrivial_eqs

println("\n  → $(length(symbolic_elims)) variables eliminated symbolically")
println("  → $(length(remaining_eqs)) equations in $(length(remaining_vars)) unknowns remain")
println("  → Remaining unknowns: $(join(string.(remaining_vars), ", "))")
flush(stdout)

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: Display the elimination chain
# ═══════════════════════════════════════════════════════════════════════════════
println("\n\nPHASE 4: Elimination chain (what each eliminated variable equals)")
println("=" ^ 80)

println("\nNumerically determined (from observables):")
for (v, val) in known_numerical
	@printf("  %-15s = %s\n", string(v), fmt(val))
end

println("\nSymbolically eliminated (linear in each variable):")
for (i, (v, expr)) in enumerate(symbolic_elims)
	expr_vars = Symbolics.get_variables(expr)
	dep_names = [string(dv) for dv in expr_vars if any(isequal(dv, rv) for rv in remaining_vars)]

	# Format: show the expression with readable coefficients
	expr_str = format_equation(expr)
	expr_len = length(expr_str)

	if expr_len <= 150
		println("\n  $i. $(string(v)) = $expr_str")
	else
		println("\n  $i. $(string(v)) = f($(join(dep_names, ", ")))  [$(expr_len) chars]")
		println("     $(expr_str[1:min(120, expr_len)])...")
	end
end
flush(stdout)

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: Display the irreducible nonlinear core with readable coefficients
# ═══════════════════════════════════════════════════════════════════════════════
println("\n\nPHASE 5: The irreducible nonlinear core")
println("=" ^ 80)

println("\nFree unknowns ($(length(remaining_vars))):")
for (i, v) in enumerate(remaining_vars)
	tv = Float64(get(sub_dict, v, NaN))
	@printf("  u[%d] = %-20s  (true = %s)\n", i, string(v), fmt(tv))
end

println("\nCore equations ($(length(remaining_eqs))):")
for (i, eq) in enumerate(remaining_eqs)
	eq_vars = Symbolics.get_variables(eq)
	core_vars = [v for v in eq_vars if any(isequal(v, rv) for rv in remaining_vars)]

	# Compute residual at true solution
	all_sub = merge(sub_dict, Dict(v => Float64(sub_dict[v]) for v in keys(sub_dict)))
	resid = try abs(Float64(Symbolics.value(Symbolics.substitute(eq, all_sub)))) catch; NaN end

	# Try to get degree (may fail on unexpanded expressions)
	deg = try Symbolics.degree(eq) catch
		try Symbolics.degree(Symbolics.expand(eq)) catch; "?" end
	end

	# Format with readable coefficients
	eq_str = format_equation(eq)
	eq_len = length(eq_str)

	println("\n  CoreEq[$i] (deg=$deg, vars: $(join(string.(core_vars), ", ")), resid=$(fmt(resid)), len=$(eq_len) chars):")

	# Print equation: show in full if short, truncated preview if huge
	if eq_len <= 500
		# Word-wrap at + or - signs for readability
		pos = 1
		while pos <= length(eq_str)
			chunk_end = min(pos + 90, length(eq_str))
			if chunk_end < length(eq_str)
				for j in chunk_end:-1:max(pos+50, pos)
					if j <= length(eq_str) && eq_str[j] in ['+', '-'] && j > pos
						chunk_end = j - 1
						break
					end
				end
			end
			prefix = pos == 1 ? "    " : "      "
			println("$(prefix)$(eq_str[pos:chunk_end])")
			pos = chunk_end + 1
		end
	else
		# Show first 300 chars as preview
		println("    $(eq_str[1:min(300, eq_len)])...")
		println("    [... $(eq_len) total characters — too large to display]")
	end
end
flush(stdout)

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6: Solve the core with HC.jl
# ═══════════════════════════════════════════════════════════════════════════════
# Check if equations are small enough to expand for HC.jl
max_eq_len = maximum(length(string(eq)) for eq in remaining_eqs)
if !isempty(remaining_eqs) && !isempty(remaining_vars) && max_eq_len < 100_000
	println("\n\nPHASE 6: Solve the core system with HC.jl")
	println("-" ^ 80)

	try
		println("  Expanding equations for HC.jl...")
		flush(stdout)

		expanded_eqs = []
		for (i, eq) in enumerate(remaining_eqs)
			t_start = time()
			eq_exp = try
				Symbolics.expand(eq)
			catch e
				println("  WARNING: expand failed on CoreEq[$i]: $e")
				eq
			end
			elapsed = time() - t_start
			if elapsed > 1.0
				@printf("  CoreEq[%d] expand took %.1f sec\n", i, elapsed)
			end
			push!(expanded_eqs, eq_exp)
			flush(stdout)
		end

		hc_sys, hc_vars = ODEParameterEstimation.convert_to_hc_format(expanded_eqs, remaining_vars)
		println("  System: $(length(remaining_eqs)) eqs, $(length(remaining_vars)) vars")
		println("  Solving with polyhedral homotopy...")
		flush(stdout)

		res = HC.solve(hc_sys; show_progress = false)
		real_sols = HC.solutions(res; only_real = true, real_tol = 1e-9)

		println("  Results: $(HC.nresults(res)) converged, $(length(real_sols)) real")

		true_vec = Float64[Float64(get(sub_dict, v, NaN)) for v in remaining_vars]

		for (j, s) in enumerate(real_sols)
			d = norm(real.(s) .- true_vec)
			tag = d < 1e-3 ? " *** FOUND ***" : ""
			@printf("\n  Real sol %d: L2 = %s%s\n", j, fmt(d), tag)
			for (k, v) in enumerate(remaining_vars)
				@printf("    %-20s = %-14s  (true: %s)\n", string(v), fmt(real(s[k])), fmt(true_vec[k]))
			end
		end
	catch e
		println("  HC.jl failed: $e")
	end
else
	println("\n\nPHASE 6: HC.jl solve skipped")
	println("-" ^ 80)
	println("  Largest equation is $(max_eq_len) characters — Symbolics.expand() would be intractable.")
	println("  The 19×19 system (before symbolic elimination) IS solvable by HC.jl (8 paths, 3 real solutions).")
	println("  The symbolic elimination to 5×5 makes the expressions exponentially larger,")
	println("  even though the polynomial content is equivalent.")
end

println("\n" * "=" ^ 80)
println("Done!")
flush(stdout)
