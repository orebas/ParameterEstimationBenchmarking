using Pkg; Pkg.activate({{{julia_env_path}}})

using MKL

using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

using GaussianProcesses
using Statistics
using Optim, LineSearches
using Symbolics: Num

name = "{{name}}"
parameters = @parameters {{#parameters}}{{varname}} {{/parameters}}
states = @variables  {{#states}}{{varname}}(t){{space}}{{/states}}
observables = @variables  {{#measurements}}{{varname}}(t){{space}}{{/measurements}}
state_equations = [
{{#components}}
    D({{state_var}}) ~ {{state_expr}},
{{/components}}
]
measured_quantities = [
{{#measured_quantities}}
    {{measurement}} ~ {{measurement_expression}},
{{/measured_quantities}}
]
ic = [{{#initial_conditions}}{{value}}{{comma}}{{/initial_conditions}}]
p_true = [{{#parameters}}{{true}}{{comma}}{{/parameters}}]

time_interval = [{{time_start}}, {{time_end}}]
datasize = {{time_count}}

model, mq = create_ordered_ode_system(
    name,
    states,
    parameters,
    state_equations,
    measured_quantities
)

# Use mq (model-consistent variables) for data_sample keys, not original measured_quantities
csv_data = CSV.read(joinpath(@__DIR__, "{{data_filepath}}"), Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
    data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end

pep = ParameterEstimationProblem(
    name,
    model,
    mq,
    data_sample,
    time_interval,
    nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0,
)

# Create EstimationOptions with desired settings
# You can customize these options based on your needs
opts = EstimationOptions(
    datasize = length(data_sample["t"]),
    noise_level = 0.000,
    system_solver = SolverHC,
    flow = FlowStandard,
    use_si_template = true,
    polish_solver_solutions = true,
    polish_solutions = {{ODEPE_POLISH}},
    polish_maxiters = 5000,             # ODEPE starts from algebraic solutions; 5k suffices (was 50k)
    polish_method = PolishBFGS,         # Match SciML's BFGS full Hessian (was PolishLBFGS)
    opt_maxiters = 200000,              # Match SciML for direct opt path
    opt_lb = {{lower_bound}} * ones(length(ic) + length(p_true)),  # Match SciML bounds
    opt_ub = {{upper_bound}} * ones(length(ic) + length(p_true)),  # Match SciML bounds
    abstol = 1e-13,                     # Match SciML tolerances (was default 1e-14)
    reltol = 1e-13,                     # Match SciML tolerances (was default 1e-14)
    polish_maxtime = {{POLISH_MAXTIME}},
    polish_divergence_factor = {{POLISH_DIVERGENCE_FACTOR}},
    polish_stagnation_window = {{POLISH_STAGNATION_WINDOW}},
    polish_ode_maxiters = {{POLISH_ODE_MAXITERS}},
    diagnostics = true)

# Run the analysis with the selected options
meta, results = analyze_parameter_estimation_problem(
    pep,
    opts,  # Use the main opts, or replace with opts_fast, opts_accurate, or opts_noisy
)
 
(solutions_vector, besterror,
    best_min_error,
    best_mean_error,
    best_median_error,
    best_max_error,
    best_approximation_error,
    best_rms_error) = results
 
table = merge(
    Dict((string(x) => [each.states[x] for each in solutions_vector] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in solutions_vector] for x in parameters)),
)

result_file = joinpath(@__DIR__, "result.csv")
CSV.write(result_file, table, header = string.(collect(keys(table))))

println("\n" * "="^60)
println("Parameter Estimation Complete!")
println("="^60)
println("\nResults saved to: ", result_file)
println("Number of solutions found: ", length(solutions_vector))
if !isempty(solutions_vector)
    println("\nBest solution:")
    best_sol = solutions_vector[1]
    println("  States: ", best_sol.states)
    println("  Parameters: ", best_sol.parameters)
    println("  Error metrics:")
    println("    Best error: ", besterror)
    println("    Min error: ", best_min_error)
    println("    Mean error: ", best_mean_error)
    println("    Median error: ", best_median_error)
    println("    Max error: ", best_max_error)
    println("    Approximation error: ", best_approximation_error)
    println("    RMS error: ", best_rms_error)
end
