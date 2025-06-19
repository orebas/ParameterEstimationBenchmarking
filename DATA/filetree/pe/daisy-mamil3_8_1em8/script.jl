using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "daisy-mamil3"
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
ic = [0.126, 0.112, 0.443]
p_true = [0.796, 0.463, 0.361, 0.286, 0.592]

p_constraints = Dict((a12=>(0.0, 1.0)), (a13=>(0.0, 1.0)), (a21=>(0.0, 1.0)), (a31=>(0.0, 1.0)), (a01=>(0.0, 1.0)))
ic_constraints = Dict((x1=>(0.0, 1.0)), (x2=>(0.0, 1.0)), (x3=>(0.0, 1.0)))
 
time_interval = [-1.0, 1.0]
datasize = 1001

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read(joinpath(@__DIR__, "data.csv"), Tuple, header=false))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write(joinpath(@__DIR__, "result.csv"), table, header=string.(collect(keys(table))))

