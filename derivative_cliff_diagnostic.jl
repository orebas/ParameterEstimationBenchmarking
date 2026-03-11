## derivative_cliff_diagnostic.jl
##
## Deep dive: why does 1e-8 noise cause a cliff in estimation accuracy?
## Compares ground-truth derivatives against GPR-interpolated derivatives
## at noise=0 vs noise=1e-8, using the EXACT benchmark data and system defs.
##
## Run on a compute node:
##   srun --account=gbassikqc --partition=partnsf --time=02:00:00 --cpus-per-task=4 --mem=16G \
##     bash -c 'export PATH="/scratch/oren-qc-13/julia-1.12.5/bin:$PATH" && \
##     export JULIA_DEPOT_PATH="/scratch/oren-qc-13/.julia" && \
##     julia /scratch/oren-qc-13/ParameterEstimationBenchmarking/derivative_cliff_diagnostic.jl'

using Pkg
Pkg.activate(raw"/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using ModelingToolkit: t_nounits as t, D_nounits as D
using Symbolics
using Symbolics: Num
using OrderedCollections
using Statistics
using Printf
using GaussianProcesses
using LineSearches
using Optim
using CSV
using JSON

const BENCHMARK_DIR = "/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_agprobust_comparison"
const FILETREE = joinpath(BENCHMARK_DIR, "filetree")
const MAX_DERIV = 5

# Systems to diagnose (cover a range of cliff severities from the benchmark)
const SYSTEMS = [
    "lotka_volterra",
    "harmonic_oscillator",
    "brusselator",
    "repressilator",
    "dc_motor",
    "sirt_treatment",
    "biohydrogenation",
    "daisy_mamil3",
    "slow_fast",
    "quadrotor",
]

const NOISE_PAIRS = ["0", "1em8"]

# ── Symbolic derivative computation (from study_approx.jl) ───────────
function calculate_observable_derivatives(eqs, mq_eqs, nderivs)
    equation_dict = Dict(eq.lhs => eq.rhs for eq in eqs)
    n_obs = length(mq_eqs)
    ObsDerivs = Symbolics.variables(:d_obs, 1:n_obs, 1:nderivs)
    SymDerivs = Vector{Vector{Equation}}(undef, nderivs)
    SymDerivs[1] = [ObsDerivs[i, 1] ~ substitute(
        expand_derivatives(D(mq_eqs[i].rhs)), equation_dict) for i in 1:n_obs]
    for j in 2:nderivs
        SymDerivs[j] = [ObsDerivs[i, j] ~ substitute(
            expand_derivatives(D(SymDerivs[j-1][i].rhs)), equation_dict) for i in 1:n_obs]
    end
    expanded_mq = copy(mq_eqs)
    append!(expanded_mq, vcat(SymDerivs...))
    return expanded_mq, ObsDerivs
end

# ── GPR interpolator (matches aaad_gpr_pivot — the default) ──────────
function fit_gpr_interpolator(xs, ys)
    y_mean = mean(ys)
    y_std = std(ys)
    y_std = max(y_std, 1e-10)
    ys_norm = (ys .- y_mean) ./ y_std

    kernel = SEIso(log(std(xs) / 8), 0.0)
    jitter = 1e-8
    ys_jitter = ys_norm .+ jitter * randn(length(ys))

    gp = GP(xs, ys_jitter, MeanZero(), kernel, -2.0)
    try
        GaussianProcesses.optimize!(gp; method=LBFGS(linesearch=LineSearches.BackTracking()))
    catch e
        @warn "GP optimization failed" exception=e
    end

    noise_est = exp(gp.logNoise.value)
    if noise_est < 1e-5
        # Falls back to AAA (same logic as aaad_gpr_pivot)
        interp = ODEParameterEstimation.aaad(xs, ys)
        return interp, :AAA, noise_est
    else
        func = x -> begin
            pred, _ = GaussianProcesses.predict_y(gp, [x])
            return y_std * pred[1] + y_mean
        end
        return func, :GPR, noise_est
    end
end

# ── Build system from benchmark script.jl ────────────────────────────
function load_system_code(system_name, test_idx=0)
    script_path = joinpath(FILETREE, "odepe_default",
        "$(system_name)_$(test_idx)_0", "script.jl")
    lines = readlines(script_path)

    # Find the end of system definition (the create_ordered_ode_system call)
    end_line = 0
    in_create = false
    for (i, line) in enumerate(lines)
        if occursin("create_ordered_ode_system", line)
            in_create = true
        end
        if in_create && occursin(")", line)
            end_line = i
            break
        end
    end

    # Extract just the system definition lines (skip package loading)
    code_lines = String[]
    skip_patterns = ["###", "using ", "Pkg.activate"]
    for (i, line) in enumerate(lines)
        i > end_line && break
        any(p -> occursin(p, line), skip_patterns) && continue
        push!(code_lines, line)
    end
    return join(code_lines, "\n")
end

# ── Collect results as flat vectors ──────────────────────────────────
r_system = String[]
r_noise = String[]
r_obs = String[]
r_obs_idx = Int[]
r_deriv = Int[]
r_interp_type = String[]
r_gp_noise = Float64[]
r_rmse = Float64[]
r_mae = Float64[]
r_max_err = Float64[]
r_rel_rmse = Float64[]
r_truth_scale = Float64[]

function record!(sys, noise, obs, oi, d, itype, gpn, rmse, mae, maxe, rrmse, tscale)
    push!(r_system, sys); push!(r_noise, noise); push!(r_obs, obs)
    push!(r_obs_idx, oi); push!(r_deriv, d); push!(r_interp_type, itype)
    push!(r_gp_noise, gpn); push!(r_rmse, rmse); push!(r_mae, mae)
    push!(r_max_err, maxe); push!(r_rel_rmse, rrmse); push!(r_truth_scale, tscale)
end

# ── Per-system processing function (called via invokelatest) ─────────
function process_system(system_name)
    # Access eval'd globals
    _model = Main.model
    _mq = Main.mq
    _states = Main.states
    _parameters = Main.parameters
    _ic = Main.ic
    _p_true = Main.p_true
    _time_interval = Main.time_interval
    _datasize = Main.datasize

    # Build augmented system with derivative observables
    expanded_mq, obs_derivs = calculate_observable_derivatives(
        equations(_model.system), _mq, MAX_DERIV)
    @named deriv_sys = ODESystem(equations(_model.system), t; observed=expanded_mq)
    ssys = structural_simplify(deriv_sys)

    # Solve ODE with true params at high accuracy for ground truth derivatives
    ic_dict = OrderedDict(_states .=> _ic)
    p_dict = OrderedDict(_parameters .=> _p_true)
    prob = ODEProblem(ssys, ic_dict, (_time_interval[1], _time_interval[2]), p_dict)
    t_grid = range(_time_interval[1], _time_interval[2], length=_datasize)
    sol = solve(prob, AutoVern9(Rodas4P()), abstol=1e-14, reltol=1e-14, saveat=t_grid)

    if sol.retcode != ReturnCode.Success
        println("  SKIPPING: ODE solve failed with $(sol.retcode)")
        return
    end

    ts = collect(Float64, sol.t)
    n_obs = length(_mq)

    for noise_tag in NOISE_PAIRS
        println("\n  --- noise = $noise_tag ---")

        data_path = joinpath(FILETREE, "odepe_default",
            "$(system_name)_0_$(noise_tag)", "data.csv")
        if !isfile(data_path)
            println("    SKIPPING: $data_path not found")
            continue
        end
        csv_data = CSV.read(data_path, Tuple, header=false)

        for obs_idx in 1:n_obs
            obs_eq = _mq[obs_idx]
            obs_key = string(Num(obs_eq.rhs))

            t_data = collect(Float64, csv_data[1])
            y_data = collect(Float64, csv_data[obs_idx + 1])

            interp_func, interp_type, gp_noise_est = fit_gpr_interpolator(t_data, y_data)

            @printf("    obs=%s  interp=%s  gp_noise=%.2e\n", obs_key, interp_type, gp_noise_est)

            for d in 0:MAX_DERIV
                if d == 0
                    pred = [interp_func(x) for x in ts]
                    truth = collect(Float64, sol[obs_eq.lhs])
                else
                    pred = try
                        [ODEParameterEstimation.nth_deriv(x -> interp_func(x), d, x) for x in ts]
                    catch e
                        @warn "  d$d failed" exception=e
                        fill(NaN, length(ts))
                    end
                    truth = collect(Float64, sol(ts, idxs=obs_derivs[obs_idx, d]))
                end

                abs_errors = abs.(pred .- truth)
                truth_scale = max(mean(abs.(truth)), 1e-15)
                rmse = sqrt(mean(abs_errors .^ 2))
                mae_val = mean(abs_errors)
                max_err = maximum(abs_errors)
                rel_rmse = rmse / truth_scale

                record!(system_name, noise_tag, obs_key, obs_idx, d,
                    string(interp_type), gp_noise_est, rmse, mae_val, max_err, rel_rmse, truth_scale)

                @printf("      d%d: RMSE=%.2e  relRMSE=%.2e  maxErr=%.2e  truth_scale=%.2e\n",
                    d, rmse, rel_rmse, max_err, truth_scale)
            end
        end
    end
end

# ── Main loop ────────────────────────────────────────────────────────
for system_name in SYSTEMS
    println("\n" * "="^70)
    println("SYSTEM: $system_name")
    println("="^70)

    code = load_system_code(system_name, 0)
    try
        eval(Meta.parse("begin\n$code\nend"))
    catch e
        println("  SKIPPING: Failed to eval system definition: $e")
        continue
    end

    # Use invokelatest to cross the world age barrier
    Base.invokelatest(process_system, system_name)
end

# ── Save CSV ─────────────────────────────────────────────────────────
outpath = joinpath(@__DIR__, "derivative_cliff_results.csv")
open(outpath, "w") do io
    println(io, "system,noise,observable,obs_idx,deriv_order,interp_type,gp_noise_est,rmse,mae,max_error,rel_rmse,truth_scale")
    for i in eachindex(r_system)
        println(io, "$(r_system[i]),$(r_noise[i]),$(r_obs[i]),$(r_obs_idx[i]),$(r_deriv[i]),$(r_interp_type[i]),$(r_gp_noise[i]),$(r_rmse[i]),$(r_mae[i]),$(r_max_err[i]),$(r_rel_rmse[i]),$(r_truth_scale[i])")
    end
end
println("\n\nResults saved to: $outpath")
println("Total rows: $(length(r_system))")

# ── Summary tables ───────────────────────────────────────────────────
println("\n" * "="^70)
println("SUMMARY: Median rel_rmse across observables, by system × deriv order")
println("="^70)

for noise_tag in NOISE_PAIRS
    println("\n  noise = $noise_tag:")
    @printf("  %-22s", "system")
    for d in 0:MAX_DERIV
        @printf("  d%-9d", d)
    end
    println()
    println("  " * "-"^90)

    for sys in SYSTEMS
        @printf("  %-22s", sys)
        for d in 0:MAX_DERIV
            vals = [r_rel_rmse[i] for i in eachindex(r_system)
                    if r_system[i] == sys && r_noise[i] == noise_tag && r_deriv[i] == d]
            med = isempty(vals) ? NaN : median(vals)
            @printf("  %-10.2e", med)
        end
        println()
    end
end

println("\n" * "="^70)
println("CLIFF RATIO: rel_rmse(1e-8) / rel_rmse(0) by system × deriv order")
println("  (How much worse does derivative accuracy get with 1e-8 noise?)")
println("="^70)
@printf("%-22s", "system")
for d in 0:MAX_DERIV
    @printf("  d%-9d", d)
end
@printf("  %-10s  %-10s", "interp_0", "interp_1e8")
println()
println("-"^110)

for sys in SYSTEMS
    @printf("%-22s", sys)
    for d in 0:MAX_DERIV
        v0 = [r_rel_rmse[i] for i in eachindex(r_system)
              if r_system[i] == sys && r_noise[i] == "0" && r_deriv[i] == d]
        v8 = [r_rel_rmse[i] for i in eachindex(r_system)
              if r_system[i] == sys && r_noise[i] == "1em8" && r_deriv[i] == d]
        med0 = isempty(v0) ? NaN : median(v0)
        med8 = isempty(v8) ? NaN : median(v8)
        ratio = (med0 > 0 && !isnan(med0)) ? med8 / med0 : NaN
        @printf("  %-10.1f", ratio)
    end
    # Show which interpolator was selected at each noise level
    t0_vals = [r_interp_type[i] for i in eachindex(r_system)
               if r_system[i] == sys && r_noise[i] == "0" && r_deriv[i] == 0]
    t8_vals = [r_interp_type[i] for i in eachindex(r_system)
               if r_system[i] == sys && r_noise[i] == "1em8" && r_deriv[i] == 0]
    t0 = isempty(t0_vals) ? "?" : first(t0_vals)
    t8 = isempty(t8_vals) ? "?" : first(t8_vals)
    @printf("  %-10s  %-10s", t0, t8)
    println()
end

println("\n(interp_0/interp_1e8 = which interpolator aaad_gpr_pivot chose: AAA vs GPR)")
