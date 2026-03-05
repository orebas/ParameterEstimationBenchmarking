#!/usr/bin/env julia
#
# Interpolator Quick-Check: Solo AGP vs Multi-Interpolator on wombat HIV (datasize=1500)
#
# Config A — Solo AGPRobust (SE kernel)
# Config B — Multi-interpolator (6 methods: AGPRobust, AGPRobustRQ, AGPRobustSEpRQ,
#            AGPRobustSExRQ, AAADGPR, FHD)
#
# Each config runs twice: pass 1 = JIT warmup, pass 2 = timed.
# Same data (seed=42, noise=1e-8) for all 4 runs.

using ODEParameterEstimation
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using OrderedCollections
using Random
using Printf

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Define wombat rescaled HIV model (verbatim from benchmark hiv_0_1em8)
# ═══════════════════════════════════════════════════════════════════════════════
function make_hiv_wombat()
    parameters_sym = @parameters lm d beta a k uu c q b h
    states_sym = @variables x(t) yv(t) vv(t) w(t) z(t)
    observables_sym = @variables y1(t) y2(t) y3(t) y4(t)

    state_equations = [
        D(x)  ~ (2.0 * lm - 40.0 * d * x - 0.00016 * beta * x * vv) / 2000.0,
        D(yv) ~ (-2.0 * a * yv + 0.00016 * beta * x * vv) / 2.0,
        D(vv) ~ (200.0 * k * yv - 0.012 * uu * vv) / 0.002,
        D(w)  ~ (-0.008 * b * w - 0.08000000000000002 * c * q * w * yv + 0.4 * c * w * z * yv) / 2.0,
        D(z)  ~ -0.2 * h * z + 0.08000000000000002 * c * q * w * yv,
    ]

    measured_quantities = [
        y1 ~ 2.0 * w,
        y2 ~ z,
        y3 ~ 2000.0 * x,
        y4 ~ 0.002 * vv + 2.0 * yv,
    ]

    p_true = [0.662, 0.145, 0.806, 0.342, 0.214, 0.69, 0.11, 0.106, 0.116, 0.689]
    ic     = [0.57, 0.807, 0.559, 0.64, 0.855]

    model, mq = create_ordered_ode_system(
        "hiv_wombat", collect(states_sym), collect(parameters_sym),
        state_equations, measured_quantities
    )

    pep = ParameterEstimationProblem(
        "hiv_wombat",
        model,
        mq,
        nothing,             # data_sample — filled by sample_problem_data
        [0.0, 25.0],        # time_interval
        nothing,             # solver
        OrderedDict(collect(parameters_sym) .=> p_true),
        OrderedDict(collect(states_sym) .=> ic),
        0,                   # unident_count
    )

    return pep, parameters_sym, states_sym
end

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Compute max relative error across all 15 unknowns
# ═══════════════════════════════════════════════════════════════════════════════
const P_TRUE = OrderedDict(
    :lm => 0.662, :d => 0.145, :beta => 0.806, :a => 0.342, :k => 0.214,
    :uu => 0.69,  :c => 0.11,  :q => 0.106,  :b => 0.116,  :h => 0.689,
)
const IC_TRUE = OrderedDict(
    :x => 0.57, :yv => 0.807, :vv => 0.559, :w => 0.64, :z => 0.855,
)

function compute_max_rel_error(result::ParameterEstimationResult)
    max_err = 0.0
    for (sym, val) in result.parameters
        name = Symbol(sym)
        if haskey(P_TRUE, name) && abs(P_TRUE[name]) > 1e-15
            max_err = max(max_err, abs(val - P_TRUE[name]) / abs(P_TRUE[name]))
        end
    end
    for (sym, val) in result.states
        name = Symbol(sym)
        if haskey(IC_TRUE, name) && abs(IC_TRUE[name]) > 1e-15
            max_err = max(max_err, abs(val - IC_TRUE[name]) / abs(IC_TRUE[name]))
        end
    end
    return max_err
end

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Parse per-interpolator timing from captured diagnostics output
# ═══════════════════════════════════════════════════════════════════════════════
struct InterpTiming
    sym::String
    interp_time::Float64
    eval_time::Float64
    hc_time::Float64
    total_time::Float64
