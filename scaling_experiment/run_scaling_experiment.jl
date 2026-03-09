#!/usr/bin/env julia
#
# Scaling Experiment: Does rescaling state variables hurt HC parameter estimation?
#
# Hypothesis: The wombat benchmark's equation rescaling (e.g., y4 = 0.002*v_s + 2*y_s)
# creates an ill-conditioned polynomial system that HC can't solve accurately under noise.
#
# Method: Define v_s = alpha * v and sweep alpha from 1 (well-scaled) to 500 (benchmark-like).
# The measured data y4 = y + v = y + v_s/alpha is IDENTICAL for all alpha values.
# Only the polynomial system coefficients change.
#
# Expected: noise=0 succeeds for all alpha; noise=1e-8 degrades with increasing alpha.

using ODEParameterEstimation
using ModelingToolkit
using OrderedCollections
using Random
using Printf

# ---------------------------------------------------------------------------
# Build the HIV model with a scaled virus variable: v_s = alpha * v
# ---------------------------------------------------------------------------
function make_hiv_scaled(; alpha::Float64 = 1.0)
    @parameters lm d beta a k u c q b h
    t = ModelingToolkit.t_nounits
    D = ModelingToolkit.D_nounits

    @variables x(t) y(t) v_s(t) w(t) z(t) y1(t) y2(t) y3(t) y4(t)

    states = [x, y, v_s, w, z]
    parameters = [lm, d, beta, a, k, u, c, q, b, h]

    # Original HIV model (alpha=1):
    #   D(x) = lm - d*x - beta*x*v
    #   D(y) = beta*x*v - a*y
    #   D(v) = k*y - u*v
    #   D(w) = c*x*y*w - c*q*y*w - b*w
    #   D(z) = c*q*y*w - h*z
    # With v_s = alpha*v, so v = v_s/alpha:
    #   D(x)   = lm - d*x - (beta/alpha)*x*v_s
    #   D(y)   = (beta/alpha)*x*v_s - a*y
    #   D(v_s) = alpha*k*y - u*v_s
    #   D(w)   = c*x*y*w - c*q*y*w - b*w       (unchanged, no v)
    #   D(z)   = c*q*y*w - h*z                  (unchanged, no v)
    # Measurement: y4 = y + v = y + (1/alpha)*v_s

    inv_alpha = 1.0 / alpha

    state_equations = [
        D(x)   ~ lm - d * x - (beta * inv_alpha) * x * v_s,
        D(y)   ~ (beta * inv_alpha) * x * v_s - a * y,
        D(v_s) ~ (alpha * k) * y - u * v_s,
        D(w)   ~ c * x * y * w - c * q * y * w - b * w,
        D(z)   ~ c * q * y * w - h * z,
    ]

    measured_quantities = [
        y1 ~ w,
        y2 ~ z,
        y3 ~ x,
        y4 ~ y + inv_alpha * v_s,
    ]

    # True parameter values (from runtests.jl hiv())
    p_true_vals = [0.091, 0.181, 0.273, 0.364, 0.455, 0.545, 0.636, 0.727, 0.818, 0.909]

    # True ICs: x=0.167, y=0.333, v=0.5, w=0.667, z=0.833
    # v_s(0) = alpha * v(0) = alpha * 0.5
    ic_vals = [0.167, 0.333, alpha * 0.5, 0.667, 0.833]

    ordered_system, mqs = create_ordered_ode_system(
        "hiv_scaled_alpha_$(Int(alpha))", states, parameters, state_equations, measured_quantities
    )

    pep = ParameterEstimationProblem(
        "hiv_scaled_alpha_$(Int(alpha))",
        ordered_system,
        mqs,
        nothing,           # data_sample (will be filled by sample_problem_data)
        [-1.0, 1.0],      # recommended_time_interval
        nothing,           # solver
        OrderedDict(parameters .=> p_true_vals),
        OrderedDict(states .=> ic_vals),
        0,                 # unident_count
    )

    return pep
end

