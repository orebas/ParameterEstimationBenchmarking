using Pkg; Pkg.activate(joinpath(dirname(dirname(dirname(dirname(@__DIR__)))), string(Symbol(:environments, /, :julia_odepe))))

using MKL

using ModelingToolkit, DifferentialEquations
using ODEParameterEstimation, Distributions
using OrderedCollections

solver = Vern9()


const t = ModelingToolkit.t_nounits
const D = ModelingToolkit.D_nounits

parameters = @parameters k01 k12 k13 k14 k21 k31 k41
states = @variables x1(t) x2(t) x3(t) x4(t) 
observables = @variables y1(t) y2(t) y3(t)
p_true = [0.25, 0.823, 0.535, 0.466, 0.806, 0.467, 0.679]
ic = [0.419, 0.823, 0.652, 0.66]

equations =             [
                             D(x1) ~ -k01 * x1 + k12 * x2 + k13 * x3 + k14 * x4 - k21 * x1 - k31 * x1 - k41 * x1,
                             D(x2) ~ -k12 * x2 + k21 * x1,
                             D(x3) ~ -k13 * x3 + k31 * x1,
                             D(x4) ~ -k14 * x4 + k41 * x1,
                        ]


measured_quantities = [
        y1 ~ x1,
        y2 ~ x2,
        y3 ~ x3 + x4,
]

model, mq = create_ordered_ode_system("daisy_mamil4", states, parameters, equations, measured_quantities)

PEP = ParameterEstimationProblem(
    "daisy_mamil4",
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
write(joinpath(@__DIR__, "../data_original/daisy_mamil4_0.csv"), dat_str)