end

function parse_interp_timings(output::String)
    timings = Dict{String, InterpTiming}()

    # Parse TOTAL lines which contain all three sub-times
    for m in eachmatch(r"\[(\w+)\] TOTAL: ([\d.]+)s\s+\(interp=([\d.]+)s, eval=([\d.]+)s, HC=([\d.]+)s\)", output)
        sym = m.captures[1]
        timings[sym] = InterpTiming(
            sym,
            parse(Float64, m.captures[3]),
            parse(Float64, m.captures[4]),
            parse(Float64, m.captures[5]),
            parse(Float64, m.captures[2]),
        )
    end

    # Fallback: parse individual lines if TOTAL line not found for some interpolator
    for m in eachmatch(r"\[(\w+)\] Interpolant creation: ([\d.]+)s", output)
        sym = m.captures[1]
        haskey(timings, sym) && continue
        interp_t = parse(Float64, m.captures[2])
        eval_t = 0.0
        hc_t = 0.0
        total_t = interp_t
        # Try to find eval and HC for this sym
        eval_m = match(Regex("\\[$sym\\] Param evaluation at shooting points: ([\\d.]+)s"), output)
        if eval_m !== nothing
            eval_t = parse(Float64, eval_m.captures[1])
            total_t += eval_t
        end
        hc_m = match(Regex("\\[$sym\\] HC solve: ([\\d.]+)s"), output)
        if hc_m !== nothing
            hc_t = parse(Float64, hc_m.captures[1])
            total_t += hc_t
        end
        timings[sym] = InterpTiming(sym, interp_t, eval_t, hc_t, total_t)
    end

    return timings
end

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Run-and-capture: redirect stdout, time execution, return results
# ═══════════════════════════════════════════════════════════════════════════════
function run_and_capture(pep_data, opts, label::String)
    println("\n--- Starting: $label ---")
    flush(stdout)

    local result
    local wall_time
    local output_str

    tmpfile = tempname() * ".log"
    wall_time = @elapsed begin
        open(tmpfile, "w") do io
            result = redirect_stdout(io) do
                analyze_parameter_estimation_problem(pep_data, opts)
            end
        end
    end

    output_str = read(tmpfile, String)
    rm(tmpfile, force=true)
    println("  Completed in $(round(wall_time, digits=1))s")
    flush(stdout)

    return result, wall_time, output_str
