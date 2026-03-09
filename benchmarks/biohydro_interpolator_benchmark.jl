#!/usr/bin/env julia
# Biohydrogenation Interpolator Benchmark (Quokka-Faithful)
# Tests all 11 interpolators + 1 combined run on the SCALED biohydrogenation model.
# Uses create_ordered_ode_system() with scaled equations matching quokka exactly.

using ModelingToolkit, OrdinaryDiffEq
using ODEParameterEstimation
using OrderedCollections
using Random
using Printf

const t = ModelingToolkit.t_nounits
const D = ModelingToolkit.D_nounits

# ─── Step 1: Build model from scratch (scaled equations, matching quokka) ─────

parameters_sym = @parameters k5 k6 k7 k8 k9 k10
states_sym = @variables x4(t) x5(t) x6(t) x7(t)
observables_sym = @variables y1(t) y2(t)

equations = [
    D(x4) ~ (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4)),
    D(x5) ~ ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5,
    D(x6) ~ ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5,
    D(x7) ~ (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10),
]

measured_quantities = [
    y1 ~ 8.0*x4,
    y2 ~ 0.5*x5,
]

p_true_vals = [0.688, 0.87, 0.299, 0.561, 0.574, 0.558]
ic_true_vals = [0.278, 0.862, 0.458, 0.777]

model, mq = create_ordered_ode_system("biohydrogenation", states_sym, parameters_sym, equations, measured_quantities)

p_true_dict = OrderedDict(parameters_sym .=> p_true_vals)
ic_true_dict = OrderedDict(states_sym .=> ic_true_vals)

PEP_base = ParameterEstimationProblem(
    "biohydrogenation",
    model,
    mq,
    nothing,
    [0.0, 10.0],
    nothing,
    p_true_dict,
    ic_true_dict,
    0,
)

# ─── Step 2: Generate clean data ─────────────────────────────────────────────

println("=" ^ 90)
println("BIOHYDROGENATION INTERPOLATOR BENCHMARK (QUOKKA-FAITHFUL)")
println("Scaled equations, t∈[0,10], datasize=1501, additive noise, polishing OFF")
println("=" ^ 90)

base_opts = EstimationOptions(datasize=1501, time_interval=[0.0, 10.0])
pep_with_data = sample_problem_data(PEP_base, base_opts)
data_clean = pep_with_data.data_sample

# Identify observable keys (non-"t")
obs_keys = [k for k in keys(data_clean) if k != "t"]
println("\nClean data generated: $(length(data_clean["t"])) points")
println("Observable keys: ", obs_keys)
for k in obs_keys
    v = data_clean[k]
    println("  $k: first=$(round(v[1], digits=4)), last=$(round(v[end], digits=4)), mean=$(round(sum(v)/length(v), digits=4))")
end
t_vals = data_clean["t"]
println("Time range: [$(t_vals[1]), $(t_vals[end])]")
println("\nExpected: y1(0)≈2.224, y2(0)≈0.431")

# ─── Interpolator list ───────────────────────────────────────────────────────

const INTERPOLATORS = [
    (InterpolatorAAAD,            "AAAD"),
    (InterpolatorAAADGPR,         "AAAD_GPR"),
    (InterpolatorS2AAAMLE,        "S2_AAA_MLE"),
    (InterpolatorAGPRobust,       "GP_SE"),
    (InterpolatorAGPRobustRQ,     "GP_RQ"),
    (InterpolatorAGPRobustSEpRQ,  "GP_SEpRQ"),
    (InterpolatorAGPRobustSExRQ,  "GP_SExRQ"),
    (InterpolatorS3SE,            "S3_SE"),
    (InterpolatorS3RQ,            "S3_RQ"),
    (InterpolatorS3SEpRQ,         "S3_SEpRQ"),
    (InterpolatorS3SExRQ,         "S3_SExRQ"),
]

const ALL_INTERP_ENUMS = [ip[1] for ip in INTERPOLATORS]
const NOISE_LEVELS = [0.0, 1e-8, 1e-6]

# ─── Additive noise ─────────────────────────────────────────────────────────

function apply_additive_noise(data, obs_keys, noise_level; seed=42)
    noise_level == 0.0 && return data
    rng = MersenneTwister(seed)
    noisy = copy(data)
    for k in obs_keys
        vals = data[k]
        μ = sum(vals) / length(vals)
        noisy[k] = vals .+ μ .* noise_level .* randn(rng, length(vals))
    end
    return noisy
end

# ─── Result helpers ──────────────────────────────────────────────────────────

function best_result(results_vec)
    valid = [r for r in results_vec if r.err !== nothing && isfinite(r.err)]
    isempty(valid) && return nothing
    return sort(valid, by=r -> r.err)[1]
end

function compute_relative_errors(result, true_params)
    errs = OrderedDict{String, Float64}()
    for (k, v_true) in true_params
        k_str = string(k)
        for (rk, rv) in result.parameters
            if string(rk) == k_str
                errs[k_str] = abs(rv - v_true) / max(abs(v_true), 1e-15)
                break
            end
        end
    end
    return errs
end

struct BenchmarkResult
    noise_level::Float64
    interpolator_name::String
    elapsed::Float64
    n_solutions::Int
    best_err::Union{Nothing, Float64}
    param_rel_errors::Union{Nothing, OrderedDict{String, Float64}}
    interp_sources::Vector{Symbol}
    status::String
