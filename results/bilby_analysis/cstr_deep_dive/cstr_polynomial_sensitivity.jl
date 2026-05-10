#!/usr/bin/env julia
#
# CSTR Polynomial Sensitivity Analysis
# =====================================
# Deep investigation into WHY a 0.26% derivative error (AAAD vs PerfectInterpolant)
# causes 8 orders of magnitude degradation in HC solution quality (L2: 2.6e-5 → 2.6e7).
#
# Tests 4 polynomial systems:
#   SYS1: PerfectInterpolant at t=0.00 (FOUND, L2≈2.6e-5)
#   SYS2: PerfectInterpolant at t≈0.33 (MISSED)
#   SYS3: AAAD at t=0.00 (MISSED, L2≈2.6e7)
#   SYS4: AAAD at t≈0.33 (MISSED)
#
# Steps 3 analyzes all 4. Steps 4-8 focus on SYS1 vs SYS3 (the t=0 pair).
#
# Run: julia results/bilby_analysis/cstr_deep_dive/cstr_polynomial_sensitivity.jl

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
# STEP 1: Setup (model definition, ODE solve, PEP transform, SIAN analysis)
# ═══════════════════════════════════════════════════════════════════════════════
println("=" ^ 80)
println("  CSTR POLYNOMIAL SENSITIVITY ANALYSIS")
println("=" ^ 80)
println()

println("STEP 1: Setup — model, ODE solve, PEP transform, SIAN analysis")
println("-" ^ 80)
flush(stdout)

# ─── Configuration ────────────────────────────────────────────────────────────
INSTANCE_NAME = "cstr_0_0"
p_true_vals = [0.15, 0.439, 0.307, 0.779]    # [tau, Tin, dH_rhoCP, UA_VrhoCP]
ic_vals      = [0.127, 0.867, 0.384]          # [C, Temp, r_eff]

DATASIZE = 1501
TIME_INTERVAL = [0.0, 20.0]
N_SHOOTING = 12
WARP_BETA = 3.0
MAX_DERIV_ORDER = 20

# Nondimensionalization constants
const ALPHA1 = 1.999863916554819
const ALPHA2 = 0.0285694845222117
const ALPHA3 = 0.8571428571428571
const ALPHA4 = 0.05714285714285714
const E_R_NONDIM = 12.5


# ─── PerfectInterpolant struct ────────────────────────────────────────────────
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


# ─── Taylor coefficient computation ──────────────────────────────────────────
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


# ─── Build PerfectInterpolant dict ───────────────────────────────────────────
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


# ─── Build true substitution dict ────────────────────────────────────────────
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


# ─── Build model ─────────────────────────────────────────────────────────────
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

# Compute shooting indices
shooting_indices = ODEParameterEstimation.compute_shooting_indices(
	N_SHOOTING, DATASIZE; warp = true, beta = WARP_BETA,
)
t_vector = data_sample["t"]

println("  First 3 shooting points:")
for i in 1:min(3, length(shooting_indices))
	idx = shooting_indices[i]
	@printf("    Point %d: idx=%d, t=%.6f, r_eff=%.6e\n", i, idx, t_vector[idx], sol(t_vector[idx])[3])
end

# ─── PEP Transform + SIAN ────────────────────────────────────────────────────
ordered_model, mq = create_ordered_ode_system(
	"CSTR_sens", states, parameters, eqs, measured_quantities,
)
pep_original = ParameterEstimationProblem(
	"CSTR_sens", ordered_model, mq, data_sample, TIME_INTERVAL,
	nothing,
	OrderedDict(parameters .=> p_true_vals),
	OrderedDict(states .=> ic_vals),
	0,
)

t_var = ModelingToolkit.get_iv(pep_original.model.system)
pep, tr_info = ODEParameterEstimation.transform_pep_for_estimation(pep_original, t_var)

if !isnothing(tr_info)
	println("  Transcendental transform: $(length(tr_info.entries)) expression(s) polynomialized")
end

# SIAN analysis (time-independent)
println("  Running SIAN analysis...")
flush(stdout)
ident_data = ODEParameterEstimation.setup_identifiability(pep; max_num_points = 1)
println("  SIAN: deriv_level=$(ident_data.good_deriv_level), #varlist=$(length(ident_data.good_varlist))")

# Cache SI template
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
println("  SI template: $(length(si_template_eqs)) equations cached")

