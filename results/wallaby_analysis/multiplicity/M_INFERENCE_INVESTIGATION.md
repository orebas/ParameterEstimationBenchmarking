# M-inference investigation: SI.jl, SIAN-Julia, and the path to auto-computing M

## Why this matters

ODEPE's edge over numerical estimators (AMIGO2, SHADE+LM) is that its
algebraic core finds **all M algebraic solutions** of a locally
identifiable problem, where M is the algebraic multiplicity (number of
distinct (params, IC) tuples yielding identical observations). Most
users don't know multiplicity exists — they expect a single answer.

For the paper we want:

1. **Compute M automatically per system** during the pipeline run.
2. **Return exactly M solutions** in `result.csv` (not K=20).
3. **Score against M, not K=20** — the M-bounded oracle metric we
   shipped in Phase 1 (`headline_comparison.md`).

Today the M values are in a hand-curated catalog at
`config/systems.json[*].algebraic_multiplicity`. The user's concern:
relying on a catalog feels like cheating for a paper that claims
"our pipeline finds all branches". This doc records what we investigated
and how to get to fully-automated M.

## What `:locally` count is (and isn't)

`StructuralIdentifiability.assess_identifiability(ode)` returns a Dict
`var → {:globally, :locally, :nonidentifiable}`. We initially thought
`count(:locally)` was M.

It's not. It's the **dimensionality of the branch-swap subspace** —
how many variables move together when you cross from one algebraic
branch to another. Confirmed by counterexample on our 4 mult-2 systems:

| System | n_locally | True M |
|---|---:|---:|
| daisy_mamil4 | 6 (k13, k14, k31, k41, x3, x4) | 2 |
| slow_fast | 5 (k1, k2, xA, xB, eB) | 2 |
| seir | 4 (a, ν, E, S) | 2 |
| biohydrogenation | 4 (k8, k9, k10, x6) | 2 |

All four have M=2 but with different n_locally. No formula `M = f(n_locally)`
works.

The one valid use of n_locally is as a **gate**: `n_locally == 0 ⇒ M = 1`.
The system is globally identifiable in the identifiable subspace. This
gate fires correctly for all 19 of our M=1 systems, fully automated.

## Investigation into StructuralIdentifiability.jl

Vendored at `environments/StructuralIdentifiability.jl/`, mainline is
`github.com/SciML/StructuralIdentifiability.jl`. Pogudin et al.

### What I tried (wrong)

`primality_check.jl:5-6` computes
`dim = length(Groebner.quotient_basis(Groebner.groebner(J)))` inside
`check_primality_zerodim`. I patched this to expose `dim` via a
`Ref{Int}` kwarg, plus a new `assess_algebraic_multiplicity(ode)`
wrapper.

### Why it failed

The `dim` in `check_primality_zerodim` is **over the LEADER ring**, not
over parameters. It's:

```
check_primality_zerodim builds zerodim_ideal:
  - leaders = keys(io_projections) = derivatives of observables
  - eval_point = {leader → leader, otherwise → random integer}
  - all_polys evaluated at eval_point → ideal in K[leaders]
  - dim = #solutions in K[leaders]/I
```

This answers "given random *parameters*, how many leader assignments
satisfy the IO equations?" — typically 1, because the IO equations
overdetermine the observables for fixed params.

We want the **dual**: "given a leader assignment (= an observation),
how many parameter assignments satisfy?" That's M.

Empirically verified on canonical DAISY MAMIL-4:
- `length(io_projections) = 3`
- `check_primality(io_projections; out_dim=ref)` returns `true`
- `out_dim[] = 1` (NOT 2)
- But `assess_identifiability(ode)` returns 6 vars as `:locally`,
  confirming M > 1

So the SI.jl patch is mis-aimed. The right ideal isn't built anywhere
in SI.jl's hot path.

### What SI.jl does expose

`find_identifiable_functions(ode)` returns the identifiable subfield
(as a list of rational functions). Mathematically, the field extension
`[K(all_vars) : K(identifiable_subfield)]` has degree M. But SI.jl
returns just the function generators — the extension degree isn't
computed anywhere visible.

`reparametrize_global` (in `parametrizations.jl`) works with the
identifiable subfield. It doesn't expose the degree either.

**Conclusion:** StructuralIdentifiability.jl does NOT compute M in its
current call graph. A patch wouldn't be "expose what's there" — it
would be "add new computation". Larger PR.

## Investigation into SIAN-Julia

Vendored at `environments/SIAN-Julia/`, similar authorship (Pogudin is
also a SIAN-Julia author).

### What's relevant

`SIAN.jl:211`:
```julia
deg_variety = foldl(*, [BigInt(total_degree(e)) for e in Et])
```

`Et` is the SIAN polynomial system — equations whose roots ARE the
algebraic multiplicity in the parameter space. `deg_variety` is the
**Bezout product** = upper bound on complex roots. Used internally to
compute the sample bound `D2` (line 212) for the probabilistic
algorithm.

`SIAN.jl:265`:
```julia
gb = groebner(vcat(Et_hat, parent_ring_change(z_aux * Q_hat, Rjet_new) - 1))
```

`Et_hat` is `Et` with **random leader values substituted** — polynomials
in parameters only. This is the right ideal. `length(Groebner.quotient_basis(gb))`
on it would give the **exact M** (number of distinct complex roots in
the parameter variety, with multiplicity).

