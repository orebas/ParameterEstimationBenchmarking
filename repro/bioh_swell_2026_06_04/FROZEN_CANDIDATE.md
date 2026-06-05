# biohydrogenation_3_1em8 — the MTK/FLINT hang, captured (2026-06-04)

The single degenerate blown-backsolve candidate that hangs ~14h in MTK
alias-elimination's FLINT GCD (gdb-proven earlier; see
`project_2026_06_03_groebner_mwe_deferred`). Captured by freezing the live
estimation at the swelling candidate and serializing its `pre_fixed_params`.

## The frozen candidate (#344 in the candidate stream)

`pre_fixed_params` = `OrderedDict{Any,Float64}` (length 6):

| param | value |
|---|---|
| k5  | 0.4070000353946035 |
| k6  | 0.5540003058773132 |
| k7  | 0.4890170470145302 |
| k8  | 0.5139226564568873 |
| **k9**  | **1.5670109524204556e-20**  (≈ 0, denormal) |
| **k10** | **1.0025488049613471e-32**  (≈ 0, denormal) |

## The trigger

**k9 and k10 underflow to ~zero.** The backsolve "blew" these two reaction
rates to denormal-tiny values; fixing them makes the bioh algebraic system
(the t=0 IC re-solve) degenerate, and MTK `structural_simplify` →
`find_perfect_aliases!` → `fmpq_mpoly_gcd` (FLINT Zippel sparse GCD) →
`fmpz_CRT_ui` swells (CRT integer reconstruction / intermediate coefficient
blow-up) and never returns. NOT negative k9/k10 (that was the earlier guess) —
it's the underflow-to-zero.

## Artifacts (this dir)

- `last_cand.jls`     — the serialized OrderedDict above (Julia Serialization;
                        deserialize under the ODEPE env / OrderedCollections).
- `capture_script.jl` — the driver that ran the real bioh_3_1em8 polish with an
                        `apply_prefixed_params_to_model` override that serializes
                        `pre_fixed_params` (len==6) then freezes.
- `data.csv`          — the bioh_3_1em8 noisy data the run used.

## Next step → standalone MWE for upstream (ModelingToolkit / FLINT)

Have the *input* (these params). The upstream report wants the *System* that
`mtkcompile` chokes on, with NO ODEPE dependency. To get it (now FAST — no HC
solve needed):
1. Load the bioh model + call the backsolve re-solve
   (`resolve_states_with_fixed_params`, si_template_integration.jl) with these
   6 fixed params.
2. Intercept the `System` passed to `mtkcompile`/`structural_simplify` and
   `serialize` it (before the hanging call).
3. Ship a 3-line repro: `using ModelingToolkit, Serialization;
   sys = deserialize("sys.jls"); mtkcompile(sys)` → hangs in FLINT GCD.
4. File against ModelingToolkit (alias_elimination) and/or FLINT (fmpq_mpoly_gcd
   CRT swell), with `sys.jls` + the Julia/MTK/FLINT versions from the run.
