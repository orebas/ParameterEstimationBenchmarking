#=============================================================================
  A/B TEST: crauste — isolate cause of regression

  4 variants, testing interpolator list × multipoint on/off:
    A: Old 12 interpolators, no multipoint   (control — should match nopolish)
    B: Old 12 interpolators + multipoint     (isolates multipoint effect)
    C: New 7 interpolators, no multipoint    (isolates interpolator change)
    D: New 7 interpolators + multipoint      (current config — should match regression)

  Runs on instances 0,1,2 (3 instances to get a pattern).
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
#  INTERPOLATOR SETS
# ─────────────────────────────────────────────────────────────────────────────

const OLD_12 = [
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

const NEW_7 = [
    InterpolatorAGPRobust,
    InterpolatorS3AdaptSE,
    InterpolatorChebyshevBIC,
    InterpolatorS3AdaptSExRQ,
    InterpolatorAGPRobustSExRQ,
    InterpolatorChebyshevAICc,
    InterpolatorAAADGPR,
]

# ─────────────────────────────────────────────────────────────────────────────
#  HELPER: build PEP for a given crauste instance
# ─────────────────────────────────────────────────────────────────────────────

function load_crauste_instance(instance_idx::Int)
    # Read true values from huge_json
    huge = JSON.parsefile(joinpath(BENCHMARK_DIR, "huge_json.json"))
    inst = nothing
    target_id = "crauste_$(instance_idx)_0"
    for i in huge["instances"]
        if i["id"] == target_id
            inst = i
            break
        end
    end
    isnothing(inst) && error("Instance $target_id not found")

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

    # Extract true values in parameter order
    pvar_names = ["mu_N", "mu_EE", "mu_LE", "mu_LL", "mu_P", "mu_PE", "mu_PL",
                  "delta_NE", "delta_EL", "delta_LM", "rho_E", "rho_P"]
    svar_names = ["Npop", "E", "L", "M", "P"]

    p_true = [inst["parameter_values"][n] for n in pvar_names]
    ic = [inst["state_values"][n] for n in svar_names]
    time_interval = [inst["time"]["start"], inst["time"]["end"]]

    model, mq = create_ordered_ode_system(
        "crauste_$(instance_idx)",
        states, parameters, state_equations, measured_quantities,
    )

    data_path = joinpath(BENCHMARK_DIR, "filetree", "data_noisy", target_id, "data.csv")
    csv_data = CSV.read(data_path, Tuple, header=false)
    data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
    data_sample["t"] = collect(Float64, csv_data[1])
    for (i, eq) in enumerate(mq)
        data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
    end

    pep = ParameterEstimationProblem(
        "crauste_$(instance_idx)", model, mq, data_sample, time_interval,
        nothing, OrderedDict(parameters .=> p_true), OrderedDict(states .=> ic), 0,
    )

    return pep, p_true, ic, parameters, states
end

# ─────────────────────────────────────────────────────────────────────────────
#  HELPER: run estimation with given config, return max relative error
# ─────────────────────────────────────────────────────────────────────────────

function run_variant(pep, p_true, ic, parameters, states;
                     interpolators, use_multipoint, label)
    opts = EstimationOptions(
        datasize = length(pep.data_sample["t"]),
        noise_level = 0.0,
        system_solver = SolverHC,
        flow = FlowStandard,
        use_si_template = true,
        interpolators = interpolators,
        shooting_points = 12,
        shooting_warp = true,
        shooting_warp_beta = 3.0,
        use_parameter_homotopy = true,
        use_multipoint = use_multipoint,
        multipoint_n_points = 2,
        multipoint_max_pairs = 15,
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

    raw_results, analysis, _ = analyze_parameter_estimation_problem(pep, opts)
    (solutions_vector, besterror, best_min, best_mean, best_median, best_max, best_approx, best_rms) = analysis

    n_solutions = length(solutions_vector)

    if n_solutions == 0
        return (label=label, n_solutions=0, max_rel_err=Inf, median_rel_err=Inf, success=false)
    end

    # Compute per-parameter relative errors for best solution
    best = solutions_vector[1]
    max_rel = best_max
    med_rel = best_median

    success = max_rel < 0.10
    return (label=label, n_solutions=n_solutions, max_rel_err=max_rel, median_rel_err=med_rel, success=success)
end

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN: run A/B/C/D on instances 0, 1, 2
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 80)
println("  A/B TEST: crauste — isolate cause of regression")
println("  A: Old 12 interps, no multipoint (control)")
println("  B: Old 12 interps + multipoint")
println("  C: New 7 interps, no multipoint")
println("  D: New 7 interps + multipoint (current config)")
println("=" ^ 80)
println()

variants = [
    (interpolators=OLD_12, use_multipoint=false, label="A: Old12, no-mp"),
    (interpolators=OLD_12, use_multipoint=true,  label="B: Old12, mp"),
    (interpolators=NEW_7,  use_multipoint=false, label="C: New7, no-mp"),
    (interpolators=NEW_7,  use_multipoint=true,  label="D: New7, mp"),
]

all_results = []

for inst_idx in [0, 1, 2]
    println("─" ^ 80)
    println("  Instance $inst_idx")
    println("─" ^ 80)

    pep, p_true, ic, params, sts = load_crauste_instance(inst_idx)

    for v in variants
        print("  Running $(v.label) ... ")
        flush(stdout)
        t0 = time()
        result = try
            run_variant(pep, p_true, ic, params, sts;
                       interpolators=v.interpolators,
                       use_multipoint=v.use_multipoint,
                       label=v.label)
        catch e
            println("ERROR: $e")
            (label=v.label, n_solutions=0, max_rel_err=Inf, median_rel_err=Inf, success=false)
        end
        elapsed = time() - t0
        status = result.success ? "PASS" : "FAIL"
        @printf("%s  n_sol=%3d  max_rel=%.4f  median_rel=%.6f  (%.0fs)\n",
            status, result.n_solutions, result.max_rel_err, result.median_rel_err, elapsed)
        push!(all_results, (instance=inst_idx, result...))
    end
    println()
end

# ─────────────────────────────────────────────────────────────────────────────
#  SUMMARY TABLE
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 80)
println("  SUMMARY")
println("=" ^ 80)
println()
@printf("  %-20s", "Variant")
for inst_idx in [0, 1, 2]
    @printf("  inst_%d       ", inst_idx)
end
println()
println("  " * "-" ^ 65)

for label in ["A: Old12, no-mp", "B: Old12, mp", "C: New7, no-mp", "D: New7, mp"]
    @printf("  %-20s", label)
    for inst_idx in [0, 1, 2]
        r = filter(x -> x.instance == inst_idx && x.label == label, all_results)
        if !isempty(r)
            r = r[1]
            status = r.success ? "PASS" : "FAIL"
            @printf("  %s %.4f  ", status, r.max_rel_err)
        else
            @printf("  %-14s", "???")
        end
    end
    println()
end

println()
println("  If A passes and C fails → dropped interpolators are the cause")
println("  If A passes and B fails → multipoint is the cause")
println("  If A and C both pass    → interaction between interps + multipoint")
println()

# Save results as JSON
results_json = [Dict(pairs(r)) for r in all_results]
outfile = joinpath(BENCHMARK_DIR, "diagnostics", "ab_test_crauste_results.json")
open(outfile, "w") do io
    JSON.print(io, results_json, 4)
end
println("  Results saved to: $outfile")
println("=" ^ 80)
