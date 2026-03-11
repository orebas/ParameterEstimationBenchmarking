## kernel_sweep.jl — compare SE, Matern52, Periodic, SE×Periodic kernels
## on lotka_volterra derivative quality at 8 shooting points

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

MAX_DERIV = 3
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

println("Ground truth solved.\n")

# ── Estimate period from data ─────────────────────────────────────────
function estimate_period(ts, ys)
    ym = mean(ys)
    # Count upward zero-crossings of (y - mean)
    crossings = Float64[]
    for i in 1:(length(ys)-1)
        if (ys[i] - ym) <= 0 && (ys[i+1] - ym) > 0
            # Linear interpolation for crossing time
            frac = (ym - ys[i]) / (ys[i+1] - ys[i])
            push!(crossings, ts[i] + frac * (ts[i+1] - ts[i]))
        end
    end
    if length(crossings) >= 2
        periods = diff(crossings)
        return median(periods)
    end
    return (ts[end] - ts[1]) / 2  # fallback
end

# ── Kernel definitions (TaylorDiff-compatible pointwise evaluation) ───
# Each returns: (K_matrix_builder!, k_star_fn)
# K_matrix_builder!(K, xs, params) fills K in-place
# k_star_fn(x, xi, params) returns scalar kernel value

_softplus(x::Real) = x > 34.0 ? x : log(1.0 + exp(x))
_inv_softplus(y::Real) = y > 34.0 ? y : log(exp(y) - 1.0)

# -- SE kernel: σ² exp(-d²/(2l²))
function se_kernel_matrix!(K, xs, θ)
    l, σ² = θ[1], θ[2]
    inv_2l2 = 1.0 / (2.0 * l * l)
    n = length(xs)
    for j in 1:n, i in 1:n
        K[i, j] = σ² * exp(-abs2(xs[i] - xs[j]) * inv_2l2)
    end
end
function se_k_star(x, xi, θ)
    l, σ² = θ[1], θ[2]
    return σ² * exp(-abs2(x - xi) / (2.0 * l * l))
end

# -- Periodic kernel: σ² exp(-2 sin²(π(x-x')/p) / l²)
# All C∞, TaylorDiff-safe (no abs)
function periodic_kernel_matrix!(K, xs, θ)
    l, σ², p = θ[1], θ[2], θ[3]
    inv_l2 = 2.0 / (l * l)
    n = length(xs)
    for j in 1:n, i in 1:n
        s = sin(π * (xs[i] - xs[j]) / p)
        K[i, j] = σ² * exp(-inv_l2 * s * s)
    end
end
function periodic_k_star(x, xi, θ)
    l, σ², p = θ[1], θ[2], θ[3]
    s = sin(π * (x - xi) / p)
    return σ² * exp(-2.0 * s * s / (l * l))
end

# -- Locally Periodic: SE × Periodic
function locper_kernel_matrix!(K, xs, θ)
    l_se, l_per, σ², p = θ[1], θ[2], θ[3], θ[4]
    inv_2l2_se = 1.0 / (2.0 * l_se * l_se)
    inv_l2_per = 2.0 / (l_per * l_per)
    n = length(xs)
    for j in 1:n, i in 1:n
        d = xs[i] - xs[j]
        se_part = exp(-d * d * inv_2l2_se)
        s = sin(π * d / p)
        per_part = exp(-inv_l2_per * s * s)
        K[i, j] = σ² * se_part * per_part
    end
end
function locper_k_star(x, xi, θ)
    l_se, l_per, σ², p = θ[1], θ[2], θ[3], θ[4]
    d = x - xi
    se_part = exp(-d * d / (2.0 * l_se * l_se))
    s = sin(π * d / p)
    per_part = exp(-2.0 * s * s / (l_per * l_per))
    return σ² * se_part * per_part
end

