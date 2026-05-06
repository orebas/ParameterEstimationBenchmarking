# Snapshot readiness for the next benchmark

This note is a companion to `NEXT_BENCHMARK_RECOMMENDATIONS.md`.
That file covers the *interpretation* side of the next run (what
variants to run, how to record run factors for comparison, model
tiers, CSTR sampling, interpolator portfolio, sidecar metadata,
analysis outputs). This file covers the *archival* side: what the
pipeline should emit so the next run is directly vendor-able to a
citable Zenodo snapshot without backfill. Read both before pressing
the big red button.

## Why this exists

The IEEE-paper data archive (v1.0 of
`orebas/parameter-estimation-snapshots`) was assembled in May 2026
from the October 2025 benchmark output. About three days of work
went into reconstruction that should not have been needed:

- AMIGO2 cells had no per-cell `result.csv`, only `stdout.txt`.
  All 1100 AMIGO2 stdouts had to be parsed offline by a
  scratch script (`scripts/extract_amigo2_results.py` in the
  snapshot repo). The simple regex in
  `src/collect_results.py:29` is unscoped and matched things like
  date stamps in MATLAB output for HIV cells; the snapshot's
  parser scopes matches to the `Estimated global parameters:`
  section first to avoid that.
- 138 AMIGO2 cells had no per-cell file explaining their failure
  mode. The aggregate `result.csv`'s `has_result=False` column was
  the only signal. We had to cross-reference cell-by-cell to
  confirm the failure was a known `mklJac` post-processing crash
  rather than a missing run.
- The live `config/config.json` had drifted between October 2025
  and May 2026 (`NOISE_TYPE` flipped MULTIPLICATIVE -> ADDITIVE,
  `ODEPE_POLISH` flipped false -> true). Initial reproduction
  missed the paper by 1e-3 until we recovered the paper-era
  config from the per-run preserved copy.
- Julia package SHAs and Manifest.toml hashes had to be
  reconstructed from `git log` and the Manifest in
  `environments/julia_odepe/`, not read from a manifest stamped
  alongside the run.

The next benchmark should require none of this. Each section
below pins the small change that closes one of those gaps.

## 1. Per-cell result.csv must exist for every variant

ODEPE, PE, and SciML cells already write `result.csv` next to
`script.jl`; see the dispatch at `src/collect_results.py:100-109`.
AMIGO2 cells write only `stdout.txt`; the parsing happens later in
`parse_output()` at `src/collect_results.py:27-35` during
aggregation.

Required: at the end of each AMIGO2 cell's MATLAB run, write a
`result.csv` next to `script.m` with the recovered parameters and
initial conditions. Two implementation paths:

- **Inside MATLAB (preferred)**: extend
  `templates/amigo2.m.template` to write `result.csv` from the
  AMIGO2 result struct directly after `AMIGO_PE`. This sidesteps
  parsing entirely and the values come straight from the result
  struct, so there is no risk of regex drift.
- **As a post-step in the bash launcher**: after MATLAB exits,
  run a Python parser on `stdout.txt`. If you take this route,
  copy the scoped regex (`PARAM_HEADER_RE`, `IC_HEADER_RE`,
  `NAMED_VALUE_RE`) from
  `~/sandbox/paper-snapshot-repo/scripts/extract_amigo2_results.py`,
  do NOT use the unscoped regex on `collect_results.py:29`.

Either way, the payoff is that `data/per_experiment/<cell>/`
has a uniform shape across all variants and the snapshot tool
can copy it verbatim.

## 2. Failure markers for cells that did not produce a result

Today, when AMIGO2 hits the `mklJac` crash, the cell directory has
`stdout.txt` and `stderr.txt` but no `result.csv`, and the only
record of the failure is the `has_result=False` row in the
aggregate. There is no per-cell file to read.

Required: when a cell does not produce a result, write a small
`failure_reason.txt` next to the cell's `script.*`. One token
identifying the class of failure plus a one-line summary:

```
mklJac_crash
AMIGO2 eSS optimization completed; mklJac post-processing failed
with "Execution of script as a function is not supported".
```

Suggested tokens:
`mklJac_crash`, `julia_exception`, `slurm_timeout`,
`mex_compile_failed`, `no_estimated_section`, `unknown`.

This applies to ODEPE too; the existing recs file's "ODEPE
Metadata To Save Per Instance" section already requests a
`status` field on the ODEPE side, but at the aggregate-row level,
not per-cell. Per-cell is what the snapshot needs because the
aggregate is regenerable from the per-cell files but not vice
versa. Generate at the lowest level and aggregate up.

## 3. MANIFEST.toml stamped into every benchmark run

`NEXT_BENCHMARK_RECOMMENDATIONS.md` already requests this under
"Record These Run Factors" but flags it as not yet implemented.
This note pins the *exact format* so it maps directly to the
snapshot repo's `SNAPSHOT.toml` schema and the pack-for-snapshot
script (section 5) is mechanical.

