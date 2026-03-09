#!/usr/bin/env julia
#=
Worker script for 06_noise_comparison.
Usage: julia 06_worker.jl <noise_type> <noise_level_index>
  noise_type: "multiplicative" or "additive"
  noise_level_index: 1-5 (maps to [0, 1e-8, 1e-6, 1e-4, 1e-2])

Runs all 8 methods × 2 observables for one (noise_type, noise_level) combo.
Writes results to 06_worker_<nt_short>_<noise_name>.csv
=#

noise_type = ARGS[1]
noise_level_idx = parse(Int, ARGS[2])

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

noise_levels = [0.0, 1e-8, 1e-6, 1e-4, 1e-2]
noise_names  = ["0", "1e-8", "1e-6", "1e-4", "1e-2"]

noise_frac = noise_levels[noise_level_idx]
noise_name = noise_names[noise_level_idx]
nt_short = noise_type == "multiplicative" ? "mult" : "add"

println("="^70)
@printf("Worker: %s noise, level=%s (index %d)\n", noise_type, noise_name, noise_level_idx)
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

println("Computing ground truth...")
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

# ──────────────────────────────────────────────────────────────────────
# 3. Barycentric primitives
# ──────────────────────────────────────────────────────────────────────

"""Use ODEPE's baryEval which has AD-friendly limiting form at support points."""
bary_eval(t, z, w, f) = ODEParameterEstimation.baryEval(t, f, z, w)

function bary_deriv_td(t, z, w, f, order::Int)
    order == 0 && return bary_eval(t, z, w, f)
    return TaylorDiff.derivative(s -> ODEParameterEstimation.baryEval(s, f, z, w), t, Val(order))
end

function bary_poles(z, w)
    m = length(w)
    B = diagm(ones(m + 1)); B[1, 1] = 0.0
    E = [0.0 transpose(w); ones(m) diagm(z)]
    sp = schur(Complex.(E), Complex.(B))
    return sp.values[isfinite.(sp.values)]
end

function pole_report(z, w, t_min, t_max; threshold=0.1)
    poles = bary_poles(z, w)
    real_poles = filter(p -> abs(imag(p)) < threshold, poles)
    near_poles = filter(p -> t_min - threshold ≤ real(p) ≤ t_max + threshold, real_poles)
    return (poles=poles, near_real=real_poles, near_interval=near_poles)
end

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

function mle_fg!(F, G, θ, z, t_data, y_data)
    m = length(z)
    T = eltype(θ)
    w = vcat(one(T), θ[1:m-1])
    fv = θ[m:2m-1]

    loss = zero(T)
    G !== nothing && fill!(G, 0.0)

    for j in eachindex(t_data)
        tj = t_data[j]
        exact = 0
        for i in 1:m
            tj == z[i] && (exact = i; break)
        end

        if exact > 0
            res = y_data[j] - fv[exact]
            loss += res^2
            if G !== nothing
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
                    G[m - 1 + i] -= 2.0 * res * dr_df
                    if i >= 2
                        dr_dw = ai * (fv[i] - rv) * id
                        G[i - 1] -= 2.0 * res * dr_dw
                    end
                end
            end
        end
    end
    return loss
end

function fit_bbra_clean(z, w_init, f_init, t_data, y_data;
                        maxiter=20000, g_tol=1e-15)
    m = length(z)
    w_scaled = w_init ./ w_init[1]
    f_scaled = copy(f_init)
    θ0 = vcat(w_scaled[2:end], f_scaled)

    fg! = (F, G, θ) -> mle_fg!(F, G, θ, z, t_data, y_data)
    od = OnceDifferentiable(Optim.only_fg!(fg!), θ0)
    opts = Optim.Options(iterations=maxiter, g_tol=g_tol,
                         f_reltol=1e-16, x_reltol=1e-16, show_trace=false)

    result = optimize(od, θ0, LBFGS(), opts)
    θ_best = Optim.minimizer(result)
    best_loss = Optim.minimum(result)
    info = "LBFGS1: $(Optim.iterations(result)) iters, loss=$(round(best_loss, sigdigits=6))"

    result2 = optimize(od, θ_best, LBFGS(), opts)
    if Optim.minimum(result2) < best_loss
        θ_best = Optim.minimizer(result2)
        best_loss = Optim.minimum(result2)
        result = result2
    end
    info *= " → LBFGS2: $(Optim.iterations(result2)) iters, loss=$(round(Optim.minimum(result2), sigdigits=6))"

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

    w_opt = vcat(1.0, θ_best[1:m-1])
    f_opt = θ_best[m:2m-1]
    @assert w_opt[1] == 1.0 "Gauge violation: w₁ = $(w_opt[1])"
    return z, w_opt, f_opt, result, info
