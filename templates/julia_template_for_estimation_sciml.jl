using ModelingToolkit, DifferentialEquations, Optimization, OptimizationPolyalgorithms,
      OptimizationOptimJL, SciMLSensitivity, ForwardDiff, Plots
using Distributions, Random, StaticArrays
using JLD2, FileIO

using CSV

solver = Vern9()

@parameters {{#parameters}}{{varname}}{{space}}{{/parameters}}
@variables t {{#states}}{{varname}}(t){{space}}{{/states}} {{#measurements}}{{varname}}(t){{space}}{{/measurements}}
D = Differential(t)
# TODO
states = [{{#states}}{{varname}}{{comma}}{{/states}}]
parameters = [{{#parameters}}{{varname}}{{comma}}{{/parameters}}]
@named model = ODESystem([
                            {{#components}}
                             D({{state_var}}) ~ {{state_expr}},
                            {{/components}}
                         ], t, states, parameters)
measured_quantities = [
    {{#measured_quantities}}
        {{measurement}} ~ {{measurement_expression}},
    {{/measured_quantities}}
]

ic = [{{#initial_conditions}}{{value}}{{comma}}{{/initial_conditions}}]
p_true = [{{#parameters}}{{true}}{{comma}}{{/parameters}}]
time_interval = [{{time_start}}, {{time_end}}]
datasize = {{time_count}}

sampling_times = range(time_interval[1], time_interval[2], length = datasize)

data_sample = Dict(vcat("t", map(x -> x.rhs, measured_quantities)) .=> CSV.read(joinpath(@__DIR__, "{{data_filepath}}"), Tuple, header=false))

# p_rand = rand(Uniform({{lower_bound}}, {{upper_bound}}), length(ic) + length(p_true)) # Random Parameters
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
    data = [{{data_expr}}]
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
# optprob = Optimization.OptimizationProblem(optf, p_rand, lb = {{lower_bound}}*ones({{num_states}}+{{num_parameters}}), ub = {{upper_bound}}*ones({{num_states}}+{{num_parameters}}))
optprob = Optimization.OptimizationProblem(optf, p_rand, lb = 0.0*ones({{num_states}}+{{num_parameters}}), ub = 1.0*ones({{num_states}}+{{num_parameters}}))

@time result_ode = Optimization.solve(optprob, BFGS(), callback = callback, maxiters = 200000)

println(result_ode.u)

table = merge(
	      Dict(string(x) => [result_ode.u[i]] for (i,x) in enumerate(states)),
	      Dict(string(x) => [result_ode.u[length(states)+i]] for (i,x) in enumerate(parameters))
)

CSV.write(joinpath(@__DIR__, "{{estimation_result_filepath}}"), table, header=string.(collect(keys(table))))

