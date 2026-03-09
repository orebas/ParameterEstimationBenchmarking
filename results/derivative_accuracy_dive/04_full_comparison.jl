#!/usr/bin/env julia
#=
Full Derivative Accuracy Comparison — Benchmark Noise Levels
============================================================
Compares all methods at the benchmark noise levels {0, 1e-8, 1e-6, 1e-4, 1e-2}
with MULTIPLICATIVE noise (matching benchmark convention).

Shows all derivatives d0–d7 for every method × noise level.

Methods:
  - PureAAA: raw AAA interpolation
  - GP_SE: Gaussian Process (squared exponential kernel)
  - GP_RQ: Gaussian Process (rational quadratic kernel)
  - FHD5: Floater-Hormann (d=5)
  - BBRA-A: AAA-initialized, MAP optimization against raw data
  - BBRA-C: GP→AAA→BBRA (GP denoise, harvest support points, optimize)
=#

using ODEParameterEstimation
using ODEParameterEstimation: aaad, agp_gpr_robust, nth_deriv, fhdn
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
# 3. BBRA infrastructure
# ──────────────────────────────────────────────────────────────────────
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

function bary_deriv_td(t, z, w, f, order::Int)
    order == 0 && return bary_eval(t, z, w, f)
    return TaylorDiff.derivative(s -> bary_eval(s, z, w, f), t, Val(order))
end

function bbra_fg!(F, G, θ, z, t_data, y_data, f_init, λ_f, μ_gauge)
    m = length(z)
    w = θ[1:m]; fv = θ[m+1:2m]
    loss = 0.0
    G !== nothing && fill!(G, 0.0)
    for j in eachindex(t_data)
        tj = t_data[j]
        exact = 0
        for i in 1:m; tj == z[i] && (exact = i; break); end
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
    if λ_f > 0
        for i in 1:m
            df = fv[i] - f_init[i]
            loss += λ_f * df^2
            G !== nothing && (G[m + i] += 2.0 * λ_f * df)
        end
    end
    wnq = sum(abs2, w)
    loss += μ_gauge * (wnq - 1.0)^2
    if G !== nothing
        gg = 4.0 * μ_gauge * (wnq - 1.0)
        for i in 1:m; G[i] += gg * w[i]; end
    end
    return loss
end

function fit_bbra(z, w_init, f_init, t_data, y_data; λ_f=1e-4, maxiter=3000)
    θ = vcat(copy(w_init), copy(f_init))
    fg! = (F, G, θ) -> bbra_fg!(F, G, θ, z, t_data, y_data, f_init, λ_f, 10.0)
    od = OnceDifferentiable(Optim.only_fg!(fg!), θ)
    result = optimize(od, θ, LBFGS(),
                      Optim.Options(iterations=maxiter, g_tol=1e-12, f_reltol=1e-16))
    θ_opt = Optim.minimizer(result)
    m = length(z)
    w_opt = θ_opt[1:m]; w_opt ./= norm(w_opt)
    f_opt = θ_opt[m+1:2m]
    return z, w_opt, f_opt, result
end

# Strategy A: AAA → BBRA
function run_bbra_a(t_data, y_noisy; λ_f=1e-4, smooth=false, smooth_window=5)
    y_for_aaa = if smooth
        n = length(y_noisy); hw = smooth_window ÷ 2
        [mean(y_noisy[max(1,i-hw):min(n,i+hw)]) for i in 1:n]
    else
        y_noisy
    end
    r = aaa(t_data, y_for_aaa)
    z = copy(r.x); w0 = copy(r.w) ./ norm(r.w); f0 = copy(r.f)
    if smooth
        for (j, zj) in enumerate(z)
            idx = searchsortedlast(t_data, zj)
            if idx >= 1 && idx <= length(t_data) && t_data[idx] == zj
                f0[j] = y_noisy[idx]
            end
        end
    end
    z, w, f, res = fit_bbra(z, w0, f0, t_data, y_noisy; λ_f=λ_f)
    @printf("    %d pts, %d iters, loss=%.3e, conv=%s\n",
            length(z), Optim.iterations(res), Optim.minimum(res), Optim.converged(res))
    return z, w, f
