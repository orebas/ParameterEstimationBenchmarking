using ParameterEstimation
using ModelingToolkit, DifferentialEquations
using BenchmarkTools
using CSV

solver = Tsit5()

name = "daisy-mamil4_0"
@parameters k01 k12 k13 k14 k21 k31 k41
@variables t x1(t) x2(t) x3(t) x4(t) y1(t) y2(t) y3(t)
D = Differential(t)
states = [x1, x2, x3, x4]
parameters = [k01, k12, k13, k14, k21, k31, k41]
@named model = ODESystem([
                             D(x1) ~ -k01 * x1 + k12 * x2 + k13 * x3 + k14 * x4 - k21 * x1 - k31 * x1 - k41 * x1,
                             D(x2) ~ -k12 * x2 + k21 * x1,
                             D(x3) ~ -k13 * x3 + k31 * x1,
                             D(x4) ~ -k14 * x4 + k41 * x1,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ x1,
        y2 ~ x2,
        y3 ~ x3 + x4,
]
ic = [0.585, 0.115, 0.341, 0.628]
p_true = [0.805, 0.654, 0.68, 0.501, 0.865, 0.615, 0.439]

p_constraints = Dict((k01=>(-3.0, 3.0)), (k12=>(-3.0, 3.0)), (k13=>(-3.0, 3.0)), (k14=>(-3.0, 3.0)), (k21=>(-3.0, 3.0)), (k31=>(-3.0, 3.0)), (k41=>(-3.0, 3.0)))
ic_constraints = Dict((x1=>(-3.0, 3.0)), (x2=>(-3.0, 3.0)), (x3=>(-3.0, 3.0)), (x4=>(-3.0, 3.0)))
 
time_interval = [-1.0, 1.0]
datasize = 201

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-27-13-20/copy_1em8/data/daisy-mamil4_0.csv", Tuple))

@time res = ParameterEstimation.estimate(model, measured_quantities, data_sample;
            solver = solver, interpolators = Dict("AAA" => ParameterEstimation.aaad), parameter_constraints = p_constraints, ic_constraints = ic_constraints)

table = merge(
    Dict((string(x) => [each.states[x] for each in res] for x in states)),
    Dict((string(x) => [each.parameters[x] for each in res] for x in parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-27-13-20/copy_1em8/estimation_results/daisy-mamil4_0.csv", table, header=string.(collect(keys(table))))

