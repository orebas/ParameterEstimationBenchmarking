## trace_blowup.jl — trace exactly where the Matern derivative blow-up happens
## Uses TaylorDiff to show what happens at d=0 vs d=0.01

using Pkg; Pkg.activate(raw"/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using Printf

const EPS = 1e-30

# ── Step 1: Derivatives of smooth_abs itself ──────────────────────────
println("=" ^ 70)
println("STEP 1: Derivatives of smooth_abs(d) = sqrt(d² + ε), ε = $EPS")
println("=" ^ 70)

smooth_abs(d) = sqrt(d * d + EPS)

for d_val in [0.0, 0.001, 0.01, 0.02]
    @printf("\n  d = %.4f:  smooth_abs(d) = %.4e\n", d_val, smooth_abs(d_val))
    for order in 0:8
        val = if order == 0
            smooth_abs(d_val)
        else
            ODEParameterEstimation.nth_deriv(smooth_abs, order, d_val)
        end
        @printf("    d^%d/dd^%d [smooth_abs] = %.4e%s\n", order, order, val,
            abs(val) > 1e10 ? "  *** BLOW-UP" : "")
    end
end

# ── Step 2: Derivatives of a single Matern 7/2 basis function ─────────
println("\n\n" * "=" ^ 70)
println("STEP 2: Single Matern 7/2 basis function k(x, xi) at x=xi vs x≠xi")
println("=" ^ 70)

l = 5.86  # typical optimized lengthscale
σ² = 1.0

function matern72_single(x, xi)
    r = smooth_abs(x - xi) / l
    u = sqrt(7.0) * r
    return σ² * (1.0 + u + 2.0 * u^2 / 5.0 + u^3 / 15.0) * exp(-u)
end

# At x = xi (d = 0)
xi = 12.0
println("\n  x = xi = $xi (d = 0):")
for order in 0:8
    val = if order == 0
        matern72_single(xi, xi)
    else
        ODEParameterEstimation.nth_deriv(x -> matern72_single(x, xi), order, xi)
    end
    @printf("    d^%d k/dx^%d = %.6e%s\n", order, order, val,
        abs(val) > 1e10 ? "  *** BLOW-UP" : "")
end

# At x = xi + 0.02 (one grid spacing away)
for offset in [0.001, 0.01, 0.02, 0.1]
    x_test = xi + offset
    @printf("\n  x = xi + %.3f = %.3f (d = %.3f):\n", offset, x_test, offset)
    for order in 0:8
        val = if order == 0
            matern72_single(x_test, xi)
        else
            ODEParameterEstimation.nth_deriv(x -> matern72_single(x, xi), order, x_test)
        end
        @printf("    d^%d k/dx^%d = %.6e%s\n", order, order, val,
            abs(val) > 1e10 ? "  *** BLOW-UP" : "")
    end
end

# ── Step 3: Compare with SE basis function ────────────────────────────
println("\n\n" * "=" ^ 70)
println("STEP 3: SE basis function k(x, xi) at x=xi (no |d| → no blow-up)")
println("=" ^ 70)

function se_single(x, xi)
    return σ² * exp(-(x - xi)^2 / (2.0 * l^2))
end

println("\n  x = xi = $xi (d = 0):")
for order in 0:8
    val = if order == 0
        se_single(xi, xi)
    else
        ODEParameterEstimation.nth_deriv(x -> se_single(x, xi), order, xi)
    end
    @printf("    d^%d k/dx^%d = %.6e\n", order, order, val)
end

# ── Step 4: Full prediction sum — how the blow-up propagates ─────────
println("\n\n" * "=" ^ 70)
println("STEP 4: How the d=0 term contaminates the full prediction")
println("=" ^ 70)

# Simulate a small GP with 5 data points
xs_small = [10.0, 11.0, 12.0, 13.0, 14.0]
alpha_small = [0.1, -0.2, 0.5, -0.3, 0.15]  # fake alpha values

function pred_matern(x)
    kv = [σ² * begin
        r = smooth_abs(x - xi) / l
        u = sqrt(7.0) * r
        (1.0 + u + 2.0 * u^2 / 5.0 + u^3 / 15.0) * exp(-u)
    end for xi in xs_small]
    return dot(kv, alpha_small)
end

function pred_se(x)
    kv = [σ² * exp(-(x - xi)^2 / (2.0 * l^2)) for xi in xs_small]
    return dot(kv, alpha_small)
end

using LinearAlgebra

# Evaluate at x = 12.0 (coincides with xs_small[3])
x_eval = 12.0
println("\n  Evaluating at x = $x_eval (= xs_small[3]):")
@printf("  %-8s  %-16s  %-16s\n", "order", "Matern 7/2", "SE")
println("  " * "-" ^ 45)
for order in 0:8
    vm = if order == 0; pred_matern(x_eval)
         else ODEParameterEstimation.nth_deriv(pred_matern, order, x_eval); end
    vs = if order == 0; pred_se(x_eval)
         else ODEParameterEstimation.nth_deriv(pred_se, order, x_eval); end
    flag = abs(vm) > 1e10 ? " ***" : ""
    @printf("  d%-7d  %-16.6e  %-16.6e%s\n", order, vm, vs, flag)
end

# Same but at x = 12.01 (NOT a data point)
x_eval2 = 12.01
println("\n  Evaluating at x = $x_eval2 (NOT a data point):")
@printf("  %-8s  %-16s  %-16s\n", "order", "Matern 7/2", "SE")
println("  " * "-" ^ 45)
for order in 0:8
    vm = if order == 0; pred_matern(x_eval2)
         else ODEParameterEstimation.nth_deriv(pred_matern, order, x_eval2); end
    vs = if order == 0; pred_se(x_eval2)
         else ODEParameterEstimation.nth_deriv(pred_se, order, x_eval2); end
    @printf("  d%-7d  %-16.6e  %-16.6e\n", order, vm, vs)
end

# ── Step 5: What EXACTLY is smooth_abs doing analytically ─────────────
println("\n\n" * "=" ^ 70)
println("STEP 5: Analytical derivatives of smooth_abs at d=0")
println("=" ^ 70)
println("""
  smooth_abs(d) = sqrt(d² + ε)

  f(0)    = √ε           = $(sqrt(EPS))
  f'(0)   = 0/√ε         = 0
  f''(0)  = ε/ε^(3/2)    = 1/√ε  = $(1/sqrt(EPS))
  f'''(0) = 0             (odd → zero by symmetry)
  f''''(0)= -3/ε^(3/2)   = $(-3/EPS^(3/2))

  Pattern: EVEN derivatives blow up, ODD derivatives = 0
  This is why d4 (even) of Matern 7/2 = 1.94e+27 at data points
  while d3, d5, d7 (odd) are fine.
""")
