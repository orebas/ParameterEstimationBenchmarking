using ModelingToolkit, DifferentialEquations
using ParameterEstimation, Distributions
solver = Tsit5()

@parameters muN muEE muLE muLL muM muP muPE muPL deltaNE deltaEL deltaLM rhoE rhoP
@variables t n(t) e(t) s(t) m(t) p(t) y1(t) y2(t) y3(t) y4(t)
D = Differential(t)
states = [n, e, s, m, p]
parameters = [muN, muEE, muLE, muLL, muM, muP, muPE, muPL, deltaNE, deltaEL, deltaLM, rhoE, rhoP]
@named model = ODESystem([
                             D(n) ~ -1 * n * muN - n * p * deltaNE,
                             D(e) ~ n * p * deltaNE - e * e * muEE - e * deltaEL + e * p * rhoE,
                             D(s) ~ s * deltaEL - s * deltaLM - s * s * muLL - e * s * muLE,
                             D(m) ~ s * deltaLM - muM * m,
                             D(p) ~ p * p * rhoP - p * muP - e * p * muPE - s * p * muPL,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ n,
        y2 ~ e,
        y3 ~ s+m,
        y4 ~ p,
]
ic = [0.843, 0.355, 0.634, 0.205, 0.673]
p_true = [0.326, 0.196, 0.337, 0.195, 0.354, 0.431, 0.151, 0.654, 0.553, 0.312, 0.519, 0.175, 0.561]
time_interval = [-1.0, 1.0]
datasize = 1001

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
for i=1:1001
  global dat_str = dat_str * string(data_sample["t"][i]) * ", " * join(collect(data_sample[ks[j]][i] for j=1:(length(ks)-1)), ", ") * "\n"
end
write("/home/ademin/no-matlab-no-worry/2025-01-27-20-27/data/crauste_2.csv", dat_str)

