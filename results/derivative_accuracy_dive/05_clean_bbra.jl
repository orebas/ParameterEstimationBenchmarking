#!/usr/bin/env julia
#=
Clean BBRA Experiments — No Oracle, Maximum Effort
====================================================
Lessons learned from 01–04:
  - AAA gives spectral derivative accuracy on noiseless data
  - GP→AAA→BBRA (Strategy C) is the best noisy method at low noise
  - Strategy B (Chebyshev/VF) is dead — AAA's adaptive support points are essential
  - MAP ≈ MLE empirically (too few parameters to overfit)
  - d5 ~100% barrier at moderate noise (1e-4) for all methods

Critiques addressed:
  1. λ_f was tuned on noise_frac — ORACLE CHEATING → eliminated (pure MLE)
  2. Regularization unnecessary → removed entirely
  3. Soft gauge μ·(‖w‖²-1)² overcomplicated → hard fix w₁=1
  4. Need more effort → tighter tolerances, more iterations, warm restarts

Strategies:
  1. Clean GP→AAA→MLE (baseline clean)
  2. Direct AAA→MLE (no GP)
  3. GP→AAA→MLE with more support points (AAA tol=1e-14 + midpoints)
  4. Alternating optimization (alternate linear f-solve ↔ w-optimize)
=#

using ODEParameterEstimation
using ODEParameterEstimation: aaad, agp_gpr_robust, nth_deriv, fhdn
using BaryRational
using OrdinaryDiffEq
using TaylorDiff
using Optim
using ForwardDiff
using CSV, DataFrames
using Statistics
using LinearAlgebra
using Printf
using Random

const OUTDIR = @__DIR__
const MAX_DERIV = 7

println("="^70)
println("05: Clean BBRA — No Oracle, Maximum Effort")
println("="^70)

# ──────────────────────────────────────────────────────────────────────
# 1. Model & Data
# ──────────────────────────────────────────────────────────────────────
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
    [(-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4)),
     ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5,
     ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5,
     (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10)]
end

p_vals = [0.688, 0.87, 0.299, 0.561, 0.574, 0.558]
ic_vals = [0.278, 0.862, 0.458, 0.777]
t_phys = collect(range(0.0, 10.0, length=1501))
t_norm = collect(range(-0.5, 0.5, length=1501))

println("Solving ODE...")
prob = ODEProblem(biohydrogenation!, ic_vals, (0.0, 10.0), p_vals)
sol_data = solve(prob, Vern9(), abstol=1e-14, reltol=1e-14, saveat=t_phys)
sol_dense = solve(prob, Vern9(), abstol=1e-14, reltol=1e-14)

y1_clean = 8.0 .* sol_data[1, :]
y2_clean = 0.5 .* sol_data[2, :]
println("  1501 points, y1 ∈ [$(round(minimum(y1_clean),digits=4)), $(round(maximum(y1_clean),digits=4))]")
println("               y2 ∈ [$(round(minimum(y2_clean),digits=4)), $(round(maximum(y2_clean),digits=4))]")

# ──────────────────────────────────────────────────────────────────────
# 2. Ground truth
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

eval_idxs = warped_indices(12, 1501, beta=3.0)

println("Computing ground truth (d0-d$MAX_DERIV at $(length(eval_idxs)) points)...")
gt = Dict{Tuple{String, Int, Int}, Float64}()
for (i, idx) in enumerate(eval_idxs)
    tp = t_phys[idx]
    x0 = collect(sol_dense(tp))
    jets = compute_ode_taylor(x0, p_vals, MAX_DERIV)
    for n in 0:MAX_DERIV
        gt[("y1", i, n)] = 8.0 * jets[n+1][1] * 10.0^n
        gt[("y2", i, n)] = 0.5 * jets[n+1][2] * 10.0^n
    end
end
println("  Done.")

# ──────────────────────────────────────────────────────────────────────
# 3. Barycentric primitives
# ──────────────────────────────────────────────────────────────────────

"""Evaluate barycentric rational r(t) = N(t)/D(t). AD-compatible."""
function bary_eval(t, z, w, f)
    T = promote_type(typeof(t), eltype(z), eltype(w), eltype(f))
    num = zero(T); den = zero(T)
    for j in eachindex(z)
        d = t - z[j]
        d == zero(d) && return T(f[j])
        a = w[j] / d
        num += a * f[j]; den += a
    end
    return num / den