end

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Main experiment
# ═══════════════════════════════════════════════════════════════════════════════
function run_interpolator_experiment()
    println("=" ^ 80)
    println("INTERPOLATOR QUICK-CHECK: Solo AGPRobust vs Multi-Interpolator (5 methods)")
    println("+ Config C/D: No parameter homotopy (fresh solve at every shooting point)")
    println("Model: wombat rescaled HIV  |  datasize=1500  |  noise=1e-8")
    println("Note: InterpolatorFHD dropped (fhd5 undef bug in ODEPE)")
    println("=" ^ 80)

    # --- Build model & sample data once ---
    pep, params_sym, states_sym = make_hiv_wombat()

    n_unknowns = length(params_sym) + length(states_sym)  # 15

    # Shared opts for sampling (Config A settings, used just for data generation)
    sample_opts = EstimationOptions(
        datasize = 1500,
        time_interval = [0.0, 25.0],
        noise_level = 1e-8,
    )

    println("\nSampling data (datasize=1500, noise=1e-8, seed=42)...")
    Random.seed!(42)
    pep_data = sample_problem_data(pep, sample_opts)
    println("  Data sampled. $(length(pep_data.data_sample["t"])) time points.")

    # --- Config A: Solo AGPRobust ---
    opts_A = EstimationOptions(
        datasize = 1500,
        time_interval = [0.0, 25.0],
        noise_level = 1e-8,
        system_solver = SolverHC,
        flow = FlowStandard,
        use_si_template = true,
        use_parameter_homotopy = true,
        polish_solver_solutions = true,
        polish_solutions = false,
        polish_maxiters = 5000,
        polish_method = PolishBFGS,
        opt_maxiters = 200000,
        opt_lb = 1e-5 * ones(n_unknowns),
        opt_ub = 10.0 * ones(n_unknowns),
        abstol = 1e-13,
        reltol = 1e-13,
        polish_maxtime = 1200.0,
        polish_divergence_factor = 10.0,
        polish_stagnation_window = 50,
        polish_ode_maxiters = 20000,
        diagnostics = true,
        profile_phases = true,
        interpolator = InterpolatorAGPRobust,
    )

    # --- Config B: Multi-interpolator (6 methods) ---
    opts_B = EstimationOptions(
        datasize = 1500,
        time_interval = [0.0, 25.0],
        noise_level = 1e-8,
        system_solver = SolverHC,
        flow = FlowStandard,
        use_si_template = true,
        use_parameter_homotopy = true,
        polish_solver_solutions = true,
        polish_solutions = false,
        polish_maxiters = 5000,
        polish_method = PolishBFGS,
        opt_maxiters = 200000,
        opt_lb = 1e-5 * ones(n_unknowns),
        opt_ub = 10.0 * ones(n_unknowns),
        abstol = 1e-13,
        reltol = 1e-13,
        polish_maxtime = 1200.0,
        polish_divergence_factor = 10.0,
        polish_stagnation_window = 50,
        polish_ode_maxiters = 20000,
        diagnostics = true,
        profile_phases = true,
        interpolators = [
            InterpolatorAGPRobust,
            InterpolatorAGPRobustRQ,
            InterpolatorAGPRobustSEpRQ,
            InterpolatorAGPRobustSExRQ,
            InterpolatorAAADGPR,
        ],
    )

    # --- Config C: Solo AGPRobust, NO parameter homotopy (fresh solve each point) ---
    opts_C = EstimationOptions(
        datasize = 1500,
        time_interval = [0.0, 25.0],
        noise_level = 1e-8,
        system_solver = SolverHC,
        flow = FlowStandard,
        use_si_template = true,
        use_parameter_homotopy = false,
        polish_solver_solutions = true,
        polish_solutions = false,
        polish_maxiters = 5000,
        polish_method = PolishBFGS,
        opt_maxiters = 200000,
        opt_lb = 1e-5 * ones(n_unknowns),
        opt_ub = 10.0 * ones(n_unknowns),
        abstol = 1e-13,
        reltol = 1e-13,
        polish_maxtime = 1200.0,
        polish_divergence_factor = 10.0,
        polish_stagnation_window = 50,
        polish_ode_maxiters = 20000,
        diagnostics = true,
        profile_phases = true,
        interpolator = InterpolatorAGPRobust,
    )

    # --- Config D: Multi-interpolator, NO parameter homotopy ---
    opts_D = EstimationOptions(
        datasize = 1500,
        time_interval = [0.0, 25.0],
        noise_level = 1e-8,
        system_solver = SolverHC,
        flow = FlowStandard,
        use_si_template = true,
        use_parameter_homotopy = false,
        polish_solver_solutions = true,
        polish_solutions = false,
        polish_maxiters = 5000,
        polish_method = PolishBFGS,
        opt_maxiters = 200000,
        opt_lb = 1e-5 * ones(n_unknowns),
        opt_ub = 10.0 * ones(n_unknowns),
        abstol = 1e-13,
        reltol = 1e-13,
        polish_maxtime = 1200.0,
        polish_divergence_factor = 10.0,
        polish_stagnation_window = 50,
        polish_ode_maxiters = 20000,
        diagnostics = true,
        profile_phases = true,
        interpolators = [
            InterpolatorAGPRobust,
            InterpolatorAGPRobustRQ,
            InterpolatorAGPRobustSEpRQ,
            InterpolatorAGPRobustSExRQ,
            InterpolatorAAADGPR,
        ],
    )

    # --- Storage ---
    overall_results = []   # (label, pass, wall_time, max_rel_err, success, n_sol)
    config_b_timings = Dict{String, InterpTiming}()
    config_b_per_interp_accuracy = Dict{Symbol, NamedTuple}()
    config_b_output_timed = ""
    config_d_timings = Dict{String, InterpTiming}()
    config_d_per_interp_accuracy = Dict{Symbol, NamedTuple}()
    config_d_output_timed = ""

    # --- Run all 8 configurations (4 configs × 2 passes) ---
    configs = [
        ("Solo AGP+Hom", opts_A),
        ("Solo AGP NoHom", opts_C),
        ("Multi+Hom", opts_B),
        ("Multi NoHom", opts_D),
    ]

    for (config_label, opts) in configs
        for pass_label in ["warmup", "timed"]
            label = "$config_label — $pass_label"

            local result, wall_time, output_str
            try
                result, wall_time, output_str = run_and_capture(pep_data, opts, label)
            catch e
                println("  ERROR in $label: ", sprint(showerror, e))
                push!(overall_results, (
                    config = config_label, pass = pass_label,
                    wall_time = NaN, max_rel_err = Inf, success = false, n_sol = 0,
                ))
                continue
            end

            # Extract solutions
            solved = result[1][1]  # Vector{ParameterEstimationResult}
            n_sol = length(solved)

            # Compute best accuracy
            best_err = Inf
            for r in solved
                err = compute_max_rel_error(r)
                best_err = min(best_err, err)
            end
            success = best_err < 0.1

            push!(overall_results, (
                config = config_label,
                pass = pass_label,
                wall_time = wall_time,
                max_rel_err = best_err,
                success = success,
                n_sol = n_sol,
            ))

            @printf("  → max_rel_err=%.4e  n_sol=%d  [%s]\n",
                best_err, n_sol, success ? "OK" : "FAIL")

            # Parse per-interpolator details for multi-interpolator configs (timed pass)
            interp_symbols = [:agp_robust, :agp_robust_rq, :agp_robust_se_plus_rq,
                              :agp_robust_se_times_rq, :aaad_gpr]

            if config_label == "Multi+Hom" && pass_label == "timed"
                config_b_output_timed = output_str
                config_b_timings = parse_interp_timings(output_str)
                for isym in interp_symbols
                    matching = filter(r -> r.interpolator_source == isym, solved)
                    best = isempty(matching) ? Inf : minimum(compute_max_rel_error(r) for r in matching)
                    config_b_per_interp_accuracy[isym] = (
                        best_err = best, success = best < 0.1, n_solutions = length(matching)
                    )
                end
            end

            if config_label == "Multi NoHom" && pass_label == "timed"
                config_d_output_timed = output_str
                config_d_timings = parse_interp_timings(output_str)
                for isym in interp_symbols
                    matching = filter(r -> r.interpolator_source == isym, solved)
                    best = isempty(matching) ? Inf : minimum(compute_max_rel_error(r) for r in matching)
                    config_d_per_interp_accuracy[isym] = (
                        best_err = best, success = best < 0.1, n_solutions = length(matching)
                    )
                end
            end

            # Print per-interpolator timing for solo configs
            if pass_label == "timed" && startswith(config_label, "Solo")
                timings_solo = parse_interp_timings(output_str)
                if !isempty(timings_solo)
                    println("  Per-interpolator timing:")
                    for (sym, ti) in timings_solo
                        @printf("    [%s] interp=%.1fs eval=%.1fs HC=%.1fs total=%.1fs\n",
                            sym, ti.interp_time, ti.eval_time, ti.hc_time, ti.total_time)
                    end
                end
            end
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # 6. Print summary tables
    # ═══════════════════════════════════════════════════════════════════════════
    println("\n" * "=" ^ 80)
    println("TABLE 1: Overall Results")
    println("=" ^ 80)
    @printf("%-20s | %-7s | %10s | %12s | %7s | %5s\n",
        "Config", "Pass", "wall_time", "max_rel_err", "success", "n_sol")
    println("-" ^ 80)
    for r in overall_results
        @printf("%-20s | %-7s | %9.1fs | %12.4e | %7s | %5d\n",
            r.config, r.pass, r.wall_time, r.max_rel_err,
            r.success ? "YES" : "NO", r.n_sol)
    end

    # --- Per-interpolator tables for multi-interpolator configs ---
    sym_order = ["agp_robust", "agp_robust_rq", "agp_robust_se_plus_rq",
                 "agp_robust_se_times_rq", "aaad_gpr"]

    for (table_label, timings_dict, acc_dict) in [
        ("Multi+Hom (Config B)", config_b_timings, config_b_per_interp_accuracy),
        ("Multi NoHom (Config D)", config_d_timings, config_d_per_interp_accuracy),
    ]
        println("\n" * "=" ^ 80)
        println("Per-Interpolator Timing — $table_label, timed pass")
        println("=" ^ 80)
        @printf("%-25s | %10s | %10s | %10s | %10s\n",
            "Interpolator", "interp_t", "eval_t", "hc_t", "total_t")
        println("-" ^ 80)
        for sym in sym_order
            if haskey(timings_dict, sym)
                ti = timings_dict[sym]
                @printf("%-25s | %9.1fs | %9.1fs | %9.1fs | %9.1fs\n",
                    sym, ti.interp_time, ti.eval_time, ti.hc_time, ti.total_time)
            else
                @printf("%-25s | %10s | %10s | %10s | %10s\n",
                    sym, "N/A", "N/A", "N/A", "N/A")
            end
        end

        println("\n" * "=" ^ 80)
        println("Per-Interpolator Accuracy — $table_label, timed pass")
        println("=" ^ 80)
        @printf("%-25s | %15s | %7s | %11s\n",
            "Interpolator", "best_max_rel_err", "success", "n_solutions")
        println("-" ^ 80)
        for sym_str in sym_order
            sym = Symbol(sym_str)
            if haskey(acc_dict, sym)
                acc = acc_dict[sym]
                @printf("%-25s | %15.4e | %7s | %11d\n",
                    sym_str, acc.best_err,
                    acc.success ? "YES" : "NO", acc.n_solutions)
            else
                @printf("%-25s | %15s | %7s | %11s\n",
                    sym_str, "N/A", "N/A", "N/A")
            end
        end
    end

    # --- Homotopy vs NoHom comparison ---
    println("\n" * "=" ^ 80)
    println("HOMOTOPY COMPARISON (per-interpolator, timed pass)")
    println("=" ^ 80)
    @printf("%-25s | %12s %5s | %12s %5s | %s\n",
        "Interpolator", "Hom err", "n", "NoHom err", "n", "Winner")
    println("-" ^ 80)
    for sym_str in sym_order
        sym = Symbol(sym_str)
        hom = get(config_b_per_interp_accuracy, sym, nothing)
        nohom = get(config_d_per_interp_accuracy, sym, nothing)
        if hom !== nothing && nohom !== nothing
            winner = hom.best_err < nohom.best_err ? "Hom" :
                     nohom.best_err < hom.best_err ? "NoHom" : "Tie"
            @printf("%-25s | %12.4e %5d | %12.4e %5d | %s\n",
                sym_str, hom.best_err, hom.n_solutions,
                nohom.best_err, nohom.n_solutions, winner)
        else
            @printf("%-25s | %12s %5s | %12s %5s | %s\n",
                sym_str, "N/A", "", "N/A", "", "")
        end
    end

    # --- Raw diagnostics for debugging ---
    for (label, output) in [("Multi+Hom (B)", config_b_output_timed),
                             ("Multi NoHom (D)", config_d_output_timed)]
        println("\n" * "=" ^ 80)
        println("RAW DIAGNOSTICS — $label, timed pass")
        println("=" ^ 80)
        for line in split(output, '\n')
            if occursin(r"\[.*\]", line) || occursin("Interpolator", line) ||
               occursin("Parameter Homotopy", line) || occursin("HC-PARAM", line) ||
               occursin("solutions", line)
                println("  ", line)
            end
        end
    end

    println("\n" * "=" ^ 80)
    println("EXPERIMENT COMPLETE")
    println("=" ^ 80)

    return overall_results
end

# ═══════════════════════════════════════════════════════════════════════════════
# Run
# ═══════════════════════════════════════════════════════════════════════════════
results = run_interpolator_experiment()
