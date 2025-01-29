using ModelingToolkit, DifferentialEquations
using ParameterEstimation, Distributions
solver = Tsit5()

@parameters a b nu
@variables t S(t) E(t) In(t) NN(t) y1(t) y2(t)
D = Differential(t)
states = [S, E, In, NN]
parameters = [a, b, nu]
@named model = ODESystem([
                             D(S) ~ -b * S * In / NN,
                             D(E) ~ b * S * In / NN - nu * E,
                             D(In) ~ nu * E - a * In,
                             D(NN) ~ 0,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ In,
        y2 ~ NN,
]
ic = [0.871, 0.218, 0.306, 0.799]
p_true = [0.326, 0.372, 0.58]
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
write("/home/ademin/no-matlab-no-worry/2025-01-28-22-18/data/seir_6.csv", dat_str)

