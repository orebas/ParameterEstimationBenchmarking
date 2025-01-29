using ModelingToolkit, DifferentialEquations, Optimization, OptimizationPolyalgorithms,
      OptimizationOptimJL, SciMLSensitivity, ForwardDiff, Plots
using Distributions, Random, StaticArrays
using JLD2, FileIO

using CSV

solver = Vern9()

@parameters a b nu
@variables t S(t) E(t) In(t) NN(t) y1(t) y2(t)
D = Differential(t)
# TODO
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

ic = [0.212, 0.387, 0.85, 0.839]
p_true = [0.668, 0.242, 0.487]
time_interval = [-1.0, 1.0]
datasize = 1001

sampling_times = range(time_interval[1], time_interval[2], length = datasize)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-28-22-18/copy_0/data/seir_5.csv", Tuple, header=false))

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
    data = [(sol[3, :]), (sol[4, :])]
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
# optprob = Optimization.OptimizationProblem(optf, p_rand, lb = -3.0*ones(4+3), ub = 3.0*ones(4+3))
optprob = Optimization.OptimizationProblem(optf, p_rand, lb = 0.0*ones(4+3), ub = 1.0*ones(4+3))

@time result_ode = Optimization.solve(optprob, BFGS(), callback = callback, maxiters = 200000)

println(result_ode.u)

table = merge(
	      Dict(string(x) => [result_ode.u[i]] for (i,x) in enumerate(states)),
	      Dict(string(x) => [result_ode.u[length(states)+i]] for (i,x) in enumerate(parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-28-22-18/copy_0/estimation_results/seir_5.csv", table, header=string.(collect(keys(table))))