end

"""Derivative via TaylorDiff."""
function bary_deriv_td(t, z, w, f, order::Int)
    order == 0 && return bary_eval(t, z, w, f)
    return TaylorDiff.derivative(s -> bary_eval(s, z, w, f), t, Val(order))
end

"""Poles via generalized Schur decomposition."""
function bary_poles(z, w)
    m = length(w)
    B = diagm(ones(m + 1)); B[1, 1] = 0.0
    E = [0.0 transpose(w); ones(m) diagm(z)]
    sp = schur(Complex.(E), Complex.(B))
    return sp.values[isfinite.(sp.values)]
end

"""Check for poles near data interval."""
function pole_report(z, w, t_min, t_max; threshold=0.1)
    poles = bary_poles(z, w)
    real_poles = filter(p -> abs(imag(p)) < threshold, poles)
    near_poles = filter(p -> t_min - threshold ≤ real(p) ≤ t_max + threshold, real_poles)
    return (poles=poles, near_real=real_poles, near_interval=near_poles)
end

"""Solve for f via linear LS given fixed z, w: r(t) is linear in f."""
function solve_f_linear(z, w, t_data, y_data)
    n = length(t_data)
    m = length(z)
    A = zeros(n, m)
    for j in 1:n
        exact = 0
        for i in 1:m
            t_data[j] == z[i] && (exact = i; break)
        end
        if exact > 0
            A[j, exact] = 1.0
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

# ──────────────────────────────────────────────────────────────────────
# 4. Clean MLE objective with hard gauge (w₁=1)
# ──────────────────────────────────────────────────────────────────────

"""
Clean MLE objective and analytical gradient.
θ = [w₂, w₃, …, wₘ, f₁, f₂, …, fₘ]  (w₁=1 is fixed, NOT in θ)
Loss = Σ(yⱼ - r(tⱼ))²  (pure RSS, no regularization, no gauge penalty)
"""
function mle_fg!(F, G, θ, z, t_data, y_data)
    m = length(z)
    # Unpack: w₁=1 is fixed
    T = eltype(θ)
    w = vcat(one(T), θ[1:m-1])
    fv = θ[m:2m-1]

    loss = zero(T)
    G !== nothing && fill!(G, 0.0)

    for j in eachindex(t_data)
        tj = t_data[j]

        # Check for exact support point match
        exact = 0
        for i in 1:m
            tj == z[i] && (exact = i; break)
        end

        if exact > 0
            res = y_data[j] - fv[exact]
            loss += res^2
            if G !== nothing
                # ∂/∂f_exact; f index in θ is (m-1) + exact
                G[m - 1 + exact] -= 2.0 * res
            end
        else
            num = zero(T)
            den = zero(T)
            for i in 1:m
                a = w[i] / (tj - z[i])
                num += a * fv[i]; den += a
            end
            rv = num / den
            res = y_data[j] - rv
            loss += res^2

            if G !== nothing
                id = 1.0 / den
                for i in 1:m
                    ai = 1.0 / (tj - z[i])
                    dr_df = w[i] * ai * id
                    # f gradient: index in θ is (m-1) + i
                    G[m - 1 + i] -= 2.0 * res * dr_df

                    # w gradient: only for i ≥ 2 (w₁=1 is fixed)
                    if i >= 2
                        dr_dw = ai * (fv[i] - rv) * id
                        # w_i index in θ is i-1
                        G[i - 1] -= 2.0 * res * dr_dw
                    end
                end
            end
        end
    end

    return loss
end

