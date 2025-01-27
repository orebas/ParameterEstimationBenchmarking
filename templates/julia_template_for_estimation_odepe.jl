using ODEParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV

solver = Vern9()

name = "{{name}}"
@parameters {{#parameters}}{{varname}} {{/parameters}}
@variables {{#states}}{{varname}}(t){{space}}{{/states}} {{#measurements}}{{varname}}(t){{space}}{{/measurements}}
states = [{{#states}}{{varname}}{{comma}}{{/states}}]
parameters = [{{#parameters}}{{varname}}{{comma}}{{/parameters}}]
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

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("{{data_filepath}}", Tuple))

pep = ParameterEstimationProblem(
    name,
    model,
    mq,
    data_sample,
    time_interval,
    nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0
)

res = analyze_parameter_estimation_problem(
    pep,
    test_mode = false,
    nooutput = true,
    interpolator = aaad
)

analysis_result, besterror = analyze_estimation_result(
    pep,
    res,
    nooutput = true
)

table = merge(
    Dict((string(x) => [each.states[x] for each in analysis_result] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in analysis_result] for x in parameters))
)

CSV.write("{{estimation_result_filepath}}", table, header=string.(collect(keys(table))))

