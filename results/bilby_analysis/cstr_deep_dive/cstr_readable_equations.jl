#!/usr/bin/env julia
#
# CSTR Readable Equation Display
# ================================
# Print the 19-equation polynomial system in the cleanest possible form:
# - Named physical constants
# - Short variable names
# - Equations organized by ODE family
# - Recurrence structure made explicit
#
# Run: julia results/bilby_analysis/cstr_deep_dive/cstr_readable_equations.jl

using ODEParameterEstimation
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using DifferentialEquations
using OrderedCollections
using Printf
using Symbolics

# ═══════════════════════════════════════════════════════════════════════════════
# Setup (minimal — just build the 26-equation system)
# ═══════════════════════════════════════════════════════════════════════════════
println("Building CSTR polynomial system...")
flush(stdout)

p_true_vals = [0.15, 0.439, 0.307, 0.779]
ic_vals = [0.127, 0.867, 0.384]

const ALPHA1 = 1.999863916554819
const ALPHA2 = 0.0285694845222117
const ALPHA3 = 0.8571428571428571
const ALPHA4 = 0.05714285714285714
const E_R_NONDIM = 12.5

struct PerfectInterpolant
	t0::Float64; coeffs::Vector{Float64}
end
function (p::PerfectInterpolant)(t_val)
	dt = t_val - p.t0; result = p.coeffs[end]
	for k in (length(p.coeffs) - 1):-1:1; result = result * dt + p.coeffs[k]; end
	return result
end

function compute_taylor_coefficients(sol, t_eval, p_vals, max_order)
	tau_v, Tin_v, dH_v, UA_v = p_vals; omega = 0.5
	state_at_t = sol(t_eval)
	tc_C = zeros(max_order + 1); tc_Temp = zeros(max_order + 1); tc_reff = zeros(max_order + 1)
	tc_sin = zeros(max_order + 1); tc_cos = zeros(max_order + 1)
	tc_C[1] = state_at_t[1]; tc_Temp[1] = state_at_t[2]; tc_reff[1] = state_at_t[3]
	tc_sin[1] = sin(omega * t_eval); tc_cos[1] = cos(omega * t_eval)
	for k in 1:max_order
		tc_sin[k+1] = Float64(omega^k * sin(omega * t_eval + k * π / 2) / factorial(big(k)))
		tc_cos[k+1] = Float64(omega^k * cos(omega * t_eval + k * π / 2) / factorial(big(k)))
	end
	tc_Temp2 = zeros(max_order + 1); tc_reff_over_Temp2 = zeros(max_order + 1)
	for k in 0:(max_order - 1)
		tc_Temp2[k+1] = sum(tc_Temp[j+1] * tc_Temp[k-j+1] for j in 0:k)
		s = tc_reff[k+1]
		for j in 0:(k-1); s -= tc_reff_over_Temp2[j+1] * tc_Temp2[k-j+1]; end
		tc_reff_over_Temp2[k+1] = s / tc_Temp2[1]
		reff_C_k = sum(tc_reff[j+1] * tc_C[k-j+1] for j in 0:k)
		delta_k0 = k == 0 ? 1.0 : 0.0
		tc_C[k+2] = ((delta_k0 - tc_C[k+1]) / (2.0 * tau_v) - ALPHA1 * reff_C_k) / (k + 1)
		rhs_Temp_k = (delta_k0 * Tin_v - tc_Temp[k+1]) / (2.0 * tau_v) +
			ALPHA2 * dH_v * reff_C_k - 2.0 * UA_v * tc_Temp[k+1] +
			delta_k0 * ALPHA3 * UA_v + ALPHA4 * UA_v * tc_sin[k+1]
		tc_Temp[k+2] = rhs_Temp_k / (k + 1)
		rhs_reff_k = 0.0
		for j in 0:k
			dT_j = (k - j + 1) * tc_Temp[k-j+2]
			rhs_reff_k += tc_reff_over_Temp2[j+1] * dT_j
		end
		tc_reff[k+2] = E_R_NONDIM * rhs_reff_k / (k + 1)
	end
	return Dict("C" => tc_C, "Temp" => tc_Temp, "r_eff" => tc_reff,
		"sin_0_5" => tc_sin, "cos_0_5" => tc_cos)
