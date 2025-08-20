using Pkg; Pkg.activate(joinpath(dirname(dirname(dirname(dirname(@__DIR__)))), string(Symbol(:environments, /, :julia_odepe))))

using MKL

using ModelingToolkit, DifferentialEquations
using ODEParameterEstimation, Distributions
using OrderedCollections

solver = Vern9()


const t = ModelingToolkit.t_nounits
const D = ModelingToolkit.D_nounits

parameters = @parameters lm d beta a k uu c q b h
states = @variables x(t) yy(t) vv(t) w(t) z(t) 
observables = @variables y1(t) y2(t) y3(t) y4(t)
p_true = [0.802, 0.398, 0.101, 0.298, 0.355, 0.787, 0.467, 0.456, 0.369, 0.805]
ic = [0.856, 0.894, 0.401, 0.873, 0.734]

equations =             [
                             D(x) ~ lm - d * x - beta * x * vv,
                             D(yy) ~ beta * x * vv - a * yy,
                             D(vv) ~ k * yy - uu * vv,
                             D(w) ~ c * x * yy * w - c * q * yy * w - b * w,
                             D(z) ~ c * q * yy * w - h * z,
                        ]


measured_quantities = [
        y1 ~ w,
        y2 ~ z,
        y3 ~ x,
        y4 ~ yy+vv,
]

model, mq = create_ordered_ode_system("hiv", states, parameters, equations, measured_quantities)

PEP = ParameterEstimationProblem(
    "hiv",
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
write(joinpath(@__DIR__, "../data_original/hiv_9.csv"), dat_str)

