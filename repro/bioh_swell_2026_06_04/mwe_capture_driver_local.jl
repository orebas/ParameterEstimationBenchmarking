# Re-run the bioh_3_1em8 estimation with BIOH_MWE_CAPTURE=1 so the instrumentation in
# resolve_states_with_fixed_params (src/core/si_template_integration.jl) prints which step
# hangs + dumps the equations of the degenerate candidate. Uses the global Julia env (ODEPE
# dev'd there, with the instrumentation). Reads the bioh data from this dir.
#
# It WILL hang (forever) at the degenerate candidate — that's expected. Read /tmp/mwe_capture.log
# for the [MWE] prints (the equations + the last STEP*-ENTER with no matching EXIT = the hang),
# then kill the process. Run: julia --startup-file=no mwe_capture_driver_local.jl > /tmp/mwe_capture.log 2>&1

ENV["BIOH_MWE_CAPTURE"] = "1"

using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV
using Symbolics: Num

name = "biohydrogenation"
parameters = @parameters k5 k6 k7 k8 k9 k10
states = @variables x4(t) x5(t) x6(t) x7(t)
observables = @variables y1(t) y2(t)
state_equations = [
    D(x4) ~ (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4)),
    D(x5) ~ ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5,
    D(x6) ~ ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5,
    D(x7) ~ (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10),
]
measured_quantities = [y1 ~ 8.0*x4, y2 ~ 0.5*x5]
ic = [0.68, 0.81, 0.703, 0.684]
p_true = [0.407, 0.554, 0.488, 0.524, 0.562, 0.785]
time_interval = [0.0, 10.0]

model, mq = create_ordered_ode_system(name, states, parameters, state_equations, measured_quantities)

csv_data = CSV.read(joinpath(@__DIR__, "data.csv"), Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
    data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end

pep = ParameterEstimationProblem(
    name, model, mq, data_sample, time_interval, nothing,
    OrderedDict(parameters .=> p_true), OrderedDict(states .=> ic), 0,
)

opts = EstimationOptions(
    datasize = length(data_sample["t"]),
    noise_level = 0.000,
    system_solver = SolverHC,
    flow = FlowStandard,
    use_si_template = true,
    shooting_points = 20,
    shooting_warp = true,
    shooting_warp_beta = 3.0,
    use_parameter_homotopy = true,
    use_multipoint = true,
    multipoint_n_points = 2,
    multipoint_max_pairs = 15,
    polish_solver_solutions = true,
    polish_solutions = true,
    polish_maxiters = 5000,
    polish_method = PolishLSOBoundedLog,
    opt_maxiters = 200000,
    opt_lb = 1e-05 * ones(length(ic) + length(p_true)),
    opt_ub = 10.0 * ones(length(ic) + length(p_true)),
    abstol = 1e-12,
    reltol = 1e-12,
    polish_maxtime = 600.0,
    polish_divergence_factor = 10.0,
    polish_stagnation_window = 50,
    polish_ode_maxiters = 20000,
    diagnostics = true,
)

println("[MWE] starting bioh estimation (will hang at the degenerate candidate; read prints + kill)..."); flush(stdout)
analyze_parameter_estimation_problem(pep, opts)
println("[MWE] FINISHED without hanging (unexpected)")