end

function build_perfect_interpolants(taylor_coeffs, t_eval, mq_list, max_order)
	interps = Dict()
	for mq_eq in mq_list
		obs_rhs = ModelingToolkit.diff2term(mq_eq.rhs); obs_str = string(obs_rhs)
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
	param_map = Dict("tau" => p_vals[1], "Tin" => p_vals[2], "dH_rhoCP" => p_vals[3], "UA_VrhoCP" => p_vals[4])
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
			sub_dict[v] = Float64(taylor_coeffs[state_keys[base_name]][deriv_order+1] * factorial(big(deriv_order)))
		else
			trfn_info = ODEParameterEstimation._parse_trfn_base_name(base_name)
			if !isnothing(trfn_info)
				func_type, frequency = trfn_info
				if func_type == :sin; sub_dict[v] = frequency^deriv_order * sin(frequency * t_eval + deriv_order * π / 2)
				elseif func_type == :cos; sub_dict[v] = frequency^deriv_order * cos(frequency * t_eval + deriv_order * π / 2)
				end
			end
		end
	end
	return sub_dict
end

@parameters tau Tin dH_rhoCP UA_VrhoCP
@variables C(t) Temp(t) r_eff(t) y1(t)
states = [C, Temp, r_eff]; parameters_list = [tau, Tin, dH_rhoCP, UA_VrhoCP]
eqs = [
	D(C) ~ (1.0 - C) / (2.0 * tau) - ALPHA1 * r_eff * C,
	D(Temp) ~ (Tin - Temp) / (2.0 * tau) + ALPHA2 * dH_rhoCP * r_eff * C -
		2.0 * UA_VrhoCP * Temp + ALPHA3 * UA_VrhoCP + ALPHA4 * UA_VrhoCP * sin(0.5 * t),
	D(r_eff) ~ E_R_NONDIM * r_eff / (Temp^2) * (
		(Tin - Temp) / (2.0 * tau) + ALPHA2 * dH_rhoCP * r_eff * C -
		2.0 * UA_VrhoCP * Temp + ALPHA3 * UA_VrhoCP + ALPHA4 * UA_VrhoCP * sin(0.5 * t)),
]
measured_quantities = [y1 ~ 700.0 * Temp]
p_true_dict = Dict(parameters_list .=> p_true_vals); ic_dict = Dict(states .=> ic_vals)
@named cstr_model = ODESystem(eqs, t, states, parameters_list)
data_sample = ODEParameterEstimation.sample_data(cstr_model, measured_quantities,
	[0.0, 20.0], p_true_dict, ic_dict, 1501; solver = AutoVern9(Rodas4P()))
sys_complete = complete(cstr_model)
prob = ODEProblem(sys_complete,
	merge(Dict(ModelingToolkit.unknowns(sys_complete) .=> ic_vals),
		Dict(ModelingToolkit.parameters(sys_complete) .=> p_true_vals)), [0.0, 20.0])
sol = DifferentialEquations.solve(prob, AutoVern9(Rodas4P()); abstol=1e-14, reltol=1e-14, dense=true)
ordered_model, mq = create_ordered_ode_system("CSTR_red", states, parameters_list, eqs, measured_quantities)
pep_original = ParameterEstimationProblem("CSTR_red", ordered_model, mq, data_sample, [0.0, 20.0],
	nothing, OrderedDict(parameters_list .=> p_true_vals), OrderedDict(states .=> ic_vals), 0)
t_var = ModelingToolkit.get_iv(pep_original.model.system)
pep, tr_info = ODEParameterEstimation.transform_pep_for_estimation(pep_original, t_var)
ident_data = ODEParameterEstimation.setup_identifiability(pep; max_num_points=1)
si_template_eqs, si_deriv_dict, si_unident, _ =
	ODEParameterEstimation.get_si_equation_system(pep.model, pep.measured_quantities, pep.data_sample;
		DD=ident_data.good_DD, infolevel=1)
