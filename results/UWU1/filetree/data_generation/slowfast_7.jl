using Pkg; Pkg.activate(joinpath(dirname(dirname(dirname(dirname(@__DIR__)))), string(Symbol(:environments, /, :julia_odepe))))

using MKL

using ModelingToolkit, DifferentialEquations
using ODEParameterEstimation, Distributions
using OrderedCollections

solver = Vern9()


const t = ModelingToolkit.t_nounits
const D = ModelingToolkit.D_nounits

parameters = @parameters k1 k2 eB
states = @variables xA(t) xB(t) xC(t) eA(t) eC(t) 
observables = @variables y1(t) y2(t) y3(t) y4(t)
p_true = [0.242, 0.487, 0.212]
ic = [0.387, 0.85, 0.839, 0.326, 0.372]

equations =             [
                             D(xA) ~ -k1 * xA,
                             D(xB) ~ k1 * xA - k2 * xB,
                             D(xC) ~ k2 * xB,
                             D(eA) ~ 0,
                             D(eC) ~ 0,
                        ]


measured_quantities = [
        y1 ~ xC,
        y2 ~ eA * xA + eB * xB + eC * xC,
        y3 ~ eA,
        y4 ~ eC,
]

model, mq = create_ordered_ode_system("slowfast", states, parameters, equations, measured_quantities)

PEP = ParameterEstimationProblem(
    "slowfast",
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
write(joinpath(@__DIR__, "../data_original/slowfast_7.csv"), dat_str)

