using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "biohydrogenation_0"
@parameters k5 k6 k7 k8 k9 k10
@variables t x4(t) x5(t) x6(t) x7(t) y1(t) y2(t)
D = Differential(t)
states = [x4, x5, x6, x7]
parameters = [k5, k6, k7, k8, k9, k10]
@named model = ODESystem([
                             D(x4) ~ - k5 * x4 / (k6 + x4),
                             D(x5) ~ k5 * x4 / (k6 + x4) - k7 * x5/(k8 + x5 + x6),
                             D(x6) ~ k7 * x5 / (k8 + x5 + x6) - k9 * x6 * (k10 - x6) / k10,
                             D(x7) ~ k9 * x6 * (k10 - x6) / k10,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ x4,
        y2 ~ x5,
]
ic = [0.45, 0.813, 0.871, 0.407]
p_true = [0.539, 0.672, 0.582, 0.536, 0.439, 0.617]

p_constraints = Dict((k5=>(-3.0, 3.0)), (k6=>(-3.0, 3.0)), (k7=>(-3.0, 3.0)), (k8=>(-3.0, 3.0)), (k9=>(-3.0, 3.0)), (k10=>(-3.0, 3.0)))
ic_constraints = Dict((x4=>(-3.0, 3.0)), (x5=>(-3.0, 3.0)), (x6=>(-3.0, 3.0)), (x7=>(-3.0, 3.0)))
 
time_interval = [-1.0, 1.0]
datasize = 201

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-03-53/copy_1em6/data/biohydrogenation_0.csv", Tuple))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-03-53/copy_1em6/estimation_results/biohydrogenation_0.csv", table, header=string.(collect(keys(table))))