# ---------------------------------------------------------------------------
# Compute max relative error across all unknowns
# ---------------------------------------------------------------------------
function compute_max_rel_error(result::ParameterEstimationResult, alpha::Float64)
    # True values
    p_true = OrderedDict(
        :lm => 0.091, :d => 0.181, :beta => 0.273, :a => 0.364, :k => 0.455,
        :u => 0.545, :c => 0.636, :q => 0.727, :b => 0.818, :h => 0.909,
    )
    ic_true = OrderedDict(
        :x => 0.167, :y => 0.333, :v_s => alpha * 0.5, :w => 0.667, :z => 0.833,
    )

    max_err = 0.0

    # Check parameters
    for (sym, val) in result.parameters
        name = Symbol(sym)
        if haskey(p_true, name)
            true_val = p_true[name]
            if abs(true_val) > 1e-15
                rel_err = abs(val - true_val) / abs(true_val)
                max_err = max(max_err, rel_err)
            end
        end
    end

    # Check states (ICs)
    for (sym, val) in result.states
        name = Symbol(sym)
        if haskey(ic_true, name)
            true_val = ic_true[name]
            if abs(true_val) > 1e-15
                rel_err = abs(val - true_val) / abs(true_val)
                max_err = max(max_err, rel_err)
            end
        end
    end

    return max_err
end

