using ModelingToolkit, DifferentialEquations
using ParameterEstimation, Distributions
solver = Tsit5()

@parameters lm d beta a k uu c q b h
@variables t x(t) yy(t) vv(t) w(t) z(t) y1(t) y2(t) y3(t) y4(t)
D = Differential(t)
states = [x, yy, vv, w, z]
parameters = [lm, d, beta, a, k, uu, c, q, b, h]
@named model = ODESystem([
                             D(x) ~ lm - d * x - beta * x * vv,
                             D(yy) ~ beta * x * vv - a * yy,
                             D(vv) ~ k * yy - uu * vv,
                             D(w) ~ c * x * yy * w - c * q * yy * w - b * w,
                             D(z) ~ c * q * yy * w - h * z,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ w,
        y2 ~ z,
        y3 ~ x,
        y4 ~ yy+vv,
]
ic = [0.218, 0.648, 0.625, 0.79, 0.178]
p_true = [0.867, 0.194, 0.186, 0.572, 0.696, 0.779, 0.849, 0.887, 0.42, 0.404]
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
write("/home/ademin/no-matlab-no-worry/2025-01-28-22-18/data/hiv_1.csv", dat_str)

