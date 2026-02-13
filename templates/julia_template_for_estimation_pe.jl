using Pkg; Pkg.activate({{{julia_env_path}}})

using MKL

using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "{{name}}"
@parameters {{#parameters}}{{varname}}{{space}}{{/parameters}}
@variables t {{#states}}{{varname}}(t){{space}}{{/states}} {{#measurements}}{{varname}}(t){{space}}{{/measurements}}
D = Differential(t)
states = [{{#states}}{{varname}}{{comma}}{{/states}}]
parameters = [{{#parameters}}{{varname}}{{comma}}{{/parameters}}]
@named model = ODESystem([
                            {{#components}}
                             D({{state_var}}) ~ {{state_expr}},
                            {{/components}}
                         ], t, states, parameters)
measured_quantities = [
    {{#measured_quantities}}
        {{measurement}} ~ {{measurement_expression}},
    {{/measured_quantities}}
]
ic = [{{#initial_conditions}}{{value}}{{comma}}{{/initial_conditions}}]
p_true = [{{#parameters}}{{true}}{{comma}}{{/parameters}}]

p_constraints = Dict({{#parameters}}({{varname}}=>({{lower_bound}}, {{upper_bound}})){{comma}}{{/parameters}})
ic_constraints = Dict({{#states}}({{varname}}=>({{lower_bound}}, {{upper_bound}})){{comma}}{{/states}})
 
time_interval = [{{time_start}}, {{time_end}}]
datasize = {{time_count}}

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read(joinpath(@__DIR__, "{{data_filepath}}"), Tuple, header=false))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write(joinpath(@__DIR__, "{{estimation_result_filepath}}"), table, header=string.(collect(keys(table))))

