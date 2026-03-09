#!/usr/bin/env julia
#=
Derivative Accuracy Deep Dive — Biohydrogenation (exact quokka config)
=====================================================================
Strategy: Generate data independently from a plain ODE solve (matching quokka
config), then test interpolator derivative accuracy against ground truth
from recursive ForwardDiff on the same ODE solution.

This avoids any discrepancy from ODEPE's internal model transformations.
=#

using ODEParameterEstimation
using OrdinaryDiffEq
using ForwardDiff, TaylorDiff
using CSV, DataFrames
using Statistics

using ODEParameterEstimation: aaad, aaad_gpr_pivot, aaad_old_reliable,
    fhd, fhdn, agp_gpr_robust, nth_deriv

const OUTDIR = @__DIR__

# ──────────────────────────────────────────────
# 1. Model: exact quokka biohydrogenation config
# ──────────────────────────────────────────────
# Parameters and ICs from quokka benchmark
const K5, K6, K7, K8, K9, K10 = 0.688, 0.87, 0.299, 0.561, 0.574, 0.558
const X4_0, X5_0, X6_0, X7_0 = 0.278, 0.862, 0.458, 0.777
const T_START, T_END = 0.0, 10.0
const DATASIZE = 1501
const T_RANGE = T_END - T_START  # = 10.0

# ODE RHS (exact quokka scaled equations)
function biohydrogenation!(du, u, p, t)
    x4, x5, x6, x7 = u
    k5, k6, k7, k8, k9, k10 = p
    du[1] = (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4))
    du[2] = ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5
    du[3] = ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5
    du[4] = (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10)
end

p_vals = [K5, K6, K7, K8, K9, K10]
ic_vals = [X4_0, X5_0, X6_0, X7_0]

println("="^70)
println("Derivative Accuracy Deep Dive: biohydrogenation (quokka config)")
println("="^70)
println("  datasize=$DATASIZE, time=[$T_START, $T_END]")
println("  params: k5=$K5, k6=$K6, k7=$K7, k8=$K8, k9=$K9, k10=$K10")
println("  ICs: x4=$X4_0, x5=$X5_0, x6=$X6_0, x7=$X7_0")
println("  Observables: y1 = 8*x4, y2 = 0.5*x5")
println()

# ──────────────────────────────────────────────
# 2. High-precision ODE solve
# ──────────────────────────────────────────────
t_phys = collect(range(T_START, T_END, length=DATASIZE))
t_norm = collect(range(-0.5, 0.5, length=DATASIZE))  # ODEPE normalized time

println("Solving ODE (Vern9, atol=rtol=1e-14)...")
prob = ODEProblem(biohydrogenation!, ic_vals, (T_START, T_END), p_vals)

# Solve twice: once with saveat for data, once without for dense output
sol_data = solve(prob, Vern9(), abstol=1e-14, reltol=1e-14, saveat=t_phys)
sol_dense = solve(prob, Vern9(), abstol=1e-14, reltol=1e-14)  # dense=true by default
println("  Status: $(sol_data.retcode), $(length(sol_data.t)) data points, $(length(sol_dense.t)) dense steps")

# Generate observable data from the saved-at solution
y1_data = 8.0 .* sol_data[1, :]   # y1 = 8*x4
y2_data = 0.5 .* sol_data[2, :]   # y2 = 0.5*x5

println("  y1: [$(y1_data[1]), ..., $(y1_data[end])], range [$(minimum(y1_data)), $(maximum(y1_data))]")
println("  y2: [$(y2_data[1]), ..., $(y2_data[end])], range [$(minimum(y2_data)), $(maximum(y2_data))]")

# Save data
CSV.write(joinpath(OUTDIR, "generated_data.csv"),
    DataFrame(t_phys=t_phys, t_norm=t_norm, y1=y1_data, y2=y2_data))
println("  Saved to generated_data.csv")
println()

