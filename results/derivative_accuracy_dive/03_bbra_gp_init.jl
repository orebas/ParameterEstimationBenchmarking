#!/usr/bin/env julia
#=
BBRA Extended Experiments
=========================
1. GP → AAA → BBRA ("Strategy C"): Use GP to denoise, run AAA on GP predictions
   to harvest good support points, then optimize w/f against raw noisy data.
2. MLE vs MAP: Compare pure least-squares (no regularization) vs regularized.
3. Noise estimation: Try estimating σ from residuals.
4. More support points: Test what happens when we force AAA to use more points.
=#

using ODEParameterEstimation
using ODEParameterEstimation: aaad, agp_gpr_robust, nth_deriv
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
const MAX_DERIV = 7

# ──────────────────────────────────────────────────────────────────────
# 1. Model & Data (identical to 02_bbra_prototype.jl)
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
    du1 = (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4))
    du2 = ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5
    du3 = ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5
    du4 = (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10)
    return [du1, du2, du3, du4]
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
println("  Done. 1501 points.")

# ──────────────────────────────────────────────────────────────────────
# 2. Ground truth derivatives
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

println("Computing ground truth derivatives...")
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
# 3. Shared infrastructure (from 02)
# ──────────────────────────────────────────────────────────────────────

function bary_eval(t, z, w, f)
    T = promote_type(typeof(t), eltype(z), eltype(w), eltype(f))
    num = zero(T)
    den = zero(T)
    for j in eachindex(z)
        d = t - z[j]
        d == zero(d) && return T(f[j])
        a = w[j] / d
        num += a * f[j]
        den += a
    end
    return num / den
end

function bary_deriv_td(t, z, w, f, order::Int)
    order == 0 && return bary_eval(t, z, w, f)
    return TaylorDiff.derivative(s -> bary_eval(s, z, w, f), t, Val(order))
end

function bary_poles(z, w)
    m = length(w)
    B = diagm(ones(m + 1)); B[1, 1] = 0.0
    E = [0.0 transpose(w); ones(m) diagm(z)]
    sp = schur(Complex.(E), Complex.(B))
    return sp.values[isfinite.(sp.values)]
end

"""Objective with analytical gradient. mode: :map or :mle"""
function bbra_fg!(F, G, θ, z, t_data, y_data, f_init, λ_f, μ_gauge, mode)
    m = length(z)
    w = θ[1:m]
    fv = θ[m+1:2m]
    loss = 0.0
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
            G !== nothing && (G[m + exact] -= 2.0 * res)
        else
            num, den = 0.0, 0.0
            for i in 1:m
                a = w[i] / (tj - z[i])
                num += a * fv[i]; den += a
            end
            rv = num / den; res = y_data[j] - rv
            loss += res^2
            if G !== nothing
                id = 1.0 / den
                for i in 1:m
                    ai = 1.0 / (tj - z[i])
                    G[i]     -= 2.0 * res * ai * (fv[i] - rv) * id
                    G[m + i] -= 2.0 * res * w[i] * ai * id
                end
            end
        end
    end

    # Regularization (MAP only)
    if mode == :map
        for i in 1:m
            df = fv[i] - f_init[i]
            loss += λ_f * df^2
            G !== nothing && (G[m + i] += 2.0 * λ_f * df)
        end
    end

    # Gauge penalty
    wnq = sum(abs2, w)
    loss += μ_gauge * (wnq - 1.0)^2
    if G !== nothing
        gg = 4.0 * μ_gauge * (wnq - 1.0)
        for i in 1:m; G[i] += gg * w[i]; end
    end
    return loss
end

function fit_bbra(z, w_init, f_init, t_data, y_data;
                  λ_f=1e-4, μ_gauge=10.0, maxiter=3000, mode=:map)
    θ = vcat(copy(w_init), copy(f_init))
    fg! = (F, G, θ) -> bbra_fg!(F, G, θ, z, t_data, y_data, f_init, λ_f, μ_gauge, mode)
    od = OnceDifferentiable(Optim.only_fg!(fg!), θ)
    result = optimize(od, θ, LBFGS(),
                      Optim.Options(iterations=maxiter, g_tol=1e-12, f_reltol=1e-16))
    θ_opt = Optim.minimizer(result)
    m = length(z)
    w_opt = θ_opt[1:m]; w_opt ./= norm(w_opt)
    f_opt = θ_opt[m+1:2m]
    return z, w_opt, f_opt, result
end

