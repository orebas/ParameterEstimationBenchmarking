# dump_pool.jl — harness-side full candidate-pool dump for the ranking study.
#
# Called from a (copied) benchmark cell script.jl AFTER the analyze call, where
# `raw_results`, `pep`, and `opts` are already bound. NO ODEParameterEstimation change.
#
#   raw_results[1] == solved_res  (the FULL pre-truncation pool; analysis_utils.jl:1002).
#   With branch_completion=false (M1), the pool is not replaced.
#
# Writes:
#   - pool.csv : one row per candidate — params/states/err/provenance/saturation_count +
#                truth-distance (EVAL ONLY: max/mean rel error on identifiable vars).
#   - pool.jls : Serialization of (trimmed real candidate vector + truth + bounds) so the
#                offline Julia harness can call the REAL ranking functions on real objects.
#
# err is the scaled-SSE the ranking sees (auto_rescale ON); params/states are un-rescaled
# physical, so truth-distance is in physical units. Both coherent for the study.

import ODEParameterEstimation
import Serialization

const _RS_OPE = ODEParameterEstimation

_rs_relerr(ev, tv) = abs(ev - tv) / max(abs(tv), 1e-12)
_rs_g(x) = x === nothing ? "" : string(x)

# max & mean relative error over IDENTIFIABLE params+states (exclude all_unidentifiable).
function _rs_truth_dist(c, pep)
	unid = (hasproperty(c, :all_unidentifiable) && c.all_unidentifiable !== nothing) ?
		   c.all_unidentifiable : Set{Any}()
	rels = Float64[]
	for (k, tv) in pep.p_true
		(k in unid) && continue
		haskey(c.parameters, k) || continue
		push!(rels, _rs_relerr(c.parameters[k], tv))
	end
	for (k, tv) in pep.ic
		(k in unid) && continue
		haskey(c.states, k) || continue
		push!(rels, _rs_relerr(c.states[k], tv))
	end
	isempty(rels) && return (NaN, NaN, 0)
	return (maximum(rels), sum(rels) / length(rels), length(rels))
end

function dump_pool(raw_results, pep, opts; csv_path::String, jls_path::String)
	pool = raw_results[1]
	pnames = collect(keys(pep.p_true))
	snames = collect(keys(pep.ic))

	header = vcat(
		["idx"],
		["p_" * string(p) for p in pnames],
		["s_" * string(s) for s in snames],
		["err", "max_rel_err", "mean_rel_err", "n_id_vars", "truth_near_1pct", "truth_near_10pct",
			"saturation_count", "source_type", "polish_source_hc_idx", "primary_method",
			"interpolator_source", "source_shooting_index", "source_candidate_index",
			"branch_size", "rescue_path", "pre_polish_error", "post_polish_error",
			"aggregation_strategy", "notes"],
	)

	open(csv_path, "w") do io
		println(io, join(header, ","))
		for (i, c) in enumerate(pool)
			prov = c.provenance
			sat = try
				_RS_OPE.saturation_count(c, opts.opt_lb, opts.opt_ub)
			catch
				""
			end
			mx, mn, nv = _rs_truth_dist(c, pep)
			row = String[string(i)]
			for p in pnames
				push!(row, haskey(c.parameters, p) ? string(c.parameters[p]) : "")
			end
			for s in snames
				push!(row, haskey(c.states, s) ? string(c.states[s]) : "")
			end
			push!(row, _rs_g(c.err))
			push!(row, string(mx))
			push!(row, string(mn))
			push!(row, string(nv))
			push!(row, string(isfinite(mx) && mx <= 0.01))
			push!(row, string(isfinite(mx) && mx <= 0.10))
			push!(row, string(sat))
			push!(row, _rs_g(prov.source_type))
			push!(row, _rs_g(prov.polish_source_hc_idx))
			push!(row, _rs_g(prov.primary_method))
			push!(row, _rs_g(prov.interpolator_source))
			push!(row, _rs_g(prov.source_shooting_index))
			push!(row, _rs_g(prov.source_candidate_index))
			push!(row, _rs_g(c.branch_size))
			push!(row, _rs_g(prov.rescue_path))
			push!(row, _rs_g(prov.pre_polish_error))
			push!(row, _rs_g(prov.post_polish_error))
			push!(row, _rs_g(prov.aggregation_strategy))
			push!(row, "\"" * join(string.(prov.notes), ";") * "\"")
			println(io, join(row, ","))
		end
	end

	# Serialize trimmed real candidate objects (drop the heavy/fragile ODE solution) so the
	# offline harness can call cluster_solutions / s2_sort_key / saturation_count on them.
	trimmed = map(pool) do c
		c2 = deepcopy(c)
		try
			c2.solution = nothing
		catch
		end
		c2
	end
	Serialization.serialize(jls_path, (
		pool = trimmed,
		p_true = pep.p_true,
		ic = pep.ic,
		opt_lb = opts.opt_lb,
		opt_ub = opts.opt_ub,
		name = pep.name,
	))

	# console summary
	errs = [c.err for c in pool if c.err !== nothing && isfinite(c.err)]
	nnear = count(c -> begin
		mx, _, _ = _rs_truth_dist(c, pep)
		isfinite(mx) && mx <= 0.01
	end, pool)
	println("[dump_pool] $(length(pool)) candidates → $csv_path + $jls_path")
	println("[dump_pool] truth-near(≤1%) candidates in pool: $nnear / $(length(pool))")
	if !isempty(errs)
		println("[dump_pool] err (SSE) range: $(minimum(errs)) … $(maximum(errs))")
	end
	return nothing
end