# ── Build GP and evaluate derivatives ─────────────────────────────────
function eval_gp_derivs(xs, ys_raw, kernel_matrix!, k_star_fn, θ_kernel, noise_var,
                        t_eval, eval_indices, sol, mq, obs_derivs, max_d)
    n = length(xs)
    y_mean = mean(ys_raw)
    y_std = max(std(ys_raw), 1e-8)
    ys_norm = (collect(Float64, ys_raw) .- y_mean) ./ y_std
    jitter = 1e-8

    K = Matrix{Float64}(undef, n, n)
    kernel_matrix!(K, xs, θ_kernel)
    for i in 1:n
        K[i, i] += noise_var + jitter
    end

    C = try
        cholesky(Symmetric(K))
    catch
        return nothing
    end
    alpha = C \ ys_norm

    xs_cap = collect(Float64, xs)
    function pred(x::Real)
        kv = [k_star_fn(x, xi, θ_kernel) for xi in xs_cap]
        return y_std * dot(kv, alpha) + y_mean
    end

    results = Float64[]
    for d in 0:max_d
        if d == 0
            pred_vals = [pred(x) for x in t_eval]
            truth_vals = sol[mq[1].lhs][eval_indices]
        else
            pred_vals = try
                [ODEParameterEstimation.nth_deriv(pred, d, x) for x in t_eval]
            catch
                push!(results, NaN)
                continue
            end
            truth_vals = collect(Float64, sol(collect(t_eval), idxs=obs_derivs[1, d]))
        end
        abs_errs = abs.(pred_vals .- truth_vals)
        scale = mean(abs.(truth_vals))
        rel_rmse = scale > 1e-15 ? sqrt(mean(abs_errs .^ 2)) / scale : sqrt(mean(abs_errs .^ 2))
        push!(results, rel_rmse)
    end
    return results
end

# ── Optimize hyperparameters via marginal likelihood ──────────────────
function optimize_kernel(xs, ys_raw, kernel_matrix!, n_hyper, θ0, θ_lo, θ_hi, noise_var)
    n = length(xs)
    y_mean = mean(ys_raw)
    y_std = max(std(ys_raw), 1e-8)
    ys_norm = (collect(Float64, ys_raw) .- y_mean) ./ y_std
    jitter = 1e-8
    K = Matrix{Float64}(undef, n, n)

    function neg_lml(θ_raw)
        θ = [_softplus(θ_raw[i]) for i in 1:n_hyper]
        kernel_matrix!(K, xs, θ)
        for i in 1:n
            K[i, i] += noise_var + jitter
        end
        try
            C = cholesky(Symmetric(K))
            alpha = C \ ys_norm
            data_fit = dot(ys_norm, alpha)
            log_det = 2.0 * sum(log.(diag(C.U)))
            return 0.5 * (data_fit + log_det + n * log(2π))
        catch
            return Inf
        end
    end

    θ0_raw = [_inv_softplus(θ0[i]) for i in 1:n_hyper]
    lo_raw = [_inv_softplus(θ_lo[i]) for i in 1:n_hyper]
    hi_raw = [_inv_softplus(θ_hi[i]) for i in 1:n_hyper]

    result = try
        Optim.optimize(neg_lml, lo_raw, hi_raw, θ0_raw,
            Fminbox(LBFGS(linesearch=LineSearches.BackTracking())),
            Optim.Options(iterations=1000))
    catch e
        @warn "Optimization failed" exception=e
        return θ0, false, Inf
    end

    θ_opt = [_softplus(Optim.minimizer(result)[i]) for i in 1:n_hyper]
    return θ_opt, Optim.converged(result), Optim.minimum(result)
end