end

# ──────────────────────────────────────────────────────────────────────
# 5. Strategies
# ──────────────────────────────────────────────────────────────────────

function strategy_gp_aaa_mle(t_data, y_noisy;
                              aaa_tol=1e-10, gp_kernel=:se, maxiter=20000, g_tol=1e-15)
    gp = agp_gpr_robust(t_data, y_noisy; kernel_type=gp_kernel)
    y_gp = [gp(t) for t in t_data]
    r = aaa(t_data, y_gp; tol=aaa_tol, mmax=200)
    z = copy(r.x); w0 = copy(r.w); f0 = copy(r.f)
    @printf("    GP→AAA: %d support points\n", length(z))
    z, w, f, res, info = fit_bbra_clean(z, w0, f0, t_data, y_noisy;
                                         maxiter=maxiter, g_tol=g_tol)
    println("    $info")
    println("    converged=$(Optim.converged(res)), g_norm=$(round(Optim.g_residual(res), sigdigits=3))")
    return z, w, f
end

function strategy_aaa_mle(t_data, y_noisy;
                           aaa_tol=1e-10, maxiter=20000, g_tol=1e-15)
    r = aaa(t_data, y_noisy; tol=aaa_tol, mmax=200)
    z = copy(r.x); w0 = copy(r.w); f0 = copy(r.f)
    @printf("    AAA: %d support points\n", length(z))
    z, w, f, res, info = fit_bbra_clean(z, w0, f0, t_data, y_noisy;
                                         maxiter=maxiter, g_tol=g_tol)
    println("    $info")
    println("    converged=$(Optim.converged(res)), g_norm=$(round(Optim.g_residual(res), sigdigits=3))")
    return z, w, f
end

function strategy_gp_aaa_mle_high(t_data, y_noisy;
                                   gp_kernel=:se, maxiter=20000, g_tol=1e-15)
    gp = agp_gpr_robust(t_data, y_noisy; kernel_type=gp_kernel)
    y_gp = [gp(t) for t in t_data]
    r = aaa(t_data, y_gp; tol=1e-14, mmax=200)
    z = copy(r.x); w0 = copy(r.w); f0 = copy(r.f)
    @printf("    GP→AAA(tol=1e-14): %d support points\n", length(z))
    z, w, f, res, info = fit_bbra_clean(z, w0, f0, t_data, y_noisy;
                                         maxiter=maxiter, g_tol=g_tol)
    println("    $info")
    println("    converged=$(Optim.converged(res)), g_norm=$(round(Optim.g_residual(res), sigdigits=3))")
    return z, w, f
end

function strategy_alternating(t_data, y_noisy;
                               aaa_tol=1e-10, gp_kernel=:se,
                               cycles=10, maxiter=20000, g_tol=1e-15)
    gp = agp_gpr_robust(t_data, y_noisy; kernel_type=gp_kernel)
    y_gp = [gp(t) for t in t_data]
    r = aaa(t_data, y_gp; tol=aaa_tol, mmax=200)
    z = copy(r.x); w = copy(r.w); f = copy(r.f)

    z, w, f, _, _ = fit_bbra_clean(z, w, f, t_data, y_noisy;
                                    maxiter=maxiter, g_tol=g_tol)
    m = length(z)
    rss = sum((y_noisy[j] - bary_eval(t_data[j], z, w, f))^2 for j in eachindex(t_data))
    @printf("    Init: %d pts, RSS=%.6e\n", m, rss)

    for cyc in 1:cycles
        f_new = solve_f_linear(z, w, t_data, y_noisy)
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
                        for i in 2:m
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

# ──────────────────────────────────────────────────────────────────────
# 7. Noise generation
# ──────────────────────────────────────────────────────────────────────

function generate_noise(ydata_clean, noise_frac, noise_type::String)
    if noise_frac == 0.0
        return copy(ydata_clean)
    end
    N = length(ydata_clean)
    if noise_type == "multiplicative"
        return ydata_clean .* (1.0 .+ noise_frac .* randn(N))
    else
        σ = noise_frac * std(ydata_clean)
        return ydata_clean .+ σ .* randn(N)
    end
end

# ──────────────────────────────────────────────────────────────────────
# 8. Run this worker's slice
# ──────────────────────────────────────────────────────────────────────

