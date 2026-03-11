## kernel_comparison_v2.jl — fixed evaluation at offset points to avoid smooth_abs artifacts
## Saves CSV data for Python plotting

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
parameters_sym = @parameters k1 k2 k3
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
    "lotka_volterra", states, parameters_sym, state_equations, measured_quantities
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
p_dict = OrderedDict(parameters_sym .=> p_true)
prob = ODEProblem(ssys, ic_dict, (time_interval[1], time_interval[2]), p_dict)
t_data_grid = collect(Float64, range(time_interval[1], time_interval[2], length=datasize))

# Evaluation grid: offset from data points by half spacing to avoid d=0 issues with Matern
dt = t_data_grid[2] - t_data_grid[1]
t_eval = collect(Float64, range(time_interval[1] + dt/2, time_interval[2] - dt/2, length=2000))

# "Shooting" evaluation points: 8 equispaced, offset from data grid
t_shoot_eval = collect(Float64, range(time_interval[1] + dt/2, time_interval[2] - dt/2, length=8))

sol = solve(prob, AutoVern9(Rodas4P()), abstol=1e-14, reltol=1e-14, saveat=vcat(t_data_grid, t_eval, t_shoot_eval))

println("Ground truth solved.\n")

# Get ground truth at eval points
function get_truth(t_pts, d_order)
    if d_order == 0
        return [sol(tv, idxs=mq[1].lhs) for tv in t_pts]
    else
        return [sol(tv, idxs=obs_derivs[1, d_order]) for tv in t_pts]
    end
end

# Save ground truth at eval grid
open(joinpath(OUTDIR, "ground_truth.csv"), "w") do f
    print(f, "t")
    for d in 0:MAX_DERIV; print(f, ",d$d"); end
    println(f)
    for tv in t_eval
        print(f, tv)
        for d in 0:MAX_DERIV
            print(f, ",", get_truth([tv], d)[1])
        end
        println(f)
    end
end

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

# smooth_abs: only used in Matern kstar for TaylorDiff. At eval points
# (offset from data), d is never 0, so this is just a safety net.
const MATERN_EPS = 1e-30
@inline smooth_abs(d) = sqrt(d * d + MATERN_EPS)

# ── Kernel definitions ────────────────────────────────────────────────

# SE: θ = [l, σ²]
function se_K!(K, xs, θ)
    local l = θ[1]; local σ² = θ[2]
    local inv2l2 = 1.0 / (2.0 * l * l)
    local n = length(xs)
    for j in 1:n, i in 1:n
        K[i, j] = σ² * exp(-abs2(xs[i] - xs[j]) * inv2l2)
    end
end
se_kstar(x, xi, θ) = θ[2] * exp(-abs2(x - xi) / (2.0 * θ[1]^2))

# Matern 5/2: θ = [l, σ²]
function m52_K!(K, xs, θ)
    local l = θ[1]; local σ² = θ[2]
    local n = length(xs)
    for j in 1:n, i in 1:n
        local r = abs(xs[i] - xs[j]) / l
        local s5r = sqrt(5.0) * r
        K[i, j] = σ² * (1.0 + s5r + 5.0 * r^2 / 3.0) * exp(-s5r)
    end
end
function m52_kstar(x, xi, θ)
    local l = θ[1]; local σ² = θ[2]
    local r = smooth_abs(x - xi) / l
    local s5r = sqrt(5.0) * r
    return σ² * (1.0 + s5r + 5.0 * r^2 / 3.0) * exp(-s5r)
end

# Matern 7/2: θ = [l, σ²]
function m72_K!(K, xs, θ)
    local l = θ[1]; local σ² = θ[2]
    local n = length(xs)
    local s7 = sqrt(7.0)
    for j in 1:n, i in 1:n
        local r = abs(xs[i] - xs[j]) / l
        local u = s7 * r
        K[i, j] = σ² * (1.0 + u + 2.0 * u^2 / 5.0 + u^3 / 15.0) * exp(-u)
    end
end
function m72_kstar(x, xi, θ)
    local l = θ[1]; local σ² = θ[2]
    local r = smooth_abs(x - xi) / l
    local u = sqrt(7.0) * r
    return σ² * (1.0 + u + 2.0 * u^2 / 5.0 + u^3 / 15.0) * exp(-u)
end