end

# Strategy C: GP → AAA → BBRA
function run_bbra_c(t_data, y_noisy; λ_f=1e-4, aaa_tol=1e-10)
    gp = agp_gpr_robust(t_data, y_noisy; kernel_type=:se)
    y_gp = [gp(t) for t in t_data]
    r = aaa(t_data, y_gp; tol=aaa_tol, mmax=200)
    z = copy(r.x); w0 = copy(r.w) ./ norm(r.w); f0 = copy(r.f)
    z, w, f, res = fit_bbra(z, w0, f0, t_data, y_noisy; λ_f=λ_f)
    @printf("    GP→AAA: %d pts, %d iters, loss=%.3e, conv=%s\n",
            length(z), Optim.iterations(res), Optim.minimum(res), Optim.converged(res))
    return z, w, f
end

# ──────────────────────────────────────────────────────────────────────
# 4. Evaluation
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
    println(rpad("Method", 22), " | ", join([rpad("d$n", col_width) for n in 0:MAX_DERIV], " | "))
    println("-"^22, "-+-", join(["-"^col_width for _ in 0:MAX_DERIV], "-+-"))
    for nm in nms
        cells = [begin
            v = filter(!isnan, df[(df.interpolator .== nm) .& (df.deriv_order .== n), :rel_error])
            isempty(v) ? "N/A" : fmt(median(v))
        end for n in 0:MAX_DERIV]
        println(rpad(nm, 22), " | ", join([rpad(c, col_width) for c in cells], " | "))
    end
end

# ──────────────────────────────────────────────────────────────────────
# 5. Run all methods at benchmark noise levels
# ──────────────────────────────────────────────────────────────────────

# Benchmark noise levels (MULTIPLICATIVE: noise = noise_frac * y_value)
noise_levels = [0.0, 1e-8, 1e-6, 1e-4, 1e-2]
noise_names  = ["0", "1e-8", "1e-6", "1e-4", "1e-2"]

all_results = DataFrame()
Random.seed!(42)

