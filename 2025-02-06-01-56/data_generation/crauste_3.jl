using ModelingToolkit, DifferentialEquations
using ODEParameterEstimation, Distributions
using OrderedCollections

solver = Vern9()


const t = ModelingToolkit.t_nounits
const D = ModelingToolkit.D_nounits

parameters = @parameters muN muEE muLE muLL muM muP muPE muPL deltaNE deltaEL deltaLM rhoE rhoP
states = @variables n(t) e(t) s(t) m(t) p(t) 
observables = @variables y1(t) y2(t) y3(t) y4(t)
p_true = [0.117, 0.707, 0.356, 0.407, 0.571, 0.765, 0.603, 0.798, 0.319, 0.738, 0.249, 0.862, 0.65]
ic = [0.272, 0.858, 0.685, 0.303, 0.271]

equations =             [
                             D(n) ~ -1 * n * muN - n * p * deltaNE,
                             D(e) ~ n * p * deltaNE - e * e * muEE - e * deltaEL + e * p * rhoE,
                             D(s) ~ s * deltaEL - s * deltaLM - s * s * muLL - e * s * muLE,
                             D(m) ~ s * deltaLM - muM * m,
                             D(p) ~ p * p * rhoP - p * muP - e * p * muPE - s * p * muPL,
                        ]


measured_quantities = [
        y1 ~ n,
        y2 ~ e,
        y3 ~ s+m,
        y4 ~ p,
]

model, mq = create_ordered_ode_system("", states, parameters, equations, measured_quantities)

PEP = ParameterEstimationProblem(
    "",
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
write("/home/orebas/julia/no-matlab-no-worry/2025-02-06-01-56/data/crauste_3.csv", dat_str)

