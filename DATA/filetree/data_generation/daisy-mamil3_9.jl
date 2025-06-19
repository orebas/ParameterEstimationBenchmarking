using ModelingToolkit, DifferentialEquations
using ODEParameterEstimation, Distributions
using OrderedCollections

solver = Vern9()


const t = ModelingToolkit.t_nounits
const D = ModelingToolkit.D_nounits

parameters = @parameters a12 a13 a21 a31 a01
states = @variables x1(t) x2(t) x3(t) 
observables = @variables y1(t) y2(t)
p_true = [0.154, 0.302, 0.277, 0.303, 0.205]
ic = [0.11, 0.192, 0.595]

equations =             [
                             D(x1) ~ -(a21 + a31 + a01) * x1 + a12 * x2 + a13 * x3,
                             D(x2) ~ a21 * x1 - a12 * x2,
                             D(x3) ~ a31 * x1 - a13 * x3,
                        ]


measured_quantities = [
        y1 ~ x1,
        y2 ~ x2,
]

model, mq = create_ordered_ode_system("daisy-mamil3", states, parameters, equations, measured_quantities)

PEP = ParameterEstimationProblem(
    "daisy-mamil3",
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
write(joinpath(@__DIR__, "../data_original/daisy-mamil3_9.csv"), dat_str)

