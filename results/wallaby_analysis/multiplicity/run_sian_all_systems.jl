### SIAN / StructuralIdentifiability cross-check for all 23 wallaby benchmark systems.
###
### Run with:
###   julia --startup-file=no --project=environments/julia_odepe \
###     results/wallaby_analysis/multiplicity/run_sian_all_systems.jl
###
### For each system, calls StructuralIdentifiability.assess_identifiability and prints
### the per-variable status (:globally / :locally / :nonidentifiable).
###
### Empirical multiplicity claims being cross-checked
### (from MULTIPLICITY_FINDINGS.md):
###   daisy_mamil4: multiplicity 2  -> expect at least one :locally
###   seir:         multiplicity 2  -> expect at least one :locally
###   slow_fast:    multiplicity 2  -> expect at least one :locally
###   All others:   multiplicity 1  -> all :globally (no :locally, no :nonidentifiable)
### Plus aircraft_pitch's theta(t) should be :nonidentifiable, and biohydrogenation's
### x7(t) should be :nonidentifiable (these are the structurally-unidentifiable axes).

using Pkg; Pkg.activate(raw"/pfssfs1/scratch/oren-qc-13/ParameterEstimationBenchmarking/environments/julia_odepe")
using StructuralIdentifiability
using Logging

const SEP = "=" ^ 80

# Helper to capture per-system results into a summary the parent script can read.
const SUMMARY = Dict{String, Dict{String, Symbol}}()
const ERRORS = Dict{String, String}()

function run_one(name::String, ode_constructor::Function)
    println()
    println(SEP)
    println(name)
    println(SEP)
    try
        ode = ode_constructor()
        t0 = time()
        res = StructuralIdentifiability.assess_identifiability(ode; loglevel=Logging.Warn)
        dt = time() - t0
        sys_summary = Dict{String, Symbol}()
        # Sort by string repr for stable output
        keys_sorted = sort(collect(keys(res)); by = x -> string(x))
        for k in keys_sorted
            v = res[k]
            ks = string(k)
            println("  $ks => $v")
            sys_summary[ks] = v
        end
        println("[time: $(round(dt; digits=2)) s]")
        SUMMARY[name] = sys_summary
    catch e
        println("ERROR: $e")
        ERRORS[name] = string(e)
    end
end

###############################################################################
# 1. aircraft_pitch
###############################################################################
run_one("aircraft_pitch", () -> StructuralIdentifiability.@ODEmodel(
    theta'(t) = q(t),
    alpha'(t) = (0.05*q(t) - 0.002*Z_alpha*alpha(t)) / 0.1,
    q'(t) = (-M_alpha*alpha(t) - M_delta_e*sin(2.0*t) - 0.2*M_q*q(t)) / 0.05,
    y1(t) = 0.05*q(t)
))

###############################################################################
# 2. bicycle_model
###############################################################################
run_one("bicycle_model", () -> StructuralIdentifiability.@ODEmodel(
    vy'(t) = ((160000.0*Cf*(0.05*sin(0.5*t) + (-0.12*r(t) - 0.5*vy(t)) / 20.0) + (8000.0)*Cr*(0.13999999999999999*r(t) - 0.5*vy(t))) / (3000.0*m_veh) - 2.0*r(t)) / 0.5,
    r'(t) = (192000.0*Cf*(0.05*sin(0.5*t) + (-0.12*r(t) - 0.5*vy(t)) / 20.0) - (11200.0)*Cr*(0.13999999999999999*r(t) - 0.5*vy(t))) / 250.0,
    y1(t) = 0.1*r(t),
    y2(t) = 0.5*vy(t)
))

###############################################################################
# 3. biohydrogenation
###############################################################################
run_one("biohydrogenation", () -> StructuralIdentifiability.@ODEmodel(
    x5'(t) = ((-0.3*k7*x5(t)) / (2.0*k8 + 0.5*x6(t) + 0.5*x5(t)) + (8.0*k5*x4(t)) / (4.0*k6 + 8.0*x4(t))) / 0.5,
    x7'(t) = (0.2*(10.0*k10 - 0.5*x6(t))*k9*x6(t)) / (5.0*k10),
    x4'(t) = (-8.0*k5*x4(t)) / (8.0*(4.0*k6 + 8.0*x4(t))),
    x6'(t) = ((-0.2*(10.0*k10 - 0.5*x6(t))*k9*x6(t)) / (10.0*k10) + (0.3*k7*x5(t)) / (2.0*k8 + 0.5*x6(t) + 0.5*x5(t))) / 0.5,
    y1(t) = 8.0*x4(t),
    y2(t) = 0.5*x5(t)
))

