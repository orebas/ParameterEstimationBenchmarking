#!/usr/bin/env julia
#=
Bayesian Barycentric Rational Approximation (BBRA) — Prototype
==============================================================
Combines AAA's derivative accuracy with noise robustness via MAP estimation
of barycentric rational functions.

Two strategies:
  A: AAA-initialized (use AAA for initial support points, weights, values)
  B: Vector Fitting style (linearly-spaced support points, optimize from scratch)

References:
  - Nakatsukasa, Sète, Trefethen (2018): The AAA algorithm
  - Gustavsen & Semlyen (1999): Vector Fitting
  - Schneider & Werner: Barycentric derivatives (Proposition 12)
  - Gonnet et al.: Robust Padé approximation via SVD
=#

using ODEParameterEstimation
using ODEParameterEstimation: aaad, aaad_gpr_pivot, agp_gpr_robust, nth_deriv, fhdn
using BaryRational
using OrdinaryDiffEq
using TaylorDiff
using Optim
using CSV, DataFrames
using Statistics
using LinearAlgebra
using Printf
using Random

const OUTDIR = @__DIR__

println("="^70)
println("BBRA Prototype: Bayesian Barycentric Rational Approximation")
println("="^70)
println()

# ──────────────────────────────────────────────────────────────────────
# 1. Model: Biohydrogenation (exact quokka config, same as 01)
# ──────────────────────────────────────────────────────────────────────
const K5, K6, K7, K8, K9, K10 = 0.688, 0.87, 0.299, 0.561, 0.574, 0.558
const X4_0, X5_0, X6_0, X7_0 = 0.278, 0.862, 0.458, 0.777
const T_START, T_END = 0.0, 10.0
const DATASIZE = 1501
const T_RANGE = T_END - T_START
const MAX_DERIV = 7

function biohydrogenation!(du, u, p, t)
    x4, x5, x6, x7 = u
    k5, k6, k7, k8, k9, k10 = p
    du[1] = (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4))
    du[2] = ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5
    du[3] = ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5
    du[4] = (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10)
end

function ode_rhs_vec(u, p)
    x4, x5, x6, x7 = u
    k5, k6, k7, k8, k9, k10 = p
    du1 = (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4))
    du2 = ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5
    du3 = ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5
    du4 = (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10)
    return [du1, du2, du3, du4]
end

# ──────────────────────────────────────────────────────────────────────
# 2. ODE Solve
# ──────────────────────────────────────────────────────────────────────
p_vals = [K5, K6, K7, K8, K9, K10]
ic_vals = [X4_0, X5_0, X6_0, X7_0]
t_phys = collect(range(T_START, T_END, length=DATASIZE))
t_norm = collect(range(-0.5, 0.5, length=DATASIZE))

println("Solving ODE (Vern9, abstol=rtol=1e-14)...")
prob = ODEProblem(biohydrogenation!, ic_vals, (T_START, T_END), p_vals)
sol_data = solve(prob, Vern9(), abstol=1e-14, reltol=1e-14, saveat=t_phys)
sol_dense = solve(prob, Vern9(), abstol=1e-14, reltol=1e-14)

y1_data = 8.0 .* sol_data[1, :]
y2_data = 0.5 .* sol_data[2, :]
println("  $(length(sol_data.t)) data points, y1 ∈ [$(round(minimum(y1_data),digits=4)), $(round(maximum(y1_data),digits=4))]")
println()

# ──────────────────────────────────────────────────────────────────────
# 3. Ground Truth Derivatives via ODE Taylor Recursion
# ──────────────────────────────────────────────────────────────────────
function compute_ode_taylor(x0::Vector{Float64}, p, max_order::Int)
    n_states = length(x0)
    jets = Vector{Vector{Float64}}(undef, max_order + 1)
    jets[1] = copy(x0)
    for k in 1:max_order
        local current_jets = jets
        jet_k = zeros(n_states)
        for comp in 1:n_states
            function f_comp_of_h(h)
                x = copy(current_jets[1])
                hpow = one(h)
                for j in 1:k-1
                    hpow = hpow * h / j
                    x = x .+ current_jets[j+1] .* hpow
                end
                return ode_rhs_vec(x, p)[comp]
            end
            jet_k[comp] = k == 1 ? f_comp_of_h(0.0) : TaylorDiff.derivative(f_comp_of_h, 0.0, Val(k - 1))
        end
        jets[k + 1] = jet_k
    end
    return jets
