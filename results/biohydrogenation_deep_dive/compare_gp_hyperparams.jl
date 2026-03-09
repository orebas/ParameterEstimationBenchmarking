#!/usr/bin/env julia
# Compare optimized hyperparameters between OldGPR and AGPRobust settings
# on biohydrogenation y2 data, using the SAME manual Cholesky-based likelihood.
#
# The two implementations differ in:
#   1. Noise initialization (exp(-2)≈0.135 std vs 1e-6 variance)
#   2. Optimization (unconstrained vs Fminbox-bounded)
#   3. Parameterization (log vs softplus)
#   4. Jitter (none vs 1e-8)
#
# We replicate both settings in a controlled way to isolate the cause.

using DifferentialEquations
using Statistics, LinearAlgebra, Printf
using Optim, LineSearches
using TaylorDiff

# ── Biohydrogenation ODE (plain, no MTK) ──
function biohydrogenation!(du, u, p, t)
    x4, x5, x6, x7 = u
    k5, k6, k7, k8, k9, k10 = p
    du[1] = -k5 * x4 / (k6 + x4)
    du[2] = k5 * x4 / (k6 + x4) - k7 * x5 / (k8 + x5 + x6)
    du[3] = k7 * x5 / (k8 + x5 + x6) - k9 * (k10 - x6)
    du[4] = k9 * (k10 - x6)
end

true_params = [0.6880, 0.8700, 0.0778, 0.5840, 0.5740, 0.5580]
true_ic = [0.2, 0.3, 0.5, 0.0]
datasize = 1001

prob = ODEProblem(biohydrogenation!, true_ic, (0.0, 1.0), true_params)
sol = solve(prob, Tsit5(), saveat=range(0.0, 1.0, length=datasize))
xs = Float64.(sol.t)
y2_data = Float64.(sol[2, :])

println("Data: $(length(xs)) points, t ∈ [$(xs[1]), $(xs[end])]")
println("y2 range: [$(minimum(y2_data)), $(maximum(y2_data))]")
println("y2 std: $(std(y2_data))")

# ── Shared: normalize y, precompute D² ──
y_mean = mean(y2_data)
y_std = max(std(y2_data), 1e-8)
ys_norm = (y2_data .- y_mean) ./ y_std
n = length(xs)

D2 = [abs2(xs[i] - xs[j]) for i in 1:n, j in 1:n]
I_n = Matrix{Float64}(I, n, n)

# ── SE kernel neg log marginal likelihood ──
# θ = [ℓ, σ², σₙ²] in REAL space (caller transforms)
function neg_lml(l, σ², σₙ², jitter)
    inv_2l² = 1.0 / (2.0 * l * l)
    K = σ² .* exp.(-D2 .* inv_2l²)
    for i in 1:n; K[i,i] += σₙ² + jitter; end
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

# ═══════════════════════════════════════════════════════════
# Strategy A: "OldGPR-like" — log-space, unconstrained LBFGS
# Initial: log(ℓ) = log(std(xs)/8), log(σ) = 0, log(σₙ) = -2
# ═══════════════════════════════════════════════════════════
println("\n", "="^60)
println("Strategy A: OldGPR-like (log-space, unconstrained)")
println("="^60)

# GaussianProcesses.jl SEIso: params are [log(ℓ), log(σ)], noise is log(σₙ)
# So σ² = exp(2*log(σ)) and σₙ² = exp(2*log(σₙ))
init_log_l_A = log(std(xs) / 8)
init_log_σ_A = 0.0
init_log_σₙ_A = -2.0
jitter_A = 0.0  # GaussianProcesses.jl has internal regularization but no explicit jitter

println("Initial: ℓ=$(exp(init_log_l_A)), σ²=$(exp(2*init_log_σ_A)), σₙ²=$(exp(2*init_log_σₙ_A))")

function obj_A(θ)
    l = exp(θ[1]); σ² = exp(2*θ[2]); σₙ² = exp(2*θ[3])
    neg_lml(l, σ², σₙ², jitter_A)
end

θ0_A = [init_log_l_A, init_log_σ_A, init_log_σₙ_A]
res_A = Optim.optimize(obj_A, θ0_A, LBFGS(linesearch=LineSearches.BackTracking()),
                       Optim.Options(iterations=1000))
θ_A = Optim.minimizer(res_A)
l_A = exp(θ_A[1]); σ²_A = exp(2*θ_A[2]); σₙ²_A = exp(2*θ_A[3])