cached_si_template = (equations=si_template_eqs, deriv_dict=si_deriv_dict, unidentifiable=si_unident)
tc_t0 = compute_taylor_coefficients(sol, 0.0, p_true_vals, 20)
pi_t0 = build_perfect_interpolants(tc_t0, 0.0, pep.measured_quantities, 20)
eqs_orig, vars_orig = ODEParameterEstimation.construct_equation_system_from_si_template(
	pep.model.system, pep.measured_quantities, pep.data_sample,
	ident_data.good_deriv_level, ident_data.good_udict,
	ident_data.good_varlist, ident_data.good_DD;
	interpolator=ODEParameterEstimation.agp_gpr_robust, time_index_set=[1],
	precomputed_interpolants=pi_t0, si_template=cached_si_template)
sub_dict = build_true_substitution(vars_orig, p_true_vals, tc_t0, 0.0)
println("System built: $(length(eqs_orig)) eqs, $(length(vars_orig)) vars\n")
flush(stdout)

# ═══════════════════════════════════════════════════════════════════════════════
# Substitute known Temp values (from observables), classify equations, display
# ═══════════════════════════════════════════════════════════════════════════════

# Known temperature values from observable y₁ = 700·T
known_temps = Dict{Any,Float64}()
remaining = []
for (i, eq) in enumerate(eqs_orig)
	eq_exp = Symbolics.expand(eq)
	eq_vars = collect(Symbolics.get_variables(eq_exp))
	# Check if this is a trivial observable equation (1 var, degree 1)
	if length(eq_vars) == 1
		v = eq_vars[1]
		vname = string(v)
		if startswith(vname, "Temp_")
			val = try
				solved = Symbolics.symbolic_linear_solve(eq_exp, v)
				Float64(Symbolics.value(solved))
			catch; nothing end
			if !isnothing(val)
				known_temps[v] = val
				continue
			end
		end
	end
	push!(remaining, eq_exp)
end

# Substitute known temperatures into remaining equations
remaining = [Symbolics.substitute(eq, known_temps) for eq in remaining]
remaining_vars = [v for v in vars_orig if !(v in keys(known_temps))]

# ═══════════════════════════════════════════════════════════════════════════════
# Classify each equation by its ODE family
# ═══════════════════════════════════════════════════════════════════════════════

# Classification heuristic based on degree and variable patterns:
#   Concentration chain: degree 3, has C_k terms with α₁ coefficients
#   Temperature chain: degree 4, has UA_VrhoCP and dH_rhoCP terms
#   Arrhenius chain: degree 5, has Temp² and Tin products with r_eff

conc_eqs = []    # Concentration ODE derivatives (degree 3)
temp_eqs = []    # Temperature ODE derivatives (degree 4)
arr_eqs = []     # Arrhenius equation derivatives (degree 5)

for eq in remaining
	deg = try Symbolics.degree(eq) catch; 0 end
	if deg == 3
		push!(conc_eqs, eq)
	elseif deg == 4
		push!(temp_eqs, eq)
	elseif deg == 5
		push!(arr_eqs, eq)
	else
		# Fallback: check variable content
		eq_str = string(eq)
		if occursin("Tin_0", eq_str) && !occursin("r_eff_0^2", eq_str)
			push!(temp_eqs, eq)
		elseif occursin("Tin_0", eq_str)
			push!(arr_eqs, eq)
		else
			push!(conc_eqs, eq)
		end
	end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Pretty-print helpers
# ═══════════════════════════════════════════════════════════════════════════════

# Word-wrap a string at + or - signs, using character (not byte) indexing
function print_wrapped(s::String; indent="    ", continuation="      ", width=80)
	chars = collect(s)
	n = length(chars)
	if n <= width
		println(indent, s)
		return
	end
	pos = 1
	first_line = true
	while pos <= n
		chunk_end = min(pos + width - 1, n)
		if chunk_end < n
			# Search backward for a + or - to break at
			for j in chunk_end:-1:max(pos + 40, pos + 1)
				if chars[j] in ('+', '-')
					chunk_end = j - 1
					break
				end
			end
		end
		prefix = first_line ? indent : continuation
		println(prefix, String(chars[pos:chunk_end]))
		pos = chunk_end + 1
		first_line = false
	end
end