end

function warped_indices(n_points, N; beta=3.0)
    idxs = Int[]
    for i in 1:n_points
        frac = (i - 1) / (n_points - 1)
        push!(idxs, max(1, min(N, round(Int, 1 + frac^beta * (N - 1)))))
    end
    return unique(idxs)
end

eval_idxs = warped_indices(12, DATASIZE, beta=3.0)

println("Computing ground truth derivatives (orders 0-$MAX_DERIV) at $(length(eval_idxs)) points...")
gt = Dict{Tuple{String, Int, Int}, Float64}()

for (i, idx) in enumerate(eval_idxs)
    tp = t_phys[idx]
    x0 = collect(sol_dense(tp))
    jets = compute_ode_taylor(x0, p_vals, MAX_DERIV)
    for n in 0:MAX_DERIV
        gt[("y1", i, n)] = 8.0 * jets[n+1][1] * T_RANGE^n
        gt[("y2", i, n)] = 0.5 * jets[n+1][2] * T_RANGE^n
    end
end
println("  Done.")
println()

# ──────────────────────────────────────────────────────────────────────
# 4. Core BBRA Primitives
# ──────────────────────────────────────────────────────────────────────

"""
Evaluate barycentric rational function r(t) = N(t)/D(t).
AutoDiff-compatible (ForwardDiff, TaylorDiff).
"""
function bary_eval(t, z, w, f)
    T = promote_type(typeof(t), eltype(z), eltype(w), eltype(f))
    num = zero(T)
    den = zero(T)
    for j in eachindex(z)
        d = t - z[j]
        # At support points, the barycentric formula reduces to f[j].
        # Use a soft version that avoids exact 0/0 for numeric stability,
        # but still gives correct ForwardDiff derivatives w.r.t. w,f.
        if d == zero(d)
            return T(f[j])
        end
        a = w[j] / d
        num += a * f[j]
        den += a
    end
    return num / den
end

"""Derivative via TaylorDiff (primary method for consistency with ODEPE)."""
function bary_deriv_td(t, z, w, f, order::Int)
    order == 0 && return bary_eval(t, z, w, f)
    return TaylorDiff.derivative(s -> bary_eval(s, z, w, f), t, Val(order))
end

"""
Derivative via Schneider-Werner recurrence (Prop 12).
Analytical, O(m·order). Used for cross-validation of TaylorDiff results.
"""
function bary_deriv_sw(t, z, w, f, order::Int)
    # Handle exact support point
    for j in eachindex(z)
        if t == z[j]
            # Use the removable-singularity formula from BaryRational
            ww = -w ./ w[j]
            ff = (f .- f[j]) ./ (z .- z[j])
            zz = copy(z)
            deleteat!(ww, j); deleteat!(ff, j); deleteat!(zz, j)
            γ = ww ./ sum(ww)
            δ = copy(ff)
            ϕ = zero(eltype(f))
            for k in 1:order
                ϕ = dot(γ, δ)
                δ .= (δ .- ϕ) ./ (zz .- z[j])
            end
            return factorial(order) * ϕ
        end
    end
    V = w ./ (t .- z)
    γ = V ./ sum(V)
    δ = copy(convert(Vector{Float64}, f))
    ϕ = 0.0
    for k in 0:order
        ϕ = dot(γ, δ)
        δ .= (δ .- ϕ) ./ (z .- t)
    end
    return factorial(order) * ϕ
end

"""Compute poles via generalized Schur decomposition (from BaryRational.prz)."""
function bary_poles(z, w)
    m = length(w)
    T = Float64
    B = diagm(ones(T, m + 1))
    B[1, 1] = zero(T)
    E = [zero(T) transpose(w); ones(T, m) diagm(z)]
    sp = schur(Complex.(E), Complex.(B))
    return sp.values[isfinite.(sp.values)]
end

"""Check for poles near the data interval [t_min, t_max]."""
function pole_report(z, w, t_min, t_max; threshold=0.1)
    poles = bary_poles(z, w)
    real_poles = filter(p -> abs(imag(p)) < threshold, poles)
    near_poles = filter(p -> t_min - threshold ≤ real(p) ≤ t_max + threshold, real_poles)
    return (poles=poles, near_real=real_poles, near_interval=near_poles)
