## kernel_comparison.jl — compare SE, Matern52/72/92, Periodic, SE×Periodic
## Save per-point predictions + errors for plotting

using Pkg
Pkg.activate(raw"/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using ModelingToolkit: t_nounits as t, D_nounits as D
using Symbolics
using OrderedCollections
using Statistics
using Printf
using CSV
using LinearAlgebra
using Optim, LineSearches

const OUTDIR = "/scratch/oren-qc-13/ParameterEstimationBenchmarking/kernel_comparison_results"
mkpath(OUTDIR)
const FILETREE = "/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_agprobust_comparison/filetree"

# ── System definition ─────────────────────────────────────────────────
parameters = @parameters k1 k2 k3
states = @variables r(t) w(t)
observables = @variables y1(t)
state_equations = [
    D(r) ~ 2.0*k1*r - 2.0*k2*w*r,
    D(w) ~ -0.6*k3*w + 4.0*k2*w*r,
]
measured_quantities = [y1 ~ 4.0*r]
ic = [0.471, 0.322]
p_true = [0.266, 0.44, 0.399]
time_interval = [0.0, 20.0]
datasize = 1001

model, mq = create_ordered_ode_system(
    "lotka_volterra", states, parameters, state_equations, measured_quantities
)

# ── Ground truth ──────────────────────────────────────────────────────
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

MAX_DERIV = 5
expanded_mq, obs_derivs = calculate_observable_derivatives(
    equations(model.system), mq, MAX_DERIV)
@named deriv_sys = ODESystem(equations(model.system), t; observed=expanded_mq)
ssys = structural_simplify(deriv_sys)

ic_dict = OrderedDict(states .=> ic)
p_dict = OrderedDict(parameters .=> p_true)
prob = ODEProblem(ssys, ic_dict, (time_interval[1], time_interval[2]), p_dict)
t_grid = range(time_interval[1], time_interval[2], length=datasize)
sol = solve(prob, AutoVern9(Rodas4P()), abstol=1e-14, reltol=1e-14, saveat=t_grid)
ts = collect(Float64, sol.t)

shoot_indices = [1, 144, 287, 430, 572, 715, 858, 1001]
t_shoot = ts[shoot_indices]

# Save ground truth at all points
open(joinpath(OUTDIR, "ground_truth.csv"), "w") do f
    print(f, "t")
    for d in 0:MAX_DERIV; print(f, ",d$d"); end
    println(f)
    for (i, tv) in enumerate(ts)
        print(f, tv)
        # d0 = observable value
        print(f, ",", sol[mq[1].lhs][i])
        for d in 1:MAX_DERIV
            val = sol(tv, idxs=obs_derivs[1, d])
            print(f, ",", val)
        end
        println(f)
    end
end

println("Ground truth solved and saved.\n")

# ── Helpers ───────────────────────────────────────────────────────────
_softplus(x::Real) = x > 34.0 ? x : log(1.0 + exp(x))
_inv_softplus(y::Real) = y > 34.0 ? y : log(exp(y) - 1.0)

function estimate_period(ts, ys)
    ym = mean(ys)
    crossings = Float64[]
    for i in 1:(length(ys)-1)
        if (ys[i] - ym) <= 0 && (ys[i+1] - ym) > 0
            frac = (ym - ys[i]) / (ys[i+1] - ys[i])
            push!(crossings, ts[i] + frac * (ts[i+1] - ts[i]))
        end
    end
    length(crossings) >= 2 ? median(diff(crossings)) : (ts[end] - ts[1]) / 2
end

# Regularized |d| for Matern kernels — C∞ approximation, TaylorDiff-safe
const MATERN_EPS = 1e-30
@inline smooth_abs(d) = sqrt(d * d + MATERN_EPS)

# ── Kernel definitions ────────────────────────────────────────────────
# Each: (name, n_hyper, build_K!, k_star, θ0_fn, θ_lo, θ_hi)

# SE: θ = [l, σ²]
function se_K!(K, xs, θ)
    l, σ² = θ[1], θ[2]
    inv2l2 = 1.0 / (2.0 * l * l)
    n = length(xs)
    for j in 1:n, i in 1:n
        K[i, j] = σ² * exp(-abs2(xs[i] - xs[j]) * inv2l2)
    end
end
se_kstar(x, xi, θ) = θ[2] * exp(-abs2(x - xi) / (2.0 * θ[1]^2))

# Matern 5/2: θ = [l, σ²]
function m52_K!(K, xs, θ)
    l, σ² = θ[1], θ[2]
    n = length(xs)
    for j in 1:n, i in 1:n
        r = abs(xs[i] - xs[j]) / l
        s5r = sqrt(5.0) * r
        K[i, j] = σ² * (1.0 + s5r + 5.0 * r^2 / 3.0) * exp(-s5r)
    end
end
function m52_kstar(x, xi, θ)
    l, σ² = θ[1], θ[2]
    r = smooth_abs(x - xi) / l
    s5r = sqrt(5.0) * r
    return σ² * (1.0 + s5r + 5.0 * r^2 / 3.0) * exp(-s5r)
end

# Matern 7/2: θ = [l, σ²]
function m72_K!(K, xs, θ)
    l, σ² = θ[1], θ[2]
    n = length(xs)
    s7 = sqrt(7.0)
    for j in 1:n, i in 1:n
        r = abs(xs[i] - xs[j]) / l
        u = s7 * r
        K[i, j] = σ² * (1.0 + u + 2.0 * u^2 / 5.0 + u^3 / 15.0) * exp(-u)
    end
end
function m72_kstar(x, xi, θ)
    l, σ² = θ[1], θ[2]
    r = smooth_abs(x - xi) / l
    u = sqrt(7.0) * r
    return σ² * (1.0 + u + 2.0 * u^2 / 5.0 + u^3 / 15.0) * exp(-u)
end

# Matern 9/2: θ = [l, σ²]
function m92_K!(K, xs, θ)
    l, σ² = θ[1], θ[2]
    n = length(xs)
    for j in 1:n, i in 1:n
        r = abs(xs[i] - xs[j]) / l
        u = 3.0 * r
        K[i, j] = σ² * (1.0 + u + 27.0 * r^2 / 7.0 + 18.0 * r^3 / 7.0 + 27.0 * r^4 / 35.0) * exp(-u)
    end
end
function m92_kstar(x, xi, θ)
    l, σ² = θ[1], θ[2]
    r = smooth_abs(x - xi) / l
    u = 3.0 * r
    return σ² * (1.0 + u + 27.0 * r^2 / 7.0 + 18.0 * r^3 / 7.0 + 27.0 * r^4 / 35.0) * exp(-u)
end

# Periodic: θ = [l, σ², p]
function per_K!(K, xs, θ)
    l, σ², p = θ[1], θ[2], θ[3]
    inv_l2 = 2.0 / (l * l)
    n = length(xs)
    for j in 1:n, i in 1:n
        s = sin(π * (xs[i] - xs[j]) / p)
        K[i, j] = σ² * exp(-inv_l2 * s * s)
    end
end
function per_kstar(x, xi, θ)
    l, σ², p = θ[1], θ[2], θ[3]
    s = sin(π * (x - xi) / p)
    return σ² * exp(-2.0 * s * s / (l * l))
end

# SE × Periodic: θ = [l_se, l_per, σ², p]
function sep_K!(K, xs, θ)
    l_se, l_per, σ², p = θ[1], θ[2], θ[3], θ[4]
    inv2l2 = 1.0 / (2.0 * l_se^2)
    inv_lp2 = 2.0 / (l_per^2)
    n = length(xs)
    for j in 1:n, i in 1:n
        d = xs[i] - xs[j]
        se = exp(-d * d * inv2l2)
        s = sin(π * d / p)
        pe = exp(-inv_lp2 * s * s)
        K[i, j] = σ² * se * pe
    end
end
function sep_kstar(x, xi, θ)
    l_se, l_per, σ², p = θ[1], θ[2], θ[3], θ[4]
    d = x - xi
    se = exp(-d * d / (2.0 * l_se^2))
    s = sin(π * d / p)
    pe = exp(-2.0 * s * s / (l_per^2))
    return σ² * se * pe
end

# ── Optimize + predict ────────────────────────────────────────────────
function optimize_and_predict(name, xs, ys_raw, K_fn!, kstar_fn, n_hyper, θ0, θ_lo, θ_hi, noise_var,
                              t_eval, eval_indices, sol, mq, obs_derivs, max_d)
    n = length(xs)
    y_mean = mean(ys_raw)
    y_std = max(std(ys_raw), 1e-8)
    ys_norm = (collect(Float64, ys_raw) .- y_mean) ./ y_std
    jitter = 1e-8
    K = Matrix{Float64}(undef, n, n)

    # Optimize
    function neg_lml(θ_raw)
        θ = [_softplus(θ_raw[i]) for i in 1:n_hyper]
        K_fn!(K, xs, θ)
        for i in 1:n; K[i, i] += noise_var + jitter; end
        try
            C = cholesky(Symmetric(K))
            alpha = C \ ys_norm
            return 0.5 * (dot(ys_norm, alpha) + 2.0 * sum(log.(diag(C.U))) + n * log(2π))
        catch; return Inf; end
    end

    θ0_raw = [_inv_softplus(θ0[i]) for i in 1:n_hyper]
    lo_raw = [_inv_softplus(θ_lo[i]) for i in 1:n_hyper]
    hi_raw = [_inv_softplus(θ_hi[i]) for i in 1:n_hyper]

    θ_opt = copy(θ0)
    lml_val = neg_lml(θ0_raw)
    conv = false
    try
        result = Optim.optimize(neg_lml, lo_raw, hi_raw, θ0_raw,
            Fminbox(LBFGS(linesearch=LineSearches.BackTracking())),
            Optim.Options(iterations=1000))
        θ_opt = [_softplus(Optim.minimizer(result)[i]) for i in 1:n_hyper]
        lml_val = Optim.minimum(result)
        conv = Optim.converged(result)
    catch e
        @warn "$name optimization failed" exception=e
    end

    @printf("  %-16s converged=%-5s neg_lml=%9.1f  θ=", name, conv, lml_val)
    for (i, v) in enumerate(θ_opt)
        @printf(" %.4f", v)
    end
    println()

    # Build predictor
    K_fn!(K, xs, θ_opt)
    for i in 1:n; K[i, i] += noise_var + jitter; end
    C = try
        cholesky(Symmetric(K))
    catch
        @warn "$name: Cholesky failed with optimized params"
        return nothing, θ_opt, lml_val
    end
    alpha = C \ ys_norm
    xs_cap = collect(Float64, xs)

    pred(x::Real) = begin
        kv = [kstar_fn(x, xi, θ_opt) for xi in xs_cap]
        y_std * dot(kv, alpha) + y_mean
    end

    # Evaluate at all points for plots + at shooting points for errors
    n_eval = length(t_eval)
    pred_data = Dict{Int, Vector{Float64}}()
    truth_data = Dict{Int, Vector{Float64}}()
    errors_shoot = Float64[]

    for d in 0:max_d
        if d == 0
            pv = [pred(x) for x in t_eval]
            tv = sol[mq[1].lhs][eval_indices]
        else
            pv = try
                [ODEParameterEstimation.nth_deriv(pred, d, x) for x in t_eval]
            catch e
                @warn "$name: nth_deriv failed for d=$d" exception=e
                push!(errors_shoot, NaN)
                continue
            end
            tv = collect(Float64, sol(collect(t_eval), idxs=obs_derivs[1, d]))
        end
        pred_data[d] = pv
        truth_data[d] = tv

        # Error at shooting points
        shoot_pred = [pv[findfirst(==(si), eval_indices)] for si in shoot_indices
                      if findfirst(==(si), eval_indices) !== nothing]
        shoot_truth = [tv[findfirst(==(si), eval_indices)] for si in shoot_indices
                       if findfirst(==(si), eval_indices) !== nothing]

        if length(shoot_pred) > 0
            ae = abs.(shoot_pred .- shoot_truth)
            scale = mean(abs.(shoot_truth))
            rr = scale > 1e-15 ? sqrt(mean(ae .^ 2)) / scale : sqrt(mean(ae .^ 2))
            push!(errors_shoot, rr)
        else
            push!(errors_shoot, NaN)
        end
    end

    # Save predictions to CSV
    return (pred_data=pred_data, truth_data=truth_data, errors=errors_shoot,
            θ=θ_opt, lml=lml_val, conv=conv)
end

# ── Main ──────────────────────────────────────────────────────────────
for noise_tag in ["0", "1em8"]
    data_path = joinpath(FILETREE, "odepe_default", "lotka_volterra_0_$(noise_tag)", "data.csv")
    csv_data = CSV.read(data_path, Tuple, header=false)
    t_data = collect(Float64, csv_data[1])
    y_data = collect(Float64, csv_data[2])
    period = estimate_period(t_data, y_data)
    noise_var = 1e-10

    println("\n" * "=" ^ 90)
    @printf("NOISE = %s   n = %d   period = %.3f   noise_var = %.1e\n", noise_tag, length(t_data), period, noise_var)
    println("=" ^ 90)

    ls0 = std(t_data) / 8.0

    kernels = [
        ("SE",         2, se_K!,  se_kstar,  [ls0, 1.0],          [1e-3, 1e-8],         [150.0, 150.0]),
        ("Matern52",   2, m52_K!, m52_kstar, [ls0, 1.0],          [1e-3, 1e-8],         [150.0, 150.0]),
        ("Matern72",   2, m72_K!, m72_kstar, [ls0, 1.0],          [1e-3, 1e-8],         [150.0, 150.0]),
        ("Matern92",   2, m92_K!, m92_kstar, [ls0, 1.0],          [1e-3, 1e-8],         [150.0, 150.0]),
        ("Periodic",   3, per_K!, per_kstar, [1.0, 1.0, period],  [1e-3, 1e-8, period*0.5], [150.0, 150.0, period*2.0]),
        ("SExPeriodic",4, sep_K!, sep_kstar, [10.0, 1.0, 1.0, period], [1e-3, 1e-3, 1e-8, period*0.5], [150.0, 150.0, 150.0, period*2.0]),
    ]

    results = Dict{String, Any}()
    for (name, nh, Kfn, ksfn, θ0, θlo, θhi) in kernels
        r = optimize_and_predict(name, t_data, y_data, Kfn, ksfn, nh, θ0, θlo, θhi, noise_var,
            ts, 1:length(ts), sol, mq, obs_derivs, MAX_DERIV)
        if r !== nothing
            results[name] = r

            # Save per-point predictions
            open(joinpath(OUTDIR, "pred_$(name)_$(noise_tag).csv"), "w") do f
                print(f, "t")
                for d in 0:MAX_DERIV; print(f, ",pred_d$d,truth_d$d"); end
                println(f)
                for (i, tv) in enumerate(ts)
                    print(f, tv)
                    for d in 0:MAX_DERIV
                        pv = haskey(r.pred_data, d) ? r.pred_data[d][i] : NaN
                        trv = haskey(r.truth_data, d) ? r.truth_data[d][i] : NaN
                        print(f, ",", pv, ",", trv)
                    end
                    println(f)
                end
            end
        end
    end

    # Summary table
    println("\n  SUMMARY (rel_rmse at 8 shooting points):")
    @printf("  %-16s  neg_lml   ", "Kernel")
    for d in 0:MAX_DERIV; @printf("d%-8d", d); end
    println()
    println("  " * "-" ^ 90)
    for (name, _, _, _, _, _, _) in kernels
        if haskey(results, name)
            r = results[name]
            @printf("  %-16s  %8.1f  ", name, r.lml)
            for e in r.errors
                @printf("%-9.2e", e)
            end
            println()
        end
    end

    # Save summary
    open(joinpath(OUTDIR, "summary_$(noise_tag).csv"), "w") do f
        print(f, "kernel,neg_lml")
        for d in 0:MAX_DERIV; print(f, ",d$d"); end
        println(f)
        for (name, _, _, _, _, _, _) in kernels
            if haskey(results, name)
                r = results[name]
                print(f, name, ",", r.lml)
                for e in r.errors; print(f, ",", e); end
                println(f)
            end
        end
    end
end

println("\nResults saved to $OUTDIR")
