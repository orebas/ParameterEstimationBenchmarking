#=============================================================================
  DIAGNOSTIC: cstr instance 0, noise=0
  Regression: 0% multipoint vs 25% old nopolish (100% AMIGO2)

  Run via SLURM (not login node):
    sbatch --wrap="julia --startup-file=no benchmark_bilby_2026_03_09/diagnostics/diagnose_cstr.jl" \
           --cpus-per-task=4 --mem=16G --time=2:00:00 -o output/diag_cstr.out -e output/diag_cstr.err
=============================================================================#

using Pkg; Pkg.activate(raw"/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")

using MKL
using ODEParameterEstimation
using ModelingToolkit, OrdinaryDiffEq
using OrderedCollections
using ModelingToolkit: t_nounits as t, D_nounits as D
using CSV
using JSON
using Printf
using Symbolics: Num

ENV["JULIA_NUM_THREADS"] = "4"

const BENCHMARK_DIR = "/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/benchmark_bilby_2026_03_09"
const OUTPUT_DIR = joinpath(BENCHMARK_DIR, "diagnostics")

println("=" ^ 72)
println("  DIAGNOSTIC: cstr (instance 0, noise=0)")
println("  Regression: 0% multipoint vs 25% old nopolish (100% AMIGO2)")
println("=" ^ 72)
println()

# ─────────────────────────────────────────────────────────────────────────────
#  MODEL DEFINITION (from generated script — has sin(0.5*t) forcing)
# ─────────────────────────────────────────────────────────────────────────────

parameters = @parameters tau Tin dH_rhoCP UA_VrhoCP
states = @variables C(t) Temp(t) r_eff(t)
observables = @variables y1(t)

state_equations = [
    D(C) ~ (1.0 - C) / (2.0*tau) - 1.999863916554819*r_eff*C,
    D(Temp) ~ (Tin - Temp) / (2.0*tau) + 0.0285694845222117*dH_rhoCP*r_eff*C - 2.0*UA_VrhoCP*Temp + 0.8571428571428571*UA_VrhoCP + 0.05714285714285714*UA_VrhoCP*sin(0.5*t),
    D(r_eff) ~ 12.5*r_eff/(Temp^2)*((Tin - Temp) / (2.0*tau) + 0.0285694845222117*dH_rhoCP*r_eff*C - 2.0*UA_VrhoCP*Temp + 0.8571428571428571*UA_VrhoCP + 0.05714285714285714*UA_VrhoCP*sin(0.5*t)),
]
measured_quantities = [
    y1 ~ 700.0*Temp,
]

ic = [0.127, 0.867, 0.384]
p_true = [0.15, 0.439, 0.307, 0.779]
time_interval = [0.0, 20.0]

model, mq = create_ordered_ode_system(
    "cstr_0",
    states,
    parameters,
    state_equations,
    measured_quantities,
)

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD DATA (noise-free, instance 0)
# ─────────────────────────────────────────────────────────────────────────────

data_path = joinpath(BENCHMARK_DIR, "filetree", "data_noisy", "cstr_0_0", "data.csv")
println("  Loading data from: $data_path")
csv_data = CSV.read(data_path, Tuple, header=false)
data_sample = OrderedDict{Union{String, Num}, Vector{Float64}}()
data_sample["t"] = collect(Float64, csv_data[1])
for (i, eq) in enumerate(mq)
    data_sample[Num(eq.rhs)] = collect(Float64, csv_data[i + 1])
end
println("  Loaded $(length(data_sample["t"])) time points, $(length(mq)) observables")
println()

pep = ParameterEstimationProblem(
    "cstr_0",
    model,
    mq,
    data_sample,
    time_interval,
    nothing,
    OrderedDict(parameters .=> p_true),
    OrderedDict(states .=> ic),
    0,
)

# ─────────────────────────────────────────────────────────────────────────────
#  RUN DIAGNOSTICS — all 16 interpolators (union of old 12 + new 7)
# ─────────────────────────────────────────────────────────────────────────────

all_interpolators = [
    InterpolatorAAAD,
    InterpolatorAAADGPR,
    InterpolatorS2AAAMLE,
    InterpolatorAGPRobust,
    InterpolatorAGPRobustRQ,
    InterpolatorAGPRobustSEpRQ,
    InterpolatorAGPRobustSExRQ,
    InterpolatorS3SE,
    InterpolatorS3RQ,
    InterpolatorS3SEpRQ,
    InterpolatorS3SExRQ,
    InterpolatorFHD,
    InterpolatorS3AdaptSE,
    InterpolatorChebyshevBIC,
    InterpolatorS3AdaptSExRQ,
    InterpolatorChebyshevAICc,
]

println("─" ^ 72)
println("  Running diagnose_model with $(length(all_interpolators)) interpolators ...")
println("  (cstr has sin(0.5*t) — diagnose_model handles transcendental transform)")
println("─" ^ 72)
println()