println("Converged: $(Optim.converged(res_A)), iterations: $(Optim.iterations(res_A))")
@printf("Optimized: ℓ=%.8f, σ²=%.8f, σₙ²=%.2e\n", l_A, σ²_A, σₙ²_A)
@printf("NLL: %.4f\n", Optim.minimum(res_A))

# ═══════════════════════════════════════════════════════════
# Strategy B: "AGPRobust-like" — softplus, Fminbox-bounded
# Initial: ℓ=std(xs)/8, σ²=1, σₙ²=1e-6 (smooth), jitter=1e-8
# ═══════════════════════════════════════════════════════════
println("\n", "="^60)
println("Strategy B: AGPRobust-like (softplus, Fminbox-bounded)")
println("="^60)

_softplus(x) = x > 34.0 ? x : log(1.0 + exp(x))
_inv_softplus(y) = y > 34.0 ? y : log(exp(y) - 1.0)

init_l_B = std(xs) / 8.0
init_σ²_B = 1.0
# Smoothness detection
d2 = [ys_norm[i+2] - 2.0*ys_norm[i+1] + ys_norm[i] for i in 1:(n-2)]
roughness = mean(abs.(d2))
init_σₙ²_B = roughness < 0.1 ? 1e-6 : roughness < 1.0 ? 1e-4 : 0.01
jitter_B = 1e-8

println("Roughness: $roughness → init_σₙ²=$init_σₙ²_B")
println("Initial: ℓ=$init_l_B, σ²=$init_σ²_B, σₙ²=$init_σₙ²_B, jitter=$jitter_B")

θ0_B = [_inv_softplus(init_l_B), _inv_softplus(init_σ²_B), _inv_softplus(init_σₙ²_B)]
θ_lower_B = [_inv_softplus(1e-3), _inv_softplus(1e-8), _inv_softplus(1e-10)]
θ_upper_B = [_inv_softplus(150.0), _inv_softplus(150.0), _inv_softplus(10.0)]

function obj_B(θ)
    l = _softplus(θ[1]); σ² = _softplus(θ[2]); σₙ² = _softplus(θ[3])
    neg_lml(l, σ², σₙ², jitter_B)
end

res_B = Optim.optimize(obj_B, θ_lower_B, θ_upper_B, θ0_B,
                       Fminbox(LBFGS(linesearch=LineSearches.BackTracking())),
                       Optim.Options(iterations=1000))
θ_B = Optim.minimizer(res_B)
l_B = _softplus(θ_B[1]); σ²_B = _softplus(θ_B[2]); σₙ²_B = _softplus(θ_B[3])

println("Converged: $(Optim.converged(res_B)), iterations: $(Optim.iterations(res_B))")
@printf("Optimized: ℓ=%.8f, σ²=%.8f, σₙ²=%.2e\n", l_B, σ²_B, σₙ²_B)
@printf("NLL: %.4f\n", Optim.minimum(res_B))

# ═══════════════════════════════════════════════════════════
# Strategy C: AGPRobust settings but UNCONSTRAINED (isolate Fminbox effect)
# ═══════════════════════════════════════════════════════════
println("\n", "="^60)
println("Strategy C: AGPRobust init + jitter, but UNCONSTRAINED")
println("="^60)

# Use softplus parameterization but no bounds
function obj_C(θ)
    l = _softplus(θ[1]); σ² = _softplus(θ[2]); σₙ² = _softplus(θ[3])
    neg_lml(l, σ², σₙ², jitter_B)
end

res_C = Optim.optimize(obj_C, θ0_B, LBFGS(linesearch=LineSearches.BackTracking()),
                       Optim.Options(iterations=1000))
θ_C = Optim.minimizer(res_C)
l_C = _softplus(θ_C[1]); σ²_C = _softplus(θ_C[2]); σₙ²_C = _softplus(θ_C[3])

println("Converged: $(Optim.converged(res_C)), iterations: $(Optim.iterations(res_C))")
@printf("Optimized: ℓ=%.8f, σ²=%.8f, σₙ²=%.2e\n", l_C, σ²_C, σₙ²_C)
@printf("NLL: %.4f\n", Optim.minimum(res_C))

# ═══════════════════════════════════════════════════════════
# Strategy D: OldGPR settings but WITH jitter (isolate jitter effect)
# ═══════════════════════════════════════════════════════════
println("\n", "="^60)
println("Strategy D: OldGPR init, unconstrained, WITH jitter=1e-8")
println("="^60)

function obj_D(θ)
    l = exp(θ[1]); σ² = exp(2*θ[2]); σₙ² = exp(2*θ[3])
    neg_lml(l, σ², σₙ², jitter_B)
