using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "daisy-mamil3_0"
@parameters a12 a13 a21 a31 a01
@variables t x1(t) x2(t) x3(t) y1(t) y2(t)
D = Differential(t)
states = [x1, x2, x3]
parameters = [a12, a13, a21, a31, a01]
@named model = ODESystem([
                             D(x1) ~ -(a21 + a31 + a01) * x1 + a12 * x2 + a13 * x3,
                             D(x2) ~ a21 * x1 - a12 * x2,
                             D(x3) ~ a31 * x1 - a13 * x3,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ x1,
        y2 ~ x2,
]
ic = [0.475, 0.881, 0.584]
p_true = [0.757, 0.178, 0.77, 0.177, 0.881]

p_constraints = Dict((a12=>(, )), (a13=>(, )), (a21=>(, )), (a31=>(, )), (a01=>(, )))
ic_constraints = Dict((x1=>(, )), (x2=>(, )), (x3=>(, )))
 
time_interval = [-1.0, 1.0]
datasize = 201

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-03-40/copy_1em8/data/daisy-mamil3_0.csv", Tuple))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-03-40/copy_1em8/estimation_results/daisy-mamil3_0.csv", table, header=string.(collect(keys(table))))

