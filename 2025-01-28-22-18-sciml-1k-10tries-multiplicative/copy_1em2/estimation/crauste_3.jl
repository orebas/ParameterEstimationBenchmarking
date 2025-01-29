using ModelingToolkit, DifferentialEquations, Optimization, OptimizationPolyalgorithms,
      OptimizationOptimJL, SciMLSensitivity, ForwardDiff, Plots
using Distributions, Random, StaticArrays
using JLD2, FileIO

using CSV

solver = Vern9()

@parameters muN muEE muLE muLL muM muP muPE muPL deltaNE deltaEL deltaLM rhoE rhoP
@variables t n(t) e(t) s(t) m(t) p(t) y1(t) y2(t) y3(t) y4(t)
D = Differential(t)
# TODO
states = [n, e, s, m, p]
parameters = [muN, muEE, muLE, muLL, muM, muP, muPE, muPL, deltaNE, deltaEL, deltaLM, rhoE, rhoP]
@named model = ODESystem([
                             D(n) ~ -1 * n * muN - n * p * deltaNE,
                             D(e) ~ n * p * deltaNE - e * e * muEE - e * deltaEL + e * p * rhoE,
                             D(s) ~ s * deltaEL - s * deltaLM - s * s * muLL - e * s * muLE,
                             D(m) ~ s * deltaLM - muM * m,
                             D(p) ~ p * p * rhoP - p * muP - e * p * muPE - s * p * muPL,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ n,
        y2 ~ e,
        y3 ~ s+m,
        y4 ~ p,
]

ic = [0.272, 0.858, 0.685, 0.303, 0.271]
p_true = [0.117, 0.707, 0.356, 0.407, 0.571, 0.765, 0.603, 0.798, 0.319, 0.738, 0.249, 0.862, 0.65]
time_interval = [-1.0, 1.0]
datasize = 1001

sampling_times = range(time_interval[1], time_interval[2], length = datasize)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read("/home/ademin/no-matlab-no-worry/2025-01-28-22-18/copy_1em2/data/crauste_3.csv", Tuple, header=false))

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
    data = [(sol[1, :]), (sol[2, :]), (sol[3, :] .+ sol[4, :]), (sol[5, :])]
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
# optprob = Optimization.OptimizationProblem(optf, p_rand, lb = -3.0*ones(5+13), ub = 3.0*ones(5+13))
optprob = Optimization.OptimizationProblem(optf, p_rand, lb = 0.0*ones(5+13), ub = 1.0*ones(5+13))

@time result_ode = Optimization.solve(optprob, BFGS(), callback = callback, maxiters = 200000)

println(result_ode.u)

table = merge(
	      Dict(string(x) => [result_ode.u[i]] for (i,x) in enumerate(states)),
	      Dict(string(x) => [result_ode.u[length(states)+i]] for (i,x) in enumerate(parameters))
)

CSV.write("/home/ademin/no-matlab-no-worry/2025-01-28-22-18/copy_1em2/estimation_results/crauste_3.csv", table, header=string.(collect(keys(table))))