# ---------------------------------------------------------------------------
# Main experiment
# ---------------------------------------------------------------------------
function run_experiment()
    alphas = [1.0, 10.0, 100.0, 500.0]
    noises = [0.0, 1e-8]
    seeds  = 1:4

    println("=" ^ 80)
    println("SCALING EXPERIMENT: HIV model with v_s = alpha * v")
    println("Sweep alpha ∈ $alphas, noise ∈ $noises, seeds ∈ $seeds")
    println("Total runs: $(length(alphas) * length(noises) * length(seeds))")
    println("=" ^ 80)

    # -----------------------------------------------------------------------
    # JIT warmup: alpha=1, small datasize, no noise
    # -----------------------------------------------------------------------
    println("\n--- JIT warmup (alpha=1, datasize=21, noise=0) ---")
    warmup_pep = make_hiv_scaled(alpha = 1.0)
    warmup_opts = EstimationOptions(
        datasize = 21,
        time_interval = [-1.0, 1.0],
        interpolator = InterpolatorAAAD,
        use_parameter_homotopy = true,
        try_more_methods = false,
        nooutput = true,
    )
    warmup_pep_data = sample_problem_data(warmup_pep, warmup_opts)
    try
        analyze_parameter_estimation_problem(warmup_pep_data, warmup_opts)
        println("  Warmup complete.")
    catch e
        println("  Warmup failed (expected for JIT): ", sprint(showerror, e))
    end

    # -----------------------------------------------------------------------
    # Sanity check: y4 data invariance across alpha values
    # -----------------------------------------------------------------------
    println("\n--- Sanity check: y4 data should be identical across alpha ---")
    sanity_opts = EstimationOptions(
        datasize = 11,
        time_interval = [-1.0, 1.0],
        interpolator = InterpolatorAAAD,
        noise_level = 0.0,
        nooutput = true,
    )
    y4_data_by_alpha = Dict{Float64, Vector{Float64}}()
    for alpha in alphas
        pep = make_hiv_scaled(alpha = alpha)
        pep_data = sample_problem_data(pep, sanity_opts)
        # y4 is the 4th measurement → 4th non-"t" entry in the OrderedDict
        non_t_vals = [vals for (key, vals) in pep_data.data_sample if key != "t"]
        y4_data_by_alpha[alpha] = non_t_vals[4]  # y1=w, y2=z, y3=x, y4=y+v_s/alpha
    end
    # Compare all to alpha=1
    ref = y4_data_by_alpha[1.0]
    for alpha in alphas[2:end]
        diff = maximum(abs.(y4_data_by_alpha[alpha] .- ref))
        status = diff < 1e-12 ? "PASS" : "FAIL (diff=$diff)"
        @printf("  y4 alpha=%.0f vs alpha=1: max|diff| = %.2e  [%s]\n", alpha, diff, status)
    end

    # -----------------------------------------------------------------------
    # Main grid
    # -----------------------------------------------------------------------
    opts = EstimationOptions(
        datasize = 101,
        time_interval = [-1.0, 1.0],
        interpolator = InterpolatorAAAD,
        use_parameter_homotopy = true,
        try_more_methods = false,
        nooutput = true,
    )

    # Store results: (alpha, noise, seed) => (max_rel_error, n_solutions, success)
    results = Dict{Tuple{Float64, Float64, Int}, NamedTuple{(:max_rel_error, :n_solutions, :success), Tuple{Float64, Int, Bool}}}()

    for alpha in alphas
        for noise in noises
            for seed in seeds
                label = @sprintf("alpha=%6.1f  noise=%.0e  seed=%d", alpha, noise, seed)
                print("  Running $label ... ")

                pep = make_hiv_scaled(alpha = alpha)

                # Seed RNG before sampling so noise is reproducible
                Random.seed!(seed)
                run_opts = EstimationOptions(
                    datasize = 101,
                    time_interval = [-1.0, 1.0],
                    interpolator = InterpolatorAAAD,
                    use_parameter_homotopy = true,
                    try_more_methods = false,
                    nooutput = true,
                    noise_level = noise,
                )
                pep_data = sample_problem_data(pep, run_opts)

                local best_err = Inf
                local n_sol = 0
                try
                    res = analyze_parameter_estimation_problem(pep_data, run_opts)
                    # res = (results_tuple, results_tuple_to_return, uq_result)
                    # results_tuple[1] = solved_res::Vector{ParameterEstimationResult}
                    solved = res[1][1]
                    n_sol = length(solved)
                    for r in solved
                        err = compute_max_rel_error(r, alpha)
                        best_err = min(best_err, err)
                    end
                catch e
                    println("ERROR: ", sprint(showerror, e))
                    best_err = Inf
                    n_sol = 0
                end

                success = best_err < 0.1
                results[(alpha, noise, seed)] = (max_rel_error = best_err, n_solutions = n_sol, success = success)
                status_str = success ? "OK" : "FAIL"
                @printf("  max_rel_err=%.2e  n_sol=%d  [%s]\n", best_err, n_sol, status_str)
            end
        end
    end

    # -----------------------------------------------------------------------
    # Summary table
    # -----------------------------------------------------------------------
    println("\n" * "=" ^ 80)
    println("SUMMARY TABLE")
    println("=" ^ 80)
    @printf("%-10s | %-30s | %-30s\n", "alpha", "noise=0", "noise=1e-8")
    @printf("%-10s | %-30s | %-30s\n", "", "success_rate  median_err", "success_rate  median_err")
    println("-" ^ 80)

    for alpha in alphas
        for (ni, noise) in enumerate(noises)
            errs = Float64[]
            successes = 0
            for seed in seeds
                r = results[(alpha, noise, seed)]
                push!(errs, r.max_rel_error)
                if r.success
                    successes += 1
                end
            end
            sort!(errs)
            med_err = length(errs) >= 2 ? (errs[2] + errs[3]) / 2.0 : errs[1]  # median of 4
            rate = successes / length(seeds)

            if ni == 1
                @printf("%-10.0f | %d/%d (%.0f%%)  med_err=%.2e", alpha, successes, length(seeds), rate * 100, med_err)
            else
                @printf("   | %d/%d (%.0f%%)  med_err=%.2e", successes, length(seeds), rate * 100, med_err)
            end
        end
        println()
    end

    # -----------------------------------------------------------------------
    # Detailed results per (alpha, noise)
    # -----------------------------------------------------------------------
    println("\n" * "=" ^ 80)
    println("DETAILED RESULTS")
    println("=" ^ 80)
    for alpha in alphas
        for noise in noises
            @printf("\nalpha=%.0f, noise=%.0e:\n", alpha, noise)
            for seed in seeds
                r = results[(alpha, noise, seed)]
                status = r.success ? "OK  " : "FAIL"
                @printf("  seed=%d: max_rel_err=%.4e  n_solutions=%d  [%s]\n",
                    seed, r.max_rel_error, r.n_solutions, status)
            end
        end
    end

    println("\n" * "=" ^ 80)
    println("EXPERIMENT COMPLETE")
    println("=" ^ 80)

    return results
end

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
results = run_experiment()
