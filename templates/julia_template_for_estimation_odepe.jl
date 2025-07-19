using Pkg; Pkg.activate({{julia_env_path}})

using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

using GaussianProcesses
using Statistics
using Optim, LineSearches

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

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read(joinpath(@__DIR__, "{{data_filepath}}"), Tuple, header=false))

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
 
meta, results = analyze_parameter_estimation_problem(
    pep,
    nooutput = true,
    shooting_points = 1
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
 
CSV.write(joinpath(@__DIR__, "result.csv"), table, header = string.(collect(keys(table))))