###############################################################################
# 4. boost_converter
###############################################################################
run_one("boost_converter", () -> StructuralIdentifiability.@ODEmodel(
    vC'(t) = ((-48.0*vC(t)) / (20.0*R_load) + 2.0*(0.5 - 0.1*sin(5.0*t))*iL(t)) / (1.92*C_cap),
    iL'(t) = (12.0 - 48.0*(0.5 - 0.1*sin(5.0*t))*vC(t)) / (0.08*L),
    y1(t) = 48.0*vC(t),
    y2(t) = 2.0*iL(t)
))

###############################################################################
# 5. brusselator
###############################################################################
run_one("brusselator", () -> StructuralIdentifiability.@ODEmodel(
    Yc'(t) = 6.0*b*X(t) - 16.0*a*Yc(t)*(X(t)^2),
    X'(t) = 0.5 - 0.5*X(t) - 3.0*b*X(t) + 16.0*a*Yc(t)*(X(t)^2),
    y1(t) = 2.0*X(t),
    y2(t) = 2.0*Yc(t)
))

###############################################################################
# 6. crauste
###############################################################################
run_one("crauste", () -> StructuralIdentifiability.@ODEmodel(
    M'(t) = 0.05*delta_LM*L(t),
    P'(t) = (-0.11*mu_P - 3.6e-6*mu_PE*E(t) - 0.00036*mu_PL*L(t) + 0.6*rho_P*P(t))*P(t),
    Npop'(t) = (-24270.0*mu_N*Npop(t) - 582.4799999999999*delta_NE*P(t)*Npop(t)) / 16180.0,
    L'(t) = (11.799999999999999*delta_EL*E(t) - 10.0*(0.05*delta_LM + 7.2e-7*mu_LE*E(t) + 0.00015000000000000001*mu_LL*L(t))*L(t)) / 10.0,
    E'(t) = (582.4799999999999*delta_NE*P(t)*Npop(t) + 10.0*(-1.18*delta_EL - 0.000432*mu_EE*E(t) + 2.56*rho_E*P(t))*E(t)) / 10.0,
    y1(t) = 16180.0*Npop(t),
    y2(t) = 10.0*E(t),
    y3(t) = 10.0*M(t) + 10.0*L(t),
    y4(t) = 2.0*P(t)
))

###############################################################################
# 7. cstr (has rational dependence; sin(t))
###############################################################################
run_one("cstr", () -> StructuralIdentifiability.@ODEmodel(
    C'(t) = (1.0 - C(t)) / (2.0*tau) - 1.999863916554819*r_eff(t)*C(t),
    Temp'(t) = (Tin - Temp(t)) / (2.0*tau) + 0.0285694845222117*dH_rhoCP*r_eff(t)*C(t) - 2.0*UA_VrhoCP*Temp(t) + 0.8571428571428571*UA_VrhoCP + 0.05714285714285714*UA_VrhoCP*sin(0.5*t),
    r_eff'(t) = 12.5*r_eff(t)/(Temp(t)^2)*((Tin - Temp(t)) / (2.0*tau) + 0.0285694845222117*dH_rhoCP*r_eff(t)*C(t) - 2.0*UA_VrhoCP*Temp(t) + 0.8571428571428571*UA_VrhoCP + 0.05714285714285714*UA_VrhoCP*sin(0.5*t)),
    y1(t) = 700.0*Temp(t)
))

###############################################################################
# 8. daisy_mamil3
###############################################################################
run_one("daisy_mamil3", () -> StructuralIdentifiability.@ODEmodel(
    x1'(t) = (0.5*(-1.666*a01 - a21 - 1.334*a31)*x1(t) + 0.334*a12*x2(t) + 0.9990000000000001*a13*x3(t)) / 0.5,
    x2'(t) = -0.334*a12*x2(t) + 0.5*a21*x1(t),
    x3'(t) = (-0.9990000000000001*a13*x3(t) + 0.667*a31*x1(t)) / 1.5,
    y1(t) = 0.5*x1(t),
    y2(t) = x2(t)
))

