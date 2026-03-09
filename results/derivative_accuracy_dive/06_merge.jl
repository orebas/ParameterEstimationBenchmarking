#!/usr/bin/env julia
#=
Merge worker CSVs and produce the full report + summary CSVs.
Run after all 06_worker.jl instances complete.
=#

using CSV, DataFrames, Statistics, Printf

const OUTDIR = @__DIR__
const MAX_DERIV = 7

noise_names = ["0", "1e-8", "1e-6", "1e-4", "1e-2"]
method_prefixes = ["PureAAA", "GP_SE", "GP_RQ", "FHD5",
                   "S1_GP_AAA_MLE", "S2_AAA_MLE", "S3_High", "S4_Altern"]

# ──────────────────────────────────────────────────────────────────────
# 1. Load and merge all worker CSVs
# ──────────────────────────────────────────────────────────────────────
println("Loading worker CSVs...")
all_results = DataFrame()
missing_files = String[]

for nt_short in ["mult", "add"]
    for nn in noise_names
        fname = joinpath(OUTDIR, "06_worker_$(nt_short)_n$(nn).csv")
        if isfile(fname)
            df = CSV.read(fname, DataFrame)
            println("  Loaded $fname ($(nrow(df)) rows)")
            global all_results = vcat(all_results, df)
        else
            push!(missing_files, fname)
            println("  MISSING: $fname")
        end
    end
end

if !isempty(missing_files)
    println("\nWARNING: $(length(missing_files)) worker files missing!")
    println("  Missing: ", join(missing_files, "\n           "))
    println("  Proceeding with available data...\n")
end

println("Total rows: $(nrow(all_results))")

# ──────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────

fmt(v) = isnan(v) ? "N/A" :
    v < 1e-12 ? "~0" :
    v < 0.001 ? "$(round(v*100, sigdigits=2))%" :
    v < 10 ? "$(round(v*100, sigdigits=3))%" :
    "$(round(v*100, sigdigits=3))%"

function print_table(title, df; col_width=13)
    println("\n" * "="^70)
    println(title)
    println("="^70)
    nms = unique(df.interpolator)
    println(rpad("Method", 24), " | ", join([rpad("d$n", col_width) for n in 0:MAX_DERIV], " | "))
    println("-"^24, "-+-", join(["-"^col_width for _ in 0:MAX_DERIV], "-+-"))
    for nm in nms
        cells = [begin
            v = filter(!isnan, df[(df.interpolator .== nm) .& (df.deriv_order .== n), :rel_error])
            isempty(v) ? "N/A" : fmt(median(v))
        end for n in 0:MAX_DERIV]
        println(rpad(nm, 24), " | ", join([rpad(c, col_width) for c in cells], " | "))
    end
end

# ──────────────────────────────────────────────────────────────────────
# 2. Table 1: Per noise-type, per noise-level
# ──────────────────────────────────────────────────────────────────────

println("\n\n")
println("#"^70)
println("# TABLE 1: PER NOISE-TYPE, PER NOISE-LEVEL")
println("#"^70)

for noise_type in ["multiplicative", "additive"]
    nt_short = noise_type == "multiplicative" ? "mult" : "add"
    for nn in noise_names
        tag = "$(nt_short)_n$nn"
        mask = occursin.("_$tag", all_results.interpolator)
        sub = all_results[mask, :]
        !isempty(sub) && print_table("NOISE = $nn  ($noise_type)", sub)
    end
end

# ──────────────────────────────────────────────────────────────────────
# 3. Table 2: Side-by-side additive vs multiplicative
# ──────────────────────────────────────────────────────────────────────

println("\n\n")
println("#"^70)
println("# TABLE 2: SIDE-BY-SIDE (one table per derivative order)")
println("#"^70)

for dn in 0:MAX_DERIV
    println("\n" * "="^70)
    @printf("d%d median relative error: multiplicative vs additive\n", dn)
    println("="^70)

    header_cells = String[]
    for nn in noise_names
        push!(header_cells, rpad("$nn(M)", 12))
        push!(header_cells, rpad("$nn(A)", 12))
    end
    println(rpad("Method", 18), " | ", join(header_cells, " | "))
    println("-"^18, "-+-", join(["-"^12 for _ in 1:2*length(noise_names)], "-+-"))

    for pfx in method_prefixes
        cells = String[]
        for nn in noise_names
            for nt_short in ["mult", "add"]
                full_name = "$(pfx)_$(nt_short)_n$nn"
                mask = (all_results.interpolator .== full_name) .& (all_results.deriv_order .== dn)
                v = filter(!isnan, all_results[mask, :rel_error])
                push!(cells, rpad(isempty(v) ? "N/A" : fmt(median(v)), 12))
            end
        end
        println(rpad(pfx, 18), " | ", join(cells, " | "))
    end