end

# ──────────────────────────────────────────────────────────────────────
# 5. MAP Objective & Fitting
# ──────────────────────────────────────────────────────────────────────

"""
MAP objective and gradient for BBRA. θ = [w; f], with soft gauge ‖w‖²≈1 penalty.
Returns (loss, gradient) for use with Optim.jl's `OnceDifferentiable`.

Uses analytical gradients (no autodiff):
  ∂r_k/∂w_j = a_j(t_k) · (f_j - r_k) / D_k
  ∂r_k/∂f_j = w_j · a_j(t_k) / D_k
"""
function bbra_objective_and_grad!(F, G, θ, z, t_data, y_data, f_init, λ_f, μ_gauge)
    m = length(z)
    w = θ[1:m]
    f_vals = θ[m+1:2m]

    loss = zero(Float64)

    if G !== nothing
        fill!(G, 0.0)
    end

    # Precompute: for each data point, compute r(t_j) and optionally accumulate gradient
    for j in eachindex(t_data)
        tj = t_data[j]

        # Check if tj coincides with a support point
        exact_match = 0
        for i in 1:m
            if tj == z[i]
                exact_match = i
                break
            end
        end

        if exact_match > 0
            # At support point: r(z_i) = f_i, independent of w
            residual = y_data[j] - f_vals[exact_match]
            loss += residual^2
            if G !== nothing
                G[m + exact_match] -= 2.0 * residual  # ∂/∂f_i
            end
        else
            # Normal evaluation
            num = 0.0
            den = 0.0
            for i in 1:m
                a = w[i] / (tj - z[i])
                num += a * f_vals[i]
                den += a
            end
            r_val = num / den
            residual = y_data[j] - r_val

            loss += residual^2

            if G !== nothing
                inv_den = 1.0 / den
                for i in 1:m
                    a_i = 1.0 / (tj - z[i])
                    # ∂r/∂w_i = a_i * (f_i - r_val) / D
                    dr_dw = a_i * (f_vals[i] - r_val) * inv_den
                    G[i] -= 2.0 * residual * dr_dw
                    # ∂r/∂f_i = w_i * a_i / D
                    dr_df = w[i] * a_i * inv_den
                    G[m + i] -= 2.0 * residual * dr_df
                end
            end
        end
    end

    # f regularization
    for i in 1:m
        df = f_vals[i] - f_init[i]
        loss += λ_f * df^2
        if G !== nothing
            G[m + i] += 2.0 * λ_f * df
        end
    end

    # Soft gauge penalty: μ * (‖w‖² - 1)²
    w_norm_sq = sum(abs2, w)
    loss += μ_gauge * (w_norm_sq - 1.0)^2
    if G !== nothing
        gauge_grad = 4.0 * μ_gauge * (w_norm_sq - 1.0)
        for i in 1:m
            G[i] += gauge_grad * w[i]
        end
    end

    return loss
end

"""
Fit BBRA via MAP optimization with analytical gradients.
Returns (z, w_opt, f_opt, opt_result).
"""
function fit_bbra(z, w_init, f_init, t_data, y_data;
                  λ_f=1e-4, μ_gauge=10.0, maxiter=2000, g_tol=1e-10)
    θ_init = vcat(copy(w_init), copy(f_init))

    function fg!(F, G, θ)
        return bbra_objective_and_grad!(F, G, θ, z, t_data, y_data, f_init, λ_f, μ_gauge)
    end

    od = OnceDifferentiable(Optim.only_fg!(fg!), θ_init)

    result = optimize(od, θ_init, LBFGS(),
                      Optim.Options(iterations=maxiter, g_tol=g_tol,
                                    f_reltol=1e-16, show_trace=false))

    θ_opt = Optim.minimizer(result)
    m = length(z)
    w_opt = θ_opt[1:m]
    w_opt ./= norm(w_opt)  # final normalization
    f_opt = θ_opt[m+1:2m]

    return z, w_opt, f_opt, result
end

# ──────────────────────────────────────────────────────────────────────
# 6. Strategy A: AAA-Initialized MAP
# ──────────────────────────────────────────────────────────────────────