###############################################################################
# 9. daisy_mamil4
###############################################################################
run_one("daisy_mamil4", () -> StructuralIdentifiability.@ODEmodel(
    x1'(t) = (-0.1*k01*x1(t) + 0.4*k12*x2(t) + 0.8999999999999999*k13*x3(t) + 1.6*k14*x4(t) - 0.5*k21*x1(t) - 0.6000000000000001*k31*x1(t) - 0.7000000000000001*k41*x1(t)) / 0.4,
    x4'(t) = (-1.6*k14*x4(t) + 0.7000000000000001*k41*x1(t)) / 1.6,
    x2'(t) = (-0.4*k12*x2(t) + 0.5*k21*x1(t)) / 0.8,
    x3'(t) = (-0.8999999999999999*k13*x3(t) + 0.6000000000000001*k31*x1(t)) / 1.2,
    y1(t) = 0.4*x1(t),
    y2(t) = 0.8*x2(t),
    y3(t) = 1.2*x3(t) + 1.6*x4(t)
))

###############################################################################
# 10. dc_motor
###############################################################################
run_one("dc_motor", () -> StructuralIdentifiability.@ODEmodel(
    omega_m'(t) = (0.2*Kt*i(t) - 0.1*omega_m(t)) / (0.02*Jm),
    i'(t) = (12.0 - 0.1*omega_m(t) - 2.0*i(t) + 2.0*sin(5.0*t)) / 0.5,
    y1(t) = omega_m(t)
))

###############################################################################
# 11. fitzhugh_nagumo
###############################################################################
run_one("fitzhugh_nagumo", () -> StructuralIdentifiability.@ODEmodel(
    Vm'(t) = (-3.0)*g*(0.5*R(t) - 2.0*Vm(t) + (2.6666666666666665)*(Vm(t)^3)),
    R'(t) = (-0.4*a - 2.0*Vm(t) + 0.2*b*R(t)) / (3.0*g),
    y1(t) = -2.0*Vm(t)
))

###############################################################################
# 12. flexible_arm
###############################################################################
run_one("flexible_arm", () -> StructuralIdentifiability.@ODEmodel(
    theta_t'(t) = omega_t(t),
    omega_m'(t) = (0.5 - 0.1*bm*omega_m(t) - 20.0*k*(-0.5*theta_t(t) + 0.5*theta_m(t))) / (0.1*Jm),
    omega_t'(t) = (-0.05*bt*omega_t(t) - 20.0*k*(0.5*theta_t(t) - 0.5*theta_m(t))) / (0.05*Jt),
    theta_m'(t) = omega_m(t),
    y1(t) = 0.5*theta_m(t),
    y2(t) = 0.5*theta_t(t)
))

###############################################################################
# 13. forced_lotka_volterra (has sin(t))
###############################################################################
run_one("forced_lotka_volterra", () -> StructuralIdentifiability.@ODEmodel(
    x'(t) = (-0.3*sin(2.0*t) + 6.0*alpha*x(t) - 8.0*beta*x(t)*yv(t)) / 2.0,
    yv'(t) = (-12.0*gamma*yv(t) + 4.0*delta*x(t)*yv(t)) / 2.0,
    y1(t) = 2.0*x(t),
    y2(t) = 2.0*yv(t)
))

###############################################################################
# 14. harmonic_oscillator
###############################################################################
run_one("harmonic_oscillator", () -> StructuralIdentifiability.@ODEmodel(
    x1'(t) = -a*x2(t),
    x2'(t) = x1(t) / b,
    y1(t) = 2.0*x1(t),
    y2(t) = x2(t)
))

