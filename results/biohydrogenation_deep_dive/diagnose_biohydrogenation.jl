# Biohydrogenation Deep Dive: Diagnose 0% ODEPE Success at Noise=0
#
# This script inspects the SI template and HC system to determine why
# biohydrogenation consistently fails in the quokka benchmark.
#
# Usage: julia diagnose_biohydrogenation.jl
#
# Uses quokka instance 0: k5=0.688, k6=0.87, k7=0.299, k8=0.561, k9=0.574, k10=0.558
#                          x4=0.278, x5=0.862, x6=0.458, x7=0.777

using Printf
using LinearAlgebra
using Statistics

println("="^70)
println("  Biohydrogenation Deep Dive: SI Template & HC Diagnostics")
println("="^70)

println("\nLoading ODEParameterEstimation...")
t_load = @elapsed begin
	using ODEParameterEstimation
	using ModelingToolkit
	using ModelingToolkit: t_nounits as t, D_nounits as D
	using OrderedCollections
	using Symbolics: Num
	using CSV
end
@printf("Loaded in %.1f s\n", t_load)

const PE = ODEParameterEstimation
const Sym = ODEParameterEstimation.Symbolics
const OC = ODEParameterEstimation.OrderedCollections

# ─── Set up biohydrogenation with quokka instance 0 parameters ────────
println("\n--- Setting up biohydrogenation (quokka instance 0, noise=0) ---")

parameters_def = @parameters k5 k6 k7 k8 k9 k10
states_def = @variables x4(t) x5(t) x6(t) x7(t)
observables = @variables y1(t) y2(t)

# Quokka-style scaled equations (from systems.json / generated script)
state_equations = [
	D(x4) ~ (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4)),
	D(x5) ~ ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5,
	D(x6) ~ ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5,
	D(x7) ~ (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10),
]
measured_quantities_def = [
	y1 ~ 8.0*x4,
	y2 ~ 0.5*x5,
]

# Quokka instance 0 true values
ic = [0.278, 0.862, 0.458, 0.777]
p_true = [0.688, 0.87, 0.299, 0.561, 0.574, 0.558]
time_interval = [0.0, 10.0]
datasize = 1501

model, mq = create_ordered_ode_system(
	"BioHydrogenation",
	states_def,
	parameters_def,
	state_equations,
	measured_quantities_def
)