# Matern 9/2: θ = [l, σ²]
function m92_K!(K, xs, θ)
    local l = θ[1]; local σ² = θ[2]
    local n = length(xs)
    for j in 1:n, i in 1:n
        local r = abs(xs[i] - xs[j]) / l
        local u = 3.0 * r
        K[i, j] = σ² * (1.0 + u + 27.0 * r^2 / 7.0 + 18.0 * r^3 / 7.0 + 27.0 * r^4 / 35.0) * exp(-u)
    end
end
function m92_kstar(x, xi, θ)
    local l = θ[1]; local σ² = θ[2]
    local r = smooth_abs(x - xi) / l
    local u = 3.0 * r
    return σ² * (1.0 + u + 27.0 * r^2 / 7.0 + 18.0 * r^3 / 7.0 + 27.0 * r^4 / 35.0) * exp(-u)
end

# Periodic: θ = [l, σ², p]
function per_K!(K, xs, θ)
    local l = θ[1]; local σ² = θ[2]; local p = θ[3]
    local inv_l2 = 2.0 / (l * l)
    local n = length(xs)
    for j in 1:n, i in 1:n
        local s = sin(π * (xs[i] - xs[j]) / p)
        K[i, j] = σ² * exp(-inv_l2 * s * s)
    end
end
function per_kstar(x, xi, θ)
    local l = θ[1]; local σ² = θ[2]; local p = θ[3]
    local s = sin(π * (x - xi) / p)
    return σ² * exp(-2.0 * s * s / (l * l))
end

# SE × Periodic: θ = [l_se, l_per, σ², p]
function sep_K!(K, xs, θ)
    local l_se = θ[1]; local l_per = θ[2]; local σ² = θ[3]; local p = θ[4]
    local inv2l2 = 1.0 / (2.0 * l_se^2)
    local inv_lp2 = 2.0 / (l_per^2)
    local n = length(xs)
    for j in 1:n, i in 1:n
        local d = xs[i] - xs[j]
        local se = exp(-d * d * inv2l2)
        local s = sin(π * d / p)
        local pe = exp(-inv_lp2 * s * s)
        K[i, j] = σ² * se * pe
    end
end
function sep_kstar(x, xi, θ)
    local l_se = θ[1]; local l_per = θ[2]; local σ² = θ[3]; local p = θ[4]
    local d = x - xi
    local se = exp(-d * d / (2.0 * l_se^2))
    local s = sin(π * d / p)
    local pe = exp(-2.0 * s * s / (l_per^2))
    return σ² * se * pe
end

