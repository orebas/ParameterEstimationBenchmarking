## high_deriv_test.jl — test SE vs Matern72 vs Matern92 at d0-d9
## Uses lotka_volterra (only needs d3, but let's see how they degrade)

using Pkg
Pkg.activate(raw"/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using ModelingToolkit: t_nounits as t, D_nounits as D
using Symbolics
using OrderedCollections
using Statistics, Printf, CSV, LinearAlgebra
using Optim, LineSearches

# ── System + ground truth (d0-d9) ────────────────────────────────────
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

model, mq = create_ordered_ode_system(
    "lotka_volterra", states, parameters_sym, state_equations, measured_quantities
)

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

MAX_D = 9
expanded_mq, obs_derivs = calculate_observable_derivatives(
    equations(model.system), mq, MAX_D)
@named deriv_sys = ODESystem(equations(model.system), t; observed=expanded_mq)
ssys = structural_simplify(deriv_sys)

ic_dict = OrderedDict(states .=> ic)
p_dict = OrderedDict(parameters_sym .=> p_true)
prob = ODEProblem(ssys, ic_dict, (0.0, 20.0), p_dict)
t_grid = range(0.0, 20.0, length=1001)
sol = solve(prob, AutoVern9(Rodas4P()), abstol=1e-14, reltol=1e-14, saveat=t_grid)
ts = collect(Float64, sol.t)

# Offset shooting points (between data points)
dt = ts[2] - ts[1]
t_shoot = collect(Float64, range(dt/2, 20.0 - dt/2, length=8))

println("Ground truth solved (d0-d$MAX_D).\n")

# ── Kernel helpers ────────────────────────────────────────────────────
_softplus(x::Real) = x > 34.0 ? x : log(1.0 + exp(x))
_inv_softplus(y::Real) = y > 34.0 ? y : log(exp(y) - 1.0)
const MATERN_EPS = 1e-30
smooth_abs(d) = sqrt(d * d + MATERN_EPS)

# SE
se_K!(K, xs, θ) = let l=θ[1], σ²=θ[2], inv2l2=1/(2l^2), n=length(xs)
    for j in 1:n, i in 1:n; K[i,j] = σ²*exp(-abs2(xs[i]-xs[j])*inv2l2); end; end
se_ks(x, xi, θ) = θ[2]*exp(-abs2(x-xi)/(2θ[1]^2))

# Matern 7/2
m72_K!(K, xs, θ) = let l=θ[1], σ²=θ[2], s7=sqrt(7.0), n=length(xs)
    for j in 1:n, i in 1:n
        local r = abs(xs[i]-xs[j])/l; local u = s7*r
        K[i,j] = σ²*(1+u+2u^2/5+u^3/15)*exp(-u); end; end
m72_ks(x, xi, θ) = let l=θ[1], σ²=θ[2], r=smooth_abs(x-xi)/l, u=sqrt(7.0)*r
    σ²*(1+u+2u^2/5+u^3/15)*exp(-u); end

# Matern 9/2
m92_K!(K, xs, θ) = let l=θ[1], σ²=θ[2], n=length(xs)
    for j in 1:n, i in 1:n
        local r = abs(xs[i]-xs[j])/l; local u = 3r
        K[i,j] = σ²*(1+u+27r^2/7+18r^3/7+27r^4/35)*exp(-u); end; end
m92_ks(x, xi, θ) = let l=θ[1], σ²=θ[2], r=smooth_abs(x-xi)/l, u=3r
    σ²*(1+u+27r^2/7+18r^3/7+27r^4/35)*exp(-u); end

# ── Optimize + eval ──────────────────────────────────────────────────
function test_kernel(name, K_fn!, ks_fn, θ0, xs, ys_raw, noise_var)
    n = length(xs)
    y_mean = mean(ys_raw); y_std = max(std(ys_raw), 1e-8)
    ys_norm = (collect(Float64, ys_raw) .- y_mean) ./ y_std
    jitter = 1e-8
    K = Matrix{Float64}(undef, n, n)
    nh = length(θ0)

    function neg_lml(θr)
        local θk = [_softplus(θr[i]) for i in 1:nh]
        K_fn!(K, xs, θk)
        for i in 1:n; K[i,i] += noise_var + jitter; end
        try; local C = cholesky(Symmetric(K)); local a = C\ys_norm
            return 0.5*(dot(ys_norm,a)+2sum(log.(diag(C.U)))+n*log(2π))
        catch; return Inf; end
    end

    θ0r = [_inv_softplus(v) for v in θ0]
    lo = [_inv_softplus(1e-3), _inv_softplus(1e-8)]
    hi = [_inv_softplus(150.0), _inv_softplus(150.0)]
    θ_opt = copy(θ0)
    try
        res = Optim.optimize(neg_lml, lo, hi, θ0r,
            Fminbox(LBFGS(linesearch=LineSearches.BackTracking())),
            Optim.Options(iterations=1000))
        θ_opt = [_softplus(Optim.minimizer(res)[i]) for i in 1:nh]
    catch; end

    K_fn!(K, xs, θ_opt)
    for i in 1:n; K[i,i] += noise_var + jitter; end
    local C = cholesky(Symmetric(K))
    local alpha = C \ ys_norm
    local xs_cap = collect(Float64, xs)

    pred(x::Real) = let kv = [ks_fn(x, xi, θ_opt) for xi in xs_cap]
        y_std * dot(kv, alpha) + y_mean; end

    @printf("  %-12s  θ=[%.3f, %.3f]  ", name, θ_opt...)
    for d in 0:MAX_D
        pvals = Float64[]
        tvals = Float64[]
        for tv in t_shoot
            pv = try
                if d == 0; pred(tv); else ODEParameterEstimation.nth_deriv(pred, d, tv); end
            catch; NaN; end
            trv = if d == 0; sol(tv, idxs=mq[1].lhs)
                   else; sol(tv, idxs=obs_derivs[1, d]); end
            push!(pvals, pv); push!(tvals, trv)
        end
        ae = abs.(pvals .- tvals)
        scale = mean(abs.(tvals))
        rr = scale > 1e-15 ? sqrt(mean(ae.^2))/scale : sqrt(mean(ae.^2))
        @printf("%-9.2e", rr)
    end
    println()
end

# ── Run ───────────────────────────────────────────────────────────────
const FILETREE = "/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_agprobust_comparison/filetree"

for noise_tag in ["0", "1em8"]
    data_path = joinpath(FILETREE, "odepe_default", "lotka_volterra_0_$(noise_tag)", "data.csv")
    csv_data = CSV.read(data_path, Tuple, header=false)
    t_data = collect(Float64, csv_data[1])
    y_data = collect(Float64, csv_data[2])
    ls0 = std(t_data) / 8.0

    println("=" ^ 120)
    @printf("NOISE = %s   n = %d\n", noise_tag, length(t_data))
    @printf("  %-12s  %-16s  ", "Kernel", "θ")
    for d in 0:MAX_D; @printf("d%-8d", d); end
    println()
    println("  " * "-" ^ 115)

    test_kernel("SE",       se_K!,  se_ks,  [ls0, 1.0], t_data, y_data, 1e-10)
    test_kernel("Matern72", m72_K!, m72_ks, [ls0, 1.0], t_data, y_data, 1e-10)
    test_kernel("Matern92", m92_K!, m92_ks, [ls0, 1.0], t_data, y_data, 1e-10)
    println()
end
