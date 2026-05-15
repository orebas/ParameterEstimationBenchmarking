# Minimal reproducer: polish hc=56 (the err-cap-setter) with various opts
# and see which (if any) recovers truth basin (post-polish err ≤ 1e-9).
#
# In OLD bench (Optim 1.13.3, LSO 0.8.8), polish from this start lands at err 4.29e-11.
# In NEW deep_dump (Optim 2.0.1, LSO 0.8.9), polish from the same start lands at err 2.21e-3.
# Same polish_method, same opts, same script — only package versions differ.
#
# Usage: julia --startup-file=no --project=environments/julia_odepe results/.../polish_repro.jl

using Pkg; Pkg.activate(raw"/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")
using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV
using Optim, LineSearches
using Symbolics: Num
using Printf
using LinearAlgebra

# --- Truth values for oracle reporting ---
truth = OrderedDict(
    :theta_m => 0.311, :omega_m => 0.834, :theta_t => 0.633, :omega_t => 0.45,
    :Jm => 0.535, :Jt => 0.14, :bm => 0.309, :bt => 0.621, :k => 0.877,
)

# --- hc=56 starting point (from raw_candidates.csv) ---
hc56_states = OrderedDict(
    :theta_m => 0.6718541127893283,
    :omega_m => 0.4231385029830127,
    :theta_t => 0.5167385527937252,
    :omega_t => 0.5575676862232415,
)
hc56_params = OrderedDict(
    :Jm => 0.5502800376625937,
    :Jt => 0.08020075681641373,
    :bm => 0.6126801538708946,
    :bt => 0.014153823340691225,
    :k => 0.020865876700571186,
)

# --- System ---
name = "flexible_arm"
parameters = @parameters Jm Jt bm bt k
states = @variables theta_m(t) omega_m(t) theta_t(t) omega_t(t)
observables = @variables y1(t) y2(t)
state_equations = [
    D(theta_m) ~ omega_m,
    D(omega_m) ~ (0.5 - 0.1*bm*omega_m - 20.0*k*(-0.5*theta_t + 0.5*theta_m)) / (0.1*Jm),
    D(theta_t) ~ omega_t,
    D(omega_t) ~ (-0.05*bt*omega_t - 20.0*k*(0.5*theta_t - 0.5*theta_m)) / (0.05*Jt),
]
measured_quantities = [
    y1 ~ 0.5*theta_m,
    y2 ~ 0.5*theta_t,
]
ic = [0.311, 0.834, 0.633, 0.45]
p_true = [0.535, 0.14, 0.309, 0.621, 0.877]

time_interval = [0.0, 10.0]
datasize = 750

model, mq = create_ordered_ode_system(name, states, parameters, state_equations, measured_quantities)