function evaluate_bary(label, z, w, f, eval_idxs, gt, obs_name)
    rows = []
    for (i, idx) in enumerate(eval_idxs)
        tn = t_norm[idx]
        for n in 0:MAX_DERIV
            gt_val = gt[(obs_name, i, n)]
            est = try bary_deriv_td(tn, z, w, f, n) catch; NaN end
            ae = isnan(est) ? NaN : abs(est - gt_val)
            re = (isnan(ae) || abs(gt_val) < 1e-15) ? NaN : ae / abs(gt_val)
            push!(rows, (interpolator=label, observable=obs_name, eval_point=i,
                         t_phys=t_phys[idx], deriv_order=n,
                         ground_truth=gt_val, estimated=est,
                         abs_error=ae, rel_error=re))
        end
    end
    return DataFrame(rows)
end

function evaluate_interp(label, interp, eval_idxs, gt, obs_name)
    rows = []
    for (i, idx) in enumerate(eval_idxs)
        tn = t_norm[idx]
        for n in 0:MAX_DERIV
            gt_val = gt[(obs_name, i, n)]
            est = try (n == 0 ? interp(tn) : nth_deriv(x -> interp(x), n, tn)) catch; NaN end
            ae = isnan(est) ? NaN : abs(est - gt_val)
            re = (isnan(ae) || abs(gt_val) < 1e-15) ? NaN : ae / abs(gt_val)
            push!(rows, (interpolator=label, observable=obs_name, eval_point=i,
                         t_phys=t_phys[idx], deriv_order=n,
                         ground_truth=gt_val, estimated=est,
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

function print_table(title, df)
    println("\n" * "="^70)
    println(title)
    println("="^70)
    nms = unique(df.interpolator)
    println(rpad("Method", 22), " | ", join([rpad("d$n", 12) for n in 0:MAX_DERIV], " | "))
    println("-"^22, "-+-", join(["-"^12 for _ in 0:MAX_DERIV], "-+-"))
    for nm in nms
        cells = [begin
            v = filter(!isnan, df[(df.interpolator .== nm) .& (df.deriv_order .== n), :rel_error])
            isempty(v) ? "N/A" : fmt(median(v))
        end for n in 0:MAX_DERIV]
        println(rpad(nm, 22), " | ", join([rpad(c, 12) for c in cells], " | "))
    end
end

# ──────────────────────────────────────────────────────────────────────
# 4. Strategy C: GP → AAA → BBRA
# ──────────────────────────────────────────────────────────────────────

"""
Strategy C: Fit GP to noisy data, evaluate GP on a dense grid to get
denoised predictions, run AAA on denoised predictions to harvest
support points, then optimize w/f against raw noisy data.
"""
function strategy_c(t_data, y_noisy;
                    λ_f=1e-4, maxiter=3000, mode=:map,
                    gp_kernel=:se, aaa_tol=1e-10)
    # Step 1: Fit GP to noisy data
    println("    Step 1: Fitting GP (kernel=$gp_kernel)...")
    gp = agp_gpr_robust(t_data, y_noisy; kernel_type=gp_kernel)

    # Step 2: Evaluate GP on dense grid to get denoised predictions
    y_denoised = [gp(t) for t in t_data]
    println("    Step 2: GP denoised, max|y_gp - y_noisy| = $(round(maximum(abs.(y_denoised .- y_noisy)), sigdigits=4))")

    # Step 3: Run AAA on denoised predictions
    r = aaa(t_data, y_denoised; tol=aaa_tol, mmax=200)
    z = copy(r.x)
    w_init = copy(r.w) ./ norm(r.w)
    f_init = copy(r.f)
    println("    Step 3: AAA on GP output → $(length(z)) support points")

    # Step 4: Re-initialize f from raw noisy data at support points
    # (the GP-denoised f_init serves as the prior for MAP)
    f_from_noisy = zeros(length(z))
    for (j, zj) in enumerate(z)
        idx = searchsortedlast(t_data, zj)
        if idx < 1; f_from_noisy[j] = y_noisy[1]
        elseif idx >= length(t_data); f_from_noisy[j] = y_noisy[end]
        elseif t_data[idx] == zj; f_from_noisy[j] = y_noisy[idx]
        else
            α = (zj - t_data[idx]) / (t_data[idx+1] - t_data[idx])
            f_from_noisy[j] = (1 - α) * y_noisy[idx] + α * y_noisy[idx+1]
        end
    end

    # Step 5: Optimize against raw noisy data
    # f_init for MAP prior = GP-denoised values (not the noisy interpolation)
    println("    Step 4: Optimizing (mode=$mode)...")
    z_opt, w_opt, f_opt, res = fit_bbra(z, w_init, f_init, t_data, y_noisy;
                                         λ_f=λ_f, maxiter=maxiter, mode=mode)

    println("    → $(Optim.iterations(res)) iters, loss=$(round(Optim.minimum(res), sigdigits=4)), " *
            "converged=$(Optim.converged(res))")

    # Estimate noise from residuals
    rss = sum((y_noisy[j] - bary_eval(t_data[j], z_opt, w_opt, f_opt))^2 for j in eachindex(t_data))
    σ_est = sqrt(rss / length(t_data))
    println("    σ_estimated = $(round(σ_est, sigdigits=4))")

    return z_opt, w_opt, f_opt, res, σ_est
end

"""
Strategy A (from 02): AAA directly on (optionally smoothed) noisy data.
"""
function strategy_a(t_data, y_noisy; λ_f=1e-4, maxiter=3000, mode=:map,
                    smooth=false, smooth_window=5)
    y_for_aaa = if smooth
        n = length(y_noisy)
        hw = smooth_window ÷ 2
        [mean(y_noisy[max(1,i-hw):min(n,i+hw)]) for i in 1:n]
    else
        y_noisy
    end
    r = aaa(t_data, y_for_aaa)
    z = copy(r.x); w_init = copy(r.w) ./ norm(r.w); f_init = copy(r.f)
    if smooth
        for (j, zj) in enumerate(z)
            idx = searchsortedlast(t_data, zj)
            if idx >= 1 && idx < length(t_data) && t_data[idx] == zj
                f_init[j] = y_noisy[idx]
            end
        end
    end
    println("    AAA → $(length(z)) support points")
    z_opt, w_opt, f_opt, res = fit_bbra(z, w_init, f_init, t_data, y_noisy;
                                         λ_f=λ_f, maxiter=maxiter, mode=mode)
    println("    → $(Optim.iterations(res)) iters, loss=$(round(Optim.minimum(res), sigdigits=4)), " *
            "converged=$(Optim.converged(res))")
    return z_opt, w_opt, f_opt, res
end

# ──────────────────────────────────────────────────────────────────────
# 5. Run experiments
# ──────────────────────────────────────────────────────────────────────
println("\n" * "="^70)
println("EXPERIMENT 1: GP→AAA→BBRA vs AAA→BBRA vs GP-only, across noise levels")
println("="^70)

noise_levels = [0.0, 0.0001, 0.0003, 0.001, 0.003, 0.01, 0.03, 0.05, 0.1]
all_results = DataFrame()
Random.seed!(42)

for noise_frac in noise_levels
    nl_str = noise_frac < 0.01 ? @sprintf("%.2f%%", noise_frac*100) :
             @sprintf("%.1f%%", noise_frac*100)
    println("\n" * "─"^60)
    println("Noise = $nl_str")
    println("─"^60)

    for (obs, ydata_clean) in [("y1", y1_clean), ("y2", y2_clean)]
        σ_noise = noise_frac * std(ydata_clean)
        ydata_noisy = noise_frac == 0.0 ? copy(ydata_clean) :
                      ydata_clean .+ σ_noise .* randn(length(ydata_clean))
        σ_true = noise_frac == 0.0 ? 0.0 : σ_noise

        println("\n  [$obs] σ_true = $(round(σ_true, sigdigits=4))")

        # 1. PureAAA (reference)
        println("  AAA:")
        try
            r = aaa(t_norm, ydata_noisy)
            println("    $(length(r.x)) support points")
            df = evaluate_bary("AAA_n$nl_str", r.x, r.w, r.f, eval_idxs, gt, obs)
            global all_results = vcat(all_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # 2. GP-only (reference)
        println("  GP_SE:")
        try
            gp = agp_gpr_robust(t_norm, ydata_noisy; kernel_type=:se)
            df = evaluate_interp("GP_SE_n$nl_str", gp, eval_idxs, gt, obs)
            global all_results = vcat(all_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # 3. Strategy A: AAA→BBRA (MAP)
        println("  BBRA-A (MAP):")
        try
            do_smooth = noise_frac > 0.001
            sw = noise_frac > 0.05 ? 15 : (noise_frac > 0.01 ? 9 : 5)
            z, w, f, _ = strategy_a(t_norm, ydata_noisy;
                λ_f=max(1e-6, noise_frac * 0.1), maxiter=3000,
                mode=:map, smooth=do_smooth, smooth_window=sw)
            df = evaluate_bary("BBRA-A_MAP_n$nl_str", z, w, f, eval_idxs, gt, obs)
            global all_results = vcat(all_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # 4. Strategy A: AAA→BBRA (MLE — no regularization)
        println("  BBRA-A (MLE):")
        try
            do_smooth = noise_frac > 0.001
            sw = noise_frac > 0.05 ? 15 : (noise_frac > 0.01 ? 9 : 5)
            z, w, f, _ = strategy_a(t_norm, ydata_noisy;
                λ_f=0.0, maxiter=3000,
                mode=:mle, smooth=do_smooth, smooth_window=sw)
            df = evaluate_bary("BBRA-A_MLE_n$nl_str", z, w, f, eval_idxs, gt, obs)
            global all_results = vcat(all_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # 5. Strategy C: GP→AAA→BBRA (MAP)
        println("  BBRA-C (GP→AAA→MAP):")
        try
            z, w, f, _, σ_est = strategy_c(t_norm, ydata_noisy;
                λ_f=max(1e-6, noise_frac * 0.1), maxiter=3000,
                mode=:map, gp_kernel=:se, aaa_tol=1e-10)
            df = evaluate_bary("BBRA-C_MAP_n$nl_str", z, w, f, eval_idxs, gt, obs)
            global all_results = vcat(all_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # 6. Strategy C: GP→AAA→BBRA (MLE)
        println("  BBRA-C (GP→AAA→MLE):")
        try
            z, w, f, _, σ_est = strategy_c(t_norm, ydata_noisy;
                λ_f=0.0, maxiter=3000,
                mode=:mle, gp_kernel=:se, aaa_tol=1e-10)
            df = evaluate_bary("BBRA-C_MLE_n$nl_str", z, w, f, eval_idxs, gt, obs)
            global all_results = vcat(all_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end

        # 7. Strategy C with tighter AAA tolerance (more support points)
        println("  BBRA-C (GP→AAA(tol=1e-13)→MAP):")
        try
            z, w, f, _, σ_est = strategy_c(t_norm, ydata_noisy;
                λ_f=max(1e-6, noise_frac * 0.1), maxiter=3000,
                mode=:map, gp_kernel=:se, aaa_tol=1e-13)
            df = evaluate_bary("BBRA-C13_MAP_n$nl_str", z, w, f, eval_idxs, gt, obs)
            global all_results = vcat(all_results, df)
        catch e
            println("    FAILED: ", sprint(showerror, e))
        end
    end
end

# ──────────────────────────────────────────────────────────────────────
# 6. Results
# ──────────────────────────────────────────────────────────────────────
function nl_str(nf)
    nf < 0.01 ? @sprintf("%.2f%%", nf*100) : @sprintf("%.1f%%", nf*100)
end

# Per-noise-level tables
for noise_frac in noise_levels
    nl = nl_str(noise_frac)
    mask = occursin.("_n$nl", all_results.interpolator)
    sub = all_results[mask, :]
    !isempty(sub) && print_table("Noise=$nl: Median Relative Error", sub)
end

# Key comparison tables
for dn in [3, 5]
    println("\n" * "="^70)
    println("d$dn median relative error across noise levels")
    println("="^70)
    col_hdrs = [nl_str(nf) for nf in noise_levels]
    println(rpad("Method", 22), " | ", join([rpad(h, 12) for h in col_hdrs], " | "))
    println("-"^22, "-+-", join(["-"^12 for _ in noise_levels], "-+-"))

    for pfx in ["AAA", "GP_SE", "BBRA-A_MAP", "BBRA-A_MLE",
                "BBRA-C_MAP", "BBRA-C_MLE", "BBRA-C13_MAP"]
        cells = [begin
            nl = nl_str(nf)
            mask = (all_results.interpolator .== "$(pfx)_n$nl") .& (all_results.deriv_order .== dn)
            v = filter(!isnan, all_results[mask, :rel_error])
            isempty(v) ? "N/A" : fmt(median(v))
        end for nf in noise_levels]
        println(rpad(pfx, 22), " | ", join([rpad(c, 12) for c in cells], " | "))
    end
end

# Save
CSV.write(joinpath(OUTDIR, "bbra_gp_init_results.csv"), all_results)

# Summary CSV
summary = DataFrame(method=String[], deriv_order=Int[], median_rel=Float64[], max_rel=Float64[])
for nm in unique(all_results.interpolator), n in 0:MAX_DERIV
    v = filter(!isnan, all_results[(all_results.interpolator .== nm) .& (all_results.deriv_order .== n), :rel_error])
    push!(summary, (nm, n, isempty(v) ? NaN : median(v), isempty(v) ? NaN : maximum(v)))
end
CSV.write(joinpath(OUTDIR, "bbra_gp_init_summary.csv"), summary)

println("\n" * "="^70)
println("Done! Saved to: $OUTDIR/bbra_gp_init_*.csv")
println("="^70)