end

res_D = Optim.optimize(obj_D, θ0_A, LBFGS(linesearch=LineSearches.BackTracking()),
                       Optim.Options(iterations=1000))
θ_D = Optim.minimizer(res_D)
l_D = exp(θ_D[1]); σ²_D = exp(2*θ_D[2]); σₙ²_D = exp(2*θ_D[3])

println("Converged: $(Optim.converged(res_D)), iterations: $(Optim.iterations(res_D))")
@printf("Optimized: ℓ=%.8f, σ²=%.8f, σₙ²=%.2e\n", l_D, σ²_D, σₙ²_D)
@printf("NLL: %.4f\n", Optim.minimum(res_D))

# ═══════════════════════════════════════════════════════════
# COMPARISON TABLE
# ═══════════════════════════════════════════════════════════
println("\n", "="^60)
println("COMPARISON TABLE")
println("="^60)

strategies = [
    ("A: OldGPR-like",       l_A, σ²_A, σₙ²_A, 0.0,      Optim.minimum(res_A)),
    ("B: AGPRobust-like",    l_B, σ²_B, σₙ²_B, jitter_B,  Optim.minimum(res_B)),
    ("C: AGP-init+uncon",    l_C, σ²_C, σₙ²_C, jitter_B,  Optim.minimum(res_C)),
    ("D: Old-init+jitter",   l_D, σ²_D, σₙ²_D, jitter_B,  Optim.minimum(res_D)),
]

println()
@printf("  %-22s │ %12s │ %12s │ %12s │ %12s │ %10s\n",
        "Strategy", "ℓ", "σ²", "σₙ²", "eff.noise", "NLL")
println("  ", "-"^22, "─┼─", "-"^12, "─┼─", "-"^12, "─┼─", "-"^12, "─┼─", "-"^12, "─┼─", "-"^10)
for (name, l, sv, nv, jit, nll) in strategies
    eff = nv + jit
    @printf("  %-22s │ %12.6f │ %12.6f │ %12.2e │ %12.2e │ %10.4f\n",
            name, l, sv, nv, eff, nll)
end

# ═══════════════════════════════════════════════════════════
# DERIVATIVE ACCURACY TEST
# ═══════════════════════════════════════════════════════════
println("\n", "="^60)
println("DERIVATIVE ACCURACY AT t=0.5 (y2 = x5)")
println("="^60)

# Ground truth derivatives via Taylor recursion
function compute_true_y2_derivatives(t_eval, max_order)
    prob_local = ODEProblem(biohydrogenation!, true_ic, (0.0, t_eval + 0.01), true_params)
    sol_local = solve(prob_local, Tsit5(), saveat=[t_eval])
    x4_0, x5_0, x6_0 = sol_local[1,1], sol_local[2,1], sol_local[3,1]
    kv = true_params
    k5,k6,k7,k8,k9,k10 = kv

    N = max_order + 2
    x4c = zeros(N); x5c = zeros(N); x6c = zeros(N)
    x4c[1] = x4_0; x5c[1] = x5_0; x6c[1] = x6_0

    q1 = zeros(N); q2 = zeros(N)
    num1 = zeros(N); den1 = zeros(N)
    num2 = zeros(N); den2 = zeros(N)

    function tp(a, b, k)
        s = 0.0; for j in 0:k; s += a[j+1]*b[k-j+1]; end; s
    end
    function tq!(c, a, b, k)
        s = a[k+1]; for j in 1:k; s -= b[j+1]*c[k-j+1]; end; c[k+1] = s/b[1]
    end

    for k in 0:(N-2)
        num1[k+1] = -k5 * x4c[k+1]
        den1[k+1] = (k==0 ? 4*k6 : 0.0) + 8*x4c[k+1]
        num2[k+1] = -k7 * x5c[k+1]
        den2[k+1] = (k==0 ? 2*k8 : 0.0) + 2*x5c[k+1] + 2*x6c[k+1]

        tq!(q1, num1, den1, k)
        tq!(q2, num2, den2, k)

        dx4_k = -2.0 * q1[k+1]
        dx5_k = 2.0 * (q2[k+1] - 8.0 * q1[k+1])
        dx6_k = -2.0*q2[k+1] - k9*((k==0 ? k10 : 0.0) - x6c[k+1])

        x4c[k+2] = dx4_k / (k+1)
        x5c[k+2] = dx5_k / (k+1)
        x6c[k+2] = dx6_k / (k+1)
    end

    return [x5c[k+1] * factorial(k) for k in 0:max_order]