data_csv = "/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_numbat_2026-05-12/probes/flexible_arm_0_1em8/deep_dump/data.csv"
csv_data = CSV.read(data_csv, Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
    data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end

pep = ParameterEstimationProblem(
    name, model, mq, data_sample, time_interval, nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0,
)

# --- Build the polish context using the same opts as the deep_dump probe ---
opts_base = EstimationOptions(
    datasize = length(data_sample["t"]),
    noise_level = 0.000,
    system_solver = SolverHC,
    flow = FlowStandard,
    use_si_template = true,
    shooting_points = 20,
    shooting_warp = true,
    shooting_warp_beta = 3.0,
    use_parameter_homotopy = true,
    use_multipoint = true,
    multipoint_n_points = 2,
    multipoint_max_pairs = 15,
    polish_solver_solutions = true,
    polish_solutions = true,
    polish_maxiters = 5000,
    polish_method = PolishLSOBoundedLog,
    opt_maxiters = 200000,
    opt_lb = 1e-05 * ones(length(ic) + length(p_true)),
    opt_ub = 10.0 * ones(length(ic) + length(p_true)),
    abstol = 1e-12,
    reltol = 1e-12,
    polish_maxtime = 600.0,
    polish_divergence_factor = 10.0,
    polish_stagnation_window = 50,
    polish_ode_maxiters = 20000,
    diagnostics = false,
    branch_cluster_eps = 1e-12,
    branch_detection = true,
)

ctx = ODEParameterEstimation._build_polish_context(pep; opts = opts_base)

# Build the p0 vector in the same order as the context expects:
#   p0 = [ic values in ctx.unknown_syms order; param values in ctx.param_syms order]
p0 = Float64[]
sym_to_str(s) = string(s) |> x -> replace(x, r"\(t\)$" => "")  # strip (t)
for s in ctx.unknown_syms
    nm = Symbol(sym_to_str(s))
    push!(p0, hc56_states[nm])
end
for p in ctx.param_syms
    nm = Symbol(string(p))
    push!(p0, hc56_params[nm])
end

println("=== hc=56 starting point ===")
println("p0 = ", p0)
println()

# --- Helper to compute oracle err post-polish ---
function oracle_err(result, truth)
    vals = Float64[]
    for (k, v) in pairs(result.states)
        nm = Symbol(sym_to_str(k))
        haskey(truth, nm) || continue
        tv = truth[nm]
        push!(vals, abs(tv) > 1e-15 ? abs(v - tv) / abs(tv) : abs(v - tv))
    end
    for (k, v) in pairs(result.parameters)
        nm = Symbol(string(k))
        haskey(truth, nm) || continue
        tv = truth[nm]
        push!(vals, abs(tv) > 1e-15 ? abs(v - tv) / abs(tv) : abs(v - tv))
    end
    return isempty(vals) ? Inf : maximum(vals)
end

function run_one(label, opts; lso_delta = 10.0, lso_x_tol = -1.0, lso_f_tol = -1.0, lso_g_tol = -1.0,
                 maxiters = 5000, maxtime = 600.0, polish_method = nothing)
    pm = isnothing(polish_method) ? opts.polish_method : polish_method
    println("---- $label ----")
    @printf("  polish_method = %s   lso_delta=%.1e  maxiters=%d\n", pm, lso_delta, maxiters)
    t0 = time()
    optimizer = ODEParameterEstimation.is_residual_polish_method(pm) ? nothing :
                ODEParameterEstimation.get_polish_optimizer(pm)()
    result, opt_result = try
        ODEParameterEstimation._polish_single_from_context(
            ctx, p0;
            optimizer = isnothing(optimizer) ? BFGS() : optimizer,
            polish_method = pm,
            maxiters = maxiters,
            maxtime = maxtime,
            divergence_factor = opts.polish_divergence_factor,
            stagnation_window = opts.polish_stagnation_window,
            lso_delta = lso_delta,
            lso_x_tol = lso_x_tol,
            lso_f_tol = lso_f_tol,
            lso_g_tol = lso_g_tol,
        )
    catch e
        @warn "polish threw: $e"
        return
    end
    dt = time() - t0
    o = oracle_err(result, truth)
    err = isnothing(result.err) ? NaN : result.err
    ppe = result.provenance.post_polish_error
    @printf("  result oracle=%.3e  err=%.3e  ppe=%.3e  dt=%.1fs\n", o, err, ppe, dt)
    @printf("  final values: ")
    for (k, v) in pairs(result.states)
        @printf("%s=%.4f ", sym_to_str(k), v)
    end
    for (k, v) in pairs(result.parameters)
        @printf("%s=%.4f ", string(k), v)
    end
    println()
    if any(occursin("polish_maxtime_exceeded", string(n)) for n in result.provenance.notes)
        println("  ** polish_maxtime_exceeded **")
    end
    println()
    return result
end

# === Baseline: what we currently get ===
run_one("BASELINE: PolishLSOBoundedLog, Δ=10, maxiters=5000", opts_base)

# === Variations on lso_delta (trust region size) ===
run_one("Δ=1.0   (smaller initial trust region)", opts_base; lso_delta=1.0)
run_one("Δ=100.0 (larger)", opts_base; lso_delta=100.0)
run_one("Δ=1000.0 (huge)", opts_base; lso_delta=1000.0)

# === More iterations ===
run_one("Δ=10, maxiters=50000", opts_base; maxiters=50000)

# === Tighter tolerances ===
run_one("tight tolerances 1e-15", opts_base; lso_x_tol=1e-15, lso_f_tol=1e-15, lso_g_tol=1e-15)

# === Other polish_methods ===
run_one("PolishFastLMBoundedLog", opts_base; polish_method=PolishFastLMBoundedLog)
run_one("PolishBFGS (scalar)", opts_base; polish_method=PolishBFGS)
run_one("PolishLBFGS (scalar)", opts_base; polish_method=PolishLBFGS)
run_one("PolishNewtonTrust (scalar)", opts_base; polish_method=PolishNewtonTrust)

println("=== DONE ===")
