using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "vanderpol_0"
@parameters a b
@variables t x1(t) x2(t) y1(t) y2(t)
D = Differential(t)
states = [x1, x2]
parameters = [a, b]
@named model = ODESystem([
                             D(x1) ~ a * x2,
                             D(x2) ~ -(x1) - b * (x1^2 - 1) * (x2),
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ x1,
        y2 ~ x2,
]
ic = [0.664, 0.125]
p_true = [0.376, 0.842]

p_constraints = Dict((a=>(, )), (b=>(, )))
ic_constraints = Dict((x1=>(, )), (x2=>(, )))
 
time_interval = [-1.0, 1.0]
datasize = 201

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-03-40/copy_1em6/data/vanderpol_0.csv", Tuple))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-03-40/copy_1em6/estimation_results/vanderpol_0.csv", table, header=string.(collect(keys(table))))