end

# ──────────────────────────────────────────────────────────────────────
# 4. Table 3: Compact summary
# ──────────────────────────────────────────────────────────────────────

println("\n\n")
println("#"^70)
println("# TABLE 3: COMPACT SUMMARY — method → [d0 d1 d2 d3 d4 d5 d6 d7]")
println("#"^70)

for noise_type in ["multiplicative", "additive"]
    nt_short = noise_type == "multiplicative" ? "mult" : "add"
    for nn in noise_names
        tag = "$(nt_short)_n$nn"
        println("\n--- Noise = $nn ($noise_type) ---")
        for pfx in method_prefixes
            full_name = "$(pfx)_$tag"
            cells = [begin
                mask = (all_results.interpolator .== full_name) .& (all_results.deriv_order .== n)
                v = filter(!isnan, all_results[mask, :rel_error])
                isempty(v) ? "N/A" : fmt(median(v))
            end for n in 0:MAX_DERIV]
            @printf("  %-18s  %s\n", pfx, join([rpad(c, 13) for c in cells], " "))
        end
    end
end

# ──────────────────────────────────────────────────────────────────────
# 5. Verification checks
# ──────────────────────────────────────────────────────────────────────
println("\n\n")
println("#"^70)
println("# VERIFICATION CHECKS")
println("#"^70)

println("\n✓ Noiseless consistency check (mult vs add should be identical at noise=0):")
for pfx in method_prefixes
    for dn in [0, 3, 5]
        mask_m = (all_results.interpolator .== "$(pfx)_mult_n0") .& (all_results.deriv_order .== dn)
        mask_a = (all_results.interpolator .== "$(pfx)_add_n0") .& (all_results.deriv_order .== dn)
        vm = filter(!isnan, all_results[mask_m, :rel_error])
        va = filter(!isnan, all_results[mask_a, :rel_error])
        if !isempty(vm) && !isempty(va)
            diff = abs(median(vm) - median(va))
            status = diff < 1e-12 ? "✓ IDENTICAL" : "✗ DIFFER (Δ=$(diff))"
            @printf("    %-18s d%d: %s\n", pfx, dn, status)
        end
    end
end

println("\n  Noiseless d5 check (should all be < 0.1%):")
for pfx in method_prefixes
    mask = (all_results.interpolator .== "$(pfx)_mult_n0") .& (all_results.deriv_order .== 5)
    v = filter(!isnan, all_results[mask, :rel_error])
    val = isempty(v) ? NaN : median(v)
    status = isnan(val) ? "N/A" : (val < 0.001 ? "✓ PASS" : "✗ FAIL")
    @printf("    %-18s  d5=%-12s  %s\n", pfx, isempty(v) ? "N/A" : fmt(median(v)), status)
end

# ──────────────────────────────────────────────────────────────────────
# 6. Save combined CSVs
# ──────────────────────────────────────────────────────────────────────

all_results[!, :noise_type] = [
    occursin("mult_", row.interpolator) ? "multiplicative" : "additive"
    for row in eachrow(all_results)
]
CSV.write(joinpath(OUTDIR, "noise_comparison_results.csv"), all_results)

summary = DataFrame(method=String[], noise_type=String[], noise=String[],
                     deriv_order=Int[],
                     median_rel=Float64[], max_rel=Float64[], mean_rel=Float64[])
for nm in unique(all_results.interpolator), n in 0:MAX_DERIV
    v = filter(!isnan, all_results[(all_results.interpolator .== nm) .& (all_results.deriv_order .== n), :rel_error])
    nt = occursin("mult_", nm) ? "multiplicative" : "additive"
    nn = replace(nm, r".*_n" => "")
    pfx = replace(nm, r"_(mult|add)_n.*" => "")
    push!(summary, (pfx, nt, nn, n,
        isempty(v) ? NaN : median(v),
        isempty(v) ? NaN : maximum(v),
        isempty(v) ? NaN : mean(v)))
end
CSV.write(joinpath(OUTDIR, "noise_comparison_summary.csv"), summary)

println("\n" * "="^70)
println("Done! Saved to:")
println("  $OUTDIR/noise_comparison_results.csv")
println("  $OUTDIR/noise_comparison_summary.csv")
println("="^70)