end

# Build GP prediction functions for each strategy
function make_gp_pred(l, σ², σₙ², jitter)
    K = σ² .* exp.(-D2 ./ (2.0 * l^2))
    for i in 1:n; K[i,i] += σₙ² + jitter; end
    alpha = cholesky(Symmetric(K)) \ ys_norm
    function pred(x)
        k_star = [σ² * exp(-(x - xi)^2 / (2.0 * l^2)) for xi in xs]
        return y_std * dot(k_star, alpha) + y_mean
    end
    return pred
end

pred_A = make_gp_pred(l_A, σ²_A, σₙ²_A, 0.0)
pred_B = make_gp_pred(l_B, σ²_B, σₙ²_B, jitter_B)
pred_C = make_gp_pred(l_C, σ²_C, σₙ²_C, jitter_B)
pred_D = make_gp_pred(l_D, σ²_D, σₙ²_D, jitter_B)

t_eval = 0.5
true_derivs = compute_true_y2_derivatives(t_eval, 5)

println()
@printf("  d# │ %14s │ %12s │ %12s │ %12s │ %12s\n",
        "True", "A:Old%", "B:AGP%", "C:AGP-unc%", "D:Old+jit%")
println("  ───┼─", "-"^14, "─┼─", "-"^12, "─┼─", "-"^12, "─┼─", "-"^12, "─┼─", "-"^12)

for order in 0:5
    tv = true_derivs[order+1]
    vals = Float64[]
    for pred in [pred_A, pred_B, pred_C, pred_D]
        v = order == 0 ? pred(t_eval) : TaylorDiff.derivative(pred, t_eval, Val(order))
        push!(vals, v)
    end
    errs = [abs(tv) > 1e-15 ? abs(v - tv)/abs(tv)*100 : abs(v-tv) for v in vals]
    @printf("  d%d  │ %14.8f │ %10.4f%%  │ %10.4f%%  │ %10.4f%%  │ %10.4f%%\n",
            order, tv, errs...)
end

# ═══════════════════════════════════════════════════════════
# Also test: what if AGPRobust posterior hits jitter escalation?
# ═══════════════════════════════════════════════════════════
println("\n", "="^60)
println("JITTER ESCALATION TEST (AGPRobust posterior construction)")
println("="^60)

# Check if the optimized AGPRobust kernel matrix needs jitter escalation
K_B = σ²_B .* exp.(-D2 ./ (2.0 * l_B^2))
for jitter in [1e-8, 1e-6, 1e-4, 1e-2]
    K_test = K_B + (σₙ²_B + jitter) * I_n
    try
        cholesky(Symmetric(K_test))
        @printf("  σₙ²=%.2e + jitter=%.0e: Cholesky OK, eff.noise=%.2e\n", σₙ²_B, jitter, σₙ²_B+jitter)

        # Test derivative accuracy with this effective noise
        pred_esc = make_gp_pred(l_B, σ²_B, σₙ²_B, jitter)
        d5_val = TaylorDiff.derivative(pred_esc, t_eval, Val(5))
        d5_err = abs(true_derivs[6]) > 1e-15 ? abs(d5_val - true_derivs[6])/abs(true_derivs[6])*100 : 0
        @printf("    → d5 error: %.4f%%\n", d5_err)
        break
    catch
        @printf("  σₙ²=%.2e + jitter=%.0e: Cholesky FAILED\n", σₙ²_B, jitter)
    end
end

# Same test for OldGPR-like
K_A = σ²_A .* exp.(-D2 ./ (2.0 * l_A^2))
for jitter in [0.0, 1e-8, 1e-6, 1e-4, 1e-2]
    K_test = K_A + (σₙ²_A + jitter) * I_n
    try
        cholesky(Symmetric(K_test))
        @printf("  OldGPR σₙ²=%.2e + jitter=%.0e: Cholesky OK\n", σₙ²_A, jitter)
        break
    catch
        @printf("  OldGPR σₙ²=%.2e + jitter=%.0e: Cholesky FAILED\n", σₙ²_A, jitter)
    end
end

println("\n", "="^60)
println("CONDITION NUMBERS")
println("="^60)
for (name, l, sv, nv, jit) in strategies
    K = sv .* exp.(-D2 ./ (2.0 * l^2))
    cK = cond(K)
    K_n = K + (nv + jit) * I_n
    cKn = cond(K_n)
    @printf("  %-22s: cond(K)=%.2e, cond(K+noise)=%.2e\n", name, cK, cKn)
end

println("\nDone.")