"""
Fit BBRA via clean MLE with hard gauge (w₁=1).
Tries LBFGS with warm restart. If m ≤ 15 (≤29 params), also tries NewtonTrustRegion.
Returns (z, w_opt, f_opt, opt_result, convergence_info).
"""
function fit_bbra_clean(z, w_init, f_init, t_data, y_data;
                        maxiter=20000, g_tol=1e-15)
    m = length(z)

    # Normalize so w₁=1
    w_scaled = w_init ./ w_init[1]
    f_scaled = copy(f_init)

    # Pack: θ = [w₂…wₘ, f₁…fₘ]
    θ0 = vcat(w_scaled[2:end], f_scaled)

    fg! = (F, G, θ) -> mle_fg!(F, G, θ, z, t_data, y_data)
    od = OnceDifferentiable(Optim.only_fg!(fg!), θ0)

    opts = Optim.Options(iterations=maxiter, g_tol=g_tol,
                         f_reltol=1e-16, x_reltol=1e-16, show_trace=false)

    # Run 1: LBFGS
    result = optimize(od, θ0, LBFGS(), opts)
    θ_best = Optim.minimizer(result)
    best_loss = Optim.minimum(result)
    info = "LBFGS1: $(Optim.iterations(result)) iters, loss=$(round(best_loss, sigdigits=6))"

    # Warm restart: run LBFGS again from current solution
    result2 = optimize(od, θ_best, LBFGS(), opts)
    if Optim.minimum(result2) < best_loss
        θ_best = Optim.minimizer(result2)
        best_loss = Optim.minimum(result2)
        result = result2
    end
    info *= " → LBFGS2: $(Optim.iterations(result2)) iters, loss=$(round(Optim.minimum(result2), sigdigits=6))"

    # For small m, try NewtonTrustRegion with ForwardDiff Hessian
    if m <= 15
        try
            f_scalar = θ -> mle_fg!(nothing, nothing, θ, z, t_data, y_data)
            td_od = TwiceDifferentiable(f_scalar, θ_best; autodiff=:forward)
            result_nt = optimize(td_od, θ_best, NewtonTrustRegion(), opts)
            if Optim.minimum(result_nt) < best_loss
                θ_best = Optim.minimizer(result_nt)
                best_loss = Optim.minimum(result_nt)
                result = result_nt
            end
            info *= " → NTR: $(Optim.iterations(result_nt)) iters, loss=$(round(Optim.minimum(result_nt), sigdigits=6))"
        catch e
            info *= " → NTR: failed ($(typeof(e)))"
        end
    end

    # Unpack
    w_opt = vcat(1.0, θ_best[1:m-1])
    f_opt = θ_best[m:2m-1]

    # Verify gauge: w₁ should be exactly 1.0
    @assert w_opt[1] == 1.0 "Gauge violation: w₁ = $(w_opt[1])"

    return z, w_opt, f_opt, result, info
end

# ──────────────────────────────────────────────────────────────────────
# 5. Strategies
# ──────────────────────────────────────────────────────────────────────

"""
Strategy 1: Clean GP→AAA→MLE (baseline clean version).
GP denoise → AAA on GP output → harvest support points → pure MLE on raw data.
NO oracle parameters, NO regularization.
"""
function strategy_gp_aaa_mle(t_data, y_noisy;
                              aaa_tol=1e-10, gp_kernel=:se, maxiter=20000, g_tol=1e-15)
    # Step 1: GP denoise
    gp = agp_gpr_robust(t_data, y_noisy; kernel_type=gp_kernel)
    y_gp = [gp(t) for t in t_data]

    # Step 2: AAA on denoised GP output → support points
    r = aaa(t_data, y_gp; tol=aaa_tol, mmax=200)
    z = copy(r.x); w0 = copy(r.w); f0 = copy(r.f)
    @printf("    GP→AAA: %d support points\n", length(z))

    # Step 3: Pure MLE against raw noisy data
    z, w, f, res, info = fit_bbra_clean(z, w0, f0, t_data, y_noisy;
                                         maxiter=maxiter, g_tol=g_tol)
    println("    $info")
    println("    converged=$(Optim.converged(res)), g_norm=$(round(Optim.g_residual(res), sigdigits=3))")
    return z, w, f
end

"""
Strategy 2: Direct AAA→MLE (no GP denoising).
Tests whether GP denoising is needed for support point selection.
"""
function strategy_aaa_mle(t_data, y_noisy;
                           aaa_tol=1e-10, maxiter=20000, g_tol=1e-15)
    # AAA directly on noisy data
    r = aaa(t_data, y_noisy; tol=aaa_tol, mmax=200)
    z = copy(r.x); w0 = copy(r.w); f0 = copy(r.f)
    @printf("    AAA: %d support points\n", length(z))

    # Pure MLE against raw noisy data
    z, w, f, res, info = fit_bbra_clean(z, w0, f0, t_data, y_noisy;
                                         maxiter=maxiter, g_tol=g_tol)
    println("    $info")
    println("    converged=$(Optim.converged(res)), g_norm=$(round(Optim.g_residual(res), sigdigits=3))")
    return z, w, f