Suggested: a new module `pipeline/src/render_manifest.py` writes
`{benchmark_dir}/MANIFEST.toml` before script generation. Schema:

```toml
[run]
benchmark_dir = "benchmark_<date>"
date = "2026-XX-XX"
git_sha_peb = "..."
peb_dirty_diff_summary = "(clean)" or "N files dirty"

[julia]
version = "1.11.5"
manifest_path = "environments/julia_odepe/Manifest.toml"
manifest_sha256 = "..."

[components.odepe]
package = "ODEParameterEstimation"
sha = "..."
url = "..."

# similar [components.X] sections for GaussianProcesses.jl,
# mpfi.jl, rs.jl, RationalUnivariateRepresentation.jl,
# each with its upstream URL and the SHA recorded at run time.

[python]
version = "3.11.x"
requirements_sha256 = "..."

[matlab]
version_string = "..."
amigo2_version = "AMIGO2_R2025"

[gcc_wrapper]
path = "bin/gcc"
flags = "-Wno-error=incompatible-pointer-types"

[config]
paper_era_settings = { NOISE_TYPE = "...", ODEPE_POLISH = false, SEARCH_BOUNDS = [0, 1], NUM_TESTS = 10 }
```

Roughly 30 lines. Written once per benchmark run. Removes the
"reconstruct SHAs from git log" tax forever.

## 4. Vendor-ready output layout (already 90% there)

The current per-cell layout
`benchmark_<date>/filetree/{run_name}/{instance_id}/` already
maps cleanly onto the snapshot repo's
`data/per_experiment/{variant}/{cell_id}/`. The contract is:

```
script.{jl,m}        (always)
data.csv             (always)
result.csv           (when the run produced a result; gap closed by section 1)
failure_reason.txt   (when it did not; gap closed by section 2)
stdout.txt           (optional, useful for debugging)
stderr.txt           (optional)
objf_nl2sol.m        (AMIGO2 only)
```

Once sections 1 and 2 land, the run output is literally copy-able
into a snapshot. Do not change this layout casually; every change
ripples into snapshot tooling.

## 5. One-shot pack-for-snapshot script

Producing v1.0 was a multi-day manual process driven by scratch
work in `~/sandbox/paper-snapshot-repo/`. That should be a single
command for the next release.

Suggested: add `scripts/pack_for_snapshot.py` (or bash) that takes
a benchmark output directory and produces a vendor-ready directory
under `~/sandbox/snapshots/<date>/` containing:

- `data/per_experiment/<variant>/<cell>/` (copies of all cells)
- `data/source_csvs/{result.csv, result.json}` (the aggregate)
- `pipeline/{src, templates, config, hpc}/`
- `julia/env/{Project.toml, Manifest.toml}`
- `julia/<package>/` for each Julia path-dep, vendored at the
  SHA recorded in `MANIFEST.toml` (section 3 makes this lookup
  one-line)
- `bin/gcc`
- `MANIFEST.toml` renamed to `SNAPSHOT.toml`
- `setup.sh`, `reproduce_one.sh`, `reproduce_all.sh` (copy from
  v1.0, adjust paths)
- `LICENSE`, `NOTICES.md` (copy from v1.0, fill in new SHAs)

The user runs `git init`, commits, tags `v<N>`, pushes, cuts a
GitHub release. Five minutes, not three days.

The script can be skeletal at first; even just "copy these dirs
in this order and emit a checklist" is huge. v1.0's snapshot
tree is the executable spec.

## 6. Config-drift hygiene (no code change, just discipline)

The October-to-May `config.json` drift is the single most painful
class of bug because nothing complains: the new run succeeds, the
old run succeeded, but they used different settings. Avoid by:

- Treat `config/config.json` as immutable for the duration of a
  benchmark run. If you need to change settings, fork to a new
  benchmark dir; do not edit in place mid-run.
- After a run completes, copy its
  `{benchmark_dir}/config/config.json` to a tagged path
  (e.g. `config/config_<date>.json`) so future readers see what
  was used without scraping the run dir.
- The `MANIFEST.toml` (section 3) under `[config]` carries the
  same info; this is belt-and-suspenders.

## 60-second pre-flight checklist

```
Before launching the next benchmark:
[ ] Have I edited config/config.json since the last run? If yes, fork or tag.
[ ] Does pipeline/src/render_manifest.py exist and run before script generation?
[ ] Does templates/amigo2.m.template write result.csv per cell?
[ ] Does each launcher (Julia and MATLAB) write failure_reason.txt on non-success?
[ ] Is bin/gcc present and prepended to PATH by templates/amigo2.m.template?
[ ] Does scripts/pack_for_snapshot.py exist and has it been smoke-tested on a small subset?
[ ] Have I committed all PEB changes so the manifest's git SHA is meaningful?
```

If any of these is "no", fixing it now is much cheaper than
backfilling six months later. v1.0 cost three days of backfill;
each gap closed here costs a few hours up front.