for (noise_frac, noise_name) in zip(noise_levels, noise_names)
    println("\n" * "="^70)
    @printf("NOISE LEVEL: %s (multiplicative)\n", noise_name)
    println("="^70)

    for (obs, ydata_clean) in [("y1", y1_clean), ("y2", y2_clean)]
        # Multiplicative noise: each point gets noise proportional to its value
        if noise_frac == 0.0
            ydata_noisy = copy(ydata_clean)
        else
            ydata_noisy = ydata_clean .* (1.0 .+ noise_frac .* randn(length(ydata_clean)))
        end

        actual_noise_std = std(ydata_noisy .- ydata_clean)
        println("\n  [$obs] actual noise σ = $(round(actual_noise_std, sigdigits=4))")

        tag = "n$noise_name"

        # 1. PureAAA
        print("  AAA: ")
        try
            r = aaa(t_norm, ydata_noisy)
            @printf("%d pts\n", length(r.x))
            global all_results = vcat(all_results, eval_bary("AAA_$tag", r.x, r.w, r.f, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # 2. GP (SE kernel)
        print("  GP_SE: ")
        try
            elapsed = @elapsed (gp = agp_gpr_robust(t_norm, ydata_noisy; kernel_type=:se))
            @printf("%.1fs\n", elapsed)
            global all_results = vcat(all_results, eval_interp("GP_SE_$tag", gp, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # 3. GP (RQ kernel)
        print("  GP_RQ: ")
        try
            elapsed = @elapsed (gp = agp_gpr_robust(t_norm, ydata_noisy; kernel_type=:rq))
            @printf("%.1fs\n", elapsed)
            global all_results = vcat(all_results, eval_interp("GP_RQ_$tag", gp, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # 4. FHD5
        print("  FHD5: ")
        try
            elapsed = @elapsed (interp = fhdn(5)(t_norm, ydata_noisy))
            @printf("%.2fs\n", elapsed)
            global all_results = vcat(all_results, eval_interp("FHD5_$tag", interp, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # 5. BBRA-A (AAA → optimize)
        print("  BBRA-A: ")
        try
            do_smooth = noise_frac >= 1e-4
            sw = noise_frac >= 1e-2 ? 15 : 5
            λ = noise_frac == 0.0 ? 1e-6 : max(1e-6, noise_frac * 0.01)
            z, w, f = run_bbra_a(t_norm, ydata_noisy; λ_f=λ, smooth=do_smooth, smooth_window=sw)
            global all_results = vcat(all_results, eval_bary("BBRA-A_$tag", z, w, f, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end

        # 6. BBRA-C (GP → AAA → optimize)
        print("  BBRA-C: ")
        try
            λ = noise_frac == 0.0 ? 1e-6 : max(1e-6, noise_frac * 0.01)
            z, w, f = run_bbra_c(t_norm, ydata_noisy; λ_f=λ, aaa_tol=1e-10)
            global all_results = vcat(all_results, eval_bary("BBRA-C_$tag", z, w, f, obs))
        catch e
            println("FAILED: ", sprint(showerror, e))
        end
    end
end

# ──────────────────────────────────────────────────────────────────────
# 6. Full Results Tables
# ──────────────────────────────────────────────────────────────────────
println("\n\n")
println("#"^70)
println("# FULL RESULTS")
println("#"^70)

# Per noise level: show all methods × all derivatives
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

method_prefixes = ["AAA", "GP_SE", "GP_RQ", "FHD5", "BBRA-A", "BBRA-C"]

for dn in 0:MAX_DERIV
    println("\n" * "="^70)
    @printf("d%d median relative error across noise levels\n", dn)
    println("="^70)
    println(rpad("Method", 14), " | ", join([rpad(nn, 13) for nn in noise_names], " | "))
    println("-"^14, "-+-", join(["-"^13 for _ in noise_names], "-+-"))

    for pfx in method_prefixes
        cells = [begin
            full_name = "$(pfx)_n$nn"
            mask = (all_results.interpolator .== full_name) .& (all_results.deriv_order .== dn)
            v = filter(!isnan, all_results[mask, :rel_error])
            isempty(v) ? "N/A" : fmt(median(v))
        end for nn in noise_names]
        println(rpad(pfx, 14), " | ", join([rpad(c, 13) for c in cells], " | "))
    end
end

# Compact summary: all derivatives × all methods for key noise levels
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
        @printf("  %-10s  %s\n", pfx, join([rpad(c, 13) for c in cells], " "))
    end
end

# Save
CSV.write(joinpath(OUTDIR, "full_comparison_results.csv"), all_results)

summary = DataFrame(method=String[], noise=String[], deriv_order=Int[],
                     median_rel=Float64[], max_rel=Float64[], mean_rel=Float64[])
for nm in unique(all_results.interpolator), n in 0:MAX_DERIV
    v = filter(!isnan, all_results[(all_results.interpolator .== nm) .& (all_results.deriv_order .== n), :rel_error])
    # Extract noise name from interpolator label
    nn = replace(nm, r".*_n" => "")
    pfx = replace(nm, r"_n.*" => "")
    push!(summary, (pfx, nn, n,
        isempty(v) ? NaN : median(v),
        isempty(v) ? NaN : maximum(v),
        isempty(v) ? NaN : mean(v)))
end
CSV.write(joinpath(OUTDIR, "full_comparison_summary.csv"), summary)

println("\n" * "="^70)
println("Done! Saved to:")
println("  $OUTDIR/full_comparison_results.csv")
println("  $OUTDIR/full_comparison_summary.csv")
println("="^70)
