# Residual Check: Are HC solutions genuine zeros? Is the true solution a zero?
#
# This script evaluates the instantiated polynomial system at:
#   (a) Each HC solution
#   (b) The TRUE parameter/state values (computed from the ODE at the shooting point)
#   (c) The true parameters + interpolated state derivatives
#
# If HC solutions have near-zero residuals but the true solution does NOT,
# then the interpolated derivatives are wrong and HC is blameless.

using Printf
using Statistics
using LinearAlgebra

println("="^70)
println("  Residual Check: HC accuracy vs interpolation accuracy")
println("="^70)

println("\nLoading ODEParameterEstimation...")
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
const Sym = ODEParameterEstimation.Symbolics

# ─── Setup ────────────────────────────────────────────────────────────
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

model, mq = create_ordered_ode_system("BioHydrogenation", states_def, parameters_def, state_equations, measured_quantities_def)

# Load quokka data
data_path = expanduser("~/ParameterEstimationBenchmarking/benchmark_quokka_2026_03_05/filetree/data_noisy/biohydrogenation_0_0/data.csv")
csv_data = CSV.read(data_path, Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
	data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end

pep = ParameterEstimationProblem("biohydrogenation", model, mq, data_sample, [0.0, 10.0], nothing,
	OrderedDict(parameters_def .=> p_true), OrderedDict(states_def .=> ic), 0)

# ─── Run identifiability + build SI template ──────────────────────────
(t_var, eqns, states, params) = PE.unpack_ODE(pep.model.system)
t_vector = pep.data_sample["t"]

num_points_cap = min(length(params), 1, length(t_vector))
good_num_points, good_deriv_level, good_udict, good_varlist, good_DD =
	PE.determine_optimal_points_count(pep.model.system, pep.measured_quantities, num_points_cap, t_vector, true)

ordered_model = isa(pep.model.system, PE.OrderedODESystem) ?
	pep.model.system : PE.OrderedODESystem(pep.model.system, states, params)

template_equations, derivative_dict, unidentifiable, identifiable_funcs = PE.get_si_equation_system(
	ordered_model, pep.measured_quantities, pep.data_sample; DD=good_DD, infolevel=0)
si_template = (equations=template_equations, deriv_dict=derivative_dict,
	unidentifiable=unidentifiable, identifiable_funcs=identifiable_funcs)

# ─── Create interpolants ──────────────────────────────────────────────
interpolator_func = PE.get_interpolator_function(InterpolatorAGPRobust, nothing)
interpolants = PE.create_interpolants(pep.measured_quantities, pep.data_sample, t_vector, interpolator_func)

# ─── Test at multiple shooting points ─────────────────────────────────
# Also solve the ODE to get TRUE state values at each shooting point
println("\nSolving ODE to get true state trajectories...")
prob = ODEProblem(
	(du, u, p, t_val) -> begin
		x4v, x5v, x6v, x7v = u
		k5v, k6v, k7v, k8v, k9v, k10v = p
		du[1] = (-8.0*k5v*x4v) / (8.0*(4.0*k6v + 8.0*x4v))
		du[2] = ((-0.3*k7v*x5v) / (2.0*k8v + 0.5*x6v + 0.5*x5v) + (8.0*k5v*x4v) / (4.0*k6v + 8.0*x4v)) / 0.5
		du[3] = ((-0.2*(10.0*k10v - 0.5*x6v)*k9v*x6v) / (10.0*k10v) + (0.3*k7v*x5v) / (2.0*k8v + 0.5*x6v + 0.5*x5v)) / 0.5
		du[4] = (0.2*(10.0*k10v - 0.5*x6v)*k9v*x6v) / (5.0*k10v)
	end,
	ic, (0.0, 10.0), p_true
)
sol = solve(prob, Tsit5(), abstol=1e-14, reltol=1e-14, saveat=t_vector)

# ─── Helper: evaluate polynomial residuals ────────────────────────────
function evaluate_residuals(equations, varlist, values_dict)
	residuals = Float64[]
	for eq in equations
		val = Sym.substitute(eq, values_dict)
		try
			push!(residuals, Float64(Sym.value(val)))
		catch
			push!(residuals, NaN)
		end
	end
	return residuals
end

# ─── Helper: compute TRUE derivatives at a time point via ODE RHS ────
function true_derivatives_at_t(sol, p_true, t_val; max_order=6)
	# Get state values at t
	u = sol(t_val)
	x4v, x5v, x6v, x7v = u
	k5v, k6v, k7v, k8v, k9v, k10v = p_true

	# Compute RHS (first derivatives)
	dx4 = (-8.0*k5v*x4v) / (8.0*(4.0*k6v + 8.0*x4v))
	dx5 = ((-0.3*k7v*x5v) / (2.0*k8v + 0.5*x6v + 0.5*x5v) + (8.0*k5v*x4v) / (4.0*k6v + 8.0*x4v)) / 0.5
	dx6 = ((-0.2*(10.0*k10v - 0.5*x6v)*k9v*x6v) / (10.0*k10v) + (0.3*k7v*x5v) / (2.0*k8v + 0.5*x6v + 0.5*x5v)) / 0.5
	dx7 = (0.2*(10.0*k10v - 0.5*x6v)*k9v*x6v) / (5.0*k10v)

	# For higher derivatives, use numerical differentiation of the ODE solution
	h = 1e-6
	derivs = Dict{String, Vector{Float64}}()
	derivs["x4"] = [x4v]
	derivs["x5"] = [x5v]
	derivs["x6"] = [x6v]

	# Numerical higher derivatives via finite differences on ODE solution
	for var_name in ["x4", "x5", "x6"]
		var_idx = var_name == "x4" ? 1 : (var_name == "x5" ? 2 : 3)
		for order in 1:max_order
			# Use high-order central finite differences
			deriv_val = 0.0
			try
				# Central difference for nth derivative
				n = order
				coeff_h = h^n
				deriv_val = 0.0
				for k in 0:n
					sign = (-1)^(n - k)
					binom = binomial(n, k)
					t_k = t_val + (k - n/2) * h
					t_k = clamp(t_k, 0.0, 10.0)
					u_k = sol(t_k)
					deriv_val += sign * binom * u_k[var_idx]
				end
				deriv_val /= coeff_h
			catch
				deriv_val = NaN
			end
			push!(derivs[var_name], deriv_val)
		end
	end

	return derivs, Dict("k5"=>k5v, "k6"=>k6v, "k7"=>k7v, "k8"=>k8v, "k9"=>k9v, "k10"=>k10v)
end

# ─── Main loop over shooting points ──────────────────────────────────
system_solver_func = PE.get_solver_function(SolverHC)

test_points = [1, div(length(t_vector), 4), div(length(t_vector), 2),
	3*div(length(t_vector), 4), length(t_vector)]

for time_idx in test_points
	t_val = t_vector[time_idx]
	println("\n", "="^70)
	@printf("  Shooting point: t[%d] = %.4f\n", time_idx, t_val)
	println("="^70)

	# Instantiate the polynomial system
	target, varlist = PE.construct_equation_system_from_si_template(
		pep.model.system, pep.measured_quantities, pep.data_sample,
		good_deriv_level, good_udict, good_varlist, good_DD;
		interpolator=interpolator_func, time_index_set=[time_idx],
		precomputed_interpolants=interpolants, diagnostics=false, si_template=si_template)

	var_names = string.(varlist)
	println("  System: $(length(target)) equations, $(length(varlist)) variables")

	# ─── Compute true derivatives at this shooting point ──────────
	true_derivs, true_params = true_derivatives_at_t(sol, p_true, t_val; max_order=6)

	# Build substitution dict for TRUE values
	true_subst = Dict{Any, Float64}()
	for (i, vn) in enumerate(var_names)
		# Parse variable name: e.g. "k5_0" -> param k5, "x4_3" -> x4 deriv order 3
		m = match(r"^([a-z]\w?)(\d*)_(\d+)$", vn)
		if isnothing(m)
			m2 = match(r"^([a-z]+\d+)_(\d+)$", vn)
			if !isnothing(m2)
				base = m2.captures[1]
				order = parse(Int, m2.captures[2])
				if base in ["x4", "x5", "x6"] && haskey(true_derivs, base) && order+1 <= length(true_derivs[base])
					true_subst[varlist[i]] = true_derivs[base][order+1]
				elseif haskey(true_params, base)
					true_subst[varlist[i]] = true_params[base]
				end
			end
		else
			base = m.captures[1] * m.captures[2]
			order = parse(Int, m.captures[3])
			if base in ["x4", "x5", "x6"] && haskey(true_derivs, base) && order+1 <= length(true_derivs[base])
				true_subst[varlist[i]] = true_derivs[base][order+1]
			elseif haskey(true_params, base)
				true_subst[varlist[i]] = true_params[base]
			end
		end
	end

	# Print what we mapped
	n_mapped = length(true_subst)
	println("  Mapped $n_mapped / $(length(varlist)) variables to true values")
	if n_mapped < length(varlist)
		unmapped = [vn for (i, vn) in enumerate(var_names) if !haskey(true_subst, varlist[i])]
		println("  UNMAPPED: ", unmapped)
	end

	# ─── Evaluate residuals at TRUE values ────────────────────────
	if n_mapped == length(varlist)
		true_residuals = evaluate_residuals(target, varlist, true_subst)
		true_max_res = maximum(abs, filter(!isnan, true_residuals))
		true_rms_res = sqrt(mean(filter(!isnan, true_residuals).^2))
		@printf("  TRUE values residual: max=%.2e, rms=%.2e\n", true_max_res, true_rms_res)

		# Print per-equation residuals
		println("  Per-equation residuals (true):")
		for (i, r) in enumerate(true_residuals)
			marker = abs(r) > 1e-3 ? " *** BAD ***" : ""
			@printf("    Eq%2d: residual = %+.6e%s\n", i, r, marker)
		end
	end

	# ─── Now compare: interpolated derivative values vs true ──────
	println("\n  --- Interpolated vs True Observable Derivatives ---")
	# The interpolated values were substituted into the system already.
	# Let's compare what the interpolator gives vs the true ODE solution.
	for (obs_idx, obs_eq) in enumerate(pep.measured_quantities)
		obs_rhs = ModelingToolkit.diff2term(obs_eq.rhs)
		obs_interp = interpolants[obs_rhs]
		obs_name = obs_idx == 1 ? "y1" : "y2"

		# True observable values from ODE
		u_at_t = sol(t_val)
		true_obs = obs_idx == 1 ? 8.0 * u_at_t[1] : 0.5 * u_at_t[2]

		println("  $obs_name at t=$(@sprintf("%.4f", t_val)):")
		for deriv_order in 0:5
			interp_val = PE.nth_deriv(x -> obs_interp(x), deriv_order, t_val)
			# True derivative via numerical diff on ODE solution
			h = 1e-5
			true_deriv = 0.0
			n = deriv_order
			for k in 0:n
				sign = (-1)^(n - k)
				binom_coeff = binomial(n, k)
				t_k = t_val + (k - n/2) * h
				t_k = clamp(t_k, 0.0, 10.0)
				u_k = sol(t_k)
				obs_k = obs_idx == 1 ? 8.0 * u_k[1] : 0.5 * u_k[2]
				true_deriv += sign * binom_coeff * obs_k
			end
			true_deriv /= h^n

			if deriv_order == 0
				# Direct comparison, no finite diff needed
				true_deriv = true_obs
			end

			rel_err = abs(true_deriv) > 1e-15 ? abs(interp_val - true_deriv) / abs(true_deriv) : abs(interp_val - true_deriv)
			marker = rel_err > 0.01 ? " *** >1% ***" : (rel_err > 0.001 ? " * >0.1% *" : "")
			@printf("    d^%d/dt^%d: interp=%+.8e  true=%+.8e  relerr=%.2e%s\n",
				deriv_order, deriv_order, interp_val, true_deriv, rel_err, marker)
		end
	end

	# ─── HC solve and check residuals ─────────────────────────────
	solutions, hc_vars, _, _ = system_solver_func(target, varlist; options=Dict(:debug_solver=>false))
	println("\n  HC found $(length(solutions)) solutions")

	for (sol_idx, hc_sol) in enumerate(solutions)
		try
			sol_real = real.(hc_sol)
			# Build substitution dict
			hc_subst = Dict{Any, Float64}()
			for (i, v) in enumerate(varlist)
				if i <= length(sol_real)
					hc_subst[v] = sol_real[i]
				end
			end

			hc_residuals = evaluate_residuals(target, varlist, hc_subst)
			hc_max_res = maximum(abs, filter(!isnan, hc_residuals))
			hc_rms_res = sqrt(mean(filter(!isnan, hc_residuals).^2))

			# Key parameter values
			k9_idx = findfirst(==("k9_0"), var_names)
			k10_idx = findfirst(==("k10_0"), var_names)
			x6_idx = findfirst(==("x6_0"), var_names)
			k9_val = !isnothing(k9_idx) && k9_idx <= length(sol_real) ? sol_real[k9_idx] : NaN
			k10_val = !isnothing(k10_idx) && k10_idx <= length(sol_real) ? sol_real[k10_idx] : NaN
			x6_val = !isnothing(x6_idx) && x6_idx <= length(sol_real) ? sol_real[x6_idx] : NaN

			@printf("  Sol %d: max_res=%.2e, rms_res=%.2e | k9=%.4f k10=%.4f x6=%.4f\n",
				sol_idx, hc_max_res, hc_rms_res, k9_val, k10_val, x6_val)

			# If residuals are bad, show worst equations
			if hc_max_res > 1e-3
				worst_idx = argmax(abs.(hc_residuals))
				@printf("    Worst equation: Eq%d with residual %.2e\n", worst_idx, hc_residuals[worst_idx])
			end
		catch e
			println("  Sol $sol_idx: ERROR - $(typeof(e))")
		end
	end
end

println("\n", "="^70)
println("  RESIDUAL CHECK COMPLETE")
println("="^70)