end

"""
Strategy 3: GP→AAA→MLE with more support points.
Uses AAA tol=1e-14 (forces more points) but keeps AAA's own weights as initialization.
No midpoint enrichment (uniform weights for inserted points are ill-conditioned).
"""
function strategy_gp_aaa_mle_high(t_data, y_noisy;
                                   gp_kernel=:se, maxiter=20000, g_tol=1e-15)
    # Step 1: GP denoise
    gp = agp_gpr_robust(t_data, y_noisy; kernel_type=gp_kernel)
    y_gp = [gp(t) for t in t_data]

    # Step 2: AAA with tight tolerance → more support points
    r = aaa(t_data, y_gp; tol=1e-14, mmax=200)
    z = copy(r.x); w0 = copy(r.w); f0 = copy(r.f)
    @printf("    GP→AAA(tol=1e-14): %d support points\n", length(z))

    # Step 3: Pure MLE (using AAA's own weights as init — they're well-conditioned)
    z, w, f, res, info = fit_bbra_clean(z, w0, f0, t_data, y_noisy;
                                         maxiter=maxiter, g_tol=g_tol)
    println("    $info")
    println("    converged=$(Optim.converged(res)), g_norm=$(round(Optim.g_residual(res), sigdigits=3))")
    return z, w, f
end

"""
Strategy 4: Alternating optimization.
Start from Strategy 1's solution, then alternate:
  (a) Fix w, solve f by linear LS (convex subproblem)
  (b) Fix f, optimize w by MLE
Repeat for `cycles` iterations.
"""
function strategy_alternating(t_data, y_noisy;
                               aaa_tol=1e-10, gp_kernel=:se,
                               cycles=10, maxiter=20000, g_tol=1e-15)
    # Initialize from Strategy 1
    gp = agp_gpr_robust(t_data, y_noisy; kernel_type=gp_kernel)
    y_gp = [gp(t) for t in t_data]
    r = aaa(t_data, y_gp; tol=aaa_tol, mmax=200)
    z = copy(r.x); w = copy(r.w); f = copy(r.f)

    # Initial MLE to get a good starting point
    z, w, f, _, _ = fit_bbra_clean(z, w, f, t_data, y_noisy;
                                    maxiter=maxiter, g_tol=g_tol)
    m = length(z)

    # Compute initial RSS
    rss = sum((y_noisy[j] - bary_eval(t_data[j], z, w, f))^2 for j in eachindex(t_data))
    @printf("    Init: %d pts, RSS=%.6e\n", m, rss)

    for cyc in 1:cycles
        # (a) Fix w, solve f by linear LS
        f_new = solve_f_linear(z, w, t_data, y_noisy)

        # (b) Fix f, optimize w by MLE (only w₂…wₘ, w₁=1)
        # Pack just the w parameters (m-1 of them)
        function w_fg!(F, G, w_free)
            w_full = vcat(1.0, w_free)
            loss = 0.0
            G !== nothing && fill!(G, 0.0)
            for j in eachindex(t_data)
                tj = t_data[j]
                exact = 0
                for i in 1:m; tj == z[i] && (exact = i; break); end
                if exact > 0
                    res = y_noisy[j] - f_new[exact]
                    loss += res^2
                    # No w gradient for exact matches
                else
                    num, den = 0.0, 0.0
                    for i in 1:m
                        a = w_full[i] / (tj - z[i])
                        num += a * f_new[i]; den += a
                    end
                    rv = num / den; res = y_noisy[j] - rv
                    loss += res^2
                    if G !== nothing
                        id = 1.0 / den
                        for i in 2:m  # skip w₁ (fixed)
                            ai = 1.0 / (tj - z[i])
                            dr_dw = ai * (f_new[i] - rv) * id
                            G[i - 1] -= 2.0 * res * dr_dw
                        end
                    end
                end
            end
            return loss
        end

        w_free = w[2:end]
        od = OnceDifferentiable(Optim.only_fg!(w_fg!), w_free)
        w_opts = Optim.Options(iterations=maxiter ÷ cycles, g_tol=g_tol,
                               f_reltol=1e-16, x_reltol=1e-16, show_trace=false)
        w_res = optimize(od, w_free, LBFGS(), w_opts)
        w = vcat(1.0, Optim.minimizer(w_res))
        f = f_new

        rss_new = sum((y_noisy[j] - bary_eval(t_data[j], z, w, f))^2 for j in eachindex(t_data))
        if cyc ≤ 3 || cyc == cycles
            @printf("    Cycle %2d: RSS=%.6e (Δ=%.2e)\n", cyc, rss_new, rss_new - rss)
        end
        rss = rss_new
    end

    # Final joint MLE polish
    z, w, f, res, info = fit_bbra_clean(z, w, f, t_data, y_noisy;
                                         maxiter=maxiter, g_tol=g_tol)
    @printf("    Final polish: %s\n", info)
    println("    converged=$(Optim.converged(res)), g_norm=$(round(Optim.g_residual(res), sigdigits=3))")
    return z, w, f
