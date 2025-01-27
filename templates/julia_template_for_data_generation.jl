using ModelingToolkit, DifferentialEquations
using ParameterEstimation, Distributions
solver = Tsit5()

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
time_interval = [{{time_start}}, {{time_end}}]
datasize = {{time_count}}

data_sample = ParameterEstimation.sample_data(model, measured_quantities, convert(Array{Float64},time_interval),
                                              p_true, ic, datasize; solver = solver)

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
write("{{data_filepath}}", dat_str)