# Seed RNG deterministically: we need the same seed sequence as the sequential
# version. In the sequential version, seed(42) is called once per noise_type,
# then randn is called in order for each (noise_level, observable).
# To reproduce: advance RNG by the same number of draws that precede this worker's slice.
Random.seed!(42)
# Skip draws for noise levels before this one (each level draws 1501 for y1 + 1501 for y2)
for skip_idx in 1:(noise_level_idx - 1)
    for _ in 1:2  # two observables
        if noise_levels[skip_idx] != 0.0
            randn(1501)  # consume the draws that would have been made
        end
    end
end

tag = "$(nt_short)_n$noise_name"
worker_results = DataFrame()

for (obs, ydata_clean) in [("y1", y1_clean), ("y2", y2_clean)]
    ydata_noisy = generate_noise(ydata_clean, noise_frac, noise_type)

    actual_noise_std = std(ydata_noisy .- ydata_clean)
    println("\n  [$obs] actual noise σ = $(round(actual_noise_std, sigdigits=4))")

    # PureAAA
    print("  PureAAA: ")
    try
        r = aaa(t_norm, ydata_noisy)
        @printf("%d pts\n", length(r.x))
        global worker_results = vcat(worker_results, eval_bary("PureAAA_$tag", r.x, r.w, r.f, obs))
    catch e
        println("FAILED: ", sprint(showerror, e))
    end

    # GP_SE
    print("  GP_SE: ")
    try
        elapsed = @elapsed (gp = agp_gpr_robust(t_norm, ydata_noisy; kernel_type=:se))
        @printf("%.1fs\n", elapsed)
        global worker_results = vcat(worker_results, eval_interp("GP_SE_$tag", gp, obs))
    catch e
        println("FAILED: ", sprint(showerror, e))
    end

    # GP_RQ
    print("  GP_RQ: ")
    try
        elapsed = @elapsed (gp = agp_gpr_robust(t_norm, ydata_noisy; kernel_type=:rq))
        @printf("%.1fs\n", elapsed)
        global worker_results = vcat(worker_results, eval_interp("GP_RQ_$tag", gp, obs))
    catch e
        println("FAILED: ", sprint(showerror, e))
    end

    # FHD5
    print("  FHD5: ")
    try
        elapsed = @elapsed (interp = fhdn(5)(t_norm, ydata_noisy))
        @printf("%.2fs\n", elapsed)
        global worker_results = vcat(worker_results, eval_interp("FHD5_$tag", interp, obs))
    catch e
        println("FAILED: ", sprint(showerror, e))
    end

    # Strategy 1
    println("  Strategy1 (GP→AAA→MLE):")
    try
        z, w, f = strategy_gp_aaa_mle(t_norm, ydata_noisy)
        pr = pole_report(z, w, -0.5, 0.5)
        println("    Poles near interval: $(length(pr.near_interval))")
        global worker_results = vcat(worker_results, eval_bary("S1_GP_AAA_MLE_$tag", z, w, f, obs))
    catch e
        println("    FAILED: ", sprint(showerror, e))
    end

    # Strategy 2
    println("  Strategy2 (AAA→MLE):")
    try
        z, w, f = strategy_aaa_mle(t_norm, ydata_noisy)
        pr = pole_report(z, w, -0.5, 0.5)
        println("    Poles near interval: $(length(pr.near_interval))")
        global worker_results = vcat(worker_results, eval_bary("S2_AAA_MLE_$tag", z, w, f, obs))
    catch e
        println("    FAILED: ", sprint(showerror, e))
    end

    # Strategy 3
    println("  Strategy3 (GP→AAA_high→MLE):")
    try
        z, w, f = strategy_gp_aaa_mle_high(t_norm, ydata_noisy)
        pr = pole_report(z, w, -0.5, 0.5)
        println("    Poles near interval: $(length(pr.near_interval))")
        global worker_results = vcat(worker_results, eval_bary("S3_High_$tag", z, w, f, obs))
    catch e
        println("    FAILED: ", sprint(showerror, e))
    end

    # Strategy 4
    println("  Strategy4 (Alternating):")
    try
        z, w, f = strategy_alternating(t_norm, ydata_noisy)
        pr = pole_report(z, w, -0.5, 0.5)
        println("    Poles near interval: $(length(pr.near_interval))")
        global worker_results = vcat(worker_results, eval_bary("S4_Altern_$tag", z, w, f, obs))
    catch e
        println("    FAILED: ", sprint(showerror, e))
    end
end

# Save worker results
outfile = joinpath(OUTDIR, "06_worker_$(nt_short)_n$(noise_name).csv")
CSV.write(outfile, worker_results)
println("\nWorker done! Saved $(nrow(worker_results)) rows to $outfile")