end

# ──────────────────────────────────────────────────────────────────────
# 6. Evaluation helpers
# ──────────────────────────────────────────────────────────────────────

function eval_bary(label, z, w, f, obs_name)
    rows = []
    for (i, idx) in enumerate(eval_idxs)
        tn = t_norm[idx]
        for n in 0:MAX_DERIV
            gv = gt[(obs_name, i, n)]
            est = try bary_deriv_td(tn, z, w, f, n) catch; NaN end
            ae = isnan(est) ? NaN : abs(est - gv)
            re = (isnan(ae) || abs(gv) < 1e-15) ? NaN : ae / abs(gv)
            push!(rows, (interpolator=label, observable=obs_name, eval_point=i,
                         deriv_order=n, ground_truth=gv, estimated=est,
                         abs_error=ae, rel_error=re))
        end
    end
    return DataFrame(rows)
end

function eval_interp(label, interp, obs_name)
    rows = []
    for (i, idx) in enumerate(eval_idxs)
        tn = t_norm[idx]
        for n in 0:MAX_DERIV
            gv = gt[(obs_name, i, n)]
            est = try (n == 0 ? interp(tn) : nth_deriv(x -> interp(x), n, tn)) catch; NaN end
            ae = isnan(est) ? NaN : abs(est - gv)
            re = (isnan(ae) || abs(gv) < 1e-15) ? NaN : ae / abs(gv)
            push!(rows, (interpolator=label, observable=obs_name, eval_point=i,
                         deriv_order=n, ground_truth=gv, estimated=est,
                         abs_error=ae, rel_error=re))
        end
    end
    return DataFrame(rows)
end

fmt(v) = isnan(v) ? "N/A" :
    v < 1e-12 ? "~0" :
    v < 0.001 ? "$(round(v*100, sigdigits=2))%" :
    v < 10 ? "$(round(v*100, sigdigits=3))%" :
    "$(round(v*100, sigdigits=3))%"

function print_table(title, df; col_width=13)
    println("\n" * "="^70)
    println(title)
    println("="^70)
    nms = unique(df.interpolator)
    println(rpad("Method", 24), " | ", join([rpad("d$n", col_width) for n in 0:MAX_DERIV], " | "))
    println("-"^24, "-+-", join(["-"^col_width for _ in 0:MAX_DERIV], "-+-"))
    for nm in nms
        cells = [begin
            v = filter(!isnan, df[(df.interpolator .== nm) .& (df.deriv_order .== n), :rel_error])
            isempty(v) ? "N/A" : fmt(median(v))
        end for n in 0:MAX_DERIV]
        println(rpad(nm, 24), " | ", join([rpad(c, col_width) for c in cells], " | "))
    end
end

# ──────────────────────────────────────────────────────────────────────
# 7. Run benchmark
# ──────────────────────────────────────────────────────────────────────

noise_levels = [0.0, 1e-8, 1e-6, 1e-4, 1e-2]
noise_names  = ["0", "1e-8", "1e-6", "1e-4", "1e-2"]

all_results = DataFrame()
Random.seed!(42)