### SIAN doesn't expose either

`deg_variety` is computed and only used for the `D2` sampling bound.
The `gb` is used for normal-form computations (to determine which
parameters are globally vs locally identifiable) but `length(quotient_basis(gb))`
is never called.

A small upstream patch could expose:
- `deg_variety` (~3 lines) — Bezout upper bound
- `length(quotient_basis(gb))` (~3 lines) — exact M

Either via a `Ref{Int}` kwarg in `identifiability_ode` or as a return
field on the result Dict.

## What about HC.jl directly

`HomotopyContinuation.jl` finds all complex roots of a polynomial system
by path-tracking from a known start system. If we build the polynomial
system from `find_ioequations(ode)`, evaluate at random leaders to get
an ideal in parameters only, and call `HomotopyContinuation.solve` on it
— the result has all M complex roots (with HC's internal numerical
dedup).

This is essentially the "manual" version of what SIAN computes at
line 265. ODEPE already depends on HC.jl (via `solve_with_robust.jl`).
A standalone "compute M for an ODE" using HC.jl would be ~50 lines.

The catch: building the right polynomial system from `find_ioequations`
output requires care. The SI authors have done it correctly inside SIAN.jl
already; replicating in user code risks subtle bugs.

## The four paths forward, ranked

### Path A (recommended for the paper): SIAN-Julia upstream patch

Expose `length(Groebner.quotient_basis(gb))` from `SIAN.jl:265` via a
`Ref{Int}` kwarg or return-value extension. ~5 lines + tests + docs.
Pogudin is the author; small patch likely accepted within a release
cycle.

Once landed, ODEPE adds a one-liner: call SIAN's identifiability
pipeline (which it already does to build templates), harvest M from
the kwarg.

### Path B: StructuralIdentifiability.jl + new function

Add `assess_algebraic_multiplicity(ode)` to SI.jl that builds the right
parameter-space ideal (dual of what `check_primality` does) and counts
its quotient dim. Larger patch (new code, not just exposing existing).
Same author, but more review burden.

### Path C: HC.jl from ODEPE side

Inside ODEPE, build the parameter-space ideal from `find_ioequations`
output, call `HomotopyContinuation.solve`, count distinct complex roots
at cd10. No upstream PR needed; all in our code. Risk: replicating
SIAN's ideal-construction logic in ODEPE.

### Path D (today): SI gate + hand-curated catalog

What we shipped. SI's `n_locally == 0` gate correctly identifies M=1
for 19/23 wallaby systems automatically. For the 4 mult-2 systems we
read M from `config/systems.json`. The catalog values were derived by
`MULTIPLICITY_COMPLETE.md`'s case-by-case HC analysis.

Validates 23/23 against the catalog. Honest caveat for the paper:
"the SI gate is automated; M values for the 4 multiplicity-2 systems
come from a hand-derived catalog using HC root counting per
MULTIPLICITY_COMPLETE.md; automating that step upstream is in progress."

## The empirical validator we shipped

`m_inference_pipeline.py` also reports `M_empirical_validator`: for each
mult-2 system, walk K=20 result.csv rows per cell, dedup at 30% relative
threshold, take `ceil(median)` across cells.

For our 4 mult-2 systems:
- daisy_mamil4: 8 (overcounts due to within-basin polish spread on x3, x4)
- seir: 3 (slight overcount)
- slow_fast: 4 (overcount)
- biohydrogenation: 2 (matches — the cells where polish kept the
  sign-flipped raw HC candidate give 2 distinct rows; the cells where
  polish rejected it give 1; median = 1.5, ceil = 2)

So the empirical validator is noisy but **never undercounts**. It's a
"sanity floor" — if M_empirical > M_catalog, that's a red flag worth
investigating; if M_empirical ≤ M_catalog, we trust the catalog.

This validator is **not** the algorithm we'd ship in the paper as the
"automated M-inference" — it's too noise-prone. The SI gate is the
clean automated part; the catalog (and its eventual HC.jl-direct
replacement) is the M>1 path.

## TODO for upstream / handoff to local-claude

A clean handoff to local-claude (who has a more comfortable working
relationship with Pogudin et al.):

1. **Pick the upstream package.** Path A (SIAN-Julia) vs Path B (SI.jl)
   matters less than landing *one* of them. Pogudin can decide.
2. **Draft the patch.** ~5-15 lines + 2-3 tests + docs. The test
   fixtures live in `MULTIPLICITY_COMPLETE.md`: 4 known mult-2 systems
   (daisy_mamil4, seir, slow_fast, biohydrogenation), all of which
   should return M=2 from the patched function.
3. **Open the PR.** Reference the wallaby paper as the motivating
   downstream use case.
4. **Once merged + released**: bump the manifest in `julia_odepe`,
   wire into ODEPE's `si_equation_builder.jl:842` area (where SI
   template metadata gets stashed), expose via
   `EstimationOptions.algebraic_multiplicity = nothing` default → auto.
   Add 4 tests on the multiplicity-2 systems to `feature_regressions.jl`.

Until the upstream patch lands, `m_inference_pipeline.py` here gives
us the data we need for the paper (catalog-backed, SI-gate-validated,
empirically sanity-checked).