end

function run_estimation(pep, interp_list, name, noise_level)
    opts = EstimationOptions(
        interpolators = interp_list,
        datasize = 1501,
        noise_level = noise_level,
        nooutput = true,
        diagnostics = false,
        time_interval = [0.0, 10.0],
        polish_solutions = false,
        polish_solver_solutions = false,
    )

    elapsed = 0.0
    results_vec = ParameterEstimationResult[]
    status = "OK"
    try
        elapsed = @elapsed begin
            res = analyze_parameter_estimation_problem(pep, opts)
            results_vec = res[1][1]  # (solved_res, udict, trivial, unident)[1]
        end
    catch e
        elapsed = NaN
        status = string(typeof(e))
        try
            status *= ": " * sprint(showerror, e)[1:min(200, end)]
        catch
        end
    end

    sources = Symbol[]
    for r in results_vec
        if hasproperty(r, :interpolator_source) && r.interpolator_source !== nothing
            s = r.interpolator_source
            s ∉ sources && push!(sources, s)
        end
    end

    br = best_result(results_vec)
    if br === nothing && status == "OK"
        status = length(results_vec) == 0 ? "NO_SOLUTIONS" : "NO_VALID"
    end
    best_e = br === nothing ? nothing : br.err
    p_errs = br === nothing ? nothing : compute_relative_errors(br, p_true_dict)

    return BenchmarkResult(noise_level, name, elapsed, length(results_vec), best_e, p_errs, sources, status)
end

# ─── Main benchmark loop ────────────────────────────────────────────────────

all_results = BenchmarkResult[]
param_names = [string(k) for k in keys(p_true_dict)]

println("\nTrue params: ", join(["$k=$(v)" for (k,v) in p_true_dict], ", "))
println("True ICs:    ", join(["$k=$(v)" for (k,v) in ic_true_dict], ", "))
println("Polishing: OFF")

for noise_level in NOISE_LEVELS
    println("\n" * "─" ^ 90)
    @printf("NOISE LEVEL: %.1e\n", noise_level)
    println("─" ^ 90)

    noisy_data = apply_additive_noise(data_clean, obs_keys, noise_level)

    pep_noisy = ParameterEstimationProblem(
        "biohydrogenation",
        model,
        mq,
        noisy_data,
        [0.0, 10.0],
        nothing,
        p_true_dict,
        ic_true_dict,
        0,
    )

    # Individual interpolator runs
    for (interp_enum, interp_name) in INTERPOLATORS
        print("  Running $interp_name... ")
        flush(stdout)
        r = run_estimation(pep_noisy, [interp_enum], interp_name, noise_level)
        push!(all_results, r)
        if r.best_err !== nothing
            @printf("✓ %d sol, err=%.4e, %.1fs\n", r.n_solutions, r.best_err, r.elapsed)
        else
            @printf("✗ %s, %d sol, %.1fs\n", r.status, r.n_solutions, isnan(r.elapsed) ? 0.0 : r.elapsed)
        end
        flush(stdout)
    end

    # Combined run
    print("  Running ALL_COMBINED... ")
    flush(stdout)
    r = run_estimation(pep_noisy, ALL_INTERP_ENUMS, "ALL_COMBINED", noise_level)
    push!(all_results, r)
    if r.best_err !== nothing
        @printf("✓ %d sol, err=%.4e, %.1fs, sources=%s\n", r.n_solutions, r.best_err, r.elapsed, r.interp_sources)
    else
        @printf("✗ %s, %d sol, %.1fs\n", r.status, r.n_solutions, isnan(r.elapsed) ? 0.0 : r.elapsed)
    end
    flush(stdout)
end

# ─── Summary Table ───────────────────────────────────────────────────────────

println("\n\n" * "=" ^ 130)
println("SUMMARY TABLE")
println("=" ^ 130)

@printf("%-16s  %-10s  %8s  %5s  %12s", "Interpolator", "Noise", "Time(s)", "#Sol", "BestErr")
for p in param_names
    @printf("  %10s", p)
end
println("  Sources")
println("-" ^ 130)

for br in all_results
    noise_str = @sprintf("%.0e", br.noise_level)
    time_str = isnan(br.elapsed) ? "ERR" : @sprintf("%.1f", br.elapsed)
    err_str = br.best_err === nothing ? "N/A" : @sprintf("%.4e", br.best_err)

    @printf("%-16s  %-10s  %8s  %5d  %12s", br.interpolator_name, noise_str, time_str, br.n_solutions, err_str)

    for pname in param_names
        if br.param_rel_errors !== nothing && haskey(br.param_rel_errors, pname)
            v = br.param_rel_errors[pname]
            @printf("  %10.4e", v)
        else
            @printf("  %10s", "N/A")
        end
    end

    src_str = isempty(br.interp_sources) ? "-" : join(string.(br.interp_sources), ",")
    println("  $src_str")
end

# Source diversity for combined runs
println("\nINTERPOLATOR SOURCE DIVERSITY (ALL_COMBINED):")
for br in all_results
    if br.interpolator_name == "ALL_COMBINED"
        @printf("  Noise=%.0e: %d sources: %s\n", br.noise_level, length(br.interp_sources), br.interp_sources)
    end
end

println("\n" * "=" ^ 90)
println("BENCHMARK COMPLETE")
println("=" ^ 90)
