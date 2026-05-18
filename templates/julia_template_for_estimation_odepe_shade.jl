using Pkg; Pkg.activate({{{julia_env_path}}})

using MKL

using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV
using JSON

using GaussianProcesses
using Statistics
using Optim, LineSearches
using Symbolics: Num

name = "{{name}}"
parameters = @parameters {{#parameters}}{{varname}} {{/parameters}}
states = @variables  {{#states}}{{varname}}(t){{space}}{{/states}}
observables = @variables  {{#measurements}}{{varname}}(t){{space}}{{/measurements}}
state_equations = [
{{#components}}
    D({{state_var}}) ~ {{state_expr}},
{{/components}}
]
measured_quantities = [
{{#measured_quantities}}
    {{measurement}} ~ {{measurement_expression}},
{{/measured_quantities}}
]
ic = [{{#initial_conditions}}{{value}}{{comma}}{{/initial_conditions}}]
p_true = [{{#parameters}}{{true}}{{comma}}{{/parameters}}]

time_interval = [{{time_start}}, {{time_end}}]
datasize = {{time_count}}

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

# Use mq (model-consistent variables) for data_sample keys, not original measured_quantities
csv_data = CSV.read(joinpath(@__DIR__, "{{data_filepath}}"), Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
    data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end

pep = ParameterEstimationProblem(
    name,
    model,
    mq,
    data_sample,
    time_interval,
    nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0,
)

# SHADE+LM hybrid baseline. Per `SHADE_LM_BASELINE.md`:
#  * Global phase = SHADE in transformed (per-variable :auto = log/shifted_log/linear)
#    coordinates over an explicit bounded box. Defaults give 70% of evaluation budget
#    to SHADE, 30% to LM polish.
#  * Local phase = top-K SHADE seeds polished by `_polish_single_from_context`. Default
#    polish_method = `PolishLSOBoundedLog` (bounded LSO LM with ForwardDiff Jacobian,
#    revert guard, 2026-05 trust-region tuning).
#  * `shade_seed` is set deterministically from the per-cell hash so re-running a single
#    instance gives bit-identical results.
opts = EstimationOptions(
    # Default-bounds path returns ±1e9*data_scale which is useless for a derivative-free
    # metaheuristic. Pass the harness search box explicitly.
    opt_lb = fill({{lower_bound}}, length(states) + length(parameters)),
    opt_ub = fill({{upper_bound}}, length(states) + length(parameters)),
    # SHADE knobs
    shade_total_max_evals = 200_000,
    shade_total_max_time = 1200.0,
    shade_global_eval_fraction = 0.7,
    shade_n_local_starts = 5,
    shade_population = 0,        # auto: max(50, 10 * n_total)
    shade_seed = UInt({{shade_seed}}),
    # Local polish (matches odepe_v2)
    polish_method = PolishLSOBoundedLog,
    polish_lso_delta = 10.0,
    polish_maxiters = 5000,
    polish_maxtime = {{POLISH_MAXTIME}},
    polish_divergence_factor = {{POLISH_DIVERGENCE_FACTOR}},
    polish_stagnation_window = {{POLISH_STAGNATION_WINDOW}},
    polish_ode_maxiters = {{POLISH_ODE_MAXITERS}},
    abstol = 1e-12,
    reltol = 1e-12,
    diagnostics = true,
)

function ordered_pairs_to_string_dict(items)
    out = Dict{String, Float64}()
    for (k, v) in items
        out[string(k)] = Float64(v)
    end
    return out
end

function ordered_dict_to_string_dict(items)
    out = Dict{String, Float64}()
    for (k, v) in pairs(items)
        out[string(k)] = Float64(v)
    end
    return out
end

function result_metadata(best_sol)
    provenance = best_sol.provenance
    notes_strs = [string(x) for x in provenance.notes]
    return Dict(
        "parameters" => ordered_pairs_to_string_dict(collect(best_sol.parameters)),
        "states" => ordered_pairs_to_string_dict(collect(best_sol.states)),
        "all_unidentifiable" => [string(x) for x in best_sol.all_unidentifiable],
        "primary_method" => string(provenance.primary_method),
        "interpolator_source" => isnothing(provenance.interpolator_source) ? nothing : string(provenance.interpolator_source),
        "rescue_path" => string(provenance.rescue_path),
        "structural_fix_set" => ordered_dict_to_string_dict(provenance.structural_fix_set),
        "residual_fix_set" => ordered_dict_to_string_dict(provenance.residual_fix_set),
        "representative_assignments" => ordered_dict_to_string_dict(provenance.representative_assignments),
        "practical_identifiability_status" => string(provenance.practical_identifiability_status),
        "notes" => notes_strs,
        "was_terminal_fallback" => ("terminal_fallback" in notes_strs) || (string(provenance.rescue_path) == "direct_opt_fallback"),
        "pre_polish_error" => provenance.pre_polish_error,
        "post_polish_error" => provenance.post_polish_error,
        "polish_applied" => provenance.polish_applied,
        "source_type" => string(provenance.source_type),
    )
end

sidecar_file = joinpath(@__DIR__, "odepe_metadata.json")
wall_time_file = joinpath(@__DIR__, "wall_time_seconds.txt")
failure_reason_file = joinpath(@__DIR__, "failure_reason.txt")
metadata = Dict{String, Any}(
    "status" => "error",
    "raw_count" => 0,
    "best_count" => 0,
    "estimator" => "odepe_shade",
)

t_start = time()
analysis_failed = false

try
    result = ODEParameterEstimation.shade_lm_estimate(pep; opts = opts)

    metadata["status"] = isnothing(result.err) ? "no_result" : "ok"
    metadata["raw_count"] = 1                           # SHADE returns the single best polished candidate
    metadata["best_count"] = isnothing(result.err) ? 0 : 1
    metadata["besterror"] = result.err
    metadata["best_min_error"] = result.err
    metadata["best_mean_error"] = result.err
    metadata["best_median_error"] = result.err
    metadata["best_max_error"] = result.err
    metadata["best_approximation_error"] = result.err
    metadata["best_rms_error"] = result.err

    # Single-row CSV with state columns then parameter columns, matching the ODEPE schema.
    table = merge(
        Dict((string(x) => [result.states[x]] for x in states)),
        Dict((string(x) => [result.parameters[x]] for x in parameters)),
    )

    result_file = joinpath(@__DIR__, "result.csv")
    CSV.write(result_file, table, header = string.(collect(keys(table))))

    metadata["best"] = result_metadata(result)

    println("\n" * "="^60)
    println("SHADE+LM Estimation Complete!")
    println("="^60)
    println("\nResults saved to: ", result_file)
    println("Best error: ", result.err)
    println("Pre-polish error: ", result.provenance.pre_polish_error)
    println("Post-polish error: ", result.provenance.post_polish_error)
catch err
    analysis_failed = true
    err_str = sprint(showerror, err, catch_backtrace())
    metadata["status"] = "error"
    metadata["error"] = err_str
    try
        open(failure_reason_file, "w") do io
            println(io, "julia_exception")
            println(io, err_str)
        end
    catch
    end
finally
    elapsed = time() - t_start
    try
        open(wall_time_file, "w") do io
            println(io, elapsed)
        end
    catch
    end
    try
        open(sidecar_file, "w") do io
            JSON.print(io, metadata, 4)
        end
    catch
    end
end

println("Total time: ", time() - t_start)
println("===END===")

if analysis_failed
    exit(1)
end
