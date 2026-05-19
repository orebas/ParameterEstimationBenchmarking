using Pkg; Pkg.activate(raw"/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")
using StructuralIdentifiability

println("=" ^ 80)
println("seir")
println("=" ^ 80)
ode_seir = StructuralIdentifiability.@ODEmodel(
    S'(t) = (-15840.0*b*In(t)*S(t)) / (3960000.0*Npop(t)),
    E'(t) = ((15840.0*b*In(t)*S(t)) / (2000.0*Npop(t)) - 6.0*nu*E(t)) / 20.0,
    In'(t) = (-4.0*a*In(t) + 6.0*nu*E(t)) / 10.0,
    Npop'(t) = 0,
    y1(t) = 10.0*In(t),
    y2(t) = 2000.0*Npop(t)
)
try
    res = StructuralIdentifiability.assess_identifiability(ode_seir; loglevel=Logging.Warn)
    for (k, v) in res
        println("  $k => $v")
    end
catch e
    println("ERROR: $e")
end

println()
println("=" ^ 80)
println("slow_fast")
println("=" ^ 80)
# slow_fast definition from systems.json
# states: xA, xB, xC, eA, eB, eC; params: k1, k2; measurements involve eA,eB,eC,xC
# Let me get the exact equations from the script.jl
println("(see separate script)")

println()
println("=" ^ 80)
println("daisy_mamil4")
println("=" ^ 80)
println("(see separate script)")

println()
println("DONE_SEIR")
