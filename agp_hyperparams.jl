## agp_hyperparams.jl — extract optimized hyperparameters from all 3 interpolators

using Pkg
Pkg.activate(raw"/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using Statistics
using Printf
using CSV
using LinearAlgebra
using GaussianProcesses
using Optim, LineSearches

const FILETREE = "/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_agprobust_comparison/filetree"

_softplus(x::Real) = x > 34.0 ? x : log(1.0 + exp(x))
_inv_softplus(y::Real) = y > 34.0 ? y : log(exp(y) - 1.0)

for noise_tag in ["0", "1em8"]
    data_path = joinpath(FILETREE, "odepe_default", "lotka_volterra_0_$(noise_tag)", "data.csv")
    csv_data = CSV.read(data_path, Tuple, header=false)
    xs = collect(Float64, csv_data[1])
    ys = collect(Float64, csv_data[2])

    println("=" ^ 80)
    @printf("NOISE = %s   n=%d   t=[%.1f, %.1f]   y_mean=%.4f  y_std=%.4f\n",
        noise_tag, length(xs), xs[1], xs[end], mean(ys), std(ys))
    println("=" ^ 80)

    # ── AAADGPR (old GaussianProcesses.jl) ───────────────────────────
    println("\n  --- AAADGPR (aaad_gpr_pivot) ---")
    y_mean_g = mean(ys)
    y_std_g = std(ys)
    ys_norm_g = (ys .- y_mean_g) ./ y_std_g

    kernel_g = GaussianProcesses.SEIso(log(std(xs) / 8), 0.0)
    jitter = 1e-8
    ys_jitter = ys_norm_g .+ jitter * randn(length(ys))
    gp = GaussianProcesses.GP(xs, ys_jitter, GaussianProcesses.MeanZero(), kernel_g, -2.0)
    try
        GaussianProcesses.optimize!(gp; method=LBFGS(linesearch=LineSearches.BackTracking()))
    catch e
        @warn "GP opt failed" exception=e
    end

    gp_noise = exp(gp.logNoise.value)
    gp_ℓ2 = gp.kernel.ℓ2   # squared lengthscale (already exp(2*ll))
    gp_σ2 = gp.kernel.σ2   # signal variance (already exp(2*lσ))
    @printf("    log(noise) = %.4f  =>  noise = %.6e\n", gp.logNoise.value, gp_noise)
    @printf("    lengthscale = %.6f  (ℓ² = %.6f)\n", sqrt(gp_ℓ2), gp_ℓ2)
    @printf("    signal_var  = %.6f\n", gp_σ2)
    @printf("    Decision: %s (threshold: noise < 1e-5 => AAA)\n",
        gp_noise < 1e-5 ? "FALLBACK TO AAA" : "USE GPR")

    # ── AGPRobust ────────────────────────────────────────────────────
    println("\n  --- AGPRobust (agp_gpr_robust) ---")
    y_mean_a = mean(ys)
    y_std_a = max(std(ys), 1e-8)
    ys_norm_a = (collect(Float64, ys) .- y_mean_a) ./ y_std_a
    n = length(xs)

    # Smoothness detection
    d2 = [ys_norm_a[i+2] - 2.0 * ys_norm_a[i+1] + ys_norm_a[i] for i in 1:(n-2)]
    roughness = mean(abs.(d2))
    if roughness < 0.1
        init_noise = 1e-6
    elseif roughness < 1.0
        init_noise = 1e-4
    else
        init_noise = 0.01
    end
    @printf("    roughness = %.6e  =>  init_noise = %.6e\n", roughness, init_noise)

    init_lengthscale = std(xs) / 8.0
    init_signal_var = 1.0
    @printf("    init_lengthscale = %.4f  init_signal_var = %.4f\n", init_lengthscale, init_signal_var)

    # Run optimization (reproducing agp_gpr_robust logic)
    kernel_jitter = 1e-8
    xs_raw = collect(Float64, xs)

    D2mat = Matrix{Float64}(undef, n, n)
    for j in 1:n, i in 1:n
        D2mat[i, j] = abs2(xs_raw[i] - xs_raw[j])
    end
    I_n = Matrix{Float64}(I, n, n)
    K_work = Matrix{Float64}(undef, n, n)

    function neg_logpdf(θ)
        l = _softplus(θ[1])
        σ² = _softplus(θ[2])
        σₙ² = _softplus(θ[3])
        inv_2l² = 1.0 / (2.0 * l * l)
        @. K_work = σ² * exp(-D2mat * inv_2l²)
        @inbounds for i in 1:n
            K_work[i, i] += σₙ² + kernel_jitter
        end
        try
            C = cholesky(Symmetric(K_work))
            alpha_local = C \ ys_norm_a
            data_fit = dot(ys_norm_a, alpha_local)
            log_det = 2.0 * sum(log.(diag(C.U)))
            return 0.5 * (data_fit + log_det + n * log(2π))
        catch
            return Inf
        end
    end

    θ0 = [_inv_softplus(init_lengthscale), _inv_softplus(init_signal_var), _inv_softplus(init_noise)]
    θ_lower = [_inv_softplus(1e-3), _inv_softplus(1e-8), _inv_softplus(1e-10)]
    θ_upper = [_inv_softplus(150.0), _inv_softplus(150.0), _inv_softplus(10.0)]

    result = Optim.optimize(
        neg_logpdf, θ_lower, θ_upper, θ0,
        Fminbox(LBFGS(linesearch=LineSearches.BackTracking())),
        Optim.Options(iterations=1000);
    )

    θ_opt = Optim.minimizer(result)
    l_opt = _softplus(θ_opt[1])
    σ²_opt = _softplus(θ_opt[2])
    σₙ²_opt = _softplus(θ_opt[3])

    @printf("    Optimization converged: %s\n", Optim.converged(result))
    @printf("    Iterations: %d\n", Optim.iterations(result))
    @printf("    Final neg_logpdf: %.4f  (initial: %.4f)\n", Optim.minimum(result), neg_logpdf(θ0))
    @printf("    lengthscale = %.6f\n", l_opt)
    @printf("    signal_var  = %.6f\n", σ²_opt)
    @printf("    noise_var   = %.6e\n", σₙ²_opt)
    @printf("    SNR (signal/noise) = %.1f\n", σ²_opt / σₙ²_opt)

    # Compare: what would the condition number be?
    inv_2l² = 1.0 / (2.0 * l_opt * l_opt)
    @. K_work = σ²_opt * exp(-D2mat * inv_2l²)
    @inbounds for i in 1:n
        K_work[i, i] += σₙ²_opt + kernel_jitter
    end
    C = cholesky(Symmetric(K_work))
    cond_est = cond(K_work)
    @printf("    cond(K + σₙ²I) ≈ %.2e\n", cond_est)

    println()
end
