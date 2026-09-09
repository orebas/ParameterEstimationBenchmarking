# M=1 Benchmark System Review Against Quoll

Date: 2026-06-08

This is the review table for the paper-facing M=1 benchmark system list. It compares the current M=1 benchmark config against the older Quoll broad config.

## Summary

- Quoll broad has 27 systems.
- The M=1 benchmark has 25 paper-facing systems.
- 19 systems are unchanged from Quoll.
- 4 systems keep the normal paper-facing base name but add one observable to make the benchmark variant M=1.
- 2 systems keep the Quoll observed-control ODE variant but use shorter paper-facing names.
- 2 Quoll branch-stress systems are omitted from this M=1 benchmark and recorded as `*_branched` counterparts.
- For every included row, the ODE right-hand side is identical to the listed Quoll counterpart. The benchmark differences are measurement sets, naming, and omission of branch-stress variants.

## Main Review Table

Dimensions are `states / parameters / measurements`.

| Paper-facing name | Quoll counterpart | Status vs Quoll | Dims | M=1 measurement equations | Difference from Quoll |
|---|---|---|---:|---|---|
| `aircraft_pitch` | `aircraft_pitch` | unchanged | 3 / 4 / 1 | `y1=0.05*q` | same as Quoll |
| `bicycle_model` | `bicycle_model` | unchanged | 2 / 3 / 2 | `y1=0.1*r; y2=0.5*vy` | same as Quoll |
| `biohydrogenation` | `biohydrogenation` | observable-added | 4 / 6 / 3 | `y1=8.0*x4; y2=0.5*x5; y3=0.5*x6` | added `y3=0.5*x6` |
| `boost_converter` | `boost_converter` | unchanged | 2 / 3 / 2 | `y1=48.0*vC; y2=2.0*iL` | same as Quoll |
| `brusselator` | `brusselator` | unchanged | 2 / 2 / 2 | `y1=2.0*X; y2=2.0*Yc` | same as Quoll |
| `crauste` | `crauste` | unchanged | 5 / 12 / 4 | `y1=16180.0*Npop; y2=10.0*E; y3=10.0*M + 10.0*L; y4=2.0*P` | same as Quoll |
| `cstr` | `cstr` | unchanged | 3 / 4 / 1 | `y1=700.0*Temp` | same as Quoll |
| `daisy_mamil3` | `daisy_mamil3` | unchanged | 3 / 5 / 2 | `y1=0.5*x1; y2=x2` | same as Quoll |
| `daisy_mamil4` | `daisy_mamil4` | observable-added | 4 / 7 / 4 | `y1=0.4*x1; y2=0.8*x2; y3=1.2*x3 + 1.6*x4; y4=1.2*x3` | added `y4=1.2*x3` |
| `dc_motor` | `dc_motor` | unchanged | 2 / 2 / 1 | `y1=omega_m` | same as Quoll |
| `fitzhugh_nagumo` | `fitzhugh_nagumo` | unchanged | 2 / 3 / 1 | `y1=-2.0*Vm` | same as Quoll |
| `flexible_arm` | `flexible_arm` | unchanged | 4 / 5 / 2 | `y1=0.5*theta_m; y2=0.5*theta_t` | same as Quoll |
| `forced_lotka_volterra` | `forced_lotka_volterra` | unchanged | 2 / 4 / 2 | `y1=2.0*x; y2=2.0*yv` | same as Quoll |
| `harmonic_oscillator` | `harmonic_oscillator` | unchanged | 2 / 2 / 2 | `y1=2.0*x1; y2=x2` | same as Quoll |
| `hiv` | `hiv` | unchanged | 5 / 10 / 4 | `y1=2.0*w; y2=z; y3=2000.0*x; y4=0.002*vv + 2.0*yv` | same as Quoll |
| `lotka_volterra` | `lotka_volterra` | unchanged | 2 / 3 / 1 | `y1=4.0*r` | same as Quoll |
| `mass_spring_damper` | `mass_spring_damper` | unchanged | 2 / 3 / 1 | `y1=x` | same as Quoll |
| `quadrotor` | `quadrotor` | unchanged | 2 / 2 / 1 | `y1=10.0*z` | same as Quoll |
| `repressilator` | `repressilator` | unchanged | 6 / 3 / 3 | `y1=4.0*p1; y2=2.0*p2; y3=6.0*p3` | same as Quoll |
| `seir` | `seir` | observable-added | 4 / 3 / 3 | `y1=10.0*In; y2=2000.0*Npop; y3=20.0*E` | added `y3=20.0*E` |
| `slow_fast` | `slow_fast` | observable-added | 6 / 2 / 5 | `y1=xC; y2=0.44222400000000006*xA*eA + 0.9990000000000001*eB*xB + 1.666*xC*eC; y3=1.332*eA; y4=1.666*eC; y5=0.9990000000000001*eB` | added `y5=0.9990000000000001*eB` |
| `sirt_treatment` | `sirt_treatment` | unchanged | 4 / 5 / 3 | `y1=10.0*Tr; y2=2000.0*Npop; y3=10.0*In` | same as Quoll |
| `vanderpol` | `vanderpol` | unchanged | 2 / 2 / 2 | `y1=4.0*x1; y2=x2` | same as Quoll |
| `latent_subpopulation` | `latent_subpopulation_observed_control` | renamed observed-control | 5 / 6 / 5 | `y1=S; y2=I1; y3=I2; y4=I3; y5=R` | Quoll observed-control variant, renamed shorter for paper |
| `receptor_binding` | `receptor_subtype_binding_observed_control` | renamed observed-control | 3 / 6 / 3 | `y1=L; y2=Ca; y3=Cb` | Quoll observed-control variant, renamed shorter for paper |

## Quoll Systems Not In This M=1 Benchmark

| Quoll name | Paper-facing counterpart name | Why omitted |
|---|---|---|
| `latent_subpopulation_branch` | `latent_subpopulation_branched` | branch-completion stress system; Quoll branchful aggregate-observation variant, not part of M=1 main benchmark |
| `receptor_subtype_binding_branch` | `receptor_binding_branched` | branch-completion stress system; Quoll branchful aggregate-observation variant, not part of M=1 main benchmark |

## Differences To Approve

1. The M=1 benchmark gives observable-added variants the normal names `biohydrogenation`, `daisy_mamil4`, `seir`, and `slow_fast`. Their branchful counterparts are tracked only in metadata as `*_branched`.
2. `latent_subpopulation` is a shorter paper-facing alias for Quoll `latent_subpopulation_observed_control`, while `latent_subpopulation_branched` is omitted.
3. `receptor_binding` is a shorter paper-facing alias for Quoll `receptor_subtype_binding_observed_control`, while `receptor_binding_branched` is omitted.
4. The longest remaining names in the main list are `forced_lotka_volterra`, `mass_spring_damper`, and `fitzhugh_nagumo`; these are unchanged from Quoll and may or may not need paper-facing aliases.

## Source Files

- Current M=1 system config: `config/systems_m1_broad.json`
- Quoll broad system config: `config/systems_quoll_broad.json`
- Alias/provenance metadata: `config/branch_metadata_m1.json`