"""
Strategy A: Run AAA on (possibly smoothed) data to get initial support points,
weights, and values. Then optimize via MAP.
"""
function strategy_a(t_data, y_data; λ_f=1e-4, maxiter=2000,
                    smooth=false, smooth_window=5)
    # Optional: light smoothing before AAA
    y_for_aaa = if smooth
        # Simple moving average smoothing
        n = length(y_data)
        hw = smooth_window ÷ 2
        [mean(y_data[max(1,i-hw):min(n,i+hw)]) for i in 1:n]
    else
        y_data
    end

    # Run AAA
    r = aaa(t_data, y_for_aaa)
    z = copy(r.x)
    w_init = copy(r.w)
    f_init = copy(r.f)

    # Normalize
    w_init ./= norm(w_init)

    # When smoothing, re-initialize f values from RAW data (not smoothed)
    if smooth
        for (j, zj) in enumerate(z)
            idx = searchsortedlast(t_data, zj)
            if idx < 1
                f_init[j] = y_data[1]
            elseif idx >= length(t_data)
                f_init[j] = y_data[end]
            elseif t_data[idx] == zj
                f_init[j] = y_data[idx]
            else
                α = (zj - t_data[idx]) / (t_data[idx+1] - t_data[idx])
                f_init[j] = (1 - α) * y_data[idx] + α * y_data[idx+1]
            end
        end
    end

    println("    AAA selected $(length(z)) support points")

    # Optimize
    z_opt, w_opt, f_opt, opt_result = fit_bbra(z, w_init, f_init, t_data, y_data;
                                                λ_f=λ_f, maxiter=maxiter)

    println("    Optimization: $(Optim.iterations(opt_result)) iters, " *
            "final loss = $(round(Optim.minimum(opt_result), sigdigits=4)), " *
            "converged = $(Optim.converged(opt_result))")

    return z_opt, w_opt, f_opt, opt_result
end

# ──────────────────────────────────────────────────────────────────────
# 7. Strategy B: Linearly-Spaced Support Points
# ──────────────────────────────────────────────────────────────────────

"""
Solve linear least-squares for f given fixed support points z and weights w.
For fixed w, the barycentric form r(t) = Σ wᵢfᵢ/(t-zᵢ) / Σ wᵢ/(t-zᵢ) is
LINEAR in f. Build the matrix A[j,i] = wᵢ/(tⱼ-zᵢ) / Σₖ wₖ/(tⱼ-zₖ) and
solve A*f ≈ y via least squares.
"""
function solve_f_linear(z, w, t_data, y_data)
    n = length(t_data)
    m = length(z)
    A = zeros(n, m)
    for j in 1:n
        # Check if t_data[j] coincides with a support point
        exact_match = 0
        for i in 1:m
            if t_data[j] == z[i]
                exact_match = i
                break
            end
        end
        if exact_match > 0
            A[j, exact_match] = 1.0
        else
            D = 0.0
            for i in 1:m
                a = w[i] / (t_data[j] - z[i])
                A[j, i] = a
                D += a
            end
            A[j, :] ./= D
        end
    end
    return A \ y_data
end

"""
Strategy B: Start with Chebyshev-distributed support points (Vector Fitting style).
Initialize f via linear least-squares (optimal for fixed w). Optimize via MAP.
"""
function strategy_b(t_data, y_data, m; λ_f=1e-4, maxiter=2000,
                    use_chebyshev=true)
    t_min, t_max = extrema(t_data)

    # Use Chebyshev nodes (avoids Runge phenomenon with equispaced points)
    if use_chebyshev
        z = [(t_min + t_max) / 2 + (t_max - t_min) / 2 * cos((2k - 1) * π / (2m))
             for k in 1:m]
        sort!(z)  # ascending order for consistency
    else
        margin = (t_max - t_min) / (2 * m)
        z = collect(range(t_min + margin, t_max - margin, length=m))
    end

    # Floater-Hormann weights for initial w (d=3 blending order)
    # w_k = (-1)^k * Σ_{i=max(0,k-d)}^{min(k,n-d)} C(d, k-i)
    d = min(3, m - 1)
    w_init = zeros(m)
    for k in 0:m-1
        s = 0.0
        for i in max(0, k - d):min(k, m - 1 - d)
            s += binomial(d, k - i)
        end
        w_init[k+1] = (-1)^k * s
    end
    w_init ./= norm(w_init)

    # Initialize f via linear least-squares (optimal for fixed w)
    f_init = solve_f_linear(z, w_init, t_data, y_data)

    println("    m=$m Chebyshev support points, FH(d=$d) initial weights")

    z_opt, w_opt, f_opt, opt_result = fit_bbra(z, w_init, f_init, t_data, y_data;
                                                λ_f=λ_f, maxiter=maxiter)

    println("    Optimization: $(Optim.iterations(opt_result)) iters, " *
            "final loss = $(round(Optim.minimum(opt_result), sigdigits=4)), " *
            "converged = $(Optim.converged(opt_result))")

    return z_opt, w_opt, f_opt, opt_result
