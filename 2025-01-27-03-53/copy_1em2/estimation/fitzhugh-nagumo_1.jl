using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "fitzhugh-nagumo_1"
@parameters g a b
@variables t V(t) R(t) y1(t)
D = Differential(t)
states = [V, R]
parameters = [g, a, b]
@named model = ODESystem([
                             D(V) ~ g * (V - V^3 / 3 + R),
                             D(R) ~ 1 / g * (V - a + b * R),
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ V,
]
ic = [0.66, 0.338]
p_true = [0.862, 0.458, 0.777]

p_constraints = Dict((g=>(-3.0, 3.0)), (a=>(-3.0, 3.0)), (b=>(-3.0, 3.0)))
ic_constraints = Dict((V=>(-3.0, 3.0)), (R=>(-3.0, 3.0)))
 
time_interval = [-1.0, 1.0]
datasize = 201

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-03-53/copy_1em2/data/fitzhugh-nagumo_1.csv", Tuple))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-03-53/copy_1em2/estimation_results/fitzhugh-nagumo_1.csv", table, header=string.(collect(keys(table))))

