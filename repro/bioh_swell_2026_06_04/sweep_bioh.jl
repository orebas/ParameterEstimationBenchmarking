# Sweep all blown bioh candidates through get_si_equation_system with a gcd wrapper that
# aborts+dumps the moment a gcd operand swells past ABORT_BITS. Finds WHICH candidate swells.
# Usage:  julia sweep_bioh.jl <offset> <count>

import Pkg
Pkg.activate(raw"/home/orebas/ParameterEstimationBenchmark-local/environments/julia_odepe")

using ODEParameterEstimation
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using Symbolics
using OrderedCollections
import Nemo

const QQMP = Nemo.QQMPolyRingElem
const ABORT_BITS = 5000
const DUMPDIR = raw"/home/orebas/ParameterEstimationBenchmark-local/repro/bioh_swell_2026_06_04"

_nb(z) = try Int(Nemo.nbits(z)) catch; ndigits(BigInt(z); base = 2) end
function _maxbits(p::QQMP)
	mb = 0; n = 0
	for c in Nemo.coefficients(p)
		mb = max(mb, _nb(Nemo.numerator(c)), _nb(Nemo.denominator(c))); n += 1; n >= 100 && break
	end
	mb
end

struct SwellHit <: Exception; a::QQMP; b::QQMP; ba::Int; bb::Int; end
const _CURMAX = Ref(0)
function Nemo.gcd(a::QQMP, b::QQMP)
	ba, bb = _maxbits(a), _maxbits(b); big = max(ba, bb)
	big > _CURMAX[] && (_CURMAX[] = big)
	big > ABORT_BITS && throw(SwellHit(a, b, ba, bb))
	Nemo.check_parent(a, b); z = parent(a)()
	r = @ccall Nemo.libflint.fmpq_mpoly_gcd(z::Ref{QQMP}, a::Ref{QQMP}, b::Ref{QQMP}, a.parent::Ref{Nemo.QQMPolyRing})::Cint
	r == 0 && error("gcd fail"); z
end

@parameters k5 k6 k7 k8 k9 k10
@variables x4(t) x5(t) x6(t) x7(t) y1(t) y2(t)
const EQS = [
	D(x4) ~ (-8.0 * k5 * x4) / (8.0 * (4.0 * k6 + 8.0 * x4)),
	D(x5) ~ ((-0.3 * k7 * x5) / (2.0 * k8 + 0.5 * x6 + 0.5 * x5) + (8.0 * k5 * x4) / (4.0 * k6 + 8.0 * x4)) / 0.5,
	D(x6) ~ ((-0.2 * (10.0 * k10 - 0.5 * x6) * k9 * x6) / (10.0 * k10) + (0.3 * k7 * x5) / (2.0 * k8 + 0.5 * x6 + 0.5 * x5)) / 0.5,
	D(x7) ~ (0.2 * (10.0 * k10 - 0.5 * x6) * k9 * x6) / (5.0 * k10),
]
const MQ = ModelingToolkit.Equation[y1 ~ 8.0 * x4, y2 ~ 0.5 * x5]

function run_cand(c)
	subst = Dict(k5 => c.k5, k6 => c.k6, k7 => c.k7, k8 => c.k8, k9 => c.k9, k10 => c.k10)
	feqs = [substitute(eq.lhs, subst) ~ substitute(eq.rhs, subst) for eq in EQS]
	@named sys = ODESystem(feqs, t)
	fm = ODEParameterEstimation.OrderedODESystem(sys, [x4, x5, x6, x7], Num[])
	get_si_equation_system(fm, MQ, OrderedDict{Any, Any}(); infolevel = 0)
end

include(joinpath(DUMPDIR, "candidates.jl"))   # const BLOWN
offset = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 0
cnt    = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : length(BLOWN)
batch  = BLOWN[clamp(offset + 1, 1, length(BLOWN)+1):clamp(offset + cnt, 0, length(BLOWN))]
println("[sweep $offset:+$cnt] $(length(batch)) candidates, ABORT_BITS=$ABORT_BITS"); flush(stdout)
for c in batch
	_CURMAX[] = 0; t0 = time()
	try
		run_cand(c)
		println("[CAND $(c.n)] ok  max=$(_CURMAX[])b  $(round(time()-t0;digits=1))s"); flush(stdout)
	catch e
		if e isa SwellHit
			println("\n!!!!!! [SWELL CAND $(c.n)] gcd operands $(e.ba)/$(e.bb) bits!  k8=$(c.k8) k9=$(c.k9) k10=$(c.k10) !!!!!"); flush(stdout)
			f = joinpath(DUMPDIR, "swell_cand_$(c.n).txt")
			try
				open(f, "w") do io
					println(io, "# SWELL candidate n=$(c.n): k5=$(c.k5) k6=$(c.k6) k7=$(c.k7) k8=$(c.k8) k9=$(c.k9) k10=$(c.k10)")
					println(io, "# A: $(length(e.a)) terms, ~$(e.ba) bit coeffs"); println(io, "A = ", e.a)
					println(io, "\n# B: $(length(e.b)) terms, ~$(e.bb) bit coeffs"); println(io, "B = ", e.b)
				end
				println("   -> dumped $f"); flush(stdout)
			catch de; println("   dump failed: $de"); flush(stdout); end
		else
			println("[CAND $(c.n)] threw $(typeof(e))  max=$(_CURMAX[])b"); flush(stdout)
		end
	end
end
println("[sweep $offset DONE]"); flush(stdout)