end

# ──────────────────────────────────────────────────────────────────────
# 8. Evaluation Helpers
# ──────────────────────────────────────────────────────────────────────

"""
Evaluate derivative accuracy of a barycentric fit against ground truth.
Returns DataFrame of errors.
"""
function evaluate_derivatives(label, z, w, f, t_norm_vec, t_phys_vec,
                              eval_idxs, gt, observables;
                              deriv_method=:taylordiff)
    rows = []
    for (obs, _) in observables
        for (i, idx) in enumerate(eval_idxs)
            tn = t_norm_vec[idx]
            for n in 0:MAX_DERIV
                gt_val = gt[(obs, i, n)]
                est = NaN
                try
                    if deriv_method == :taylordiff
                        est = bary_deriv_td(tn, z, w, f, n)
                    else
                        est = bary_deriv_sw(tn, z, w, f, n)
                    end
                catch e
                    # Derivative computation failed (pole, numerical issue)
                end
                ae = isnan(est) ? NaN : abs(est - gt_val)
                re = (isnan(ae) || abs(gt_val) < 1e-15) ? NaN : ae / abs(gt_val)
                push!(rows, (interpolator=label, observable=obs, eval_point=i,
                             t_phys=t_phys_vec[idx], deriv_order=n,
                             ground_truth=gt_val, estimated=est,
                             abs_error=ae, rel_error=re))
            end
        end
    end
    return DataFrame(rows)
end

"""Format relative error for display."""
fmt(v) = isnan(v) ? "N/A" :
    v < 1e-12 ? "~0" :
    v < 0.001 ? "$(round(v*100, sigdigits=2))%" :
    v < 10 ? "$(round(v*100, sigdigits=3))%" :
    "$(round(v*100, sigdigits=3))%"

"""
Evaluate derivative accuracy of a generic callable interpolator against ground truth.
The interpolator `interp` should be callable as interp(t_norm).
"""
function evaluate_interp_derivatives(label, interp, t_norm_vec, t_phys_vec,
                                     eval_idxs, gt, observables)
    rows = []
    for (obs, _) in observables
        for (i, idx) in enumerate(eval_idxs)
            tn = t_norm_vec[idx]
            for n in 0:MAX_DERIV
                gt_val = gt[(obs, i, n)]
                est = NaN
                try
                    f_interp = x -> interp(x)
                    est = (n == 0) ? f_interp(tn) : nth_deriv(f_interp, n, tn)
                catch
                end
                ae = isnan(est) ? NaN : abs(est - gt_val)
                re = (isnan(ae) || abs(gt_val) < 1e-15) ? NaN : ae / abs(gt_val)
                push!(rows, (interpolator=label, observable=obs, eval_point=i,
                             t_phys=t_phys_vec[idx], deriv_order=n,
                             ground_truth=gt_val, estimated=est,
                             abs_error=ae, rel_error=re))
            end
        end
    end
    return DataFrame(rows)
end

"""Print a summary table of median relative errors."""
function print_summary_table(title, df)
    println("\n" * "="^70)
    println(title)
    println("="^70)
    names_list = unique(df.interpolator)
    println(rpad("Method", 20), " | ", join([rpad("d$n", 12) for n in 0:MAX_DERIV], " | "))
    println("-"^20, "-+-", join(["-"^12 for _ in 0:MAX_DERIV], "-+-"))
    for nm in names_list
        cells = String[]
        for n in 0:MAX_DERIV
            v = filter(!isnan, df[(df.interpolator .== nm) .& (df.deriv_order .== n), :rel_error])
            push!(cells, isempty(v) ? "N/A" : fmt(median(v)))
        end
        println(rpad(nm, 20), " | ", join([rpad(c, 12) for c in cells], " | "))
    end
end

