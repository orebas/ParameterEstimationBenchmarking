# Fidelity check for the selection study: replay ranking schemes on a SAMPLE of final_v2 polish
# pool.jls using the REAL ODEPE ranking functions + the PRODUCTION cluster-rank path, to validate
# the candidate-level Python replay (replay_strategies.py). Ranking never sees truth.
#   julia --startup-file=no rank_study_finalv2.jl
import Serialization
import ODEParameterEstimation
const OPE = ODEParameterEstimation

_relerr(ev, tv) = abs(ev - tv) / max(abs(tv), 1e-12)
function truth_maxrel(c, p_true, ic)
    unid = (hasproperty(c, :all_unidentifiable) && c.all_unidentifiable !== nothing) ? c.all_unidentifiable : Set{Any}()
    rels = Float64[]
    for (k, tv) in p_true; (k in unid) && continue; haskey(c.parameters, k) || continue; push!(rels, _relerr(c.parameters[k], tv)); end
    for (k, tv) in ic;     (k in unid) && continue; haskey(c.states, k) || continue; push!(rels, _relerr(c.states[k], tv)); end
    isempty(rels) ? Inf : maximum(rels)
end
_err(c) = (c.err === nothing || !isfinite(c.err)) ? Inf : Float64(c.err)
_sat(c, lb, ub) = try OPE.saturation_count(c, lb, ub) catch; 0 end
const SCHEMES = [
    ("err_only",     (c, lb, ub) -> (_err(c),)),
    ("sat_err",      (c, lb, ub) -> (_sat(c, lb, ub), _err(c))),
    ("sat_neg1_err", (c, lb, ub) -> Tuple(OPE.s2_sort_key(c, lb, ub))),   # real production S2
]

function eval_cell(jls; thr = 0.01, topks = (1, 5, 10, 20))
    d = Serialization.deserialize(jls); pool = d.pool
    near = [truth_maxrel(c, d.p_true, d.ic) <= thr for c in pool]
    out = Dict{String, Any}()
    for (name, key) in SCHEMES
        order = sortperm(pool, by = c -> key(c, d.opt_lb, d.opt_ub))
        out[name] = (top1 = near[order[1]],
                     caps = Dict(k => any(near[order[i]] for i in 1:min(k, length(order))) for k in topks))
    end
    try
        opts = OPE.EstimationOptions(opt_lb = d.opt_lb, opt_ub = d.opt_ub)
        reps = OPE.ranked_candidate_representatives(d.pool, opts)
        rn = [truth_maxrel(r, d.p_true, d.ic) <= thr for r in reps]
        out["PRODUCTION(cluster+rank)"] = (top1 = (!isempty(rn) && rn[1]),
            caps = Dict(k => (!isempty(rn) && any(rn[1:min(k, length(rn))])) for k in topks))
    catch
        out["PRODUCTION(cluster+rank)"] = (top1 = false, caps = Dict(k => false for k in topks))
    end
    (n = length(pool), nnear = count(near), out = out)
end

FT = "/home/orebas/ParameterEstimationBenchmark-local/benchmark_final_v2_2026-06-12/filetree/odepe_v2_polish_run"
cells = sort(readdir(FT))
jls = String[]
for c in cells[1:12:end]                      # ~ every 12th cell
    p = joinpath(FT, c, "pool.jls"); isfile(p) && push!(jls, p)
end
println("sampling $(length(jls)) final_v2 polish pools (real ranking fns; threshold = 1% truth-near)...")
evals = [eval_cell(p) for p in jls]
ab = [e for e in evals if e.nnear > 0]
println("answer-bearing (pool has a <1% candidate): $(length(ab))/$(length(evals))\n")
names = ["err_only", "sat_err", "sat_neg1_err", "PRODUCTION(cluster+rank)"]
println(rpad("scheme", 26) * rpad("top1", 9) * rpad("top5", 9) * rpad("top10", 9) * rpad("top20", 9))
nb = length(ab)
for s in names
    pct(f) = "$(round(100 * count(f, ab) / nb, digits = 1))%"
    println(rpad(s, 26) * rpad(pct(e -> e.out[s].top1), 9) * rpad(pct(e -> e.out[s].caps[5]), 9) *
            rpad(pct(e -> e.out[s].caps[10]), 9) * rpad(pct(e -> e.out[s].caps[20]), 9))
end
println("\n(compare err_only top1 to replay_strategies.py's err_only top1<1%; PRODUCTION≈err_only confirms clustering is immaterial.)")