# ──────────────────────────────────────────────
# 3. Ground truth: Taylor coefficient recursion via TaylorDiff
# ──────────────────────────────────────────────
# For each eval point t₀ where x(t₀) is known, compute d^n x/dt^n using:
#   1. Define x_local(h) via a truncated Taylor polynomial built iteratively
#   2. x₀ = x(t₀), x₁ = f(x₀), x₂ = (1/2)*d/dh[f(x₀+h*x₁)]|_{h=0}, etc.
#   3. Each Taylor coefficient requires differentiating f composed with
#      the truncated polynomial — done via TaylorDiff (flat, not nested)

using LinearAlgebra: dot

function ode_rhs_vec(u, p)
    x4, x5, x6, x7 = u
    k5, k6, k7, k8, k9, k10 = p
    du1 = (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4))
    du2 = ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5
    du3 = ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5
    du4 = (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10)
    return [du1, du2, du3, du4]
end

"""
Compute Taylor coefficients of the ODE solution x(t₀ + h) to order N.
Returns jets[k+1] = d^k x / dt^k at t=t₀ (a 4-vector).

Uses the recursive identity: the k-th Taylor coefficient of x(t₀+h) is
  c_k = (1/k) * [coefficient of h^(k-1) in f(Σ c_j h^j)]
evaluated by TaylorDiff on the scalar variable h.
"""
function compute_ode_taylor(x0::Vector{Float64}, p, max_order::Int)
    n_states = length(x0)
    # jets[k+1] = d^k x / dt^k (k=0,...,max_order)
    jets = Vector{Vector{Float64}}(undef, max_order + 1)
    jets[1] = copy(x0)

    # Build up coefficients one at a time
    for k in 1:max_order
        # x_trunc(h) = Σ_{j=0}^{k-1} jets[j+1] * h^j / j!
        # We need d^k x / dt^k = (d^(k-1)/dh^(k-1) f(x_trunc(h)))|_{h=0} / (k-1)! * k!... actually:
        #
        # The ODE x'(t) = f(x(t)) in Taylor series gives:
        # Σ_{j≥1} c_j * j * h^(j-1) = f(Σ_{j≥0} c_j * h^j)
        # So c_k = (1/k) * [h^(k-1) coefficient of f(x_trunc(h))]
        # The h^(k-1) coefficient of f(x_trunc(h)) is (1/(k-1)!) * d^(k-1)/dh^(k-1) f(x_trunc(h))|_{h=0}
        # Thus: c_k = (1/k) * (1/(k-1)!) * D^(k-1)[f(x_trunc(h))]|_{h=0}
        # And d^k x / dt^k = k! * c_k = (k-1)! * (1/(k-1)!) * D^(k-1)[f(x_trunc(h))]|_{h=0}
        #                  = D^(k-1)[f(x_trunc(h))]|_{h=0}
        # where D = d/dh.

        # Define x_trunc(h) using coefficients computed so far
        local current_jets = jets  # capture

        # For each component of f, compute the (k-1)-th derivative w.r.t. h at h=0
        jet_k = zeros(n_states)
        for comp in 1:n_states
            # Define scalar function h -> f_comp(x_trunc(h))
            function f_comp_of_h(h)
                # Build x_trunc(h)
                x = copy(current_jets[1])
                hpow = one(h)
                for j in 1:k-1
                    hpow = hpow * h / j
                    x = x .+ current_jets[j+1] .* hpow
                end
                return ode_rhs_vec(x, p)[comp]
            end

            if k == 1
                jet_k[comp] = f_comp_of_h(0.0)
            else
                jet_k[comp] = TaylorDiff.derivative(f_comp_of_h, 0.0, Val(k - 1))
            end
        end
        jets[k + 1] = jet_k
    end

    return jets
end

# Warped shooting point indices (same as quokka benchmark)
function warped_indices(n_points, N; beta=3.0)
    idxs = Int[]
    for i in 1:n_points
        frac = (i - 1) / (n_points - 1)
        push!(idxs, max(1, min(N, round(Int, 1 + frac^beta * (N - 1)))))
    end
    return unique(idxs)
end

MAX_DERIV = 7
eval_idxs = warped_indices(12, DATASIZE, beta=3.0)

