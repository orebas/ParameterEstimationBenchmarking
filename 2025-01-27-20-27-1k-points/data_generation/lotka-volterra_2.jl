using ModelingToolkit, DifferentialEquations
using ParameterEstimation, Distributions
solver = Tsit5()

@parameters k1 k2 k3
@variables t r(t) w(t) y1(t)
D = Differential(t)
states = [r, w]
parameters = [k1, k2, k3]
@named model = ODESystem([
                             D(r) ~ k1*r - k2*r*w,
                             D(w) ~ k2*r*w - k3*w,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ r,
]
ic = [0.399, 0.471]
p_true = [0.121, 0.266, 0.44]
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
write("/home/ademin/no-matlab-no-worry/2025-01-27-20-27/data/lotka-volterra_2.csv", dat_str)

