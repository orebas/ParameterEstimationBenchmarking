# Biohydrogenation Deep Dive: Experiment with Fixes
#
# Runs biohydrogenation through ODEPE with modifications to isolate the cause:
# 1. Baseline (default quokka settings, reproduce failure)
# 2. More shooting points (16, 32)
# 3. Different interpolators
# 4. Higher datasize (3001)
# 5. Manual parameter fix test
#
# Usage: julia experiment_fixes.jl

using Printf
using Statistics

println("="^70)
println("  Biohydrogenation Experiment: Testing Fixes")
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

# ─── Model Setup ──────────────────────────────────────────────────────

function setup_biohydrogenation(; datasize=1501, use_quokka_data=true)
	parameters_def = @parameters k5 k6 k7 k8 k9 k10
	states_def = @variables x4(t) x5(t) x6(t) x7(t)
	observables = @variables y1(t) y2(t)

	# Quokka-style scaled equations
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

	ic = [0.278, 0.862, 0.458, 0.777]
	p_true = [0.688, 0.87, 0.299, 0.561, 0.574, 0.558]
	time_interval = [0.0, 10.0]

	model, mq = create_ordered_ode_system(
		"BioHydrogenation",
		states_def,
		parameters_def,
		state_equations,
		measured_quantities_def
	)

	if use_quokka_data
		data_path = expanduser("~/ParameterEstimationBenchmarking/benchmark_quokka_2026_03_05/filetree/data_noisy/biohydrogenation_0_0/data.csv")
		csv_data = CSV.read(data_path, Tuple, header=false)
		data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
		data_sample["t"] = collect(Float64, csv_data[1])
		for (i, eq) in enumerate(mq)
			data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
		end
	else
		# Generate fresh data with specified datasize
		pep_raw = ParameterEstimationProblem(
			"biohydrogenation",
			model,
			mq,
			nothing,
			time_interval,
			nothing,
			OrderedDict(parameters_def .=> p_true),
			OrderedDict(states_def .=> ic),
			0,
		)
		opts_gen = EstimationOptions(datasize=datasize, noise_level=0.0)
		pep_sampled = sample_problem_data(pep_raw, opts_gen)
		data_sample = pep_sampled.data_sample
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

	return pep, parameters_def, states_def, ic, p_true
end

# ─── Scoring ──────────────────────────────────────────────────────────

function score_results(results_tuple, p_true, ic, parameters_def, states_def)
	"""Score results against true values. Returns (n_candidates, n_good, best_mean, best_max)."""
	if isnothing(results_tuple) || isnothing(results_tuple[1]) || isempty(results_tuple[1])
		return (0, 0, Inf, Inf)
	end

	solved_res = results_tuple[1]
	true_params = Dict(string(p) => v for (p, v) in zip(parameters_def, p_true))
	true_states = Dict(string(s) => v for (s, v) in zip(states_def, ic))
	true_vals = merge(true_params, true_states)

	id_vars = ["k5", "k6", "k7", "k8", "k9", "k10", "x4", "x5", "x6"]

	n_good = 0
	best_mean = Inf
	best_max_err = Inf

	for res in solved_res
		errors = Float64[]
		all_good = true
		for vn in id_vars
			# Find variable in result
			est = nothing
			for (k, v) in res.parameters
				if string(k) == vn
					est = v
					break
				end
			end
			if isnothing(est)
				for (k, v) in res.states
					if string(k) == vn
						est = v
						break
					end
				end
			end
			if isnothing(est)
				all_good = false
				push!(errors, Inf)
				continue
			end
			tv = true_vals[vn]
			err = abs(est - tv) / max(abs(tv), 1e-12)
			push!(errors, err)
			if err > 0.10
				all_good = false
			end
		end

		if all_good
			n_good += 1
		end

		if !isempty(errors) && all(isfinite, errors)
			m = mean(errors)
			mx = maximum(errors)
			if m < best_mean
				best_mean = m
				best_max_err = mx
			end
		end
	end

	return (length(solved_res), n_good, best_mean, best_max_err)
end

# ─── Run experiment ───────────────────────────────────────────────────