# ──────────────────────────────────────────────────────────────────────
# 9. Run: Noiseless Baseline
# ──────────────────────────────────────────────────────────────────────
println("="^70)
println("Phase 1: Noiseless Baseline")
println("="^70)

observables = [("y1", y1_data), ("y2", y2_data)]
all_results = DataFrame()

# Reference: PureAAA (no optimization, just BaryRational.aaa)
println("\n--- PureAAA (reference) ---")
for (obs, ydata) in observables
    r = aaa(t_norm, ydata)
    df = evaluate_derivatives("PureAAA", r.x, r.w, r.f, t_norm, t_phys,
                              eval_idxs, gt, [(obs, ydata)])
    global all_results = vcat(all_results, df)
end

# Strategy A: AAA-initialized BBRA (noiseless)
println("\n--- BBRA-A (AAA-initialized, noiseless) ---")
for (obs, ydata) in observables
    println("  Observable: $obs")
    z, w, f, res = strategy_a(t_norm, ydata; λ_f=1e-6, maxiter=3000)

    # Check poles
    pr = pole_report(z, w, -0.5, 0.5)
    println("    Poles: $(length(pr.poles)) total, $(length(pr.near_interval)) near interval")

    df = evaluate_derivatives("BBRA-A", z, w, f, t_norm, t_phys,
                              eval_idxs, gt, [(obs, ydata)])
    global all_results = vcat(all_results, df)
end

# Strategy B: Vector Fitting style (noiseless, m=50)
println("\n--- BBRA-B (m=50, noiseless) ---")
for (obs, ydata) in observables
    println("  Observable: $obs")
    z, w, f, res = strategy_b(t_norm, ydata, 50; λ_f=1e-6, maxiter=3000)

    pr = pole_report(z, w, -0.5, 0.5)
    println("    Poles: $(length(pr.poles)) total, $(length(pr.near_interval)) near interval")

    df = evaluate_derivatives("BBRA-B(50)", z, w, f, t_norm, t_phys,
                              eval_idxs, gt, [(obs, ydata)])
    global all_results = vcat(all_results, df)
end

# GP interpolators from ODEPE (reference comparisons)
gp_interpolators = [
    ("AGPRobust_SE",   (xs, ys) -> agp_gpr_robust(xs, ys; kernel_type=:se)),
    ("AGPRobust_RQ",   (xs, ys) -> agp_gpr_robust(xs, ys; kernel_type=:rq)),
    ("FHD5",           (xs, ys) -> fhdn(5)(xs, ys)),
]

for (gp_label, create_fn) in gp_interpolators
    println("\n--- $gp_label (reference) ---")
    for (obs, ydata) in observables
        print("  $obs: ")
        try
            elapsed = @elapsed (interp = create_fn(t_norm, ydata))
            println("created in $(round(elapsed, digits=2))s")
            df = evaluate_interp_derivatives(gp_label, interp, t_norm, t_phys,
                                             eval_idxs, gt, [(obs, ydata)])
            global all_results = vcat(all_results, df)
        catch e
            println("FAILED: ", sprint(showerror, e))
        end
    end
end

print_summary_table("NOISELESS: Median Relative Error (y1+y2)", all_results)

# Cross-validate TaylorDiff vs Schneider-Werner
println("\n--- Cross-validating derivative methods (TaylorDiff vs Schneider-Werner) ---")
let
    r_ref = aaa(t_norm, y1_data)
    tn_test = t_norm[eval_idxs[5]]
    local max_diff = 0.0
    for n in 0:MAX_DERIV
        td_val = bary_deriv_td(tn_test, r_ref.x, r_ref.w, r_ref.f, n)
        sw_val = bary_deriv_sw(tn_test, r_ref.x, r_ref.w, r_ref.f, n)
        diff = abs(td_val - sw_val) / max(abs(td_val), 1e-15)
        max_diff = max(max_diff, diff)
        if n ∈ [0, 3, 7]
            @printf("    d%d: TaylorDiff=%.8e, S-W=%.8e, rel_diff=%.2e\n", n, td_val, sw_val, diff)
        end
    end
    println("    Max relative difference across all orders: $(round(max_diff, sigdigits=3))")
end

# ──────────────────────────────────────────────────────────────────────
# 10. Model Order Selection (Strategy B)
# ──────────────────────────────────────────────────────────────────────
println("\n" * "="^70)
println("Phase 2: Model Order Selection (BIC)")
println("="^70)

