using Pkg; Pkg.activate({{julia_env_path}})

using ModelingToolkit, DifferentialEquations
using ODEParameterEstimation, Distributions
using OrderedCollections

solver = Vern9()


const t = ModelingToolkit.t_nounits
const D = ModelingToolkit.D_nounits

parameters = @parameters {{#parameters}}{{varname}}{{space}}{{/parameters}}
states = @variables {{#states}}{{varname}}(t){{space}}{{/states}} 
observables = @variables {{#measurements}}{{varname}}(t){{space}}{{/measurements}}
p_true = [{{#parameters}}{{true}}{{comma}}{{/parameters}}]
ic = [{{#initial_conditions}}{{value}}{{comma}}{{/initial_conditions}}]

equations =             [
                           {{#components}}
                             D({{state_var}}) ~ {{state_expr}},
                            {{/components}}
                        ]


measured_quantities = [
    {{#measured_quantities}}
        {{measurement}} ~ {{measurement_expression}},
    {{/measured_quantities}}
]

model, mq = create_ordered_ode_system("{{name}}", states, parameters, equations, measured_quantities)

PEP = ParameterEstimationProblem(
    "{{name}}",
    model,
    mq,
    nothing,
    [{{time_start}}, {{time_end}}],
    nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0,
)

estimation_problem_with_data = sample_problem_data(PEP, datasize = {{time_count}}, time_interval = [{{time_start}}, {{time_end}}], noise_level = 0.000)



data_sample = estimation_problem_with_data.data_sample

n = Normal(0.0, 1e-8)
for (key, value) in data_sample
	if key == "t"
		continue
	end
	# data_sample[key] = data_sample[key] .* (1. .+ rand(n, length(data_sample[key])))
end

ks = data_sample.keys
dat_str = ""
for i=1:{{time_count}}
  global dat_str = dat_str * string(data_sample["t"][i]) * ", " * join(collect(data_sample[ks[j]][i] for j=1:(length(ks)-1)), ", ") * "\n"
end
write(joinpath(@__DIR__, "{{data_filepath}}"), dat_str)

