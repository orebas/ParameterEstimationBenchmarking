#=============================================================================
  INTERPOLATOR HUNT: which of the 9 dropped interpolators finds the good
  branch for crauste?

  Runs estimation with ONLY the 9 dropped interpolators (not in new set).
  Lineage tags on each solution identify the hero.
=============================================================================#

using Pkg; Pkg.activate(raw"/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV
using JSON
using Printf
using Symbolics: Num

const BENCHMARK_DIR = "/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_bilby_2026_03_09"

# ─────────────────────────────────────────────────────────────────────────────
#  The 9 dropped interpolators (in old 12 but NOT in new 7)
# ─────────────────────────────────────────────────────────────────────────────

const DROPPED_9 = [
    InterpolatorAAAD,
    InterpolatorS2AAAMLE,
    InterpolatorAGPRobustRQ,
    InterpolatorAGPRobustSEpRQ,
    InterpolatorS3SE,
    InterpolatorS3RQ,
    InterpolatorS3SEpRQ,
    InterpolatorS3SExRQ,
    InterpolatorFHD,
]

# ─────────────────────────────────────────────────────────────────────────────
#  MODEL + DATA (crauste instance 0, noise=0)
# ─────────────────────────────────────────────────────────────────────────────

parameters = @parameters mu_N mu_EE mu_LE mu_LL mu_P mu_PE mu_PL delta_NE delta_EL delta_LM rho_E rho_P
states = @variables Npop(t) E(t) L(t) M(t) P(t)
observables = @variables y1(t) y2(t) y3(t) y4(t)

state_equations = [
    D(Npop) ~ (-24270.0*mu_N*Npop - 582.4799999999999*delta_NE*P*Npop) / 16180.0,
    D(E) ~ (582.4799999999999*delta_NE*P*Npop + 10.0*(-1.18*delta_EL - 0.000432*mu_EE*E + 2.56*rho_E*P)*E) / 10.0,
    D(L) ~ (11.799999999999999*delta_EL*E - 10.0*(0.05*delta_LM + 7.2e-7*mu_LE*E + 0.00015000000000000001*mu_LL*L)*L) / 10.0,
    D(M) ~ 0.05*delta_LM*L,
    D(P) ~ (-0.11*mu_P - 3.6e-6*mu_PE*E - 0.00036*mu_PL*L + 0.6*rho_P*P)*P,
]
measured_quantities = [
    y1 ~ 16180.0*Npop,
    y2 ~ 10.0*E,
    y3 ~ 10.0*M + 10.0*L,
    y4 ~ 2.0*P,
]

ic = [0.507, 0.376, 0.275, 0.846, 0.779]
p_true = [0.165, 0.527, 0.581, 0.553, 0.46, 0.188, 0.54, 0.705, 0.586, 0.132, 0.716, 0.192]
time_interval = [0.0, 25.0]

model, mq = create_ordered_ode_system("crauste_0", states, parameters, state_equations, measured_quantities)

data_path = joinpath(BENCHMARK_DIR, "filetree", "data_noisy", "crauste_0_0", "data.csv")
csv_data = CSV.read(data_path, Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
    data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end

pep = ParameterEstimationProblem(
    "crauste_0", model, mq, data_sample, time_interval, nothing,
    OrderedDict(parameters .=> p_true), OrderedDict(states .=> ic), 0,
)

# ─────────────────────────────────────────────────────────────────────────────
#  RUN 1: All 9 dropped together (fast — shared SIAN)
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 72)
println("  INTERPOLATOR HUNT: crauste instance 0")
println("  Testing the 9 dropped interpolators together")
println("=" ^ 72)
println()

opts = EstimationOptions(
    datasize = length(data_sample["t"]),
    noise_level = 0.0,
    system_solver = SolverHC,
    flow = FlowStandard,
    use_si_template = true,
    interpolators = DROPPED_9,
    shooting_points = 12,
    shooting_warp = true,
    shooting_warp_beta = 3.0,
    use_parameter_homotopy = true,
    use_multipoint = false,
    polish_solver_solutions = true,
    polish_solutions = false,
    polish_maxiters = 5000,
    polish_method = PolishBFGS,
    opt_maxiters = 200000,
    opt_lb = 1e-5 * ones(length(ic) + length(p_true)),
    opt_ub = 10.0 * ones(length(ic) + length(p_true)),
    abstol = 1e-13,
    reltol = 1e-13,
    polish_maxtime = 1200.0,
    polish_divergence_factor = 10.0,
    polish_stagnation_window = 50,
    polish_ode_maxiters = 20000,
    diagnostics = true,
)

raw_results, analysis, _ = analyze_parameter_estimation_problem(pep, opts)
(solutions_vector, besterror, best_min, best_mean, best_median, best_max, best_approx, best_rms) = analysis

println()
println("=" ^ 72)
println("  RESULTS: 9 dropped interpolators together")
println("=" ^ 72)
println("  Solutions found: $(length(solutions_vector))")
@printf("  Best MaxRelErr: %.6f\n", best_max)
println("  Success: $(best_max < 0.10 ? "PASS" : "FAIL")")
println()

# Show per-solution lineage
println("  Per-solution breakdown:")
println("  " * "-" ^ 70)
@printf("  %4s  %12s  %15s  %30s  %7s\n", "Sol#", "MaxRelErr", "Worst Param", "Interpolator", "Pass?")
println("  " * "-" ^ 70)

for (idx, sol) in enumerate(solutions_vector)
    # Compute max relative error for this solution
    max_err = 0.0
    worst = ""
    for (k, v) in sol.parameters
        true_v = pep.p_true[k]
        rel = abs(true_v) > 1e-15 ? abs(v - true_v) / abs(true_v) : abs(v - true_v)
        if rel > max_err
            max_err = rel
            worst = string(k)
        end
    end
    for (k, v) in sol.states
        true_v = pep.ic[k]
        rel = abs(true_v) > 1e-15 ? abs(v - true_v) / abs(true_v) : abs(v - true_v)
        if rel > max_err
            max_err = rel
            worst = string(k)
        end
    end

    interp_src = isnothing(sol.provenance.interpolator_source) ? "unknown" : string(sol.provenance.interpolator_source)
    pass = max_err < 0.10 ? "PASS" : "FAIL"
    @printf("  %4d  %12.6f  %15s  %30s  %7s\n", idx, max_err, worst, interp_src, pass)
end

# ─────────────────────────────────────────────────────────────────────────────
#  RUN 2: Each dropped interpolator individually (one at a time)
# ─────────────────────────────────────────────────────────────────────────────

println()
println("=" ^ 72)
println("  INDIVIDUAL INTERPOLATOR TEST (one at a time)")
println("=" ^ 72)
println()
@printf("  %-35s  %5s  %12s  %15s  %7s  %6s\n",
    "Interpolator", "Sols", "MaxRelErr", "Worst Param", "Pass?", "Time")
println("  " * "-" ^ 90)

for interp in DROPPED_9
    t0 = time()
    opts_single = EstimationOptions(
        datasize = length(data_sample["t"]),
        noise_level = 0.0,
        system_solver = SolverHC,
        flow = FlowStandard,
        use_si_template = true,
        interpolators = [interp],
        shooting_points = 12,
        shooting_warp = true,
        shooting_warp_beta = 3.0,
        use_parameter_homotopy = true,
        use_multipoint = false,
        polish_solver_solutions = true,
        polish_solutions = false,
        polish_maxiters = 5000,
        polish_method = PolishBFGS,
        opt_maxiters = 200000,
        opt_lb = 1e-5 * ones(length(ic) + length(p_true)),
        opt_ub = 10.0 * ones(length(ic) + length(p_true)),
        abstol = 1e-13,
        reltol = 1e-13,
        polish_maxtime = 1200.0,
        polish_divergence_factor = 10.0,
        polish_stagnation_window = 50,
        polish_ode_maxiters = 20000,
        diagnostics = false,
    )

    local sol_vec, b_max
    try
        _, analysis2, _ = analyze_parameter_estimation_problem(pep, opts_single)
        (sol_vec, _, _, _, _, b_max, _, _) = analysis2
    catch e
        @printf("  %-35s  ERROR: %s\n", string(interp), sprint(showerror, e))
        continue
    end
    elapsed = time() - t0

    n_sol = length(sol_vec)
    if n_sol == 0
        @printf("  %-35s  %5d  %12s  %15s  %7s  %5.0fs\n",
            string(interp), 0, "—", "—", "NOSOL", elapsed)
    else
        # Find worst param for best solution
        best = sol_vec[1]
        max_err = 0.0
        worst = ""
        for (k, v) in best.parameters
            true_v = pep.p_true[k]
            rel = abs(true_v) > 1e-15 ? abs(v - true_v) / abs(true_v) : abs(v - true_v)
            if rel > max_err; max_err = rel; worst = string(k); end
        end
        for (k, v) in best.states
            true_v = pep.ic[k]
            rel = abs(true_v) > 1e-15 ? abs(v - true_v) / abs(true_v) : abs(v - true_v)
            if rel > max_err; max_err = rel; worst = string(k); end
        end
        pass = max_err < 0.10 ? "PASS" : "FAIL"
        @printf("  %-35s  %5d  %12.6f  %15s  %7s  %5.0fs\n",
            string(interp), n_sol, max_err, worst, pass, elapsed)
    end
end

println()
println("=" ^ 72)
println("  Done.")
println("=" ^ 72)
