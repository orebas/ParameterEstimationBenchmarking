using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "seir_0"
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
ic = [0.194, 0.514, 0.206, 0.673]
p_true = [0.322, 0.569, 0.791]

p_constraints = Dict((a=>(-3.0, 3.0)), (b=>(-3.0, 3.0)), (nu=>(-3.0, 3.0)))
ic_constraints = Dict((S=>(-3.0, 3.0)), (E=>(-3.0, 3.0)), (In=>(-3.0, 3.0)), (NN=>(-3.0, 3.0)))
 
time_interval = [-1.0, 1.0]
datasize = 201

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-13-20/copy_0/data/seir_0.csv", Tuple))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-13-20/copy_0/estimation_results/seir_0.csv", table, header=string.(collect(keys(table))))