# Replace symbolic coefficients with readable names/decimals
function readable(eq)
	s = string(eq)

	# Named constants: α₁ ≈ 2.000, α₂ ≈ 0.02857
	# (51861707//25932618) = α₁ ≈ 2.000
	s = replace(s, "(51861707//25932618)" => "α₁")
	# (8141929//284986906) = α₂ ≈ 0.02857
	s = replace(s, "(8141929//284986906)" => "α₂")
	# (203548225//569973812) = α₂·E/2 ≈ 0.3571
	s = replace(s, "(203548225//569973812)" => "(α₂·E/2)")

	# Common multiples of α₁
	s = replace(s, "(51861707//12966309)" => "2α₁")   # 2·α₁
	s = replace(s, "(51861707//8644206)" => "3α₁")    # 3·α₁
	s = replace(s, "(103723414//12966309)" => "4α₁")  # 4·α₁
	s = replace(s, "(51861707//4322103)" => "6α₁")    # 6·α₁
	s = replace(s, "(259308535//25932618)" => "5α₁")   # 5·α₁
	s = replace(s, "(259308535//12966309)" => "10α₁")  # 10·α₁

	# Common multiples of α₂
	s = replace(s, "(8141929//142493453)" => "2α₂")   # 2·α₂
	s = replace(s, "(24425787//284986906)" => "α₂·3")  # 3·α₂... hmm
	s = replace(s, "(24425787//142493453)" => "α₂·6//3") # nah, let me be more careful

	# Actually let me just replace ALL rational fractions with decimal
	s = replace(s, r"\((\-?\d+)//(\d+)\)" => function(m)
		nums = match(r"\((\-?\d+)//(\d+)\)", m)
		v = parse(Int128, nums[1]) / parse(Int128, nums[2])
		av = abs(v)
		if av > 0.001 && av < 1e6
			sig = v < 0 ? "-" : ""
			return sig * string(round(av; sigdigits=4))
		else
			return @sprintf("%.3e", Float64(v))
		end
	end)

	# Replace long decimals with short ones
	s = replace(s, r"(\d+\.\d{6,})" => function(m)
		v = parse(Float64, m)
		av = abs(v)
		if av > 0.001 && av < 1e6
			return string(round(v; sigdigits=4))
		else
			return @sprintf("%.3e", v)
		end
	end)

	# Clean up multiplication notation
	s = replace(s, r"\*" => "·")

	return s
end

# ═══════════════════════════════════════════════════════════════════════════════
# DISPLAY
# ═══════════════════════════════════════════════════════════════════════════════

println("=" ^ 80)
println("CSTR POLYNOMIAL SYSTEM — READABLE FORM")
println("=" ^ 80)

println("""

THE MODEL
─────────
  dC/dt  = (1 - C)/(2τ) - α₁·r·C
  dT/dt  = (Tᵢₙ - T)/(2τ) + α₂·δH·r·C - 2U·T + (6/7)·U + (2/35)·U·sin(t/2)
  r'·T²  = (E/2)·r·dT/dt                              [Arrhenius, E = 25]

  Observable: y₁ = 700·T

  Constants: α₁ ≈ 2.000,  α₂ ≈ 0.02857,  E = 25

KNOWN FROM DATA (observable y₁ = 700·T at t = 0)
─────────────────────────────────────────────────""")
temp_names = sort(collect(keys(known_temps)); by=v -> parse(Int, match(r"(\d+)", string(v))[1]))
for v in temp_names
	k = parse(Int, match(r"(\d+)", string(v))[1])
	label = k == 0 ? "T(0)" : "T^($k)(0)"
	@printf("  %-10s = %12.4f     [from y₁⁽%d⁾(0)/700]\n", label, known_temps[v], k)
end

println("""

19 UNKNOWNS
───────────
  Parameters (4):  τ = 0.15,   Tᵢₙ = 0.439,   δH = 0.307,   U = 0.779
  States (15):     C₀..C₆,  r₀..r₆,  T₇

  Notation: Cₖ = C⁽ᵏ⁾(0),  rₖ = r⁽ᵏ⁾(0),  Tₖ = T⁽ᵏ⁾(0)
""")