# Load data from the quokka benchmark
data_path = expanduser("~/ParameterEstimationBenchmarking/benchmark_quokka_2026_03_05/filetree/data_noisy/biohydrogenation_0_0/data.csv")
csv_data = CSV.read(data_path, Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
	data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end

pep = ParameterEstimationProblem(
	"biohydrogenation",
	model,
	mq,
	data_sample,
	time_interval,
	nothing,
	OrderedDict(parameters_def .=> p_true),
	OrderedDict(states_def .=> ic),
	0,
)

println("  Data loaded: $(length(data_sample["t"])) time points, t=[$(data_sample["t"][1]), $(data_sample["t"][end])]")

# ─── STEP 1: Run setup_identifiability ────────────────────────────────
println("\n" * "="^70)
println("  STEP 1: Identifiability Analysis")
println("="^70)

(t_var, eqns, states, params) = PE.unpack_ODE(pep.model.system)
t_vector = pep.data_sample["t"]

println("  States: ", states)
println("  Params: ", params)

# Run identifiability analysis
num_points_cap = min(length(params), 1, length(t_vector))
good_num_points, good_deriv_level, good_udict, good_varlist, good_DD =
	PE.determine_optimal_points_count(
		pep.model.system, pep.measured_quantities, num_points_cap, t_vector, true
	)

println("\n  --- Identifiability Results ---")
println("  good_num_points: ", good_num_points)
println("  good_deriv_level: ", good_deriv_level)
println("  good_varlist ($(length(good_varlist)) vars): ", good_varlist)
println("  good_udict: ", good_udict)
println("  all_unidentifiable: ", good_DD.all_unidentifiable)

# Print DD structure
println("\n  --- DD (DerivativeData) structure ---")
for (level_idx, level) in enumerate(good_DD.obs_lhs)
	println("  obs_lhs[$(level_idx)] (deriv order $(level_idx-1)): ", level)
end

# ─── STEP 2: SI Template Construction (iterative fixing) ─────────────
println("\n" * "="^70)
println("  STEP 2: SI Template Construction (iterative fixing)")
println("="^70)

ordered_model = isa(pep.model.system, PE.OrderedODESystem) ?
	pep.model.system :
	PE.OrderedODESystem(pep.model.system, states, params)

pre_fixed_params = OrderedDict{Any, Float64}()
max_fix_iterations = 10
iteration = 0
converged = false
si_template = nothing

while iteration < max_fix_iterations && !converged
	global iteration, converged, si_template, pre_fixed_params
	iteration += 1
	println("\n  --- Iteration $iteration ---")
	if !isempty(pre_fixed_params)
		println("  Pre-fixed params: ", pre_fixed_params)
	end

	# Run SIAN analysis
	template_equations, derivative_dict, unidentifiable, identifiable_funcs = PE.get_si_equation_system(
		ordered_model,
		pep.measured_quantities,
		pep.data_sample;
		DD = good_DD,
		infolevel = 1,
		pre_fixed_params = pre_fixed_params,
	)

	si_template = (
		equations = template_equations,
		deriv_dict = derivative_dict,
		unidentifiable = unidentifiable,
		identifiable_funcs = identifiable_funcs,
	)

	# Count equations and variables
	n_equations = length(template_equations)
	vars_in_system = OC.OrderedSet{Any}()
	for eq in template_equations
		union!(vars_in_system, Sym.get_variables(eq))
	end

	# Classify variables: observable data vars vs unknowns
	obs_data_vars = Set{Any}()
	if !isnothing(good_DD)
		for level in good_DD.obs_lhs
			for v in level
				push!(obs_data_vars, v)
			end
		end
	end

	unknown_vars = OC.OrderedSet{Any}()
	data_vars = OC.OrderedSet{Any}()
	for v in vars_in_system
		if v in obs_data_vars
			push!(data_vars, v)
		else
			push!(unknown_vars, v)
		end
	end

	# Also classify _trfn_ variables
	trfn_var_info, real_solve_vars, trfn_only_eq_indices = PE.classify_trfn_in_template(
		collect(unknown_vars), Set(data_vars), template_equations
	)

	n_variables = length(unknown_vars)
	n_data_vars = length(data_vars)
	n_trfn_vars = length(trfn_var_info)
	n_trfn_only_eqs = length(trfn_only_eq_indices)
	n_effective_eqs = n_equations - n_trfn_only_eqs
	n_effective_vars = n_variables - n_trfn_vars

	println("  Template equations: $n_equations")
	println("  All vars in system: $(length(vars_in_system))")
	println("  Data vars (obs derivatives): $n_data_vars → ", collect(data_vars))
	println("  Unknown vars: $n_variables → ", collect(unknown_vars))
	println("  _trfn_ vars: $n_trfn_vars")
	println("  Effective: $n_effective_eqs eqs, $n_effective_vars vars")
	println("  Unidentifiable: ", unidentifiable)
	println("  Identifiable funcs: ", identifiable_funcs)

	# Print each equation and its variables
	println("\n  --- Template Equations ---")
	for (i, eq) in enumerate(template_equations)
		eq_vars = Sym.get_variables(eq)
		eq_unknowns = [v for v in eq_vars if !(v in obs_data_vars)]
		println("  Eq$i ($(length(eq_unknowns)) unknowns): $eq")
		println("       unknowns: $eq_unknowns")
	end

	# Check convergence
	if n_effective_eqs == n_effective_vars
		println("\n  CONVERGED: Determined system ($n_effective_eqs eqs = $n_effective_vars vars)")
		converged = true
	elseif n_effective_eqs > n_effective_vars && n_effective_eqs <= n_effective_vars + 2
		println("\n  CONVERGED: Nearly-determined ($n_effective_eqs eqs, $n_effective_vars vars)")
		converged = true
	elseif n_effective_eqs < n_effective_vars
		println("\n  UNDERDETERMINED: $n_effective_eqs eqs < $n_effective_vars vars (deficit: $(n_effective_vars - n_effective_eqs))")
		already_fixed = Set(keys(pre_fixed_params))
		param_to_fix, fix_value = PE.select_one_parameter_to_fix(
			si_template, already_fixed, true; states = states
		)
		if param_to_fix === nothing
			println("  No parameter to fix — stopping")
			break
		end
		println("  Fixing: $param_to_fix = $fix_value")
		pre_fixed_params[param_to_fix] = fix_value
	else
		println("\n  OVERDETERMINED: $n_effective_eqs eqs > $n_effective_vars vars")
		break
	end
end

println("\n  Final iteration count: $iteration")
println("  Final pre-fixed params: ", pre_fixed_params)

# ─── STEP 3: Construct and inspect instantiated system at one point ───
println("\n" * "="^70)
println("  STEP 3: Instantiate System at Shooting Point")
println("="^70)

# Create interpolants
interpolator_func = PE.get_interpolator_function(InterpolatorAGPRobust, nothing)
interpolants = PE.create_interpolants(pep.measured_quantities, pep.data_sample, t_vector, interpolator_func)

# Use midpoint
time_idx = div(length(t_vector), 2)
println("  Shooting point: t[$(time_idx)] = $(t_vector[time_idx])")

target, varlist = PE.construct_equation_system_from_si_template(
	pep.model.system,
	pep.measured_quantities,
	pep.data_sample,
	good_deriv_level,
	good_udict,
	good_varlist,
	good_DD;
	interpolator = interpolator_func,
	time_index_set = [time_idx],
	precomputed_interpolants = interpolants,
	diagnostics = true,
	si_template = si_template,
)

println("\n  --- Instantiated System ---")
println("  Equations: $(length(target))")
println("  Variables: $(length(varlist)) → ", varlist)

for (i, eq) in enumerate(target)
	eq_vars = Sym.get_variables(eq)
	println("  InstEq$i ($(length(eq_vars)) vars): $eq")
end

# Check which of {k9, k10, x6} are in the variable list
k9_k10_x6_vars = String["k9", "k10", "x6"]
varlist_names = string.(varlist)
println("\n  --- Key variable check ---")
for vname in k9_k10_x6_vars
	found = any(occursin(vname, vn) for vn in varlist_names)
	println("  $vname in varlist: $found")
end

# ─── STEP 4: Run HC solve and analyze solutions ──────────────────────
println("\n" * "="^70)
println("  STEP 4: HC Solve and Solution Analysis")
println("="^70)

system_solver_func = PE.get_solver_function(SolverHC)
solver_options = Dict(
	:debug_solver => true,
	:debug_cas_diagnostics => false,
	:debug_dimensional_analysis => false,
)

println("  Solving $(length(target)) equations in $(length(varlist)) variables...")
solutions, hc_vars, trivial_dict, trimmed_vars = system_solver_func(target, varlist; options = solver_options)
println("  HC found $(length(solutions)) solutions")

# Map variable names
var_names = string.(varlist)
println("  Variable order: ", var_names)

# True values for scoring — use _0 suffix to match HC variable names
true_vals = Dict(
	"k5_0" => 0.688, "k6_0" => 0.87, "k7_0" => 0.299, "k8_0" => 0.561,
	"k9_0" => 0.574, "k10_0" => 0.558,
	"x4_0" => 0.278, "x5_0" => 0.862, "x6_0" => 0.458, "x7_0" => 0.777,
)

# Identifiable variables (exclude x7) — _0 suffix for initial condition at shooting point
id_vars = ["k5_0", "k6_0", "k7_0", "k8_0", "k9_0", "k10_0", "x4_0", "x5_0", "x6_0"]

# Analyze each solution — print raw values for key variables
println("\n  --- Solution Analysis (raw values) ---")
println("  Variable order: ", var_names)

# Build index map for key variables
key_vars = ["k5_0", "k6_0", "k7_0", "k8_0", "k9_0", "k10_0", "x4_0", "x5_0", "x6_0"]
key_idx = Dict{String, Int}()
for vn in key_vars
	for (i, name) in enumerate(var_names)
		if name == vn
			key_idx[vn] = i
			break
		end
	end
end

for (sol_idx, sol) in enumerate(solutions)
	try
		sol_real = real.(sol)
		println("\n  Solution $sol_idx:")
		for vn in key_vars
			if haskey(key_idx, vn) && key_idx[vn] <= length(sol_real)
				est = sol_real[key_idx[vn]]
				tv = get(true_vals, vn, NaN)
				err = isnan(tv) ? NaN : abs(est - tv) / max(abs(tv), 1e-12)
				@printf("    %-8s: est=%12.6f  true=%8.4f  relerr=%8.4f%s\n",
					vn, est, tv, err, err < 0.10 ? " OK" : " FAIL")
			end
		end
	catch e
		println("  Solution $sol_idx: ERROR accessing - $(typeof(e))")
	end
end

println("\n  --- Summary ---")
println("  Total HC solutions: $(length(solutions))")

# ─── STEP 5: Multiple shooting points — summary only ──────
println("\n" * "="^70)
println("  STEP 5: Multiple Shooting Points (summary)")
println("="^70)

begin
	local n_pts = min(8, length(t_vector))
	local point_indices = round.(Int, range(1, length(t_vector), length=n_pts))
	local total_sols = 0

	for (pt_num, pidx) in enumerate(point_indices)
		local target_k, varlist_k = PE.construct_equation_system_from_si_template(
			pep.model.system,
			pep.measured_quantities,
			pep.data_sample,
			good_deriv_level,
			good_udict,
			good_varlist,
			good_DD;
			interpolator = interpolator_func,
			time_index_set = [pidx],
			precomputed_interpolants = interpolants,
			diagnostics = false,
			si_template = si_template,
		)

		local solutions_k, _, _, _ = system_solver_func(target_k, varlist_k; options = Dict(:debug_solver => false))
		total_sols += length(solutions_k)
		@printf("  Point %d/%d (t=%.2f): %d solutions\n", pt_num, n_pts, t_vector[pidx], length(solutions_k))
	end

	println("\n  Total solutions across $n_pts points: $total_sols")
end

println("\n" * "="^70)
println("  DIAGNOSIS COMPLETE")
println("="^70)
println()