###############################################################################
# 15. hiv
###############################################################################
run_one("hiv", () -> StructuralIdentifiability.@ODEmodel(
    vv'(t) = (200.0*k*yv(t) - 0.012*uu*vv(t)) / 0.002,
    w'(t) = (-0.008*b*w(t) - 0.08000000000000002*c*q*w(t)*yv(t) + 0.4*c*w(t)*z(t)*yv(t)) / 2.0,
    x'(t) = (2.0*lm - 40.0*d*x(t) - 0.00016*beta*x(t)*vv(t)) / 2000.0,
    z'(t) = -0.2*h*z(t) + 0.08000000000000002*c*q*w(t)*yv(t),
    yv'(t) = (-2.0*a*yv(t) + 0.00016*beta*x(t)*vv(t)) / 2.0,
    y1(t) = 2.0*w(t),
    y2(t) = z(t),
    y3(t) = 2000.0*x(t),
    y4(t) = 0.002*vv(t) + 2.0*yv(t)
))

###############################################################################
# 16. lotka_volterra
###############################################################################
run_one("lotka_volterra", () -> StructuralIdentifiability.@ODEmodel(
    w'(t) = -0.6*k3*w(t) + 4.0*k2*w(t)*r(t),
    r'(t) = 2.0*k1*r(t) - 2.0*k2*w(t)*r(t),
    y1(t) = 4.0*r(t)
))

###############################################################################
# 17. mass_spring_damper
###############################################################################
run_one("mass_spring_damper", () -> StructuralIdentifiability.@ODEmodel(
    vel'(t) = (1.0 - 0.5*c*vel(t) - 8.0*k*x(t)) / m,
    x'(t) = 0.5*vel(t),
    y1(t) = x(t)
))

###############################################################################
# 18. quadrotor (has sin(t))
###############################################################################
run_one("quadrotor", () -> StructuralIdentifiability.@ODEmodel(
    w'(t) = (2.0*sin(t) - 0.2*d*w(t)) / (2.0*m),
    z'(t) = 0.1*w(t),
    y1(t) = 10.0*z(t)
))

###############################################################################
# 19. repressilator
###############################################################################
run_one("repressilator", () -> StructuralIdentifiability.@ODEmodel(
    m3'(t) = -m3(t) + (4.0*beta) / (0.5*(1 + 8.0*n*p2(t))),
    m2'(t) = -m2(t) + (4.0*beta) / (0.5*(1 + 16.0*n*p1(t))),
    p3'(t) = -2.0*alpha*(p3(t) - 0.08333333333333333*m3(t)),
    p2'(t) = -2.0*alpha*(-0.25*m2(t) + p2(t)),
    m1'(t) = -m1(t) + (4.0*beta) / (0.5*(1 + 24.0*n*p3(t))),
    p1'(t) = -2.0*alpha*(-0.125*m1(t) + p1(t)),
    y1(t) = 4.0*p1(t),
    y2(t) = 2.0*p2(t),
    y3(t) = 6.0*p3(t)
))

###############################################################################
# 20. seir
###############################################################################
run_one("seir", () -> StructuralIdentifiability.@ODEmodel(
    S'(t) = (-15840.0*b*In(t)*S(t)) / (3960000.0*Npop(t)),
    E'(t) = ((15840.0*b*In(t)*S(t)) / (2000.0*Npop(t)) - 6.0*nu*E(t)) / 20.0,
    In'(t) = (-4.0*a*In(t) + 6.0*nu*E(t)) / 10.0,
    Npop'(t) = 0,
    y1(t) = 10.0*In(t),
    y2(t) = 2000.0*Npop(t)
))

###############################################################################
# 21. slow_fast
###############################################################################
run_one("slow_fast", () -> StructuralIdentifiability.@ODEmodel(
    eA'(t) = 0,
    xC'(t) = 0.666*k2*xB(t),
    eC'(t) = 0,
    xB'(t) = (0.166*k1*xA(t) - 0.666*k2*xB(t)) / 0.666,
    eB'(t) = 0,
    xA'(t) = -0.5*k1*xA(t),
    y1(t) = xC(t),
    y2(t) = 0.44222400000000006*xA(t)*eA(t) + 0.9990000000000001*eB(t)*xB(t) + 1.666*xC(t)*eC(t),
    y3(t) = 1.332*eA(t),
    y4(t) = 1.666*eC(t)
))