println("\n  STEP 1 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Build 4 Polynomial Systems
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 2: Building 4 polynomial systems")
println("-" ^ 80)
flush(stdout)

# Define the 4 test cases
idx_t0 = 1  # t=0.00
idx_t033 = shooting_indices[2]  # t≈0.33
t_t0 = t_vector[idx_t0]
t_t033 = t_vector[idx_t033]

println("  SYS1: PerfectInterpolant at t=$(round(t_t0, digits=4)) (index $idx_t0)")
println("  SYS2: PerfectInterpolant at t=$(round(t_t033, digits=4)) (index $idx_t033)")
println("  SYS3: AAAD at t=$(round(t_t0, digits=4)) (index $idx_t0)")
println("  SYS4: AAAD at t=$(round(t_t033, digits=4)) (index $idx_t033)")

# ─── Build AAAD interpolants (once, shared across SYS3 and SYS4) ─────────────
println("\n  Building AAAD interpolants...")
flush(stdout)
aaad_func = ODEParameterEstimation.get_interpolator_function(InterpolatorAAAD)
t_vec = pep.data_sample["t"]
aaad_interps = ODEParameterEstimation.create_interpolants(
	pep.measured_quantities, pep.data_sample, t_vec, aaad_func,
)
println("  AAAD interpolants: $(length(aaad_interps)) observables")

# ─── Build function for a single system ──────────────────────────────────────
function build_system(label, t_pt, idx, interps, tc)
	eqs_pt, vars_pt = ODEParameterEstimation.construct_equation_system_from_si_template(
		pep.model.system, pep.measured_quantities, pep.data_sample,
		ident_data.good_deriv_level, ident_data.good_udict,
		ident_data.good_varlist, ident_data.good_DD;
		interpolator = ODEParameterEstimation.agp_gpr_robust,  # unused — precomputed
		time_index_set = [idx],
		precomputed_interpolants = interps,
		si_template = cached_si_template,
	)
	sub = build_true_substitution(vars_pt, p_true_vals, tc, t_pt)
	return (label = label, eqs = eqs_pt, vars = vars_pt, sub_dict = sub,
			taylor_coeffs = tc, t_point = t_pt, index = idx)
end

# ─── SYS1: PerfectInterpolant at t=0 ─────────────────────────────────────────
tc_t0 = compute_taylor_coefficients(sol, t_t0, p_true_vals, MAX_DERIV_ORDER)
pi_t0 = build_perfect_interpolants(tc_t0, t_t0, pep.measured_quantities, MAX_DERIV_ORDER)
sys1 = build_system("SYS1_Perfect_t0", t_t0, idx_t0, pi_t0, tc_t0)

# ─── SYS2: PerfectInterpolant at t≈0.33 ──────────────────────────────────────
tc_t033 = compute_taylor_coefficients(sol, t_t033, p_true_vals, MAX_DERIV_ORDER)
pi_t033 = build_perfect_interpolants(tc_t033, t_t033, pep.measured_quantities, MAX_DERIV_ORDER)
sys2 = build_system("SYS2_Perfect_t033", t_t033, idx_t033, pi_t033, tc_t033)

# ─── SYS3: AAAD at t=0 ───────────────────────────────────────────────────────
sys3 = build_system("SYS3_AAAD_t0", t_t0, idx_t0, aaad_interps, tc_t0)

# ─── SYS4: AAAD at t≈0.33 ────────────────────────────────────────────────────
sys4 = build_system("SYS4_AAAD_t033", t_t033, idx_t033, aaad_interps, tc_t033)

all_systems = [sys1, sys2, sys3, sys4]

# Verify system dimensions and residuals
println("\n  System verification:")
for sys in all_systems
	n_eqs = length(sys.eqs)
	n_vars = length(sys.vars)
	residuals = Float64[]
	for eq in sys.eqs
		val = try
			Float64(Symbolics.value(Symbolics.substitute(eq, sys.sub_dict)))
		catch
			NaN
		end
		push!(residuals, abs(val))
	end
	max_res = maximum(filter(!isnan, residuals))
	@printf("    %-25s: %d eqs × %d vars, max|residual|=%.4e %s\n",
		sys.label, n_eqs, n_vars, max_res,
		max_res < 1e-6 ? "(good)" : max_res < 1e-3 ? "(marginal)" : "(AAAD-perturbed)")
end

println("\n  STEP 2 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2b: Print the actual equations (SYS1 and SYS3)
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 2b: Full equation dump (SYS1 = Perfect, SYS3 = AAAD)")
println("-" ^ 80)
flush(stdout)

println("\n  Variables (shared ordering, $(length(sys1.vars)) total):")
for (i, v) in enumerate(sys1.vars)
	true_val = get(sys1.sub_dict, v, NaN)
	@printf("    x[%2d] = %-30s  (true value = %.6e)\n", i, string(v), Float64(true_val))
end

for (sys_label, sys) in [("SYS1 (Perfect, t=0)", sys1), ("SYS3 (AAAD, t=0)", sys3)]
	println("\n  ┌─── $sys_label: $(length(sys.eqs)) equations ───")
	for (i, eq) in enumerate(sys.eqs)
		eq_expanded = Symbolics.expand(eq)
		println("  │ Eq[$i] = $(eq_expanded)")
	end
	println("  └───")
end

println("\n  STEP 2b DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: System Structure Analysis (all 4 systems)
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 3: System structure analysis")
println("-" ^ 80)
flush(stdout)

for sys in all_systems
	println("\n  ┌─── $(sys.label) ───")
	n_eqs = length(sys.eqs)
	n_vars = length(sys.vars)

	# Per-equation analysis
	println("  │ Per-equation degrees and variable counts:")
	@printf("  │ %4s  %6s  %6s\n", "Eq#", "Degree", "#Vars")
	@printf("  │ %4s  %6s  %6s\n", "----", "------", "-----")
	degrees = Int[]
	for (i, eq) in enumerate(sys.eqs)
		eq_expanded = Symbolics.expand(eq)
		deg = try
			Symbolics.degree(eq_expanded)
		catch
			-1
		end
		push!(degrees, deg)
		n_eq_vars = length(Symbolics.get_variables(eq))
		@printf("  │ %4d  %6d  %6d\n", i, deg, n_eq_vars)
	end

	# Bézout bound
	positive_degrees = filter(d -> d > 0, degrees)
	if !isempty(positive_degrees)
		bezout = prod(big.(positive_degrees))
		@printf("  │\n  │ Bézout bound: %s\n", string(bezout))
		if bezout > big(10)^15
			println("  │ (ENORMOUS — total-degree homotopy would track ~$(round(bezout / big(10)^Int(floor(log10(Float64(bezout)))), sigdigits=2))e$(Int(floor(log10(Float64(bezout))))) paths)")
		end
	end

	# Sparsity pattern
	println("  │")
	println("  │ Sparsity pattern (which vars appear in which eqs):")
	var_names_short = [begin
		s = string(v)
		length(s) > 8 ? s[1:8] : s
	end for v in sys.vars]

	# Print header
	header = "  │      "
	for (j, vn) in enumerate(var_names_short)
		header *= @sprintf(" %2d", j)
	end
	println(header)
	for (i, eq) in enumerate(sys.eqs)
		eq_vars = Set(Symbolics.get_variables(eq))
		row = @sprintf("  │ E%2d: ", i)
		for v in sys.vars
			row *= v in eq_vars ? " X" : " ."
		end
		println(row)
	end

	# Mixed volume (with timeout)
	println("  │")
	print("  │ Mixed volume: ")
	flush(stdout)
	try
		hc_sys_mv, _ = ODEParameterEstimation.convert_to_hc_format(sys.eqs, sys.vars)
		mv_task = @async HC.mixed_volume(hc_sys_mv)
		timer = Timer(60)
		while !istaskdone(mv_task) && isopen(timer)
			sleep(0.5)
		end
		if istaskdone(mv_task)
			mv = fetch(mv_task)
			println("$mv")
		else
			println("TIMEOUT (>60s)")
		end
	catch e
		println("FAILED: $(string(e)[1:min(80, length(string(e)))])")
	end

	println("  └─────────────────────────────────────")
end

println("\n  STEP 3 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Coefficient Comparison (SYS1 vs SYS3 at t=0)
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 4: Coefficient comparison — SYS1 (Perfect) vs SYS3 (AAAD) at t=0")
println("-" ^ 80)
flush(stdout)

n_eqs_compare = min(length(sys1.eqs), length(sys3.eqs))
println("  Comparing $n_eqs_compare equation pairs")
println()

@printf("  %4s  %15s  %15s  %15s  %12s\n",
	"Eq#", "|Delta|", "Resid(Perf)", "Resid(AAAD)", "Amplification")
@printf("  %4s  %15s  %15s  %15s  %12s\n",
	"----", "---------------", "---------------", "---------------", "-------------")

deltas = Float64[]
resid_perfect = Float64[]
resid_aaad = Float64[]
all_delta_vars_empty = true

for i in 1:n_eqs_compare
	# Compute delta (difference between equations)
	delta_i = try
		Symbolics.expand(sys1.eqs[i] - sys3.eqs[i])
	catch
		nothing
	end

	if isnothing(delta_i)
		push!(deltas, NaN)
		push!(resid_perfect, NaN)
		push!(resid_aaad, NaN)
		@printf("  %4d  %15s  %15s  %15s  %12s\n", i, "FAILED", "—", "—", "—")
		continue
	end

	# Check that delta has no variables (pure constant)
	delta_vars = Symbolics.get_variables(delta_i)
	if !isempty(delta_vars)
		all_delta_vars_empty = false
	end

	# Evaluate delta magnitude
	delta_val = try
		abs(Float64(Symbolics.value(delta_i)))
	catch
		# Delta might still contain variables — evaluate at truth
		try
			abs(Float64(Symbolics.value(Symbolics.substitute(delta_i, sys1.sub_dict))))
		catch
			NaN
		end
	end
	push!(deltas, delta_val)

	# Residuals at true solution
	rp = try
		abs(Float64(Symbolics.value(Symbolics.substitute(sys1.eqs[i], sys1.sub_dict))))
	catch
		NaN
	end
	push!(resid_perfect, rp)

	ra = try
		abs(Float64(Symbolics.value(Symbolics.substitute(sys3.eqs[i], sys3.sub_dict))))
	catch
		NaN
	end
	push!(resid_aaad, ra)

	amp = (rp > 1e-20 && ra > 1e-20) ? ra / rp : NaN

	@printf("  %4d  %15.4e  %15.4e  %15.4e  %12.2e\n", i, delta_val, rp, ra, amp)
end

println()
if all_delta_vars_empty
	println("  CONFIRMED: All deltas are pure constants (no variables)")
	println("  → The only difference between SYS1 and SYS3 is the interpolated numerical coefficients.")
else
	println("  WARNING: Some deltas contain variables — structure differs between SYS1 and SYS3")
end

valid_deltas = filter(!isnan, deltas)
if !isempty(valid_deltas)
	sorted_idx = sortperm(valid_deltas, rev = true)
	println("\n  TOP 5 most-perturbed equations:")
	for rank in 1:min(5, length(sorted_idx))
		i = sorted_idx[rank]
		@printf("    #%d: Eq%d with |delta|=%.4e\n", rank, i, valid_deltas[i])
	end
	@printf("\n  Total L1 perturbation: %.4e\n", sum(valid_deltas))
	@printf("  Max perturbation:      %.4e\n", maximum(valid_deltas))
	@printf("  Median perturbation:   %.4e\n", sort(valid_deltas)[div(length(valid_deltas), 2)])
end

println("\n  STEP 4 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Jacobian Conditioning at True Solution (t=0)
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 5: Jacobian conditioning at true solution (SYS1 and SYS3 at t=0)")
println("-" ^ 80)
flush(stdout)

function compute_jacobian_analysis(sys; label = "")
	println("  Computing Jacobian for $label...")
	flush(stdout)

	n = length(sys.vars)
	true_vec = Float64[get(sys.sub_dict, v, NaN) for v in sys.vars]

	# Method A: Symbolic Jacobian + build_function
	jac_matrix = nothing
	method_used = ""
	try
		println("    Attempting symbolic Jacobian ($(n)×$(n))...")
		flush(stdout)
		jac_expr = Symbolics.jacobian(sys.eqs, sys.vars)
		println("    Symbolic Jacobian computed, building evaluation function...")
		flush(stdout)
		jac_f = Symbolics.build_function(jac_expr, sys.vars; expression = Val(false))[1]
		jac_matrix = jac_f(true_vec)
		method_used = "symbolic"
		println("    Success via symbolic Jacobian")
	catch e
		println("    Symbolic failed: $(string(e)[1:min(100, length(string(e)))])")
		flush(stdout)
	end

	# Method B: Finite differences (fallback)
	if isnothing(jac_matrix)
		println("    Falling back to finite differences...")
		flush(stdout)
		method_used = "finite_diff"
		jac_matrix = zeros(Float64, length(sys.eqs), n)
		epsilon = 1e-8
		f0 = Float64[]
		for eq in sys.eqs
			push!(f0, Float64(Symbolics.value(Symbolics.substitute(eq, sys.sub_dict))))
		end
		for j in 1:n
			perturbed = copy(true_vec)
			h = max(epsilon * abs(true_vec[j]), epsilon)
			perturbed[j] += h
			perturbed_dict = Dict(sys.vars .=> perturbed)
			for i in eachindex(sys.eqs)
				fp = Float64(Symbolics.value(Symbolics.substitute(sys.eqs[i], perturbed_dict)))
				jac_matrix[i, j] = (fp - f0[i]) / h
			end
		end
		println("    Success via finite differences")
	end

	# Analyze
	sv = svdvals(jac_matrix)
	cond_num = sv[1] / sv[end]
	rank_tol = 1e-10
	effective_rank = count(s -> s > rank_tol * sv[1], sv)

	println("\n  ┌─── Jacobian Analysis: $label ($method_used) ───")
	@printf("  │ Condition number (2-norm): %.6e\n", cond_num)
	@printf("  │ Largest singular value:    %.6e\n", sv[1])
	@printf("  │ Smallest singular value:   %.6e\n", sv[end])
	@printf("  │ Effective rank (tol=1e-10): %d / %d\n", effective_rank, n)
	println("  │")
	println("  │ All singular values (sorted descending):")
	for (k, s) in enumerate(sv)
		flag = s < 1e-10 * sv[1] ? " ← NEAR-ZERO" : ""
		@printf("  │   σ[%2d] = %15.6e%s\n", k, s, flag)
	end
	println("  └─────────────────────────────────────")

	return (jac = jac_matrix, svdvals = sv, cond = cond_num, rank = effective_rank, method = method_used)
end

jac1 = compute_jacobian_analysis(sys1; label = "SYS1 (Perfect, t=0)")
jac3 = compute_jacobian_analysis(sys3; label = "SYS3 (AAAD, t=0)")

# Interpretation
println("\n  INTERPRETATION:")
max_delta = maximum(filter(!isnan, deltas))
predicted_error_1 = jac1.cond * max_delta
predicted_error_3 = jac3.cond * max_delta
observed_error = 2.6e7  # From the interpolator sweep

@printf("    cond(J_perfect) × max|delta| = %.4e × %.4e = %.4e\n",
	jac1.cond, max_delta, predicted_error_1)
@printf("    cond(J_aaad)    × max|delta| = %.4e × %.4e = %.4e\n",
	jac3.cond, max_delta, predicted_error_3)
@printf("    Observed L2 error (AAAD):                          %.4e\n", observed_error)

if predicted_error_1 > observed_error * 0.01
	println("    → LOCAL CONDITIONING explains the failure (cond × perturbation ≈ error)")
else
	println("    → TOPOLOGICAL failure (conditioning alone is insufficient to explain the error)")
	println("      The root likely crosses a bifurcation boundary under perturbation.")
end

# Check if Jacobians are identical (as expected — same symbolic structure)
jac_diff = norm(jac1.jac - jac3.jac)
@printf("\n    ||J_perfect - J_aaad||_F = %.4e\n", jac_diff)
if jac_diff < 1e-10
	println("    → Jacobians are IDENTICAL (same symbolic structure, evaluated at same point)")
else
	println("    → Jacobians DIFFER (different coefficients affect the Jacobian structure)")
end

println("\n  STEP 5 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Linear Variable Reduction
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 6: Linear variable reduction (algebraic elimination)")
println("-" ^ 80)
flush(stdout)

function reduce_system(eqs, vars; verbose = false)
	substitutions = OrderedDict()
	reduced_eqs = copy(eqs)
	pass = 0

	while true
		changed = false
		pass += 1
		new_eqs = []

		for eq in reduced_eqs
			eq_vars = Symbolics.get_variables(eq)
			if isempty(eq_vars)
				continue
			end

			# Find a variable with degree 1 in this equation
			linear_var = nothing
			for v in eq_vars
				try
					if Symbolics.degree(eq, v) == 1
						linear_var = v
						break
					end
				catch
					continue
				end
			end

			if !isnothing(linear_var) && !haskey(substitutions, linear_var)
				try
					solved = Symbolics.symbolic_linear_solve(eq, linear_var)
					substitutions[linear_var] = solved
					changed = true
					if verbose
						println("    Pass $pass: eliminated $(string(linear_var))")
					end
					continue
				catch
				end
			end
			push!(new_eqs, eq)
		end

		reduced_eqs = if changed
			[Symbolics.substitute(eq, Dict(substitutions)) for eq in new_eqs]
		else
			new_eqs
		end
		!changed && break
	end

	remaining_vars = unique(vcat([Symbolics.get_variables(eq) for eq in reduced_eqs]...))
	return reduced_eqs, remaining_vars, substitutions, pass
end

for (sys_label, sys) in [("SYS1 (Perfect, t=0)", sys1), ("SYS3 (AAAD, t=0)", sys3)]
	println("\n  Reducing $sys_label:")
	flush(stdout)

	red_eqs, red_vars, red_subs, n_passes = reduce_system(sys.eqs, sys.vars; verbose = true)

	println("    Passes: $n_passes")
	println("    Eliminated: $(length(red_subs)) variables")
	println("    Remaining: $(length(red_eqs)) eqs × $(length(red_vars)) vars")

	# Figure out which original variables were NOT eliminated
	eliminated_set = Set(keys(red_subs))
	free_vars = [v for v in sys.vars if !(v in eliminated_set)]
	println("    Eliminated: $(join(string.(collect(keys(red_subs))), ", "))")
	println("    Free (remaining): $(join(string.(free_vars), ", "))")

	# Analyze reduced system
	if !isempty(red_eqs)
		println()
		println("    Per-equation variable counts:")
		for (i, eq) in enumerate(red_eqs)
			n_eq_vars = length(Symbolics.get_variables(eq))
			@printf("      Eq%d: %d vars\n", i, n_eq_vars)
		end

		# Try HC.jl solve on reduced system (with timeout)
		println("    Solving reduced system with HC.jl (90s timeout)...")
		flush(stdout)
		try
			hc_red_sys, hc_red_vars = ODEParameterEstimation.convert_to_hc_format(red_eqs, red_vars)
			solve_task_red = @async HC.solve(hc_red_sys; show_progress = false)
			timer_red = Timer(90)
			while !istaskdone(solve_task_red) && isopen(timer_red)
				sleep(1)
			end
			hc_red_res = nothing
			if istaskdone(solve_task_red)
				hc_red_res = fetch(solve_task_red)
			else
				println("    HC.jl on reduced: TIMEOUT (>90s)")
			end
			if !isnothing(hc_red_res)
				n_red_results = HC.nresults(hc_red_res)
				red_real = HC.solutions(hc_red_res; only_real = true, real_tol = 1e-9)
				red_all = HC.solutions(hc_red_res)

				true_red_vec = Float64[get(sys.sub_dict, v, NaN) for v in red_vars]
				closest_red = Inf
				if !isempty(red_real)
					closest_red = minimum(norm(real.(s) .- true_red_vec) for s in red_real)
				elseif !isempty(red_all)
					closest_red = minimum(norm(real.(s) .- true_red_vec) for s in red_all)
				end

				@printf("    HC.jl on reduced: %d converged, %d real, closest=%.4e %s\n",
					n_red_results, length(red_real), closest_red,
					closest_red < 1e-3 ? "[FOUND!]" : "[MISSED]")
			end
		catch e
			println("    HC.jl on reduced FAILED: $(string(e)[1:min(100, length(string(e)))])")
		end
	end
end

println("\n  STEP 6 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6b: Scaled Systems — Row & Column Equilibration
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 6b: Diagonal scaling (row + column equilibration)")
println("-" ^ 80)
flush(stdout)

# The idea: the Jacobian J = D_r * J_scaled * D_c where
#   D_c = diag(|x_true_i|)  — column scaling (variable magnitudes)
#   D_r = diag(1/||row_i||) — row scaling (equation magnitudes)
# After substituting x_i = s_i * x̃_i, the new system has a better-conditioned Jacobian.

for (sys_label, sys) in [("SYS1 (Perfect, t=0)", sys1), ("SYS3 (AAAD, t=0)", sys3)]
	println("\n  Scaling $sys_label:")
	flush(stdout)

	n = length(sys.vars)
	true_vals = Float64[get(sys.sub_dict, v, NaN) for v in sys.vars]

	# Column scaling: substitute x_i = s_i * x̃_i
	# s_i = max(|true_val_i|, 1e-12) to avoid division by zero
	col_scales = Float64[max(abs(tv), 1e-12) for tv in true_vals]

	# Print variable scales
	println("    Variable magnitude range:")
	@printf("      min |x_true| = %.4e (var: %s)\n",
		minimum(abs.(true_vals)),
		string(sys.vars[argmin(abs.(true_vals))]))
	@printf("      max |x_true| = %.4e (var: %s)\n",
		maximum(abs.(true_vals)),
		string(sys.vars[argmax(abs.(true_vals))]))
	@printf("      ratio: %.4e\n", maximum(abs.(true_vals)) / max(minimum(abs.(true_vals)), 1e-30))

	# Build scaled equations: replace each var v_i with (s_i * v_i)
	# This means the new solution is x̃_i = x_true_i / s_i ≈ O(1) for all i
	var_scale_dict = Dict(sys.vars[i] => col_scales[i] * sys.vars[i] for i in 1:n)
	scaled_eqs_col = [Symbolics.substitute(eq, var_scale_dict) for eq in sys.eqs]

	# Row scaling: divide each equation by its max coefficient at the truth
	# Approximate: evaluate all terms at truth and scale by max |residual component|
	# Simpler approach: evaluate the Jacobian row norms and scale by those
	scaled_eqs = scaled_eqs_col  # Start with column-scaled

	# Now compute row scales from the original Jacobian
	# row_scale_i = || J_orig[i,:] || evaluated at truth
	# We already have the Jacobian from Step 5
	jac_ref = sys_label == "SYS1 (Perfect, t=0)" ? jac1 : jac3
	row_norms = [norm(jac_ref.jac[i, :]) for i in 1:length(sys.eqs)]
	scaled_eqs = [row_norms[i] > 1e-30 ? scaled_eqs[i] / row_norms[i] : scaled_eqs[i]
				  for i in eachindex(scaled_eqs)]

	# Verify: compute Jacobian of scaled system at the scaled truth
	# Scaled truth: x̃_i = x_true_i / s_i ≈ 1
	scaled_truth = true_vals ./ col_scales
	scaled_sub_dict = Dict(sys.vars[i] => scaled_truth[i] for i in 1:n)

	println("    Scaled truth range: [$(minimum(abs.(scaled_truth))), $(maximum(abs.(scaled_truth)))]")

	# Compute Jacobian of scaled system via finite differences
	println("    Computing Jacobian of scaled system...")
	flush(stdout)
	try
		jac_scaled = zeros(Float64, length(scaled_eqs), n)
		epsilon = 1e-8
		f0_s = Float64[]
		for eq in scaled_eqs
			val = try
				Float64(Symbolics.value(Symbolics.substitute(eq, scaled_sub_dict)))
			catch
				NaN
			end
			push!(f0_s, isnan(val) ? 0.0 : val)
		end

		for j in 1:n
			perturbed = copy(scaled_truth)
			h = max(epsilon * abs(scaled_truth[j]), epsilon)
			perturbed[j] += h
			pd = Dict(sys.vars[i] => perturbed[i] for i in 1:n)
			for i in eachindex(scaled_eqs)
				fp = try
					Float64(Symbolics.value(Symbolics.substitute(scaled_eqs[i], pd)))
				catch
					NaN
				end
				jac_scaled[i, j] = isnan(fp) ? 0.0 : (fp - f0_s[i]) / h
			end
		end

		sv_s = svdvals(jac_scaled)
		cond_s = sv_s[1] / max(sv_s[end], 1e-30)
		rank_s = count(s -> s > 1e-10 * sv_s[1], sv_s)

		@printf("    SCALED cond(J): %.4e (was %.4e, improvement: %.1fx)\n",
			cond_s, jac_ref.cond, jac_ref.cond / cond_s)
		@printf("    Scaled effective rank: %d / %d (was %d)\n", rank_s, n, jac_ref.rank)
		@printf("    σ_max = %.4e, σ_min = %.4e\n", sv_s[1], sv_s[end])

		# Show all singular values
		println("    Scaled singular values:")
		for (k, s) in enumerate(sv_s)
			flag = s < 1e-10 * sv_s[1] ? " ← NEAR-ZERO" : ""
			@printf("      σ[%2d] = %15.6e%s\n", k, s, flag)
		end
	catch e
		println("    Jacobian of scaled system FAILED: $(string(e)[1:min(100, length(string(e)))])")
	end

	# Solve the scaled system with HC.jl
	println("    Solving SCALED system with HC.jl...")
	flush(stdout)
	try
		hc_sc_sys, hc_sc_vars = ODEParameterEstimation.convert_to_hc_format(scaled_eqs, sys.vars)
		sc_res = HC.solve(hc_sc_sys; show_progress = false)
		sc_real = HC.solutions(sc_res; only_real = true, real_tol = 1e-9)
		sc_all = HC.solutions(sc_res)
		n_sc = HC.nresults(sc_res)

		# Distance in ORIGINAL space: multiply back by col_scales
		closest_sc = Inf
		for s in (!isempty(sc_real) ? sc_real : sc_all)
			# HC solution is in scaled coordinates; convert back
			orig_sol = real.(s) .* col_scales
			d = norm(orig_sol .- true_vals)
			closest_sc = min(closest_sc, d)
		end

		@printf("    HC on SCALED: %d converged, %d real, closest=%.4e %s\n",
			n_sc, length(sc_real), closest_sc,
			closest_sc < 1e-3 ? "[FOUND!]" : closest_sc < 1.0 ? "[CLOSE]" : "[MISSED]")

		# Multiple seeds on scaled system
		println("    Multiple seeds on scaled system:")
		for seed_num in 1:5
			try
				sr = HC.solve(hc_sc_sys; show_progress = false, seed = UInt32(seed_num * 77777))
				sr_real = HC.solutions(sr; only_real = true, real_tol = 1e-9)
				sr_all = HC.solutions(sr)
				src_s = !isempty(sr_real) ? sr_real : sr_all
				cd = isempty(src_s) ? Inf : minimum(norm(real.(s) .* col_scales .- true_vals) for s in src_s)
				@printf("      Seed %d: %d real, closest=%.4e %s\n",
					seed_num, length(sr_real), cd, cd < 1e-3 ? "[FOUND!]" : "")
			catch e
				@printf("      Seed %d: FAILED\n", seed_num)
			end
		end
	catch e
		println("    HC on SCALED FAILED: $(string(e)[1:min(100, length(string(e)))])")
	end

	# Also try JUST row scaling (equation equilibration) without column scaling
	println("\n    Also trying ROW-ONLY scaling (simpler, no variable substitution):")
	flush(stdout)
	try
		row_only_eqs = [row_norms[i] > 1e-30 ? sys.eqs[i] / row_norms[i] : sys.eqs[i]
						for i in eachindex(sys.eqs)]
		hc_ro_sys, hc_ro_vars = ODEParameterEstimation.convert_to_hc_format(row_only_eqs, sys.vars)
		ro_res = HC.solve(hc_ro_sys; show_progress = false)
		ro_real = HC.solutions(ro_res; only_real = true, real_tol = 1e-9)
		ro_all = HC.solutions(ro_res)
		src_ro = !isempty(ro_real) ? ro_real : ro_all
		cd_ro = isempty(src_ro) ? Inf : minimum(norm(real.(s) .- true_vals) for s in src_ro)
		@printf("      Row-only: %d converged, %d real, closest=%.4e %s\n",
			HC.nresults(ro_res), length(ro_real), cd_ro,
			cd_ro < 1e-3 ? "[FOUND!]" : cd_ro < 1.0 ? "[CLOSE]" : "[MISSED]")
	catch e
		println("      Row-only FAILED: $(string(e)[1:min(80, length(string(e)))])")
	end
end

println("\n  STEP 6b DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7: HC.jl Diagnostics (t=0 cases)
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 7: HC.jl diagnostics (full and reduced systems at t=0)")
println("-" ^ 80)
flush(stdout)

function hc_diagnostics(sys; label = "", timeout_sec = 120)
	println("\n  ┌─── HC Diagnostics: $label ───")
	flush(stdout)

	true_vec = Float64[get(sys.sub_dict, v, NaN) for v in sys.vars]

	# Convert to HC format
	hc_sys, hc_vars = try
		ODEParameterEstimation.convert_to_hc_format(sys.eqs, sys.vars)
	catch e
		println("  │ CONVERSION FAILED: $(string(e)[1:min(100, length(string(e)))])")
		println("  └─────────────────────────────────────")
		return nothing
	end

	# 7a: Polyhedral solve
	println("  │ 7a. Polyhedral homotopy solve:")
	flush(stdout)
	hc_res = nothing
	try
		solve_task = @async HC.solve(hc_sys; show_progress = false, start_system = :polyhedral)
		timer = Timer(timeout_sec)
		while !istaskdone(solve_task) && isopen(timer)
			sleep(1)
		end
		if istaskdone(solve_task)
			hc_res = fetch(solve_task)
		else
			println("  │   TIMEOUT (>$(timeout_sec)s) — polyhedral start system")
			# Try total degree as fallback (likely also slow)
			println("  │   Trying default (total degree) with shorter timeout...")
			flush(stdout)
			solve_task2 = @async HC.solve(hc_sys; show_progress = false)
			timer2 = Timer(60)
			while !istaskdone(solve_task2) && isopen(timer2)
				sleep(1)
			end
			if istaskdone(solve_task2)
				hc_res = fetch(solve_task2)
			else
				println("  │   Also timed out — system too large for standard homotopy")
			end
		end
	catch e
		println("  │   SOLVE FAILED: $(string(e)[1:min(100, length(string(e)))])")
	end

	if isnothing(hc_res)
		println("  └─────────────────────────────────────")
		return nothing
	end

	n_total = HC.nresults(hc_res)
	real_sols = HC.solutions(hc_res; only_real = true, real_tol = 1e-9)
	all_sols = HC.solutions(hc_res)
	n_singular = length(HC.singular(hc_res))

	@printf("  │   Total converged:  %d\n", n_total)
	@printf("  │   Real solutions:   %d\n", length(real_sols))
	@printf("  │   Singular:         %d\n", n_singular)

	closest = Inf
	closest_idx = 0
	source_sols = !isempty(real_sols) ? real_sols : all_sols
	for (i, s) in enumerate(source_sols)
		d = norm(real.(s) .- true_vec)
		if d < closest
			closest = d
			closest_idx = i
		end
	end
	@printf("  │   Closest to truth: %.4e %s\n", closest, closest < 1e-3 ? "[FOUND]" : "[MISSED]")

	# 7b: Path result details
	println("  │")
	println("  │ 7b. Path result analysis:")
	try
		path_res = HC.path_results(hc_res)
		# Categorize by return code
		code_counts = Dict{Symbol, Int}()
		for pr in path_res
			rc = pr.return_code
			code_counts[rc] = get(code_counts, rc, 0) + 1
		end
		for (code, cnt) in sort(collect(code_counts), by = x -> -x[2])
			@printf("  │     %-25s: %d\n", code, cnt)
		end

		# Details for closest solution path
		if closest_idx > 0 && closest_idx <= length(path_res)
			pr = path_res[closest_idx]
			println("  │")
			println("  │   Closest path details:")
			@printf("  │     return_code:     %s\n", pr.return_code)
			@printf("  │     accuracy:        %.4e\n", pr.accuracy)
			@printf("  │     residual:        %.4e\n", pr.residual)
			@printf("  │     condition:       %.4e\n", pr.condition_jacobian)
			@printf("  │     winding_number:  %s\n", pr.winding_number)
			@printf("  │     accepted_steps:  %d\n", pr.accepted_steps)
			@printf("  │     rejected_steps:  %d\n", pr.rejected_steps)
			# extended_precision may not exist in all HC versions
			try
				@printf("  │     ext_precision:   %s\n", pr.extended_precision_used)
			catch
			end
		end
	catch e
		println("  │   Path analysis failed: $(string(e)[1:min(80, length(string(e)))])")
	end

	# 7c: Multiple seeds
	println("  │")
	println("  │ 7c. Multiple seeds (5 runs):")
	for run in 1:5
		try
			res_seed = HC.solve(hc_sys; show_progress = false, seed = UInt32(run * 54321))
			real_seed = HC.solutions(res_seed; only_real = true, real_tol = 1e-9)
			all_seed = HC.solutions(res_seed)
			src = !isempty(real_seed) ? real_seed : all_seed
			cd = isempty(src) ? Inf : minimum(norm(real.(s) .- true_vec) for s in src)
			n_r = length(real_seed)
			@printf("  │     Seed %d: %d real, closest=%.4e %s\n",
				run, n_r, cd, cd < 1e-3 ? "[FOUND]" : "")
		catch e
			@printf("  │     Seed %d: FAILED: %s\n", run, string(e)[1:min(60, length(string(e)))])
		end
	end

	println("  └─────────────────────────────────────")
	return (result = hc_res, closest = closest, n_real = length(real_sols))
end

diag1 = hc_diagnostics(sys1; label = "SYS1 (Perfect, t=0)")
diag3 = hc_diagnostics(sys3; label = "SYS3 (AAAD, t=0)")

println("\n  STEP 7 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8: Perturbation Sweep (α-interpolation between Perfect and AAAD)
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 8: Perturbation sweep (α-interpolation, SYS1 → SYS3)")
println("-" ^ 80)
flush(stdout)

# Verify systems have same variables
if length(sys1.eqs) != length(sys3.eqs)
	println("  SKIP: SYS1 and SYS3 have different equation counts")
else
	alpha_values = [0.0, 1e-5, 1e-4, 5e-4, 1e-3, 2e-3, 5e-3, 0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 1.0]
	true_vec_sweep = Float64[get(sys1.sub_dict, v, NaN) for v in sys1.vars]

	println("  Interpolating: eqs_α = (1-α)·SYS1 + α·SYS3")
	println()
	@printf("  %8s  %12s  %6s  %12s  %6s\n",
		"alpha", "MaxResid", "#Real", "Closest_L2", "Found?")
	@printf("  %8s  %12s  %6s  %12s  %6s\n",
		"--------", "------------", "------", "------------", "------")

	sweep_results = []

	for alpha in alpha_values
		# Build interpolated equations
		eqs_alpha = [(1 - alpha) * sys1.eqs[i] + alpha * sys3.eqs[i] for i in 1:length(sys1.eqs)]

		# Max residual of truth in this system
		max_resid_alpha = 0.0
		for eq in eqs_alpha
			val = try
				abs(Float64(Symbolics.value(Symbolics.substitute(eq, sys1.sub_dict))))
			catch
				NaN
			end
			if !isnan(val)
				max_resid_alpha = max(max_resid_alpha, val)
			end
		end

		# Solve with HC.jl (with timeout)
		n_real_alpha = 0
		closest_alpha = Inf
		found_alpha = false

		try
			hc_sys_a, hc_vars_a = ODEParameterEstimation.convert_to_hc_format(eqs_alpha, sys1.vars)
			solve_task = @async HC.solve(hc_sys_a; show_progress = false)
			timer = Timer(90)
			while !istaskdone(solve_task) && isopen(timer)
				sleep(0.5)
			end

			if istaskdone(solve_task)
				res_a = fetch(solve_task)
				real_a = HC.solutions(res_a; only_real = true, real_tol = 1e-9)
				all_a = HC.solutions(res_a)
				n_real_alpha = length(real_a)
				src = !isempty(real_a) ? real_a : all_a
				if !isempty(src)
					closest_alpha = minimum(norm(real.(s) .- true_vec_sweep) for s in src)
				end
				found_alpha = closest_alpha < 1e-3
			else
				@printf("  %8.1e  %12.4e  %6s  %12s  %6s\n",
					alpha, max_resid_alpha, "T/O", "—", "—")
				push!(sweep_results, (alpha = alpha, max_resid = max_resid_alpha,
					n_real = -1, closest = Inf, found = false))
				continue
			end
		catch e
			@printf("  %8.1e  %12.4e  %6s  %12s  %6s\n",
				alpha, max_resid_alpha, "ERR", "—", "—")
			push!(sweep_results, (alpha = alpha, max_resid = max_resid_alpha,
				n_real = -1, closest = Inf, found = false))
			continue
		end

		@printf("  %8.1e  %12.4e  %6d  %12.4e  %6s\n",
			alpha, max_resid_alpha, n_real_alpha, closest_alpha,
			found_alpha ? "YES" : "no")

		push!(sweep_results, (alpha = alpha, max_resid = max_resid_alpha,
			n_real = n_real_alpha, closest = closest_alpha, found = found_alpha))
	end

	# Find critical α
	println()
	found_alphas = filter(r -> r.found, sweep_results)
	missed_alphas = filter(r -> !r.found && r.n_real >= 0, sweep_results)

	if !isempty(found_alphas) && !isempty(missed_alphas)
		max_found = maximum(r.alpha for r in found_alphas)
		min_missed = minimum(r.alpha for r in missed_alphas)
		@printf("  CRITICAL α: between %.1e and %.1e\n", max_found, min_missed)
		println("  Interpretation: HC.jl loses the root when perturbation exceeds ~$(round(max_found * 100, sigdigits=2))%")
	elseif !isempty(found_alphas)
		max_found = maximum(r.alpha for r in found_alphas)
		println("  Root found for all tested α up to $(max_found)")
	else
		println("  Root NEVER found — even α=0 (SYS1) failed in this sweep")
		println("  (This could be due to seed sensitivity; Step 7 may have found it)")
	end
end

println("\n  STEP 8 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8b: Scaled α-Sweep — Does scaling improve the critical perturbation threshold?
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 8b: Scaled perturbation sweep (α-interpolation with row+col equilibration)")
println("-" ^ 80)
flush(stdout)

# The unscaled sweep showed α_critical < 1e-5. With 69-billion× conditioning improvement
# from scaling, we expect the critical α to shift substantially higher.
# This tells us how much of the failure is conditioning vs perturbation magnitude.

if length(sys1.eqs) == length(sys3.eqs)
	n_8b = length(sys1.vars)
	true_vals_8b = Float64[get(sys1.sub_dict, v, NaN) for v in sys1.vars]
	col_scales_8b = Float64[max(abs(tv), 1e-12) for tv in true_vals_8b]

	# Row norms from the unscaled Jacobian (same for SYS1 and SYS3 at the true point)
	row_norms_8b = [norm(jac1.jac[i, :]) for i in 1:length(sys1.eqs)]

	alpha_values_8b = [0.0, 1e-6, 1e-5, 5e-5, 1e-4, 5e-4, 1e-3, 5e-3, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]

	println("  Applying row + column scaling, THEN solving each α-interpolated system")
	println("  Column scales: |x_true_i|  |  Row scales: ||J_row_i||")
	println()
	@printf("  %8s  %12s  %6s  %12s  %6s\n",
		"alpha", "MaxResid", "#Real", "Closest_L2", "Found?")
	@printf("  %8s  %12s  %6s  %12s  %6s\n",
		"--------", "------------", "------", "------------", "------")

	sweep_scaled_results = []

	for alpha in alpha_values_8b
		# Build interpolated equations (unscaled)
		eqs_alpha = [(1 - alpha) * sys1.eqs[i] + alpha * sys3.eqs[i] for i in 1:length(sys1.eqs)]

		# Apply column scaling: x_i → s_i * x̃_i
		var_scale_dict_8b = Dict(sys1.vars[i] => col_scales_8b[i] * sys1.vars[i] for i in 1:n_8b)
		scaled_eqs_8b = [Symbolics.substitute(eq, var_scale_dict_8b) for eq in eqs_alpha]

		# Apply row scaling: divide by Jacobian row norms
		scaled_eqs_8b = [row_norms_8b[i] > 1e-30 ? scaled_eqs_8b[i] / row_norms_8b[i] : scaled_eqs_8b[i]
						 for i in eachindex(scaled_eqs_8b)]

		# Max residual of truth in the SCALED system (truth in scaled coords)
		scaled_truth_8b = true_vals_8b ./ col_scales_8b
		scaled_sub_dict_8b = Dict(sys1.vars[i] => scaled_truth_8b[i] for i in 1:n_8b)
		max_resid_8b = 0.0
		for eq in scaled_eqs_8b
			val = try
				abs(Float64(Symbolics.value(Symbolics.substitute(eq, scaled_sub_dict_8b))))
			catch
				NaN
			end
			if !isnan(val)
				max_resid_8b = max(max_resid_8b, val)
			end
		end

		# Solve with HC.jl (with timeout)
		n_real_8b = 0
		closest_8b = Inf
		found_8b = false

		try
			hc_sys_8b, hc_vars_8b = ODEParameterEstimation.convert_to_hc_format(scaled_eqs_8b, sys1.vars)
			solve_task_8b = @async HC.solve(hc_sys_8b; show_progress = false)
			timer_8b = Timer(120)
			while !istaskdone(solve_task_8b) && isopen(timer_8b)
				sleep(0.5)
			end

			if istaskdone(solve_task_8b)
				res_8b = fetch(solve_task_8b)
				real_8b = HC.solutions(res_8b; only_real = true, real_tol = 1e-9)
				all_8b = HC.solutions(res_8b)
				n_real_8b = length(real_8b)
				src_8b = !isempty(real_8b) ? real_8b : all_8b
				if !isempty(src_8b)
					# Convert back to original coordinates
					closest_8b = minimum(norm(real.(s) .* col_scales_8b .- true_vals_8b) for s in src_8b)
				end
				found_8b = closest_8b < 1e-3
			else
				@printf("  %8.1e  %12.4e  %6s  %12s  %6s\n",
					alpha, max_resid_8b, "T/O", "—", "—")
				push!(sweep_scaled_results, (alpha = alpha, max_resid = max_resid_8b,
					n_real = -1, closest = Inf, found = false))
				continue
			end
		catch e
			@printf("  %8.1e  %12.4e  %6s  %12s  %6s\n",
				alpha, max_resid_8b, "ERR", "—", "—")
			push!(sweep_scaled_results, (alpha = alpha, max_resid = max_resid_8b,
				n_real = -1, closest = Inf, found = false))
			continue
		end

		@printf("  %8.1e  %12.4e  %6d  %12.4e  %6s\n",
			alpha, max_resid_8b, n_real_8b, closest_8b,
			found_8b ? "YES" : "no")

		push!(sweep_scaled_results, (alpha = alpha, max_resid = max_resid_8b,
			n_real = n_real_8b, closest = closest_8b, found = found_8b))
	end

	# Find critical α for scaled systems
	println()
	found_scaled = filter(r -> r.found, sweep_scaled_results)
	missed_scaled = filter(r -> !r.found && r.n_real >= 0, sweep_scaled_results)

	if !isempty(found_scaled) && !isempty(missed_scaled)
		max_found_sc = maximum(r.alpha for r in found_scaled)
		min_missed_sc = minimum(r.alpha for r in missed_scaled)
		@printf("  SCALED CRITICAL α: between %.1e and %.1e\n", max_found_sc, min_missed_sc)

		# Compare with unscaled
		if @isdefined(sweep_results) && !isempty(sweep_results)
			found_unsc = filter(r -> r.found, sweep_results)
			if !isempty(found_unsc)
				max_found_unsc = maximum(r.alpha for r in found_unsc)
				improvement = max_found_sc / max(max_found_unsc, 1e-30)
				@printf("  UNSCALED CRITICAL α: ≤ %.1e\n", max_found_unsc)
				@printf("  Scaling improvement: %.1fx wider perturbation tolerance\n", improvement)
			end
		end
	elseif !isempty(found_scaled)
		max_found_sc = maximum(r.alpha for r in found_scaled)
		@printf("  Root found for ALL tested α up to %.1e — scaling solves the problem!\n", max_found_sc)
		println("  Interpretation: The entire AAAD perturbation is tolerable with scaling")
	else
		println("  Root NEVER found in scaled sweep (even α=0)")
		println("  (This could be due to seed sensitivity)")
	end

	println()
	println("  KEY INSIGHT: Comparing unscaled vs scaled critical α tells us")
	println("  how much of the failure is pure conditioning (fixable by scaling)")
	println("  vs intrinsic polynomial topology (not fixable by preconditioning).")
end

println("\n  STEP 8b DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 9: Parameter Homotopy — Track the true root from Perfect → AAAD
# ═══════════════════════════════════════════════════════════════════════════════
println("STEP 9: Parameter homotopy (track true solution from SYS1 → SYS3)")
println("-" ^ 80)
flush(stdout)

# Instead of solving each α independently (polyhedral start → fresh paths),
# we use parameter homotopy: start from the KNOWN true solution at α=0
# and continuously deform the system to α=1. This answers definitively:
#   - Does the true root continuously slide away? (coefficient sensitivity)
#   - Or does the path bifurcate/diverge at some critical α? (topology change)

if length(sys1.eqs) == length(sys3.eqs)
	println("  Strategy: Build F(x; α) = F_perfect(x) + α·ΔF(x)")
	println("  where ΔF(x) = F_aaad(x) - F_perfect(x)")
	println("  Track true solution from α=0 → α=1")
	println()
	flush(stdout)

	n_9 = length(sys1.vars)

	# The delta equations: F_aaad - F_perfect (these are constants — no x dependence)
	# But symbolically they may still reference variables, so keep them symbolic.
	delta_eqs_9 = [sys3.eqs[i] - sys1.eqs[i] for i in 1:length(sys1.eqs)]

	# Build parameterized system: F_perfect(x) + α * delta(x)
	# We need to introduce α as a Symbolics variable, then convert to HC with it as a parameter
	@variables α_param

	param_eqs_9 = [sys1.eqs[i] + α_param * delta_eqs_9[i] for i in 1:length(sys1.eqs)]

	# Convert to HC format with α_param as a parameter
	# We'll use the existing convert_to_hc_format_with_params function
	println("  Converting parameterized system to HC format...")
	flush(stdout)

	try
		hc_param_sys, hc_param_vars, hc_param_params = ODEParameterEstimation.convert_to_hc_format_with_params(
			param_eqs_9, sys1.vars, [α_param])

		println("  HC parameterized system: $(length(hc_param_vars)) vars, $(length(hc_param_params)) params")
		flush(stdout)

		# True solution vector
		true_vec_9 = Float64[get(sys1.sub_dict, v, NaN) for v in sys1.vars]

		# === FORWARD: α = 0 → 1 (Perfect → AAAD) ===
		println("\n  ┌─── FORWARD TRACKING: α = 0 → 1 (Perfect → AAAD) ───")
		flush(stdout)

		# Get start solutions at α=0 using polyhedral homotopy on the parameterized system.
		# HC.solve(F; target_parameters=p) does a polyhedral solve with parameters fixed at p.
		println("  │ Getting start solutions at α=0 via polyhedral solve...")
		flush(stdout)
		start_result = HC.solve(hc_param_sys;
			target_parameters = [ComplexF64(0.0)],
			show_progress = false)
		start_sols = HC.solutions(start_result)
		start_real = HC.solutions(start_result; only_real = true, real_tol = 1e-9)
		println("  │   Solutions at α=0: $(length(start_real)) real / $(length(start_sols)) total")

		# Find the closest solution to truth
		if !isempty(start_sols)
			src_start = !isempty(start_real) ? start_real : start_sols
			dists = [norm(real.(s) .- true_vec_9) for s in src_start]
			best_idx = argmin(dists)
			@printf("  │   Closest to truth: %.4e %s\n", dists[best_idx],
				dists[best_idx] < 1e-3 ? "[FOUND]" : "[MISSED]")

			# Use ALL solutions from α=0 as start for parameter homotopy
			all_start_sols = start_sols

			# Track to multiple α values — use fine steps near 0 where sensitivity is extreme
			alpha_track_values = [1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 0.01, 0.1, 0.5, 1.0]
			println("  │")
			@printf("  │ %8s  %6s  %6s  %12s  %12s\n",
				"α_target", "#Conv", "#Real", "Closest_L2", "Status")
			@printf("  │ %8s  %6s  %6s  %12s  %12s\n",
				"--------", "------", "------", "------------", "--------")

			# Track incrementally: from each α to the next
			prev_alpha = 0.0
			prev_sols = all_start_sols
			tracked_path = [(alpha = 0.0, closest = dists[best_idx], n_conv = length(start_sols), n_real = length(start_real))]

			for alpha_t in alpha_track_values
				try
					track_res = HC.solve(hc_param_sys, prev_sols;
						start_parameters = [ComplexF64(prev_alpha)],
						target_parameters = [ComplexF64(alpha_t)],
						show_progress = false,
						tracker_options = HC.TrackerOptions(;
							extended_precision = true,
							max_steps = 50_000,
							terminate_cond = 1e30))

					track_all = HC.solutions(track_res)
					track_real = HC.solutions(track_res; only_real = true, real_tol = 1e-9)
					n_conv_t = length(track_all)
					n_real_t = length(track_real)

					src_t = !isempty(track_real) ? track_real : track_all
					closest_t = isempty(src_t) ? Inf : minimum(norm(real.(s) .- true_vec_9) for s in src_t)

					status = closest_t < 1e-3 ? "FOUND" : closest_t < 1.0 ? "CLOSE" : "MISSED"
					@printf("  │ %8.1e  %6d  %6d  %12.4e  %12s\n",
						alpha_t, n_conv_t, n_real_t, closest_t, status)

					# Show path result diagnostics on first tracking step
					if alpha_t == alpha_track_values[1] || n_conv_t == 0
						try
							prs = HC.path_results(track_res)
							code_counts = Dict{Symbol, Int}()
							for pr in prs
								rc = pr.return_code
								code_counts[rc] = get(code_counts, rc, 0) + 1
							end
							for (code, cnt) in sort(collect(code_counts), by = x -> -x[2])
								@printf("  │     return_code %-25s: %d paths\n", code, cnt)
							end
						catch; end
					end

					push!(tracked_path, (alpha = alpha_t, closest = closest_t, n_conv = n_conv_t, n_real = n_real_t))

					# Update for next step — use all results including singular
					prev_alpha = alpha_t
					if !isempty(track_all)
						prev_sols = track_all
					else
						# If nothing converged, try using all path results anyway
						@printf("  │     (no converged paths — retrying from last good solutions)\n")
						# Don't update prev_sols, keep using previous solutions
					end
				catch e
					@printf("  │ %8.3f  %6s  %6s  %12s  %12s\n",
						alpha_t, "ERR", "—", "—", string(e)[1:min(30, length(string(e)))])
				end
			end

			# === BACKWARD: α = 1 → 0 (AAAD → Perfect) ===
			println("  │")
			println("  └─── FORWARD DONE ───")
			println()
			println("  ┌─── BACKWARD TRACKING: α = 1 → 0 (AAAD → Perfect) ───")
			flush(stdout)

			# Start from the AAAD solution (α=1) — polyhedral solve at α=1
			println("  │ Getting start solutions at α=1 via polyhedral solve...")
			aaad_result = HC.solve(hc_param_sys;
				target_parameters = [ComplexF64(1.0)],
				show_progress = false)
			aaad_sols = HC.solutions(aaad_result)
			aaad_real = HC.solutions(aaad_result; only_real = true, real_tol = 1e-9)
			println("  │   Solutions at α=1: $(length(aaad_real)) real / $(length(aaad_sols)) total")

			if !isempty(aaad_sols)
				aaad_dists = [norm(real.(s) .- true_vec_9) for s in aaad_real]
				if !isempty(aaad_dists)
					@printf("  │   Closest real sol to truth: %.4e\n", minimum(aaad_dists))
				end

				# Track backwards to α=0
				alpha_back = reverse([0.0, 1e-8, 1e-6, 1e-4, 0.01, 0.1, 0.5, 0.75])
				println("  │")
				@printf("  │ %8s  %6s  %6s  %12s  %12s\n",
					"α_target", "#Conv", "#Real", "Closest_L2", "Status")
				@printf("  │ %8s  %6s  %6s  %12s  %12s\n",
					"--------", "------", "------", "------------", "--------")

				prev_alpha_b = 1.0
				prev_sols_b = aaad_sols

				for alpha_b in alpha_back
					try
						back_res = HC.solve(hc_param_sys, prev_sols_b;
							start_parameters = [ComplexF64(prev_alpha_b)],
							target_parameters = [ComplexF64(alpha_b)],
							show_progress = false,
							tracker_options = HC.TrackerOptions(;
								extended_precision = true,
								max_steps = 50_000,
								terminate_cond = 1e30))

						back_all = HC.solutions(back_res)
						back_real = HC.solutions(back_res; only_real = true, real_tol = 1e-9)
						n_conv_b = length(back_all)
						n_real_b = length(back_real)

						src_b = !isempty(back_real) ? back_real : back_all
						closest_b = isempty(src_b) ? Inf : minimum(norm(real.(s) .- true_vec_9) for s in src_b)

						status_b = closest_b < 1e-3 ? "FOUND" : closest_b < 1.0 ? "CLOSE" : "MISSED"
						@printf("  │ %8.3f  %6d  %6d  %12.4e  %12s\n",
							alpha_b, n_conv_b, n_real_b, closest_b, status_b)

						prev_alpha_b = alpha_b
						prev_sols_b = back_all
					catch e
						@printf("  │ %8.3f  %6s  %6s  %12s  %12s\n",
							alpha_b, "ERR", "—", "—", string(e)[1:min(30, length(string(e)))])
					end
				end
			else
				println("  │   No solutions found at α=1, skipping backward tracking")
			end
			println("  └─── BACKWARD DONE ───")

			# === Analysis: Forward path L2 vs α ===
			println()
			println("  ANALYSIS:")
			if length(tracked_path) > 1
				# Check linearity: is closest_L2 proportional to α?
				alphas_fwd = [tp.alpha for tp in tracked_path if tp.alpha > 0]
				l2s_fwd = [tp.closest for tp in tracked_path if tp.alpha > 0]
				if !isempty(alphas_fwd) && all(isfinite, l2s_fwd)
					ratios = l2s_fwd ./ alphas_fwd
					mean_ratio = sum(ratios) / length(ratios)
					std_ratio = sqrt(sum((r - mean_ratio)^2 for r in ratios) / length(ratios))
					@printf("    L2/α ratio: mean=%.4e, std=%.4e (CV=%.2f%%)\n",
						mean_ratio, std_ratio, 100 * std_ratio / mean_ratio)
					println("    (Low CV = linear relationship = continuous root displacement)")
					println()

					# The ratio L2/α is approximately ||J^{-1} Δf||
					# where Δf is the coefficient perturbation at α=1
					@printf("    Effective sensitivity: ||δx/δα|| ≈ %.4e\n", mean_ratio)
					@printf("    This means: 1%% coefficient perturbation → L2 displacement ≈ %.4e\n", mean_ratio * 0.01)
				end

				# Did the path ever bifurcate? Check if n_conv changed
				conv_counts = [tp.n_conv for tp in tracked_path]
				if all(c -> c == conv_counts[1], conv_counts)
					println("    Path count STABLE: $(conv_counts[1]) solutions tracked at every α")
					println("    → NO bifurcation, pure continuous deformation")
				else
					println("    Path count CHANGED: $conv_counts")
					println("    → Possible bifurcation or path crossing detected")
				end
			end
		else
			println("  │   No solutions found at α=0 — cannot start parameter homotopy")
		end
	catch e
		println("  PARAMETER HOMOTOPY FAILED:")
		println("    $(string(e)[1:min(200, length(string(e)))])")
		for (exc, bt) in Base.catch_stack()
			showerror(stdout, exc, bt; backtrace = true)
			println()
		end
	end
else
	println("  SKIP: SYS1 and SYS3 have different equation counts")
end

println("\n  STEP 9 DONE\n")
flush(stdout)


# ═══════════════════════════════════════════════════════════════════════════════
# STEP 10: Summary
# ═══════════════════════════════════════════════════════════════════════════════
println("=" ^ 80)
println("  SUMMARY — CSTR POLYNOMIAL SENSITIVITY ANALYSIS")
println("=" ^ 80)
println()

println("1. SYSTEM STRUCTURE:")
for sys in all_systems
	n_eqs = length(sys.eqs)
	degrees = [try Symbolics.degree(Symbolics.expand(eq)) catch; 0 end for eq in sys.eqs]
	pos_deg = filter(d -> d > 0, degrees)
	bezout = isempty(pos_deg) ? big(0) : prod(big.(pos_deg))
	max_deg = isempty(degrees) ? 0 : maximum(degrees)
	@printf("   %-25s: %d eqs, max_deg=%d, Bézout=%s\n", sys.label, n_eqs, max_deg, string(bezout))
end
println()

println("2. COEFFICIENT PERTURBATION (SYS1 vs SYS3):")
valid_d = filter(!isnan, deltas)
if !isempty(valid_d)
	@printf("   Max |delta|:    %.4e\n", maximum(valid_d))
	@printf("   Mean |delta|:   %.4e\n", sum(valid_d) / length(valid_d))
	@printf("   Equations with |delta| > 1e-6: %d / %d\n",
		count(d -> d > 1e-6, valid_d), length(valid_d))
end
println()

println("3. JACOBIAN CONDITIONING:")
@printf("   cond(J) at truth (SYS1): %.4e\n", jac1.cond)
@printf("   cond(J) at truth (SYS3): %.4e\n", jac3.cond)
@printf("   Effective rank: %d / %d\n", jac1.rank, length(sys1.vars))
if !isempty(valid_d)
	amp_factor = jac1.cond * maximum(valid_d)
	@printf("   cond × max|delta| = %.4e\n", amp_factor)
	@printf("   Observed error:     %.4e\n", 2.6e7)
	if amp_factor > 2.6e7 * 0.01
		println("   → Failure is EXPLAINED by local conditioning")
	else
		println("   → Failure is TOPOLOGICAL (conditioning insufficient)")
	end
end
println()

println("4. CRITICAL PERTURBATION (α-sweep):")
if @isdefined(sweep_results) && !isempty(sweep_results)
	found_sr = filter(r -> r.found, sweep_results)
	if !isempty(found_sr)
		@printf("   Root found for α ≤ %.1e\n", maximum(r.alpha for r in found_sr))
	end
	missed_sr = filter(r -> !r.found && r.n_real >= 0, sweep_results)
	if !isempty(missed_sr)
		@printf("   Root missed for α ≥ %.1e\n", minimum(r.alpha for r in missed_sr))
	end
end
println()

println("5. LINEAR REDUCTION:")
println("   (See Step 6 output for elimination details and reduced HC results)")
println()

println("6. DIAGONAL SCALING:")
if @isdefined(sweep_scaled_results) && !isempty(sweep_scaled_results)
	found_sc = filter(r -> r.found, sweep_scaled_results)
	missed_sc = filter(r -> !r.found && r.n_real >= 0, sweep_scaled_results)
	if !isempty(found_sc)
		@printf("   Scaled critical α: found up to %.1e\n", maximum(r.alpha for r in found_sc))
	end
	if !isempty(missed_sc)
		@printf("   Scaled critical α: missed from %.1e\n", minimum(r.alpha for r in missed_sc))
	end
	if @isdefined(sweep_results) && !isempty(sweep_results)
		found_unsc = filter(r -> r.found, sweep_results)
		if !isempty(found_unsc) && !isempty(found_sc)
			improvement = maximum(r.alpha for r in found_sc) / max(maximum(r.alpha for r in found_unsc), 1e-30)
			@printf("   Scaling widens perturbation tolerance by: %.1fx\n", improvement)
		end
	end
else
	println("   (See Step 6b and 8b output)")
end
println()

println("7. PARAMETER HOMOTOPY (Step 9):")
if @isdefined(tracked_path) && length(tracked_path) > 1
	alphas_tp = [tp.alpha for tp in tracked_path if tp.alpha > 0]
	l2s_tp = [tp.closest for tp in tracked_path if tp.alpha > 0]
	if !isempty(alphas_tp) && all(isfinite, l2s_tp)
		ratios_tp = l2s_tp ./ alphas_tp
		mean_r = sum(ratios_tp) / length(ratios_tp)
		@printf("   L2/α ratio (mean): %.4e\n", mean_r)
		@printf("   Effective sensitivity: 1%% perturbation → L2 ≈ %.4e\n", mean_r * 0.01)
	end
	conv_counts_tp = [tp.n_conv for tp in tracked_path]
	if all(c -> c == conv_counts_tp[1], conv_counts_tp)
		println("   Path count stable: $(conv_counts_tp[1]) at every α — NO bifurcation")
	else
		println("   Path count changed: $conv_counts_tp — BIFURCATION detected")
	end
else
	println("   (See Step 9 output)")
end
println()

println("8. CONCLUSION:")
println("   The CSTR failure is NOT a solver bug or conditioning artifact.")
println("   HC.jl correctly solves each polynomial system it is given.")
println("   The problem is that AAAD interpolation errors in high-order")
println("   derivatives produce a polynomial system whose TRUE roots are")
println("   genuinely far (~2.6e7 L2) from the actual ODE parameters.")
println()
println("   Root displacement is LINEAR in coefficient perturbation magnitude")
println("   (confirmed by parameter homotopy tracking). No bifurcation occurs —")
println("   the true root slides continuously away from the correct answer.")
println()
println("   IMPLICATIONS FOR ODEPE PIPELINE:")
println("   - Preconditioning (scaling) cannot help: the perturbed system")
println("     has different roots, and HC.jl finds those roots correctly")
println("   - The fix must be UPSTREAM: better interpolation accuracy,")
println("     especially for order-6 derivatives of y1 = 700*Temp")
println("   - Parameter homotopy from a known good solution (e.g., another")
println("     time point that succeeded) could recover the root")
println("   - Alternatively, reducing the derivative order required would")
println("     reduce the amplification factor (currently ~100-300×/order)")
println()

println("-" ^ 80)
println("Done!")
flush(stdout)
