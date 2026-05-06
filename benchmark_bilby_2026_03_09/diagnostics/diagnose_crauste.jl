#=============================================================================
  DIAGNOSTIC: crauste instance 0, noise=0
  Regression: 12.5% multipoint vs 87.5% old nopolish

  Run via SLURM (not login node):
    sbatch --wrap="julia --startup-file=no benchmark_bilby_2026_03_09/diagnostics/diagnose_crauste.jl" \
           --cpus-per-task=4 --mem=16G --time=2:00:00 -o output/diag_crauste.out -e output/diag_crauste.err
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
println("  DIAGNOSTIC: crauste (instance 0, noise=0)")
println("  Regression: 12.5% multipoint vs 87.5% old nopolish")
println("=" ^ 72)
println()

# ─────────────────────────────────────────────────────────────────────────────
#  MODEL DEFINITION (from generated script)
# ─────────────────────────────────────────────────────────────────────────────

parameters = @parameters mu_N mu_EE mu_LE mu_LL mu_P mu_PE mu_PL delta_NE delta_EL delta_LM rho_E rho_P
states = @variables Npop(t) E(t) L(t) M(t) P(t)
observables = @variables y1(t) y2(t) y3(t) y4(t)

state_equations = [
    D(Npop) ~ (-24270.0*mu_N*Npop - 582.4799999999999*delta_NE*P*Npop) / 16180.0,
    D(E) ~ (582.4799999999999*delta_NE*P*Npop + 10.0*(-1.18*delta_EL - 0.000432*mu_EE*E + 2.56*rho_E*P)*E) / 10.0,
    D(L) ~ (11.799999999999999*delta_EL*E - 10.0*(0.05*delta_LM + 7.2e-7*mu_LE*E + 0.00015000000000000001*mu_LL*L)*L) / 10.0,
    D(M) ~ 0.05*delta_LM*L,
    D(P) ~ (-0.11*mu_P - 3.6e-6*mu_PE*E - 0.00036*mu_PL*L + 0.6*rho_P*P)*P,
]
measured_quantities = [
    y1 ~ 16180.0*Npop,
    y2 ~ 10.0*E,
    y3 ~ 10.0*M + 10.0*L,
    y4 ~ 2.0*P,
]

ic = [0.507, 0.376, 0.275, 0.846, 0.779]
p_true = [0.165, 0.527, 0.581, 0.553, 0.46, 0.188, 0.54, 0.705, 0.586, 0.132, 0.716, 0.192]
time_interval = [0.0, 25.0]

model, mq = create_ordered_ode_system(
    "crauste_0",
    states,
    parameters,
    state_equations,
    measured_quantities,
)

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD DATA (noise-free, instance 0)
# ─────────────────────────────────────────────────────────────────────────────

data_path = joinpath(BENCHMARK_DIR, "filetree", "data_noisy", "crauste_0_0", "data.csv")
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
    "crauste_0",
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
    # Old 12 (bilby nopolish)
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
    # New multipoint-only (4 unique additions)
    InterpolatorS3AdaptSE,
    InterpolatorChebyshevBIC,
    InterpolatorS3AdaptSExRQ,
    InterpolatorChebyshevAICc,
]

println("─" ^ 72)
println("  Running diagnose_model with $(length(all_interpolators)) interpolators ...")
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
println("  RESULTS SUMMARY — crauste_0")
println("=" ^ 72)
println()

r = report.best

println("  Difficulty:        $(r.difficulty)")
println("  Bottleneck:        $(r.bottleneck)")
println("  Best interpolator: $(report.best_interpolator)")
@printf("  Best eval point:   t = %.3f\n", report.best_eval_point)
println()

# Derivative accuracy
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

# Polynomial feasibility
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

# Sensitivity
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

# Data sensitivity top entries
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

# Interpolator comparison grid (if comprehensive report)
if hasproperty(report, :derivative_grid) && length(report.derivative_grid) > 0
    println("─" ^ 72)
    println("  INTERPOLATOR COMPARISON (worst derivative error per interpolator)")
    println("─" ^ 72)
    @printf("  %-30s  %12s  %20s  %5s\n", "Interpolator", "Worst RelErr", "Worst Observable", "Order")
    println("  " * "-" ^ 72)
    # Group by interpolator
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
println("  HTML report: $(OUTPUT_DIR)/artifacts/diagnostics/crauste_0/report.html")
println("  Summary:     $(OUTPUT_DIR)/artifacts/diagnostics/crauste_0/summary.txt")
println()
println("=" ^ 72)
println("  Done.")
println("=" ^ 72)
