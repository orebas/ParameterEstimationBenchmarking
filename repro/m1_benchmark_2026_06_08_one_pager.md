# M=1 Parameter-Estimation Benchmark Plan

Date staged: 2026-06-08

## Goal

We are setting up a focused benchmark for the paper-facing M=1 systems, using a smaller and cleaner experimental design than the earlier broad Quoll-style run. The goal is to compare current ODEParameterEstimation behavior against a direct-optimization baseline, quantify robustness across noise levels, and isolate two specific algorithmic questions: whether the low-noise AAA interpolator remains valuable, and how much bounded log-space polishing contributes.

## Main Experiment

Scope:

- 25 M=1 systems from `config/systems_m1_broad.json`, using paper-facing names without `_m1` or `_control` suffixes
- 10 deterministic replicas per system
- 5 noise levels: `0`, `1e-8`, `1e-6`, `1e-4`, `1e-2`
- 3 arms:
  - `odepe_v2_polish`: current ODEPE v2 settings with bounded log-space polishing
  - `odepe_shade`: SHADE direct-optimization arm using the same synthetic data
  - `amigo2`: AMIGO2 baseline, run locally rather than on the CUNY path

Paper-facing system aliases:

- Observable-added M=1 variants use the normal base names: `biohydrogenation`, `daisy_mamil4`, `seir`, and `slow_fast`.
- Observed-control stress systems are shortened to `latent_subpopulation` and `receptor_binding`.
- The omitted branchful counterparts are recorded as `*_branched` in `config/branch_metadata_m1.json`.

Total size:

- 25 systems x 5 noises x 10 replicas = 1,250 cells per arm
- 3,750 total main-experiment cells

Key ODEPE settings:

- `ODEPE_BRANCH_COMPLETION=false`
- `POLISH_MAXTIME=600`
- deterministic per-cell seeds and frozen benchmark manifests
- Julia subprocesses use `--startup-file=no`

Optimization budget note:

- `odepe_v2_polish`: bounded log-space local polish has `polish_maxtime=600` and `polish_maxiters=5000`.
- `odepe_shade`: SHADE has `shade_total_max_time=600` and `shade_total_max_evals=200000`; its local polish also has `polish_maxtime=600` and `polish_maxiters=5000`.
- `amigo2`: eSS has `maxtime=600` and `maxeval=200000`; AMIGO2's internal `nl2sol` local solver has high iteration/evaluation guards but no separate local wall-time cap in the current template.
- No-polish follow-up arms disable ODEPE local polish, so the local-polish budget does not apply to those cells.

## Follow-Up Subexperiments

The follow-up runs are designed to be smaller and more diagnostic. We generate the same 10 replicas, but after the main run completes we will select two representative replicas per model using the main ODEPE polish results. The selection rule is intended to choose replicas near the median aggregate error/time profile, while preferring replicas with at least 4 of 5 main-noise cells completed.

### Low-Noise AAA Check

Question: At very low noise, does forcing the classic AAA interpolator still improve recovery enough to justify special-casing or retaining it?

- Noises: `0`, `1e-12`, `1e-10`, `1e-8`, `1e-6`
- Arms: `odepe_v2_aaa_nopolish` vs `odepe_v2_polish`
- Planned executed size after representative-replica filtering: 25 x 5 x 2 x 2 = 500 cells

### Polish Ablation

Question: How much of the current ODEPE v2 performance comes from bounded log-space polishing rather than the symbolic/homotopy candidate generation pipeline?

- Noises: `0`, `1e-8`, `1e-6`, `1e-4`, `1e-2`
- Arms: `odepe_v2_polish` vs `odepe_v2_nopolish`
- Planned executed size after representative-replica filtering: 25 x 5 x 2 x 2 = 500 cells

## Deployment Plan

ODEPE and SHADE are staged for Hetzner using `cloud/hetzner/tiers_m1.json`.

- Normal systems: `ccx33`, split by system and arm, concurrency 5, 2 Julia threads per cell.
- Hard systems: `ccx43`, split by system, noise, and arm, concurrency 6, 2 Julia threads per cell.
- Hard set: `biohydrogenation`, `crauste`, `cstr`, `daisy_mamil4`, `hiv`, `repressilator`, `seir`, `sirt_treatment`, `slow_fast`.
- Operational note: `hiv`, `repressilator`, and `sirt_treatment` remain ordinary paper-facing M=1 systems, but are assigned to the hard deployment bucket because the 2026-06-09 DO run showed they create long normal-tier tail shards.

AMIGO2 is intended to run locally with adaptive concurrency:

- start at concurrency 4
- raise to concurrency 6 after a clean small batch
- keep AMIGO2 off cloud nodes unless there is a strong reason to move it

The fleet harness now supports stable benchmark dates, shard resume from prior results, periodic result pulls, and final result pulls before node teardown. This should reduce lost work if a shard/node fails or if we hit Hetzner quota limits while launching.

Optional warm-Julia mode is now available as a canary-only launch option: `fleet.py --warm-julia --warm-julia-batch N`. It batches several cells through each Julia process while keeping the default isolated one-process-per-cell mode unchanged. We should compare a small warm run against the default runner before using warm mode for timing-sensitive results.

## Current Staging Status

Prepared locally:

- Main data: 1,250 synthetic cells, with 1,250 scripts each for `odepe_v2_polish`, `odepe_shade`, and `amigo2`.
- Low-noise AAA data: 1,250 synthetic cells, with 1,250 scripts each for `odepe_v2_aaa_nopolish` and `odepe_v2_polish`.
- Polish-ablation data: reuses the main synthetic cells, with 1,250 scripts each for `odepe_v2_polish` and `odepe_v2_nopolish`.

Hetzner dry-run plans, with no cloud nodes created:

- Main cloud launch plan: 122 shards/boxes, 2,500 ODEPE/SHADE cells, approximately `$30.50/hr` at full concurrency.
- Low-noise AAA full staging plan: 122 shards/boxes, 2,500 cells, approximately `$30.50/hr` at full concurrency.
- Polish-ablation full staging plan: 122 shards/boxes, 2,500 cells, approximately `$30.50/hr` at full concurrency.

The follow-up plans are deliberately staged with the full 10-replica universe so we can choose representative replicas after the main ODEPE-polish results are available. Launching those tiers exactly as staged would run all 10 replicas; the intended diagnostic follow-up is the filtered 2-replica-per-system subset unless we explicitly decide to spend the full run.

## Review Points

- The main experiment is intentionally M=1 only; it is not a replacement for the older broad Quoll benchmark.
- Timing comparisons should be interpreted with care because same-process warmup can be large for ODEPE. We will preserve timing sidecars and metadata, but the primary comparison should emphasize recovery/error and completion/failure behavior.
- The subexperiments should not start until the main run has enough ODEPE polish coverage to select representative replicas.
- Hetzner quota is not queryable from the CLI/API, so launch size may need to be discovered by controlled attempted creation.
