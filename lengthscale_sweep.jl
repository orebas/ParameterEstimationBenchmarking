## lengthscale_sweep.jl — sweep lengthscale for AGPRobust-style GP on lotka_volterra
## Measures derivative quality (d0-d3) at 8 shooting points

using Pkg
Pkg.activate(raw"/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using ModelingToolkit: t_nounits as t, D_nounits as D
using Symbolics
using OrderedCollections
using Statistics
using Printf
using CSV
using LinearAlgebra

const FILETREE = "/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_agprobust_comparison/filetree"

# ── System definition (lotka_volterra from benchmark) ────────────────
parameters = @parameters k1 k2 k3
states = @variables r(t) w(t)
observables = @variables y1(t)
state_equations = [
    D(r) ~ 2.0*k1*r - 2.0*k2*w*r,
    D(w) ~ -0.6*k3*w + 4.0*k2*w*r,
]
measured_quantities = [y1 ~ 4.0*r]
ic = [0.471, 0.322]
p_true = [0.266, 0.44, 0.399]
time_interval = [0.0, 20.0]
datasize = 1001

model, mq = create_ordered_ode_system(
    "lotka_volterra", states, parameters, state_equations, measured_quantities
)

# ── Ground truth derivatives via symbolic ODE augmentation ────────────
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

MAX_DERIV = 3  # lotka_volterra needs d0-d3

expanded_mq, obs_derivs = calculate_observable_derivatives(
    equations(model.system), mq, MAX_DERIV)
@named deriv_sys = ODESystem(equations(model.system), t; observed=expanded_mq)
ssys = structural_simplify(deriv_sys)

ic_dict = OrderedDict(states .=> ic)
p_dict = OrderedDict(parameters .=> p_true)
prob = ODEProblem(ssys, ic_dict, (time_interval[1], time_interval[2]), p_dict)
t_grid = range(time_interval[1], time_interval[2], length=datasize)
sol = solve(prob, AutoVern9(Rodas4P()), abstol=1e-14, reltol=1e-14, saveat=t_grid)
ts = collect(Float64, sol.t)

shoot_indices = [1, 144, 287, 430, 572, 715, 858, 1001]
t_shoot = ts[shoot_indices]

println("Ground truth solved. Sweeping lengthscales...\n")

# ── Manual SE-kernel GP with fixed hyperparameters ────────────────────
function build_gp_predictor(xs, ys_raw, lengthscale, noise_var)
    n = length(xs)
    y_mean = mean(ys_raw)
    y_std = max(std(ys_raw), 1e-8)
    ys_norm = (collect(Float64, ys_raw) .- y_mean) ./ y_std
    signal_var = 1.0
    jitter = 1e-8

    # Build kernel matrix
    K = Matrix{Float64}(undef, n, n)
    inv_2l2 = 1.0 / (2.0 * lengthscale^2)
    for j in 1:n, i in 1:n
        K[i, j] = signal_var * exp(-abs2(xs[i] - xs[j]) * inv_2l2)
    end
    for i in 1:n
        K[i, i] += noise_var + jitter
    end

    C = cholesky(Symmetric(K))
    alpha = C \ ys_norm

    # Capture in closure — TaylorDiff-compatible (only basic arithmetic)
    xs_captured = collect(Float64, xs)
    function pred(x::Real)
        k_star = [signal_var * exp(-abs2(x - xi) * inv_2l2) for xi in xs_captured]
        return y_std * dot(k_star, alpha) + y_mean
    end
    return pred
end

# ── Sweep ─────────────────────────────────────────────────────────────
lengthscales = [0.05, 0.1, 0.2, 0.5, 1.0, 1.287, 2.0, 5.0]
noise_vars = [1e-10, 1e-6]  # lower bound vs init_noise for smooth

for noise_tag in ["0", "1em8"]
    data_path = joinpath(FILETREE, "odepe_default", "lotka_volterra_0_$(noise_tag)", "data.csv")
    csv_data = CSV.read(data_path, Tuple, header=false)
    t_data = collect(Float64, csv_data[1])
    y_data = collect(Float64, csv_data[2])

    for nv in noise_vars
        println("=" ^ 90)
        @printf("NOISE_TAG = %s   noise_var = %.1e   n = %d\n", noise_tag, nv, length(t_data))
        println("=" ^ 90)

        @printf("%-12s", "lengthscale")
        for d in 0:MAX_DERIV
            @printf("  d%d_relrmse  ", d)
        end
        println()
        println("-" ^ 90)

        for ls in lengthscales
            pred_fn = try
                build_gp_predictor(t_data, y_data, ls, nv)
            catch e
                @printf("%-12.4f  FAILED: %s\n", ls, e)
                continue
            end

            @printf("%-12.4f", ls)
            for d in 0:MAX_DERIV
                if d == 0
                    pred_vals = [pred_fn(x) for x in t_shoot]
                    truth_vals = sol[mq[1].lhs][shoot_indices]
                else
                    pred_vals = try
                        [ODEParameterEstimation.nth_deriv(pred_fn, d, x) for x in t_shoot]
                    catch e
                        @printf("  %-12s", "ERR")
                        continue
                    end
                    truth_vals = collect(Float64, sol(collect(t_shoot), idxs=obs_derivs[1, d]))
                end

                abs_errs = abs.(pred_vals .- truth_vals)
                scale = mean(abs.(truth_vals))
                rel_rmse = scale > 1e-15 ? sqrt(mean(abs_errs .^ 2)) / scale : sqrt(mean(abs_errs .^ 2))
                @printf("  %-12.2e", rel_rmse)
            end
            println()
        end
        println()
    end
end