bic_results = DataFrame(m=Int[], obs=String[], rss=Float64[], bic=Float64[],
                         aic=Float64[], n_poles_near=Int[])

for (obs, ydata) in observables
    println("\n  Observable: $obs")
    n_data = length(ydata)
    for m in [10, 15, 20, 30, 40, 50, 60, 70, 80, 100]
        print("    m=$m: ")
        try
            z, w, f, res = strategy_b(t_norm, ydata, m; λ_f=1e-6, maxiter=3000)

            # Compute RSS
            rss = sum((ydata[j] - bary_eval(t_norm[j], z, w, f))^2 for j in 1:n_data)
            k_params = 2 * m  # w + f
            bic = n_data * log(rss / n_data) + k_params * log(n_data)
            aic = n_data * log(rss / n_data) + 2 * k_params

            pr = pole_report(z, w, -0.5, 0.5)
            n_near = length(pr.near_interval)

            push!(bic_results, (m, obs, rss, bic, aic, n_near))
            @printf("RSS=%.3e, BIC=%.1f, AIC=%.1f, poles_near=%d\n", rss, bic, aic, n_near)
        catch e
            println("FAILED: ", sprint(showerror, e))
        end
    end
end

# Report optimal m
for obs in ["y1", "y2"]
    sub = bic_results[bic_results.obs .== obs, :]
    if !isempty(sub)
        best_idx = argmin(sub.bic)
        println("\n  Best m for $obs by BIC: $(sub.m[best_idx]) (BIC=$(round(sub.bic[best_idx], digits=1)))")
    end
end

# ──────────────────────────────────────────────────────────────────────
# 11. Noise Sweep
# ──────────────────────────────────────────────────────────────────────
println("\n" * "="^70)
println("Phase 3: Noise Sweep")
println("="^70)

noise_levels = [0.0, 0.0001, 0.0003, 0.001, 0.003, 0.01, 0.03, 0.05, 0.1]
noise_results = DataFrame()

Random.seed!(42)

