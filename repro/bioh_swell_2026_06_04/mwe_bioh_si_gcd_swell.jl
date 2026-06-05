# MWE: reproduce the bioh SI-path FLINT GCD swell and CAPTURE the actual gcd operands.
#
# Chain: get_si_equation_system (si_template_integration.jl:436) -> StructuralIdentifiability
# lie_derivative/observability (states.jl) -> AbstractAlgebra +(::Frac,::Frac) -> Nemo.gcd ->
# FLINT fmpq_mpoly_gcd  <-- swells on astronomically-large EXACT rationals.
#
# NOTE: the near-zero candidate (k9,k10 ~ 1e-20/1e-32) does NOT swell here — SI rounds those to
# 0//1. The swell comes from a full-precision blown (sign-flipped) candidate. Using Solution 1175.

import Pkg
Pkg.activate(raw"/home/orebas/ParameterEstimationBenchmark-local/environments/julia_odepe")

using ODEParameterEstimation
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using Symbolics
using OrderedCollections
import Nemo

const QQMP = Nemo.QQMPolyRingElem
const DUMPFILE = raw"/home/orebas/ParameterEstimationBenchmark-local/repro/bioh_swell_2026_06_04/swell_operands.txt"

_nb(z) = try Int(Nemo.nbits(z)) catch; ndigits(BigInt(z); base = 2) end
function _maxbits(p::QQMP)
	mb = 0; n = 0
	for c in Nemo.coefficients(p)
		mb = max(mb, _nb(Nemo.numerator(c)), _nb(Nemo.denominator(c)))
		n += 1; n >= 200 && break
	end
	return mb
end

const _BIGGEST = Ref(0)
const _DUMPED  = Ref(false)
const _BIGA = Ref{Any}(nothing)
const _BIGB = Ref{Any}(nothing)

function _dump(a, b, ba, bb, tag)
	try
		open(DUMPFILE, "w") do io
			println(io, "# $tag — largest gcd operands on the SI lie-derivative path, degenerate bioh")
			println(io, "# A: $(length(a)) terms, max coeff ~$ba bits (~$(div(ba*3,10)) decimal digits)")
			println(io, "A = ", a)
			println(io, "\n# B: $(length(b)) terms, max coeff ~$bb bits")
			println(io, "B = ", b)
		end
		println("   dumped operands ($ba/$bb bit) to $DUMPFILE"); flush(stdout)
	catch e
		println("   dump failed: $e"); flush(stdout)
	end
end

# Type-piracy wrapper: log + capture biggest + live-dump, then forward via raw FLINT ccall.
function Nemo.gcd(a::QQMP, b::QQMP)
	la, lb = length(a), length(b)
	ba, bb = _maxbits(a), _maxbits(b)
	big = max(ba, bb)
	if big > _BIGGEST[]
		_BIGGEST[] = big; _BIGA[] = a; _BIGB[] = b
		println("[GCD] new max coeff: A=$(la)t/$(ba)b  B=$(lb)t/$(bb)b"); flush(stdout)
	end
	if big > 2000 && !_DUMPED[]   # capture early, before any hang
		_DUMPED[] = true
		println("\n===== SWELLING GCD (>2000-bit coeffs) ====="); flush(stdout)
		_dump(a, b, ba, bb, "live-capture")
	end
	Nemo.check_parent(a, b)
	z = parent(a)()
	r = @ccall Nemo.libflint.fmpq_mpoly_gcd(z::Ref{QQMP}, a::Ref{QQMP}, b::Ref{QQMP}, a.parent::Ref{Nemo.QQMPolyRing})::Cint
	r == 0 && error("Unable to compute gcd")
	return z
end

# ---- degenerate bioh model: Solution 1175 (full-precision, blown / sign-flipped) ----
@parameters k5 k6 k7 k8 k9 k10
@variables x4(t) x5(t) x6(t) x7(t) y1(t) y2(t)
eqs = [
	D(x4) ~ (-8.0 * k5 * x4) / (8.0 * (4.0 * k6 + 8.0 * x4)),
	D(x5) ~ ((-0.3 * k7 * x5) / (2.0 * k8 + 0.5 * x6 + 0.5 * x5) + (8.0 * k5 * x4) / (4.0 * k6 + 8.0 * x4)) / 0.5,
	D(x6) ~ ((-0.2 * (10.0 * k10 - 0.5 * x6) * k9 * x6) / (10.0 * k10) + (0.3 * k7 * x5) / (2.0 * k8 + 0.5 * x6 + 0.5 * x5)) / 0.5,
	D(x7) ~ (0.2 * (10.0 * k10 - 0.5 * x6) * k9 * x6) / (5.0 * k10),
]
subst = Dict(k5 => 0.40700017297546476, k6 => 0.5540006159865941, k7 => 0.49638062123433124,
	k8 => 595.9785121049448, k9 => -0.46481564065184733, k10 => -119.09115429002283)
fixed_eqs = [substitute(eq.lhs, subst) ~ substitute(eq.rhs, subst) for eq in eqs]
@named sys = ODESystem(fixed_eqs, t)
fixed_model = ODEParameterEstimation.OrderedODESystem(sys, [x4, x5, x6, x7], Num[])
mq = ModelingToolkit.Equation[y1 ~ 8.0 * x4, y2 ~ 0.5 * x5]

println(">>> get_si_equation_system on full-precision blown candidate (Sol 1175)..."); flush(stdout)
try
	get_si_equation_system(fixed_model, mq, OrderedDict{Any, Any}(); infolevel = 1)
	println(">>> RETURNED. biggest gcd operand = $(_BIGGEST[]) bits")
catch e
	println(">>> threw: ", typeof(e))
end
# end-dump the biggest seen (covers the no-hang case)
if _BIGA[] !== nothing && !_DUMPED[]
	_dump(_BIGA[], _BIGB[], _maxbits(_BIGA[]), _maxbits(_BIGB[]), "end-of-run biggest")
end
println(">>> DONE. biggest gcd operand coeff = $(_BIGGEST[]) bits; dumped=$(_DUMPED[])"); flush(stdout)
