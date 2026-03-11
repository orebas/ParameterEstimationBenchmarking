## matern_odepe_test.jl — run full ODEPE on repressilator with Matern 7/2 and 9/2 kernels
## Tests whether high-derivative systems survive with Matern kernels

using Pkg; Pkg.activate(raw"/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV
using GaussianProcesses
using Statistics
using Optim, LineSearches
using Symbolics: Num
using LinearAlgebra
using Printf

# ── System definition (repressilator) ─────────────────────────────────
name = "repressilator"
parameters = @parameters beta n alpha
states = @variables m1(t) m2(t) m3(t) p1(t) p2(t) p3(t)
observables = @variables y1(t) y2(t) y3(t)
state_equations = [
    D(m1) ~ -m1 + (4.0*beta) / (0.5*(1 + 24.0*n*p3)),
    D(m2) ~ -m2 + (4.0*beta) / (0.5*(1 + 16.0*n*p1)),
    D(m3) ~ -m3 + (4.0*beta) / (0.5*(1 + 8.0*n*p2)),
    D(p1) ~ -2.0*alpha*(-0.125*m1 + p1),
    D(p2) ~ -2.0*alpha*(-0.25*m2 + p2),
    D(p3) ~ -2.0*alpha*(p3 - 0.08333333333333333*m3),
]
measured_quantities = [
    y1 ~ 4.0*p1,
    y2 ~ 2.0*p2,
    y3 ~ 6.0*p3,
]
ic = [0.728, 0.325, 0.569, 0.151, 0.489, 0.882]
p_true = [0.113, 0.844, 0.636]

time_interval = [0.0, 24.0]
datasize = 1001

model, mq = create_ordered_ode_system(name, states, parameters, state_equations, measured_quantities)

# Load data
csv_data = CSV.read("/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_agprobust_comparison/filetree/odepe_default/repressilator_0_0/data.csv", Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
    data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end

pep = ParameterEstimationProblem(name, model, mq, data_sample, time_interval, nothing,
    OrderedDict(parameters .=> p_true), OrderedDict(states .=> ic), 0)

# ── Custom Matern interpolator builders ───────────────────────────────
_softplus(x::Real) = x > 34.0 ? x : log(1.0 + exp(x))
_inv_softplus(y::Real) = y > 34.0 ? y : log(exp(y) - 1.0)

# Regularized abs for TaylorDiff compatibility
const MEPS = 1e-30
smooth_abs(d) = sqrt(d * d + MEPS)

function make_matern_interpolator(order::Int)
    # order: 7 for Matern 7/2, 9 for Matern 9/2
    function interp_fn(xs_in, ys_in)
        xs = collect(Float64, xs_in)
        ys = collect(Float64, ys_in)
        nn = length(xs)
        y_mean = mean(ys)
        y_std = max(std(ys), 1e-8)
        ys_norm = (ys .- y_mean) ./ y_std
        jitter = 1e-8
        noise_var = 1e-10

        # Build kernel matrix (using abs for matrix, smooth_abs for prediction)
        function kernel_val_abs(d, l)
            r = abs(d) / l
            if order == 7
                u = sqrt(7.0) * r
                return (1 + u + 2u^2/5 + u^3/15) * exp(-u)
            else  # order == 9
                u = 3.0 * r
                return (1 + u + 27r^2/7 + 18r^3/7 + 27r^4/35) * exp(-u)
            end
        end

        function kernel_val_smooth(d, l)
            r = smooth_abs(d) / l
            if order == 7
                u = sqrt(7.0) * r
                return (1 + u + 2u^2/5 + u^3/15) * exp(-u)
            else
                u = 3.0 * r
                return (1 + u + 27r^2/7 + 18r^3/7 + 27r^4/35) * exp(-u)
            end
        end

        # Optimize hyperparameters: [l, σ²]
        D2mat = [abs2(xs[i] - xs[j]) for i in 1:nn, j in 1:nn]
        K = Matrix{Float64}(undef, nn, nn)

        function neg_lml(θr)
            l = _softplus(θr[1])
            σ² = _softplus(θr[2])
            for j in 1:nn, i in 1:nn
                K[i, j] = σ² * kernel_val_abs(xs[i] - xs[j], l)
            end
            for i in 1:nn; K[i, i] += noise_var + jitter; end
            try
                C = cholesky(Symmetric(K))
                alpha_l = C \ ys_norm
                return 0.5 * (dot(ys_norm, alpha_l) + 2sum(log.(diag(C.U))) + nn * log(2π))
            catch; return Inf; end
        end

        ls0 = std(xs) / 8.0
        θ0 = [_inv_softplus(ls0), _inv_softplus(1.0)]
        lo = [_inv_softplus(1e-3), _inv_softplus(1e-8)]
        hi = [_inv_softplus(150.0), _inv_softplus(150.0)]

        l_opt, σ²_opt = ls0, 1.0
        try
            res = Optim.optimize(neg_lml, lo, hi, θ0,
                Fminbox(LBFGS(linesearch=LineSearches.BackTracking())),
                Optim.Options(iterations=1000))
            l_opt = _softplus(Optim.minimizer(res)[1])
            σ²_opt = _softplus(Optim.minimizer(res)[2])
        catch e
            @warn "Matern$(order)/2 optimization failed" exception=e
        end

        # Build final kernel matrix and solve
        for j in 1:nn, i in 1:nn
            K[i, j] = σ²_opt * kernel_val_abs(xs[i] - xs[j], l_opt)
        end
        for i in 1:nn; K[i, i] += noise_var + jitter; end
        C = cholesky(Symmetric(K))
        alpha = C \ ys_norm

        @printf("    [Matern%d/2] l=%.4f σ²=%.4f n=%d\n", order, l_opt, σ²_opt, nn)

        # Return prediction function (TaylorDiff-compatible via smooth_abs)
        function predict(x::Real)
            kv = [σ²_opt * kernel_val_smooth(x - xi, l_opt) for xi in xs]
            return y_std * dot(kv, alpha) + y_mean
        end
        return predict
    end
    return interp_fn
end

# ── First: quick sanity check — does nth_deriv work at data points? ───
println("=" ^ 80)
println("SANITY CHECK: nth_deriv at data points with Matern kernels")
println("=" ^ 80)

t_data = data_sample["t"]
y_data = data_sample[Num(mq[1].rhs)]  # first observable

for order in [7, 9]
    println("\n  Matern $(order)/2:")
    interp = make_matern_interpolator(order)(t_data, y_data)

    # Test at a data point (t_data[500]) and a mid-point
    t_test_data = t_data[500]
    t_test_mid = (t_data[500] + t_data[501]) / 2

    for d in 0:8
        val_data = try
            if d == 0; interp(t_test_data)
            else; ODEParameterEstimation.nth_deriv(interp, d, t_test_data); end
        catch e; "ERROR: $e"; end

        val_mid = try
            if d == 0; interp(t_test_mid)
            else; ODEParameterEstimation.nth_deriv(interp, d, t_test_mid); end
        catch e; "ERROR: $e"; end

        is_nan = val_data isa Number && isnan(val_data)
        is_inf = val_data isa Number && isinf(val_data)
        flag = is_nan ? " *** NaN!" : (is_inf ? " *** Inf!" : "")

        @printf("    d%d: at_data=%-14s at_mid=%-14s%s\n", d,
            val_data isa Number ? @sprintf("%.4e", val_data) : string(val_data),
            val_mid isa Number ? @sprintf("%.4e", val_mid) : string(val_mid),
            flag)
    end
end

# ── Now run full ODEPE with each interpolator ─────────────────────────
println("\n\n" * "=" ^ 80)
println("FULL ODEPE RUN: repressilator noise=0")
println("=" ^ 80)

for (label, interp_method, custom_fn) in [
    ("Default (AAADGPR)", InterpolatorAAADGPR, nothing),
    ("AGPRobust (SE)",    InterpolatorAGPRobust, nothing),
    ("Matern 7/2",        InterpolatorCustom, make_matern_interpolator(7)),
    ("Matern 9/2",        InterpolatorCustom, make_matern_interpolator(9)),
]
    println("\n" * "-" ^ 60)
    println("  Interpolator: $label")
    println("-" ^ 60)

    opts = EstimationOptions(
        datasize = length(data_sample["t"]),
        noise_level = 0.0,
        system_solver = SolverHC,
        flow = FlowStandard,
        use_si_template = true,
        polish_solver_solutions = true,
        polish_solutions = false,
        polish_maxiters = 5000,
        polish_method = PolishBFGS,
        opt_maxiters = 200000,
        opt_lb = 1e-05 * ones(length(ic) + length(p_true)),
        opt_ub = 10.0 * ones(length(ic) + length(p_true)),
        abstol = 1e-13,
        reltol = 1e-13,
        polish_maxtime = 1200.0,
        polish_divergence_factor = 10.0,
        polish_stagnation_window = 50,
        polish_ode_maxiters = 20000,
        interpolator = interp_method,
        custom_interpolator = custom_fn,
        diagnostics = true,
    )

    try
        meta, results = analyze_parameter_estimation_problem(pep, opts)
        (solutions_vector, besterror, best_min_error, best_mean_error,
         best_median_error, best_max_error, best_approximation_error, best_rms_error) = results

        println("  Solutions found: ", length(solutions_vector))
        println("  Best median error: ", best_median_error)
        if !isempty(solutions_vector)
            best = solutions_vector[1]
            println("  Best params: ", best.parameters)
            println("  Best states: ", best.states)
        end
    catch e
        println("  FAILED: ", e)
        println("  Stacktrace:")
        for (exc, bt) in current_exceptions()
            showerror(stdout, exc, bt; backtrace=true)
            println()
        end
    end
end