for noise_frac in noise_levels
    println("\n--- Noise level: $(noise_frac*100)% ---")

    for (obs, ydata_clean) in observables
        # Add Gaussian noise
        σ_noise = noise_frac * std(ydata_clean)
        ydata_noisy = noise_frac == 0.0 ? copy(ydata_clean) :
                      ydata_clean .+ σ_noise .* randn(length(ydata_clean))

        noise_label = noise_frac < 0.01 ? @sprintf("%.2f%%", noise_frac * 100) : @sprintf("%.1f%%", noise_frac * 100)

        # PureAAA on noisy data
        println("  $obs PureAAA (noise=$noise_label):")
        try
            r = aaa(t_norm, ydata_noisy)
            df = evaluate_derivatives("AAA_n$(noise_label)", r.x, r.w, r.f,
                                      t_norm, t_phys, eval_idxs, gt, [(obs, ydata_clean)])
            global noise_results = vcat(noise_results, df)
            println("    $(length(r.x)) support points")
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # BBRA-A on noisy data (with smoothing when noisy)
        println("  $obs BBRA-A (noise=$noise_label):")
        try
            do_smooth = noise_frac > 0.001
            sw = noise_frac > 0.05 ? 15 : (noise_frac > 0.01 ? 9 : 5)
            z, w, f, res = strategy_a(t_norm, ydata_noisy;
                                       λ_f=max(1e-6, noise_frac * 0.1),
                                       maxiter=3000, smooth=do_smooth, smooth_window=sw)
            df = evaluate_derivatives("BBRA-A_n$(noise_label)", z, w, f,
                                      t_norm, t_phys, eval_idxs, gt, [(obs, ydata_clean)])
            global noise_results = vcat(noise_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # BBRA-B on noisy data (m=50)
        println("  $obs BBRA-B (noise=$noise_label, m=50):")
        try
            z, w, f, res = strategy_b(t_norm, ydata_noisy, 50;
                                       λ_f=max(1e-6, noise_frac * 0.1),
                                       maxiter=3000)
            df = evaluate_derivatives("BBRA-B_n$(noise_label)", z, w, f,
                                      t_norm, t_phys, eval_idxs, gt, [(obs, ydata_clean)])
            global noise_results = vcat(noise_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # GP interpolators on noisy data
        gp_noise_methods = [
            ("GPR_SE",   (xs, ys) -> agp_gpr_robust(xs, ys; kernel_type=:se)),
            ("GPR_RQ",   (xs, ys) -> agp_gpr_robust(xs, ys; kernel_type=:rq)),
            ("FHD5",     (xs, ys) -> fhdn(5)(xs, ys)),
        ]
        for (gp_label, create_fn) in gp_noise_methods
            println("  $obs $gp_label (noise=$noise_label):")
            try
                interp = create_fn(t_norm, ydata_noisy)
                df = evaluate_interp_derivatives("$(gp_label)_n$(noise_label)",
                    interp, t_norm, t_phys, eval_idxs, gt, [(obs, ydata_clean)])
                global noise_results = vcat(noise_results, df)
            catch e
                println("    FAILED: ", sprint(showerror, e))
            end
        end
    end
end

# ──────────────────────────────────────────────────────────────────────
# 12. Results Summary
# ──────────────────────────────────────────────────────────────────────

# Helper to format noise level label consistently
function noise_label_str(noise_frac)
    noise_frac < 0.01 ? @sprintf("%.2f%%", noise_frac * 100) : @sprintf("%.1f%%", noise_frac * 100)
end

println("\n" * "="^70)
println("Phase 4: Results Summary")
println("="^70)

# Noiseless comparison
print_summary_table("NOISELESS: Median Relative Error", all_results)

# Noise sweep comparison
if !isempty(noise_results)
    print_summary_table("NOISE SWEEP: Median Relative Error (all noise levels × methods)", noise_results)

    # Per noise level
    for noise_frac in noise_levels
        nl = noise_label_str(noise_frac)
        mask = occursin.("_n$(nl)", noise_results.interpolator)
        sub = noise_results[mask, :]
        if !isempty(sub)
            print_summary_table("Noise=$nl: Median Relative Error", sub)
        end
    end
end

# Key comparison tables for d3 and d5
for deriv_n in [3, 5]
    println("\n" * "="^70)
    println("KEY METRIC: d$deriv_n median relative error across noise levels")
    println("="^70)
    col_hdrs = [noise_frac < 0.01 ? @sprintf("%.2f%%", noise_frac*100) :
                @sprintf("%.1f%%", noise_frac*100) for noise_frac in noise_levels]
    println(rpad("Method", 22), " | ", join([rpad(h, 12) for h in col_hdrs], " | "))
    println("-"^22, "-+-", join(["-"^12 for _ in noise_levels], "-+-"))

    for method_prefix in ["AAA", "BBRA-A", "BBRA-B", "GPR_SE", "GPR_RQ", "FHD5"]
        cells = String[]
        for noise_frac in noise_levels
            nl = noise_label_str(noise_frac)
            pattern = "$(method_prefix)_n$(nl)"
            mask = (noise_results.interpolator .== pattern) .& (noise_results.deriv_order .== deriv_n)
            v = filter(!isnan, noise_results[mask, :rel_error])
            push!(cells, isempty(v) ? "N/A" : fmt(median(v)))
        end
        println(rpad(method_prefix, 22), " | ", join([rpad(c, 12) for c in cells], " | "))
    end
end

# Save all results
CSV.write(joinpath(OUTDIR, "bbra_noiseless_results.csv"), all_results)
CSV.write(joinpath(OUTDIR, "bbra_noise_sweep_results.csv"), noise_results)
CSV.write(joinpath(OUTDIR, "bbra_model_order_selection.csv"), bic_results)

# Summary CSV: median error per method × deriv_order
combined = vcat(all_results, noise_results)
summary_df = DataFrame(method=String[], deriv_order=Int[],
                        median_rel=Float64[], max_rel=Float64[])
for nm in unique(combined.interpolator), n in 0:MAX_DERIV
    v = filter(!isnan, combined[(combined.interpolator .== nm) .& (combined.deriv_order .== n), :rel_error])
    push!(summary_df, (nm, n, isempty(v) ? NaN : median(v), isempty(v) ? NaN : maximum(v)))
end
CSV.write(joinpath(OUTDIR, "bbra_summary.csv"), summary_df)

println("\n" * "="^70)
println("Done! Results saved to: $OUTDIR")
println("  bbra_noiseless_results.csv")
println("  bbra_noise_sweep_results.csv")
println("  bbra_model_order_selection.csv")
println("  bbra_summary.csv")
println("="^70)
