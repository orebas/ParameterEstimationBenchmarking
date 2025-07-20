using Pkg; Pkg.activate(joinpath(dirname(dirname(dirname(dirname(@__DIR__)))), string(:julia_env)))

using ModelingToolkit, DifferentialEquations, Optimization, OptimizationPolyalgorithms,
      OptimizationOptimJL, SciMLSensitivity, ForwardDiff
using Distributions, Random, StaticArrays

using CSV

solver = Vern9()

@parameters k1 k2 k3
@variables t r(t) w(t) y1(t)
D = Differential(t)
# TODO
states = [r, w]
parameters = [k1, k2, k3]
@named model = ODESystem([
                             D(r) ~ k1*r - k2*r*w,
                             D(w) ~ k2*r*w - k3*w,
                         ], t, states, parameters)
measured_quantities = [
        y1 ~ r,
]

ic = [0.818, 0.716]
p_true = [0.667, 0.863, 0.382]
time_interval = [-1.0, 1.0]
datasize = 1001

sampling_times = range(time_interval[1], time_interval[2], length = datasize)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read(joinpath(@__DIR__, "data.csv"), Tuple, header=false))

# p_rand = rand(Uniform(0.0, 1.0), length(ic) + length(p_true)) # Random Parameters
p_rand = rand(Uniform(0.0, 1.0), length(ic) + length(p_true)) # Random Parameters
prob = ODEProblem(complete(model), ic, time_interval, p_true)
sol = solve(remake(prob, u0 = p_rand[1:length(ic)], p = Dict(parameters .=> p_rand[(length(ic) + 1):end])), solver,
            saveat = sampling_times;
            abstol = 1e-13, reltol = 1e-13)

function loss(p)
    sol = solve(remake(prob; u0 = p[1:length(ic)], p = Dict(parameters .=> p[(length(ic) + 1):end])), Tsit5(),
                saveat = sampling_times;
                abstol = 1e-13, reltol = 1e-13)
    data_true = [data_sample[v.rhs] for v in measured_quantities]
    data = [sol[1, :]]
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

adtype = Optimization.AutoForwardDiff() # Optimization.AutoZygote()
optf = Optimization.OptimizationFunction((x, p) -> loss(x), adtype)
# optprob = Optimization.OptimizationProblem(optf, p_rand, lb = 0.0*ones(2+3), ub = 1.0*ones(2+3))
optprob = Optimization.OptimizationProblem(optf, p_rand, lb = 0.0*ones(2+3), ub = 1.0*ones(2+3))

@time result_ode = Optimization.solve(optprob, BFGS(), callback = callback, maxiters = 200000)

println(result_ode.u)

table = merge(
	      Dict(string(x) => [result_ode.u[i]] for (i,x) in enumerate(states)),
	      Dict(string(x) => [result_ode.u[length(states)+i]] for (i,x) in enumerate(parameters))
)

CSV.write(joinpath(@__DIR__, "result.csv"), table, header=string.(collect(keys(table))))