println("─" ^ 80)
println("CONCENTRATION CHAIN  ($(length(conc_eqs)) equations, degree 3)")
println("─" ^ 80)
println("""
  Pattern: Cₖ₊₁·τ + Cₖ/2 - δₖ₀/2 + α₁·τ·Σⱼ C(k,j)·rⱼ·Cₖ₋ⱼ = 0
  [k-th derivative of: C' = (1-C)/(2τ) - α₁·r·C, multiplied by τ]
""")
for (i, eq) in enumerate(conc_eqs)
	k = i - 1
	eq_vars = Symbolics.get_variables(eq)
	resid = try abs(Float64(Symbolics.value(Symbolics.substitute(eq, sub_dict)))) catch; NaN end
	s = readable(eq)
	println("  C-chain k=$k ($(length(eq_vars)) vars, resid=$(@sprintf("%.0e", resid))):")
	print_wrapped(s)
	println()
end

println("─" ^ 80)
println("TEMPERATURE CHAIN  ($(length(temp_eqs)) equations, degree 4)")
println("─" ^ 80)
println("""
  Pattern: Tₖ₊₁·τ + Tₖ/2 - δₖ₀·Tᵢₙ/2 + 2U·τ·Tₖ - δₖ₀·(6/7)·U·τ
           - (2/35)·U·τ·sₖ - α₂·δH·τ·Σⱼ C(k,j)·rⱼ·Cₖ₋ⱼ = 0

  [k-th derivative of: T' = (Tᵢₙ-T)/(2τ) + α₂·δH·r·C - 2U·T + (6/7)U + ..., × τ]
  [Tₖ for k=0..6 are KNOWN NUMBERS — substituted from data]
  [sₖ = sin⁽ᵏ⁾(t/2)|₀: s₀=0, s₁=½, s₂=0, s₃=-⅛, s₄=0, s₅=1/32, s₆=0]
""")
for (i, eq) in enumerate(temp_eqs)
	k = i - 1
	eq_vars = Symbolics.get_variables(eq)
	resid = try abs(Float64(Symbolics.value(Symbolics.substitute(eq, sub_dict)))) catch; NaN end
	s = readable(eq)
	println("  T-chain k=$k ($(length(eq_vars)) vars, resid=$(@sprintf("%.0e", resid))):")
	print_wrapped(s)
	println()
end

println("─" ^ 80)
println("ARRHENIUS CHAIN  ($(length(arr_eqs)) equations, degree 5)")
println("─" ^ 80)
println("""
  Pattern: Σⱼ C(k,j)·rⱼ₊₁·[T²]ₖ₋ⱼ = (E/2)·Σⱼ C(k,j)·rⱼ·Tₖ₋ⱼ₊₁
  where [T²]ₘ = Σᵢ C(m,i)·Tᵢ·Tₘ₋ᵢ   and   E = 25

  [k-th derivative of: r'·T² = (E/2)·r·T', with T' expanded as the Temp ODE]
  [These equations involve products T²·r·τ and are degree 5]
  [All Tₖ (k=0..6) substituted as known numbers]
""")
for (i, eq) in enumerate(arr_eqs)
	k = i - 1
	eq_vars = Symbolics.get_variables(eq)
	resid = try abs(Float64(Symbolics.value(Symbolics.substitute(eq, sub_dict)))) catch; NaN end
	s = readable(eq)
	println("  Arr k=$k ($(length(eq_vars)) vars, resid=$(@sprintf("%.0e", resid))):")
	print_wrapped(s)
	println()
end

println("─" ^ 80)
println("STRUCTURE SUMMARY")
println("─" ^ 80)
println("""
  System: 19 equations in 19 unknowns

  Equation families:
    $(length(conc_eqs)) concentration chain  (degree 3, k=0..$(length(conc_eqs)-1))
    $(length(temp_eqs)) temperature chain    (degree 4, k=0..$(length(temp_eqs)-1))
    $(length(arr_eqs)) Arrhenius chain      (degree 5, k=0..$(length(arr_eqs)-1))

  Bézout bound: 3⁶ × 4⁷ × 5⁶ = $(3^length(conc_eqs) * 4^length(temp_eqs) * 5^length(arr_eqs))
  Mixed volume (actual): 8
  Real solutions: 3 (1 true + 2 spurious)

  Linear elimination reduces to 5 equations in 5 unknowns:
    C₀, U, r₀, δH, C₁
  but each equation becomes millions of characters (nested rational functions).
  HC.jl solves the 19×19 form directly in seconds.
""")

println("=" ^ 80)
println("Done!")
flush(stdout)