function run_experiment(label, pep, opts, parameters_def, states_def, p_true, ic)
	println("\n  --- $label ---")
	t_run = @timed begin
		try
			meta, results = analyze_parameter_estimation_problem(pep, opts)
			(solutions_vector, besterror, best_min_error, best_mean_error,
			 best_median_error, best_max_error, best_approximation_error,
			 best_rms_error) = results
			solutions_vector
		catch e
			@warn "  Experiment '$label' failed: $(typeof(e)): $e"
			nothing
		end
	end

	if isnothing(t_run.value) || isempty(t_run.value)
		n_cand, n_good, best_mean, best_max = 0, 0, Inf, Inf
	else
		# Score against true values
		solved_res = t_run.value
		id_vars = ["k5", "k6", "k7", "k8", "k9", "k10", "x4", "x5", "x6"]
		true_params = Dict(string(p) => v for (p, v) in zip(parameters_def, p_true))
		true_states = Dict(string(s) => v for (s, v) in zip(states_def, ic))
		true_vals = merge(true_params, true_states)

		n_cand = length(solved_res)
		n_good = 0
		best_mean = Inf
		best_max = Inf

		for res in solved_res
			errors = Float64[]
			all_good = true
			for vn in id_vars
				est = nothing
				for (k, v) in res.parameters
					if string(k) == vn; est = v; break; end
				end
				if isnothing(est)
					for (k, v) in res.states
						if string(k) == vn; est = v; break; end
					end
				end
				if isnothing(est); all_good = false; push!(errors, Inf); continue; end
				tv = true_vals[vn]
				err = abs(est - tv) / max(abs(tv), 1e-12)
				push!(errors, err)
				if err > 0.10; all_good = false; end
			end
			if all_good; n_good += 1; end
			if !isempty(errors) && all(isfinite, errors)
				m = mean(errors)
				mx = maximum(errors)
				if m < best_mean; best_mean = m; best_max = mx; end
			end
		end
	end

	@printf("  Result: %d candidates, %d good (all id vars <10%%), best_mean=%.6f, best_max=%.6f, time=%.1fs\n",
		n_cand, n_good, best_mean, best_max, t_run.time)

	return (label=label, n_cand=n_cand, n_good=n_good, best_mean=best_mean, best_max=best_max, time=t_run.time)
end

# ─── Experiments ──────────────────────────────────────────────────────

println("\n" * "="^70)
println("  Setting up model...")
println("="^70)

pep, parameters_def, states_def, ic, p_true = setup_biohydrogenation()

# Warmup
println("\nWarmup pass...")
opts_warmup = EstimationOptions(
	datasize = 101,
	noise_level = 0.0,
	system_solver = SolverHC,
	use_si_template = true,
	interpolator = InterpolatorAGPRobust,
	shooting_points = 1,
	try_more_methods = false,
	nooutput = true,
	diagnostics = false,
)
pep_warmup_raw = ParameterEstimationProblem(
	"biohydrogenation", pep.model, pep.measured_quantities, nothing,
	[0.0, 10.0], nothing,
	OrderedDict(parameters_def .=> p_true),
	OrderedDict(states_def .=> ic), 0,
)
pep_warmup = sample_problem_data(pep_warmup_raw, opts_warmup)
try
	analyze_parameter_estimation_problem(pep_warmup, opts_warmup)
catch e
	@warn "Warmup error (expected): $(typeof(e))"
end
GC.gc()

println("\n" * "="^70)
println("  Running Experiments")
println("="^70)

experiment_results = []

# Experiment 1: Baseline (quokka-like settings, single interpolator for speed)
push!(experiment_results, run_experiment(
	"Baseline (AGPRobust, 8pts)",
	pep,
	EstimationOptions(
		datasize = length(pep.data_sample["t"]),
		noise_level = 0.0,
		system_solver = SolverHC,
		use_si_template = true,
		interpolator = InterpolatorAGPRobust,
		shooting_points = 8,
		try_more_methods = false,
		nooutput = true,
		diagnostics = false,
		polish_solver_solutions = true,
		polish_solutions = false,
	),
	parameters_def, states_def, p_true, ic
))

# Experiment 2: More shooting points (16)
push!(experiment_results, run_experiment(
	"More shots (AGPRobust, 16pts)",
	pep,
	EstimationOptions(
		datasize = length(pep.data_sample["t"]),
		noise_level = 0.0,
		system_solver = SolverHC,
		use_si_template = true,
		interpolator = InterpolatorAGPRobust,
		shooting_points = 16,
		try_more_methods = false,
		nooutput = true,
		diagnostics = false,
		polish_solver_solutions = true,
		polish_solutions = false,
	),
	parameters_def, states_def, p_true, ic
))