println("Evaluation points ($(length(eval_idxs)) warped shooting points):")
for (i, idx) in enumerate(eval_idxs)
    println("  $i: t_phys=$(round(t_phys[idx], digits=4)), t_norm=$(round(t_norm[idx], digits=6)) (idx $idx)")
end
println()

println("Computing ground truth derivatives (orders 0-$MAX_DERIV)...")
println("  Method: ODE Taylor coefficient recursion via TaylorDiff")

# Store ground truth in normalized-time coordinates
# d^n y / dt_norm^n = T_RANGE^n * d^n y / dt_phys^n
gt = Dict{Tuple{String, Int, Int}, Float64}()

for (i, idx) in enumerate(eval_idxs)
    tp = t_phys[idx]
    x0 = collect(sol_dense(tp))  # state at this time from dense solution

    # Taylor coefficients: jets[k+1] = d^k x / dt^k (4-vector)
    jets = compute_ode_taylor(x0, p_vals, MAX_DERIV)

    for n in 0:MAX_DERIV
        # y1 = 8*x4 (state 1), y2 = 0.5*x5 (state 2)
        d_y1_phys = 8.0 * jets[n+1][1]
        d_y2_phys = 0.5 * jets[n+1][2]
        # Convert to normalized-time derivatives
        gt[("y1", i, n)] = d_y1_phys * T_RANGE^n
        gt[("y2", i, n)] = d_y2_phys * T_RANGE^n
    end

    if i == 1
        println("  Ground truth at eval point 1 (t=$(round(tp, digits=4))):")
        for obs in ["y1", "y2"]
            vals = [gt[(obs, 1, n)] for n in 0:MAX_DERIV]
            println("    $obs (norm-time): ", [round(v, sigdigits=6) for v in vals])
        end
    end
end

# Verify d0 matches data
d0_ok = true
for (i, idx) in enumerate(eval_idxs)
    y1_gt0 = gt[("y1", i, 0)]
    y1_dat = y1_data[idx]
    if abs(y1_gt0 - y1_dat) / max(abs(y1_gt0), 1e-15) > 1e-8
        println("  ⚠ d0 mismatch at point $i: gt=$y1_gt0, data=$y1_dat, diff=$(y1_gt0-y1_dat)")
        d0_ok = false
    end
end
d0_ok && println("  d0 verification passed (ground truth matches data)")

println()

# ──────────────────────────────────────────────
# 4. Test interpolators
# ──────────────────────────────────────────────
# Each interpolator takes (t_normalized, y_values) and returns a callable

interpolators = [
    ("PureAAA",        (xs, ys) -> aaad(xs, ys)),
    ("OldGPR",         (xs, ys) -> aaad_gpr_pivot(xs, ys)),
    ("AGPRobust_SE",   (xs, ys) -> agp_gpr_robust(xs, ys; kernel_type=:se)),
    ("AGPRobust_RQ",   (xs, ys) -> agp_gpr_robust(xs, ys; kernel_type=:rq)),
    ("AGPRobust_SEpRQ",(xs, ys) -> agp_gpr_robust(xs, ys; kernel_type=:se_plus_rq)),
    ("AGPRobust_SExRQ",(xs, ys) -> agp_gpr_robust(xs, ys; kernel_type=:se_times_rq)),
    ("FHD",            (xs, ys) -> fhdn(5)(xs, ys)),
]

results = DataFrame(
    interpolator=String[], observable=String[], eval_point=Int[],
    t_phys=Float64[], deriv_order=Int[],
    ground_truth=Float64[], estimated=Float64[],
    abs_error=Float64[], rel_error=Float64[],
)