# ── Main ──────────────────────────────────────────────────────────────
for noise_tag in ["0", "1em8"]
    data_path = joinpath(FILETREE, "odepe_default", "lotka_volterra_0_$(noise_tag)", "data.csv")
    csv_data = CSV.read(data_path, Tuple, header=false)
    t_data = collect(Float64, csv_data[1])
    y_data = collect(Float64, csv_data[2])

    period = estimate_period(t_data, y_data)
    @printf("\n\nNOISE = %s   n = %d   estimated period = %.3f\n", noise_tag, length(t_data), period)

    noise_var = 1e-10  # what AGPRobust optimizer chose

    # ── 1. SE (baseline) — optimize l, σ² ─────────────────────────────
    println("\n" * "=" ^ 90)
    println("KERNEL: Squared Exponential (SE)")
    θ0_se = [std(t_data)/8, 1.0]
    lo_se = [1e-3, 1e-8]
    hi_se = [150.0, 150.0]
    θ_se, conv_se, lml_se = optimize_kernel(t_data, y_data, se_kernel_matrix!, 2, θ0_se, lo_se, hi_se, noise_var)
    @printf("  Optimized: l=%.4f  σ²=%.4f  converged=%s  neg_lml=%.2f\n",
        θ_se[1], θ_se[2], conv_se, lml_se)
    errs_se = eval_gp_derivs(t_data, y_data, se_kernel_matrix!, se_k_star, θ_se, noise_var,
        t_shoot, shoot_indices, sol, mq, obs_derivs, MAX_DERIV)
    if errs_se !== nothing
        @printf("  d0=%.2e  d1=%.2e  d2=%.2e  d3=%.2e\n", errs_se...)
    end

    # Also try a range of lengthscales
    println("  Lengthscale sweep (σ²=1.0):")
    @printf("  %-10s  %-10s  %-10s  %-10s  %-10s\n", "l", "d0", "d1", "d2", "d3")
    for ls in [0.2, 0.5, 1.0, 1.287, 2.0, 5.0]
        errs = eval_gp_derivs(t_data, y_data, se_kernel_matrix!, se_k_star, [ls, 1.0], noise_var,
            t_shoot, shoot_indices, sol, mq, obs_derivs, MAX_DERIV)
        if errs !== nothing
            @printf("  %-10.3f  %-10.2e  %-10.2e  %-10.2e  %-10.2e\n", ls, errs...)
        end
    end

    # ── 2. Periodic — optimize l, σ², p ───────────────────────────────
    println("\n" * "=" ^ 90)
    println("KERNEL: Periodic")
    θ0_per = [1.0, 1.0, period]
    lo_per = [1e-3, 1e-8, period*0.5]
    hi_per = [150.0, 150.0, period*2.0]
    θ_per, conv_per, lml_per = optimize_kernel(t_data, y_data, periodic_kernel_matrix!, 3, θ0_per, lo_per, hi_per, noise_var)
    @printf("  Optimized: l=%.4f  σ²=%.4f  p=%.4f  converged=%s  neg_lml=%.2f\n",
        θ_per[1], θ_per[2], θ_per[3], conv_per, lml_per)
    errs_per = eval_gp_derivs(t_data, y_data, periodic_kernel_matrix!, periodic_k_star, θ_per, noise_var,
        t_shoot, shoot_indices, sol, mq, obs_derivs, MAX_DERIV)
    if errs_per !== nothing
        @printf("  d0=%.2e  d1=%.2e  d2=%.2e  d3=%.2e\n", errs_per...)
    end

    # Sweep l with fixed period
    println("  Lengthscale sweep (σ²=1.0, p=$(round(period, digits=3))):")
    @printf("  %-10s  %-10s  %-10s  %-10s  %-10s\n", "l", "d0", "d1", "d2", "d3")
    for ls in [0.2, 0.5, 1.0, 2.0, 5.0, 10.0]
        errs = eval_gp_derivs(t_data, y_data, periodic_kernel_matrix!, periodic_k_star, [ls, 1.0, period], noise_var,
            t_shoot, shoot_indices, sol, mq, obs_derivs, MAX_DERIV)
        if errs !== nothing
            @printf("  %-10.3f  %-10.2e  %-10.2e  %-10.2e  %-10.2e\n", ls, errs...)
        end
    end

    # ── 3. Locally Periodic (SE × Periodic) — optimize l_se, l_per, σ², p
    println("\n" * "=" ^ 90)
    println("KERNEL: Locally Periodic (SE × Periodic)")
    θ0_lp = [10.0, 1.0, 1.0, period]  # l_se, l_per, σ², p
    lo_lp = [1e-3, 1e-3, 1e-8, period*0.5]
    hi_lp = [150.0, 150.0, 150.0, period*2.0]
    θ_lp, conv_lp, lml_lp = optimize_kernel(t_data, y_data, locper_kernel_matrix!, 4, θ0_lp, lo_lp, hi_lp, noise_var)
    @printf("  Optimized: l_se=%.4f  l_per=%.4f  σ²=%.4f  p=%.4f  converged=%s  neg_lml=%.2f\n",
        θ_lp[1], θ_lp[2], θ_lp[3], θ_lp[4], conv_lp, lml_lp)
    errs_lp = eval_gp_derivs(t_data, y_data, locper_kernel_matrix!, locper_k_star, θ_lp, noise_var,
        t_shoot, shoot_indices, sol, mq, obs_derivs, MAX_DERIV)
    if errs_lp !== nothing
        @printf("  d0=%.2e  d1=%.2e  d2=%.2e  d3=%.2e\n", errs_lp...)
    end

    # ── Summary ───────────────────────────────────────────────────────
    println("\n" * "=" ^ 90)
    println("SUMMARY (optimized, at 8 shooting points)")
    @printf("  %-20s  neg_lml   d0         d1         d2         d3\n", "Kernel")
    @printf("  %s\n", "-"^85)
    if errs_se !== nothing
        @printf("  %-20s  %8.1f  %-10.2e %-10.2e %-10.2e %-10.2e\n", "SE", lml_se, errs_se...)
    end
    if errs_per !== nothing
        @printf("  %-20s  %8.1f  %-10.2e %-10.2e %-10.2e %-10.2e\n", "Periodic", lml_per, errs_per...)
    end
    if errs_lp !== nothing
        @printf("  %-20s  %8.1f  %-10.2e %-10.2e %-10.2e %-10.2e\n", "SE×Periodic", lml_lp, errs_lp...)
    end
end
