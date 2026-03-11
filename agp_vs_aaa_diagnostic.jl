## agp_vs_aaa_diagnostic.jl
##
## Compare AAA vs AGPRobust derivative quality on lotka_volterra
## at noise=0 and noise=1e-8, using actual benchmark data.

using Pkg
Pkg.activate(raw"/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using ModelingToolkit: t_nounits as t, D_nounits as D
using Symbolics
using Symbolics: Num
using OrderedCollections
using Statistics
using Printf
using CSV

const BENCHMARK_DIR = "/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_agprobust_comparison"
const FILETREE = joinpath(BENCHMARK_DIR, "filetree")

# ── System definition (from benchmark script.jl) ────────────────────
name = "lotka_volterra"
parameters = @parameters k1 k2 k3
states = @variables r(t) w(t)
observables = @variables y1(t)
state_equations = [
    D(r) ~ 2.0*k1*r - 2.0*k2*w*r,
    D(w) ~ -0.6*k3*w + 4.0*k2*w*r,
]
measured_quantities = [
    y1 ~ 4.0*r,
]
ic = [0.471, 0.322]
p_true = [0.266, 0.44, 0.399]
time_interval = [0.0, 20.0]
datasize = 1001

model, mq = create_ordered_ode_system(
    name, states, parameters, state_equations, measured_quantities
)

# ── Symbolic derivatives for ground truth ────────────────────────────
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

MAX_DERIV = 5  # lotka_volterra uses up to d3, but let's see d0-d5

expanded_mq, obs_derivs = calculate_observable_derivatives(
    equations(model.system), mq, MAX_DERIV)
@named deriv_sys = ODESystem(equations(model.system), t; observed=expanded_mq)
ssys = structural_simplify(deriv_sys)

# Solve ODE for ground truth
ic_dict = OrderedDict(states .=> ic)
p_dict = OrderedDict(parameters .=> p_true)
prob = ODEProblem(ssys, ic_dict, (time_interval[1], time_interval[2]), p_dict)
t_grid = range(time_interval[1], time_interval[2], length=datasize)
sol = solve(prob, AutoVern9(Rodas4P()), abstol=1e-14, reltol=1e-14, saveat=t_grid)
ts = collect(Float64, sol.t)

# Shooting points (8 equispaced, matching benchmark)
shoot_indices = [1, 144, 287, 430, 572, 715, 858, 1001]
t_shoot = ts[shoot_indices]

println("Ground truth ODE solved. Testing interpolators...\n")

# ── Get the interpolator functions from ODEPE ────────────────────────
# These are the actual functions the package uses
aaa_interp_fn = ODEParameterEstimation.get_interpolator_function(InterpolatorAAAD, nothing)
gpr_interp_fn = ODEParameterEstimation.get_interpolator_function(InterpolatorAAADGPR, nothing)
agp_interp_fn = ODEParameterEstimation.get_interpolator_function(InterpolatorAGPRobust, nothing)

for noise_tag in ["0", "1em8"]
    println("=" ^ 80)
    println("NOISE = $noise_tag")
    println("=" ^ 80)

    # Read benchmark data
    data_path = joinpath(FILETREE, "odepe_default", "lotka_volterra_0_$(noise_tag)", "data.csv")
    csv_data = CSV.read(data_path, Tuple, header=false)
    t_data = collect(Float64, csv_data[1])
    y_data = collect(Float64, csv_data[2])  # y1 = 4*r

    obs_eq = mq[1]

    for (interp_name, interp_fn) in [("AAA", aaa_interp_fn), ("AAADGPR", gpr_interp_fn), ("AGPRobust", agp_interp_fn)]
        println("\n  --- $interp_name ---")

        # Fit interpolator
        interp = try
            interp_fn(t_data, y_data)
        catch e
            println("    FAILED to fit: $e")
            continue
        end

        # Evaluate at ALL points and at shooting points
        for (label, eval_pts, eval_indices) in [
            ("all 1001 pts", ts, 1:length(ts)),
            ("8 shooting pts", t_shoot, shoot_indices)
        ]
            println("\n    [$label]")
            @printf("    %-6s  %-12s  %-12s  %-12s  %-12s\n", "order", "rel_rmse", "max_rel_err", "truth_scale", "med_abs_err")
            @printf("    %s\n", "-"^60)

            for d in 0:MAX_DERIV
                if d == 0
                    pred = [interp(x) for x in eval_pts]
                    truth = sol[obs_eq.lhs][eval_indices]
                else
                    pred = try
                        [ODEParameterEstimation.nth_deriv(x -> interp(x), d, x) for x in eval_pts]
                    catch e
                        println("    d$d: FAILED ($e)")
                        continue
                    end
                    truth = collect(Float64, sol(collect(eval_pts), idxs=obs_derivs[1, d]))
                end

                abs_errors = abs.(pred .- truth)
                truth_abs = abs.(truth)
                truth_scale = mean(truth_abs)

                # Per-point relative errors (avoid div by 0)
                rel_errors = [ta > 1e-15 ? ae / ta : ae for (ae, ta) in zip(abs_errors, truth_abs)]

                rmse = sqrt(mean(abs_errors .^ 2))
                rel_rmse = truth_scale > 1e-15 ? rmse / truth_scale : rmse
                max_rel = maximum(rel_errors)
                med_abs = median(abs_errors)

                @printf("    d%-5d  %-12.2e  %-12.2e  %-12.2e  %-12.2e\n",
                    d, rel_rmse, max_rel, truth_scale, med_abs)
            end
        end
    end
    println()
end