for (label, create_fn) in interpolators
    println("─"^50)
    println("Interpolator: $label")
    println("─"^50)

    for (obs, ydata) in [("y1", y1_data), ("y2", y2_data)]
        print("  $obs: ")
        flush(stdout)

        interp = nothing
        try
            elapsed = @elapsed (interp = create_fn(t_norm, ydata))
            println("created in $(round(elapsed, digits=2))s")
        catch e
            println("FAILED: ", sprint(showerror, e))
            for (i, idx) in enumerate(eval_idxs), n in 0:MAX_DERIV
                push!(results, (label, obs, i, t_phys[idx], n, gt[(obs,i,n)], NaN, NaN, NaN))
            end
            continue
        end

        for (i, idx) in enumerate(eval_idxs)
            tn = t_norm[idx]
            for n in 0:MAX_DERIV
                gt_val = gt[(obs, i, n)]
                est = NaN
                try
                    f = x -> interp(x)
                    est = (n == 0) ? f(tn) : nth_deriv(f, n, tn)
                catch
                end
                ae = isnan(est) ? NaN : abs(est - gt_val)
                re = (isnan(ae) || abs(gt_val) < 1e-15) ? NaN : ae / abs(gt_val)
                push!(results, (label, obs, i, t_phys[idx], n, gt_val, est, ae, re))
            end
        end
    end
    println()
end

# ──────────────────────────────────────────────
# 5. Save & summarize
# ──────────────────────────────────────────────
CSV.write(joinpath(OUTDIR, "derivative_errors_detailed.csv"), results)
println("Detailed results saved to derivative_errors_detailed.csv")

fmt(v) = isnan(v) ? "N/A" : v < 1e-12 ? "~0" :
    v < 0.001 ? "$(round(v*100, sigdigits=2))%" :
    v < 10 ? "$(round(v*100, sigdigits=3))%" :
    "$(round(v*100, sigdigits=3))%"

function print_summary(title, df; obs_filter=nothing)
    println("\n" * "="^70)
    println(title)
    println("="^70)
    names = unique(df.interpolator)
    println(rpad("Interpolator",18), " | ", join([rpad("d$n",12) for n in 0:MAX_DERIV], " | "))
    println("-"^18, "-+-", join(["-"^12 for _ in 0:MAX_DERIV], "-+-"))
    for nm in names
        cells = String[]
        for n in 0:MAX_DERIV
            mask = (df.interpolator .== nm) .& (df.deriv_order .== n)
            obs_filter !== nothing && (mask .&= (df.observable .== obs_filter))
            v = filter(!isnan, df[mask, :rel_error])
            push!(cells, isempty(v) ? "N/A" : fmt(median(v)))
        end
        println(rpad(nm,18), " | ", join([rpad(c,12) for c in cells], " | "))
    end
end

print_summary("MEDIAN relative error (y1+y2 combined)", results)
print_summary("MEDIAN relative error: y1 only", results, obs_filter="y1")
print_summary("MEDIAN relative error: y2 only", results, obs_filter="y2")

# Max error table
println("\n" * "="^70)
println("MAX relative error (y1+y2 combined)")
println("="^70)
names = unique(results.interpolator)
println(rpad("Interpolator",18), " | ", join([rpad("d$n",12) for n in 0:MAX_DERIV], " | "))
println("-"^18, "-+-", join(["-"^12 for _ in 0:MAX_DERIV], "-+-"))
for nm in names
    cells = String[]
    for n in 0:MAX_DERIV
        v = filter(!isnan, results[(results.interpolator .== nm) .& (results.deriv_order .== n), :rel_error])
        push!(cells, isempty(v) ? "N/A" : fmt(maximum(v)))
    end
    println(rpad(nm,18), " | ", join([rpad(c,12) for c in cells], " | "))
end

# Save summary CSV
summary_df = DataFrame(interpolator=String[], deriv_order=Int[],
    median_rel=Float64[], max_rel=Float64[], mean_rel=Float64[])
for nm in names, n in 0:MAX_DERIV
    v = filter(!isnan, results[(results.interpolator .== nm) .& (results.deriv_order .== n), :rel_error])
    push!(summary_df, (nm, n,
        isempty(v) ? NaN : median(v),
        isempty(v) ? NaN : maximum(v),
        isempty(v) ? NaN : mean(v)))
end
CSV.write(joinpath(OUTDIR, "derivative_errors_summary.csv"), summary_df)

println("\n" * "="^70)
println("Done! Results in: $OUTDIR")
println("="^70)
