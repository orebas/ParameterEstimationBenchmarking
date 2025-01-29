using ModelingToolkit, DifferentialEquations, Optimization, OptimizationPolyalgorithms,
      OptimizationOptimJL, SciMLSensitivity, ForwardDiff, Plots
using Distributions, Random, StaticArrays
using JLD2, FileIO

using CSV

solver = Vern9()

@parameters k01 k12 k13 k14 k21 k31 k41
@variables t x1(t) x2(t) x3(t) x4(t) y1(t) y2(t) y3(t)
D = Differential(t)
# TODO
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

ic = [0.668, 0.264, 0.373, 0.641]
p_true = [0.303, 0.457, 0.184, 0.379, 0.692, 0.644, 0.598]
time_interval = [-1.0, 1.0]
datasize = 1001

sampling_times = range(time_interval[1], time_interval[2], length = datasize)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-28-22-18/copy_1em4/data/daisy-mamil4_8.csv", Tuple, header=false))

# p_rand = rand(Uniform(-3.0, 3.0), length(ic) + length(p_true)) # Random Parameters
p_rand = rand(Uniform(0.0, 1.0), length(ic) + length(p_true)) # Random Parameters
prob = ODEProblem(complete(model), ic, time_interval, p_true)
sol = solve(remake(prob, u0 = p_rand[1:length(ic)]), solver,
            p = p_rand[(length(ic) + 1):end],
            saveat = sampling_times;
            abstol = 1e-13, reltol = 1e-13)

function loss(p)
    sol = solve(remake(prob; u0 = p[1:length(ic)]), Tsit5(), p = p[(length(ic) + 1):end],
                saveat = sampling_times;
                abstol = 1e-13, reltol = 1e-13)
    data_true = [data_sample[v.rhs] for v in measured_quantities]
    data = [(sol[1, :]), (sol[2, :]), (sol[3, :] + sol[4, :])]
    if sol.retcode == ReturnCode.Success
        loss = sum(sum((data[i] .- data_true[i]) .^ 2) for i in eachindex(data))
        return loss
    else
        return Inf
    end
end

callback = function (p, l)
    return false
end

adtype = Optimization.AutoZygote()
optf = Optimization.OptimizationFunction((x, p) -> loss(x), adtype)
# optprob = Optimization.OptimizationProblem(optf, p_rand, lb = -3.0*ones(4+7), ub = 3.0*ones(4+7))
optprob = Optimization.OptimizationProblem(optf, p_rand, lb = 0.0*ones(4+7), ub = 1.0*ones(4+7))

@time result_ode = Optimization.solve(optprob, BFGS(), callback = callback, maxiters = 200000)

println(result_ode.u)

table = merge(
	      Dict(string(x) => [result_ode.u[i]] for (i,x) in enumerate(states)),
	      Dict(string(x) => [result_ode.u[length(states)+i]] for (i,x) in enumerate(parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-28-22-18/copy_1em4/estimation_results/daisy-mamil4_8.csv", table, header=string.(collect(keys(table))))