# ── Optimize + predict + save ─────────────────────────────────────────
function run_kernel(name, xs, ys_raw, K_fn!, kstar_fn, n_hyper, θ0, θ_lo, θ_hi,
                    noise_var, t_eval_pts, t_shoot_pts, noise_tag)
    n = length(xs)
    y_mean = mean(ys_raw)
    y_std = max(std(ys_raw), 1e-8)
    ys_norm = (collect(Float64, ys_raw) .- y_mean) ./ y_std
    jitter = 1e-8
    K = Matrix{Float64}(undef, n, n)

    # Optimize hyperparameters
    function neg_lml(θ_raw)
        local θk = [_softplus(θ_raw[i]) for i in 1:n_hyper]
        K_fn!(K, xs, θk)
        for i in 1:n; K[i, i] += noise_var + jitter; end
        try
            local C = cholesky(Symmetric(K))
            local alpha_l = C \ ys_norm
            return 0.5 * (dot(ys_norm, alpha_l) + 2.0 * sum(log.(diag(C.U))) + n * log(2π))
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
    for v in θ_opt; @printf(" %.4f", v); end
    println()

    # Build predictor with optimized params
    K_fn!(K, xs, θ_opt)
    for i in 1:n; K[i, i] += noise_var + jitter; end
    local C = try
        cholesky(Symmetric(K))
    catch
        @warn "$name: Cholesky failed"; return nothing
    end
    local alpha = C \ ys_norm
    local xs_cap = collect(Float64, xs)

    pred(x::Real) = begin
        local kv = [kstar_fn(x, xi, θ_opt) for xi in xs_cap]
        y_std * dot(kv, alpha) + y_mean
    end

    # Evaluate predictions + derivatives at eval grid
    open(joinpath(OUTDIR, "pred_$(name)_$(noise_tag).csv"), "w") do f
        print(f, "t")
        for d in 0:MAX_DERIV; print(f, ",pred_d$d,truth_d$d,abserr_d$d"); end
        println(f)
        for tv in t_eval_pts
            print(f, tv)
            for d in 0:MAX_DERIV
                local pv = try
                    if d == 0; pred(tv); else ODEParameterEstimation.nth_deriv(pred, d, tv); end
                catch; NaN; end
                local trv = get_truth([tv], d)[1]
                print(f, ",", pv, ",", trv, ",", abs(pv - trv))
            end
            println(f)
        end
    end

    # Errors at shooting points
    errors = Float64[]
    for d in 0:MAX_DERIV
        pvals = Float64[]
        tvals = Float64[]
        for tv in t_shoot_pts
            local pv = try
                if d == 0; pred(tv); else ODEParameterEstimation.nth_deriv(pred, d, tv); end
            catch; NaN; end
            local trv = get_truth([tv], d)[1]
            push!(pvals, pv)
            push!(tvals, trv)
        end
        if any(isnan, pvals)
            push!(errors, NaN)
        else
            local ae = abs.(pvals .- tvals)
            local scale = mean(abs.(tvals))
            push!(errors, scale > 1e-15 ? sqrt(mean(ae .^ 2)) / scale : sqrt(mean(ae .^ 2)))
        end
    end

    @printf("    errors: ")
    for (d, e) in enumerate(errors)
        @printf("d%d=%.2e  ", d-1, e)
    end
    println()

    return (errors=errors, θ=θ_opt, lml=lml_val, conv=conv)
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
    @printf("NOISE = %s   n = %d   period = %.3f   noise_var = %.1e\n",
        noise_tag, length(t_data), period, noise_var)
    println("=" ^ 90)

    ls0 = std(t_data) / 8.0

    kernel_defs = [
        ("SE",          2, se_K!,  se_kstar,  [ls0, 1.0],                [1e-3, 1e-8],                  [150.0, 150.0]),
        ("Matern52",    2, m52_K!, m52_kstar, [ls0, 1.0],                [1e-3, 1e-8],                  [150.0, 150.0]),
        ("Matern72",    2, m72_K!, m72_kstar, [ls0, 1.0],                [1e-3, 1e-8],                  [150.0, 150.0]),
        ("Matern92",    2, m92_K!, m92_kstar, [ls0, 1.0],                [1e-3, 1e-8],                  [150.0, 150.0]),
        ("Periodic",    3, per_K!, per_kstar, [1.0, 1.0, period],        [1e-3, 1e-8, period*0.5],      [150.0, 150.0, period*2.0]),
        ("SExPeriodic", 4, sep_K!, sep_kstar, [10.0, 1.0, 1.0, period],  [1e-3, 1e-3, 1e-8, period*0.5],[150.0, 150.0, 150.0, period*2.0]),
    ]

    all_results = Dict{String, Any}()
    for (name, nh, Kfn, ksfn, θ0, θlo, θhi) in kernel_defs
        r = run_kernel(name, t_data, y_data, Kfn, ksfn, nh, θ0, θlo, θhi,
            noise_var, t_eval, t_shoot_eval, noise_tag)
        if r !== nothing
            all_results[name] = r
        end
    end

    # Summary table
    println("\n  SUMMARY (rel_rmse at 8 offset shooting points):")
    @printf("  %-16s  neg_lml   ", "Kernel")
    for d in 0:MAX_DERIV; @printf("d%-8d", d); end
    println()
    println("  " * "-" ^ 90)
    for (name, _, _, _, _, _, _) in kernel_defs
        if haskey(all_results, name)
            r = all_results[name]
            @printf("  %-16s  %8.1f  ", name, r.lml)
            for e in r.errors; @printf("%-9.2e", e); end
            println()
        end
    end

    # Save summary
    open(joinpath(OUTDIR, "summary_$(noise_tag).csv"), "w") do f
        print(f, "kernel,neg_lml")
        for d in 0:MAX_DERIV; print(f, ",d$d"); end
        println(f)
        for (name, _, _, _, _, _, _) in kernel_defs
            if haskey(all_results, name)
                r = all_results[name]
                print(f, name, ",", r.lml)
                for e in r.errors; print(f, ",", e); end
                println(f)
            end
        end
    end
end

println("\nDone. Results in $OUTDIR")