###############################################################################
# 22. sirt_treatment
###############################################################################
run_one("sirt_treatment", () -> StructuralIdentifiability.@ODEmodel(
    S'(t) = -0.08*b*S(t)*In(t)/Npop(t) - 0.032*d*b*S(t)*Tr(t)/Npop(t),
    Npop'(t) = 0,
    Tr'(t) = 6.0*g*In(t) - 0.2*nu*Tr(t),
    In'(t) = 1.52*b*S(t)*In(t)/Npop(t) + 0.608*d*b*S(t)*Tr(t)/Npop(t) - (0.2*a + 0.6*g)*In(t),
    y1(t) = 10.0*Tr(t),
    y2(t) = 2000.0*Npop(t),
    y3(t) = 10.0*In(t)
))

###############################################################################
# 23. vanderpol
###############################################################################
run_one("vanderpol", () -> StructuralIdentifiability.@ODEmodel(
    x1'(t) = 0.5*a*x2(t),
    x2'(t) = -4.0*x1(t) + 2.0*b*x2(t) - 32.0*b*x2(t)*(x1(t)^2),
    y1(t) = 4.0*x1(t),
    y2(t) = x2(t)
))

###############################################################################
# Summary
###############################################################################
println()
println(SEP)
println("SUMMARY")
println(SEP)
empirical = Dict(
    "aircraft_pitch" => 1, "bicycle_model" => 1, "biohydrogenation" => 1,
    "boost_converter" => 1, "brusselator" => 1, "crauste" => 1, "cstr" => 1,
    "daisy_mamil3" => 1, "daisy_mamil4" => 2, "dc_motor" => 1,
    "fitzhugh_nagumo" => 1, "flexible_arm" => 1, "forced_lotka_volterra" => 1,
    "harmonic_oscillator" => 1, "hiv" => 1, "lotka_volterra" => 1,
    "mass_spring_damper" => 1, "quadrotor" => 1, "repressilator" => 1,
    "seir" => 2, "slow_fast" => 2, "sirt_treatment" => 1, "vanderpol" => 1
)
all_sys = sort(collect(keys(empirical)))
println(rpad("system", 24) * rpad("emp_mult", 10) * rpad("SI_global", 10) * rpad("SI_local", 9) * rpad("SI_nonid", 10) * "verdict")
println("-" ^ 90)
for s in all_sys
    info = get(SUMMARY, s, nothing)
    em = empirical[s]
    if info === nothing
        err = get(ERRORS, s, "missing")
        verdict = "ERROR: $(first(err, 40))"
        println(rpad(s, 24) * rpad("$em", 10) * rpad("-", 10) * rpad("-", 9) * rpad("-", 10) * verdict)
        continue
    end
    n_glob = count(==(:globally), values(info))
    n_loc  = count(==(:locally),  values(info))
    n_non  = count(==(:nonidentifiable), values(info))
    # Expected: empirical mult 1 -> n_loc == 0; empirical mult 2 -> n_loc >= 1
    verdict = if em == 1 && n_loc == 0
        "CONFIRMED (mult=1)"
    elseif em >= 2 && n_loc >= 1
        "CONFIRMED (mult>=2 plausible)"
    elseif em == 1 && n_loc >= 1
        "MISMATCH: empirical=1 but SI finds locally"
    elseif em >= 2 && n_loc == 0
        "MISMATCH: empirical>=2 but SI says fully globally"
    else
        "?"
    end
    println(rpad(s, 24) * rpad("$em", 10) * rpad("$n_glob", 10) * rpad("$n_loc", 9) * rpad("$n_non", 10) * verdict)
end

println()
println(SEP)
println("DETAILED PER-VAR STATUS")
println(SEP)
for s in all_sys
    info = get(SUMMARY, s, nothing)
    info === nothing && continue
    # Group variables by status
    glob = sort([k for (k, v) in info if v == :globally])
    loc  = sort([k for (k, v) in info if v == :locally])
    non  = sort([k for (k, v) in info if v == :nonidentifiable])
    println("$s:")
    if !isempty(glob); println("  globally:  " * join(glob, ", ")); end
    if !isempty(loc);  println("  locally:   " * join(loc,  ", ")); end
    if !isempty(non);  println("  nonident:  " * join(non,  ", ")); end
end

if !isempty(ERRORS)
    println()
    println(SEP)
    println("ERRORS")
    println(SEP)
    for (s, e) in ERRORS
        println("$s: $e")
    end
end

println()
println("DONE_ALL_SYSTEMS")
