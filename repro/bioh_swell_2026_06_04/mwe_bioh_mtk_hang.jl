# Minimal reproducer: ModelingToolkit `structural_simplify` hangs (forever) in FLINT's
# multivariate GCD (`fmpq_mpoly_gcd` -> `fmpz_CRT_ui`, CRT coefficient swell) on a
# degenerate biohydrogenation ODE system.
#
# Origin: the biohydrogenation parameter-estimation cell `biohydrogenation_3_1em8`. During
# a backsolve re-solve, a spurious ("blown") candidate fixed the reaction rates k9, k10 to
# DENORMAL-ZERO (k9=1.57e-20, k10=1.00e-32). Substituting those into the rate equations
# (which divide by 10*k10 and 5*k10, with a k9 factor in the numerator) yields rational
# coefficients with astronomically large exact numerators/denominators; MTK's
# alias-elimination GCD over QQ then swells and never returns.
#
# Expectation: `structural_simplify` below does NOT return (CPU pegged in libflint
# fmpq_mpoly_gcd). Normal (non-degenerate) params simplify this system in milliseconds.
#
# No ODEParameterEstimation dependency — pure ModelingToolkit/Symbolics.

using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using Symbolics

@parameters k5 k6 k7 k8 k9 k10
@variables x4(t) x5(t) x6(t) x7(t) y1(t) y2(t)

# 4 rate ODEs PLUS the 2 algebraic observable equations (y1, y2). The observables are
# what give MTK's alias-elimination (find_perfect_aliases!) something to eliminate — and
# that is where the FLINT GCD swell happens. Without them structural_simplify is trivial.
eqs = [
    D(x4) ~ (-8.0*k5*x4) / (8.0*(4.0*k6 + 8.0*x4)),
    D(x5) ~ ((-0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5) + (8.0*k5*x4) / (4.0*k6 + 8.0*x4)) / 0.5,
    D(x6) ~ ((-0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (10.0*k10) + (0.3*k7*x5) / (2.0*k8 + 0.5*x6 + 0.5*x5)) / 0.5,
    D(x7) ~ (0.2*(10.0*k10 - 0.5*x6)*k9*x6) / (5.0*k10),
    y1 ~ 8.0*x4,
    y2 ~ 0.5*x5,
]

# The degenerate blown-backsolve candidate (captured from the live estimation).
subst = Dict(
    k5  => 0.4070000353946035,
    k6  => 0.5540003058773132,
    k7  => 0.4890170470145302,
    k8  => 0.5139226564568873,
    k9  => 1.5670109524204556e-20,   # underflowed to ~0
    k10 => 1.0025488049613471e-32,   # underflowed to ~0
)
new_eqs = [substitute(eq.lhs, subst) ~ substitute(eq.rhs, subst) for eq in eqs]

@named sys = ODESystem(new_eqs, t)   # MTK infers unknowns x4..x7,y1,y2; y1,y2 get alias-eliminated

println(">>> built degenerate System; calling structural_simplify (expect HANG in FLINT fmpq_mpoly_gcd)...")
flush(stdout)
simp = isdefined(ModelingToolkit, :structural_simplify) ? ModelingToolkit.structural_simplify : ModelingToolkit.mtkcompile
simp(sys)
println(">>> RETURNED — did NOT reproduce the hang")