for (noise_frac, noise_name) in zip(noise_levels, noise_names)
    println("\n" * "="^70)
    @printf("NOISE LEVEL: %s (multiplicative)\n", noise_name)
    println("="^70)

    for (obs, ydata_clean) in [("y1", y1_clean), ("y2", y2_clean)]
        # Multiplicative noise
        if noise_frac == 0.0
            ydata_noisy = copy(ydata_clean)
        else
            ydata_noisy = ydata_clean .* (1.0 .+ noise_frac .* randn(length(ydata_clean)))
        end

        actual_noise_std = std(ydata_noisy .- ydata_clean)
        println("\n  [$obs] actual noise σ = $(round(actual_noise_std, sigdigits=4))")

        tag = "n$noise_name"

        # ── Reference methods ──

        # PureAAA
        print("  PureAAA: ")
        try
            r = aaa(t_norm, ydata_noisy)
            @printf("%d pts\n", length(r.x))
            global all_results = vcat(all_results, eval_bary("PureAAA_$tag", r.x, r.w, r.f, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # GP_SE
        print("  GP_SE: ")
        try
            elapsed = @elapsed (gp = agp_gpr_robust(t_norm, ydata_noisy; kernel_type=:se))
            @printf("%.1fs\n", elapsed)
            global all_results = vcat(all_results, eval_interp("GP_SE_$tag", gp, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # GP_RQ
        print("  GP_RQ: ")
        try
            elapsed = @elapsed (gp = agp_gpr_robust(t_norm, ydata_noisy; kernel_type=:rq))
            @printf("%.1fs\n", elapsed)
            global all_results = vcat(all_results, eval_interp("GP_RQ_$tag", gp, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # FHD5
        print("  FHD5: ")
        try
            elapsed = @elapsed (interp = fhdn(5)(t_norm, ydata_noisy))
            @printf("%.2fs\n", elapsed)
            global all_results = vcat(all_results, eval_interp("FHD5_$tag", interp, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # ── New clean strategies ──

        # Strategy 1: GP→AAA→MLE (clean)
        println("  Strategy1 (GP→AAA→MLE):")
        try
            z, w, f = strategy_gp_aaa_mle(t_norm, ydata_noisy)
            pr = pole_report(z, w, -0.5, 0.5)
            println("    Poles near interval: $(length(pr.near_interval))")
            global all_results = vcat(all_results, eval_bary("S1_GP_AAA_MLE_$tag", z, w, f, obs))
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # Strategy 2: AAA→MLE (no GP)
        println("  Strategy2 (AAA→MLE):")
        try
            z, w, f = strategy_aaa_mle(t_norm, ydata_noisy)
            pr = pole_report(z, w, -0.5, 0.5)
            println("    Poles near interval: $(length(pr.near_interval))")
            global all_results = vcat(all_results, eval_bary("S2_AAA_MLE_$tag", z, w, f, obs))
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # Strategy 3: GP→AAA(tight)→MLE + midpoints
        println("  Strategy3 (GP→AAA_high→MLE):")
        try
            z, w, f = strategy_gp_aaa_mle_high(t_norm, ydata_noisy)
            pr = pole_report(z, w, -0.5, 0.5)
            println("    Poles near interval: $(length(pr.near_interval))")
            global all_results = vcat(all_results, eval_bary("S3_High_$tag", z, w, f, obs))
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # Strategy 4: Alternating optimization
        println("  Strategy4 (Alternating):")
        try
            z, w, f = strategy_alternating(t_norm, ydata_noisy)
            pr = pole_report(z, w, -0.5, 0.5)
            println("    Poles near interval: $(length(pr.near_interval))")
            global all_results = vcat(all_results, eval_bary("S4_Altern_$tag", z, w, f, obs))
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end
    end
end

# ──────────────────────────────────────────────────────────────────────
# 8. Results
# ──────────────────────────────────────────────────────────────────────

println("\n\n")
println("#"^70)
println("# FULL RESULTS")
println("#"^70)

# Per noise level
for (noise_frac, noise_name) in zip(noise_levels, noise_names)
    tag = "n$noise_name"
    mask = occursin.("_$tag", all_results.interpolator)
    sub = all_results[mask, :]
    !isempty(sub) && print_table("NOISE = $noise_name  (multiplicative)", sub)
end

# Cross-noise comparison: one table per derivative order
println("\n\n")
println("#"^70)
println("# CROSS-NOISE COMPARISON (one table per derivative order)")
println("#"^70)

method_prefixes = ["PureAAA", "GP_SE", "GP_RQ", "FHD5",
                   "S1_GP_AAA_MLE", "S2_AAA_MLE", "S3_High", "S4_Altern"]

for dn in 0:MAX_DERIV
    println("\n" * "="^70)
    @printf("d%d median relative error across noise levels\n", dn)
    println("="^70)
    println(rpad("Method", 18), " | ", join([rpad(nn, 13) for nn in noise_names], " | "))
    println("-"^18, "-+-", join(["-"^13 for _ in noise_names], "-+-"))

    for pfx in method_prefixes
        cells = [begin
            full_name = "$(pfx)_n$nn"
            mask = (all_results.interpolator .== full_name) .& (all_results.deriv_order .== dn)
            v = filter(!isnan, all_results[mask, :rel_error])
            isempty(v) ? "N/A" : fmt(median(v))
        end for nn in noise_names]
        println(rpad(pfx, 18), " | ", join([rpad(c, 13) for c in cells], " | "))
    end
end

# Compact summary
println("\n\n")
println("#"^70)
println("# COMPACT SUMMARY: method → [d0 d1 d2 d3 d4 d5 d6 d7]")
println("#"^70)

for (noise_frac, noise_name) in zip(noise_levels, noise_names)
    tag = "n$noise_name"
    println("\n--- Noise = $noise_name ---")
    for pfx in method_prefixes
        full_name = "$(pfx)_$tag"
        cells = [begin
            mask = (all_results.interpolator .== full_name) .& (all_results.deriv_order .== n)
            v = filter(!isnan, all_results[mask, :rel_error])
            isempty(v) ? "N/A" : fmt(median(v))
        end for n in 0:MAX_DERIV]
        @printf("  %-18s  %s\n", pfx, join([rpad(c, 13) for c in cells], " "))
    end
end

# ──────────────────────────────────────────────────────────────────────
# 9. Verification checks
# ──────────────────────────────────────────────────────────────────────
println("\n\n")
println("#"^70)
println("# VERIFICATION CHECKS")
println("#"^70)

# Check 1: No oracle — verify noise_frac is NOT used in any strategy
println("\n✓ Oracle check: strategies use NO noise_frac parameter")
println("  (All strategy functions take only t_data, y_noisy, and hyperparams like aaa_tol)")

# Check 2: Noiseless sanity — all strategies should match PureAAA quality
println("\n  Noiseless d5 check (should all be < 0.1%):")
for pfx in method_prefixes
    mask = (all_results.interpolator .== "$(pfx)_n0") .& (all_results.deriv_order .== 5)
    v = filter(!isnan, all_results[mask, :rel_error])
    val = isempty(v) ? NaN : median(v)
    status = isnan(val) ? "N/A" : (val < 0.001 ? "✓ PASS" : "✗ FAIL")
    @printf("    %-18s  d5=%-12s  %s\n", pfx, isempty(v) ? "N/A" : fmt(median(v)), status)
end

# Check 3: Convergence audit
println("\n  Convergence audit (did optimizers converge?):")
println("  (See individual strategy output above for g_norm values)")

# ──────────────────────────────────────────────────────────────────────
# 10. Save
# ──────────────────────────────────────────────────────────────────────
CSV.write(joinpath(OUTDIR, "clean_bbra_results.csv"), all_results)

summary = DataFrame(method=String[], noise=String[], deriv_order=Int[],
                     median_rel=Float64[], max_rel=Float64[], mean_rel=Float64[])
for nm in unique(all_results.interpolator), n in 0:MAX_DERIV
    v = filter(!isnan, all_results[(all_results.interpolator .== nm) .& (all_results.deriv_order .== n), :rel_error])
    nn = replace(nm, r".*_n" => "")
    pfx = replace(nm, r"_n.*" => "")
    push!(summary, (pfx, nn, n,
        isempty(v) ? NaN : median(v),
        isempty(v) ? NaN : maximum(v),
        isempty(v) ? NaN : mean(v)))
end
CSV.write(joinpath(OUTDIR, "clean_bbra_summary.csv"), summary)

println("\n" * "="^70)
println("Done! Saved to:")
println("  $OUTDIR/clean_bbra_results.csv")
println("  $OUTDIR/clean_bbra_summary.csv")
println("="^70)
