using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "hiv_0"
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
ic = [0.684, 0.35, 0.419, 0.268, 0.249]
p_true = [0.664, 0.125, 0.232, 0.597, 0.562, 0.29, 0.847, 0.591, 0.529, 0.572]

p_constraints = Dict((lm=>(-3.0, 3.0)), (d=>(-3.0, 3.0)), (beta=>(-3.0, 3.0)), (a=>(-3.0, 3.0)), (k=>(-3.0, 3.0)), (uu=>(-3.0, 3.0)), (c=>(-3.0, 3.0)), (q=>(-3.0, 3.0)), (b=>(-3.0, 3.0)), (h=>(-3.0, 3.0)))
ic_constraints = Dict((x=>(-3.0, 3.0)), (yy=>(-3.0, 3.0)), (vv=>(-3.0, 3.0)), (w=>(-3.0, 3.0)), (z=>(-3.0, 3.0)))
 
time_interval = [-1.0, 1.0]
datasize = 201

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-13-20/copy_1em2/data/hiv_0.csv", Tuple))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-13-20/copy_1em2/estimation_results/hiv_0.csv", table, header=string.(collect(keys(table))))