cd(OUTPUT_DIR)

report = diagnose_model(pep;
    opts = EstimationOptions(
        datasize = length(data_sample["t"]),
        time_interval = time_interval,
    ),
    interpolators = all_interpolators,
    full_analysis = :top3,
    run_estimation = false,
)

# ─────────────────────────────────────────────────────────────────────────────
#  RESULTS SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

println()
println("=" ^ 72)
println("  RESULTS SUMMARY — cstr_0")
println("=" ^ 72)
println()

r = report.best

println("  Difficulty:        $(r.difficulty)")
println("  Bottleneck:        $(r.bottleneck)")
println("  Best interpolator: $(report.best_interpolator)")
@printf("  Best eval point:   t = %.3f\n", report.best_eval_point)
println()

da = r.derivative_accuracy
println("─" ^ 72)
println("  DERIVATIVE ACCURACY (oracle vs production interpolant)")
println("─" ^ 72)
@printf("  Worst error: %s order %d → %.2e\n", da.worst_obs, da.worst_order, da.worst_rel_error)
println()
@printf("  %-20s  %5s  %12s  %12s  %12s\n", "Observable", "Order", "True", "Interpolant", "RelErr")
println("  " * "-" ^ 65)
for e in da.entries
    status = e.rel_error < 0.01 ? "  " : e.rel_error < 0.10 ? " *" : "**"
    @printf("  %s %-18s  %5d  %12.4e  %12.4e  %12.2e\n",
        status, e.obs, e.order, e.true_val, e.interp_val, e.rel_error)
end
println()

pf = r.polynomial_feasibility
println("─" ^ 72)
println("  POLYNOMIAL FEASIBILITY")
println("─" ^ 72)
println("  System size: $(pf.n_equations) eqs × $(pf.n_variables) vars (square: $(pf.is_square))")
println("  Solutions with perfect data:    $(pf.n_solutions_perfect)")
println("  Solutions with production data: $(pf.n_solutions_production)")
@printf("  Closest to truth (perfect):     %.2e\n", pf.closest_distance_perfect)
@printf("  Closest to truth (production):  %.2e\n", pf.closest_distance_production)
println()

sr = r.sensitivity
println("─" ^ 72)
println("  SENSITIVITY ANALYSIS")
println("─" ^ 72)
@printf("  Jacobian condition number: %.2e\n", sr.jacobian_cond)
println("  Effective rank: $(sr.effective_rank) / $(length(sr.singular_values))")
if length(sr.singular_values) > 0
    @printf("  Singular values: [%.2e, ..., %.2e]\n",
        sr.singular_values[1], sr.singular_values[end])
end
@printf("  Root sensitivity (||dx||/||dd||): %.2e\n", sr.root_sensitivity)
println()

if length(sr.data_sensitivity_unknown_labels) > 0 && length(sr.data_sensitivity_data_labels) > 0
    println("  Data sensitivity matrix S (top entries by magnitude):")
    S = sr.data_sensitivity_matrix
    entries = [(abs(S[i,j]), sr.data_sensitivity_unknown_labels[i],
                sr.data_sensitivity_data_labels[j], S[i,j])
               for i in axes(S,1), j in axes(S,2)]
    sort!(entries, by = x -> x[1], rev = true)
    for (k, (mag, ulabel, dlabel, val)) in enumerate(entries[1:min(10, length(entries))])
        @printf("    S[%-12s, %-12s] = %+.4e\n", ulabel, dlabel, val)
    end
    println()
end

if hasproperty(report, :derivative_grid) && length(report.derivative_grid) > 0
    println("─" ^ 72)
    println("  INTERPOLATOR COMPARISON (worst derivative error per interpolator)")
    println("─" ^ 72)
    @printf("  %-30s  %12s  %20s  %5s\n", "Interpolator", "Worst RelErr", "Worst Observable", "Order")
    println("  " * "-" ^ 72)
    interp_results = Dict{String, Vector}()
    for da_entry in report.derivative_grid
        name = da_entry.interpolator_name
        if !haskey(interp_results, name)
            interp_results[name] = []
        end
        push!(interp_results[name], da_entry)
    end
    for (iname, entries) in sort(collect(interp_results), by=x->minimum(e.worst_rel_error for e in x[2]))
        best_entry = argmin(e -> e.worst_rel_error, entries)
        @printf("  %-30s  %12.2e  %20s  %5d\n",
            iname, best_entry.worst_rel_error, best_entry.worst_obs, best_entry.worst_order)
    end
    println()
end

println("─" ^ 72)
println("  OUTPUT FILES")
println("─" ^ 72)
println("  HTML report: $(OUTPUT_DIR)/artifacts/diagnostics/cstr_0/report.html")
println("  Summary:     $(OUTPUT_DIR)/artifacts/diagnostics/cstr_0/summary.txt")
println()
println("=" ^ 72)
println("  Done.")
println("=" ^ 72)
