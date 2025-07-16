using ModelingToolkit, DifferentialEquations
using ODEParameterEstimation, Distributions
using OrderedCollections

solver = Vern9()


const t = ModelingToolkit.t_nounits
const D = ModelingToolkit.D_nounits

parameters = @parameters k1 k2 k3
states = @variables r(t) w(t) 
observables = @variables y1(t)
p_true = [0.225, 0.343, 0.16]
ic = [0.44, 0.186]

equations =             [
                             D(r) ~ k1*r - k2*r*w,
                             D(w) ~ k2*r*w - k3*w,
                        ]


measured_quantities = [
        y1 ~ r,
]

model, mq = create_ordered_ode_system("lotka_volterra", states, parameters, equations, measured_quantities)

PEP = ParameterEstimationProblem(
    "lotka_volterra",
    model,
    mq,
    nothing,
    [-1.0, 1.0],
    nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0,
)

estimation_problem_with_data = sample_problem_data(PEP, datasize = 1001, time_interval = [-1.0, 1.0], noise_level = 0.000)



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
for i=1:1001
  global dat_str = dat_str * string(data_sample["t"][i]) * ", " * join(collect(data_sample[ks[j]][i] for j=1:(length(ks)-1)), ", ") * "\n"
end
write(joinpath(@__DIR__, "../data_original/lotka_volterra_3.csv"), dat_str)