# Experiment 3: Even more shooting points (32)
push!(experiment_results, run_experiment(
	"Many shots (AGPRobust, 32pts)",
	pep,
	EstimationOptions(
		datasize = length(pep.data_sample["t"]),
		noise_level = 0.0,
		system_solver = SolverHC,
		use_si_template = true,
		interpolator = InterpolatorAGPRobust,
		shooting_points = 32,
		try_more_methods = false,
		nooutput = true,
		diagnostics = false,
		polish_solver_solutions = true,
		polish_solutions = false,
	),
	parameters_def, states_def, p_true, ic
))

# Experiment 4: Different interpolator (AAAD)
push!(experiment_results, run_experiment(
	"AAAD interpolator, 8pts",
	pep,
	EstimationOptions(
		datasize = length(pep.data_sample["t"]),
		noise_level = 0.0,
		system_solver = SolverHC,
		use_si_template = true,
		interpolator = InterpolatorAAAD,
		shooting_points = 8,
		try_more_methods = false,
		nooutput = true,
		diagnostics = false,
		polish_solver_solutions = true,
		polish_solutions = false,
	),
	parameters_def, states_def, p_true, ic
))

# Experiment 5: FHD interpolator
push!(experiment_results, run_experiment(
	"FHD interpolator, 8pts",
	pep,
	EstimationOptions(
		datasize = length(pep.data_sample["t"]),
		noise_level = 0.0,
		system_solver = SolverHC,
		use_si_template = true,
		interpolator = InterpolatorFHD,
		shooting_points = 8,
		try_more_methods = false,
		nooutput = true,
		diagnostics = false,
		polish_solver_solutions = true,
		polish_solutions = false,
	),
	parameters_def, states_def, p_true, ic
))

# Experiment 6: Multi-interpolator (3 kernels)
push!(experiment_results, run_experiment(
	"Multi-interp (3 kernels), 8pts",
	pep,
	EstimationOptions(
		datasize = length(pep.data_sample["t"]),
		noise_level = 0.0,
		system_solver = SolverHC,
		use_si_template = true,
		interpolators = [InterpolatorAGPRobust, InterpolatorAAADGPR, InterpolatorFHD],
		shooting_points = 8,
		try_more_methods = false,
		nooutput = true,
		diagnostics = false,
		polish_solver_solutions = true,
		polish_solutions = false,
	),
	parameters_def, states_def, p_true, ic
))

# Experiment 7: With polishing enabled
push!(experiment_results, run_experiment(
	"With polishing (AGPRobust, 8pts)",
	pep,
	EstimationOptions(
		datasize = length(pep.data_sample["t"]),
		noise_level = 0.0,
		system_solver = SolverHC,
		use_si_template = true,
		interpolator = InterpolatorAGPRobust,
		shooting_points = 8,
		try_more_methods = false,
		nooutput = true,
		diagnostics = false,
		polish_solver_solutions = true,
		polish_solutions = true,
		polish_maxiters = 5000,
		polish_method = PolishBFGS,
		opt_maxiters = 200000,
		opt_lb = 1e-5 * ones(length(ic) + length(p_true)),
		opt_ub = 10.0 * ones(length(ic) + length(p_true)),
	),
	parameters_def, states_def, p_true, ic
))

# Experiment 8: Higher datasize (3001 points, fresh data)
pep_hi, _, _, _, _ = setup_biohydrogenation(datasize=3001, use_quokka_data=false)
push!(experiment_results, run_experiment(
	"High datasize (3001, fresh), 8pts",
	pep_hi,
	EstimationOptions(
		datasize = length(pep_hi.data_sample["t"]),
		noise_level = 0.0,
		system_solver = SolverHC,
		use_si_template = true,
		interpolator = InterpolatorAGPRobust,
		shooting_points = 8,
		try_more_methods = false,
		nooutput = true,
		diagnostics = false,
		polish_solver_solutions = true,
		polish_solutions = false,
	),
	parameters_def, states_def, p_true, ic
))

# ─── Summary ──────────────────────────────────────────────────────────
println("\n" * "="^70)
println("  EXPERIMENT SUMMARY")
println("="^70)

@printf("\n%-40s %7s %6s %10s %10s %7s\n", "Experiment", "#Cand", "#Good", "BestMean", "BestMax", "Time")
println("─"^40, " ", "─"^7, " ", "─"^6, " ", "─"^10, " ", "─"^10, " ", "─"^7)
for r in experiment_results
	@printf("%-40s %7d %6d %10.6f %10.6f %6.1fs\n",
		r.label, r.n_cand, r.n_good, r.best_mean, r.best_max, r.time)
end

println("\nDone.")
