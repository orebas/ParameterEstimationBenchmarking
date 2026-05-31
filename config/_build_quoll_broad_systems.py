#!/usr/bin/env python3
"""Build systems_quoll_broad.json = wallaby-23 (config/systems.json) + 4 branch systems.

Branch defs transcribed from ODEParameterEstimation
src/examples/models/branch_stress_systems.jl (quoll-v1). PEB samples params/ICs
in PARAM_INTERVAL per trial, so no true-params/ICs are stored here — only structure.
"""
import json
from pathlib import Path

CFG = Path(__file__).resolve().parent

base = json.load(open(CFG / "systems.json"))
assert "systems" in base
existing = {s["name"] for s in base["systems"]}

branch = [
    {
        "name": "latent_subpopulation_branch",
        "ode_system": {
            "S":  "-b1*S*I1 - b2*S*I2 - b3*S*I3",
            "I1": "b1*S*I1 - a1*I1",
            "I2": "b2*S*I2 - a2*I2",
            "I3": "b3*S*I3 - a3*I3",
            "R":  "a1*I1 + a2*I2 + a3*I3",
        },
        "measurements": {"y1": "S", "y2": "I1 + I2 + I3", "y3": "R"},
        "non_identifiable": [],
        "state_variables": ["S", "I1", "I2", "I3", "R"],
        "measurement_variables": ["y1", "y2", "y3"],
        "parameter_variables": ["a1", "a2", "a3", "b1", "b2", "b3"],
        "time_interval": [0.0, 12.0],
    },
    {
        "name": "latent_subpopulation_observed_control",
        "ode_system": {
            "S":  "-b1*S*I1 - b2*S*I2 - b3*S*I3",
            "I1": "b1*S*I1 - a1*I1",
            "I2": "b2*S*I2 - a2*I2",
            "I3": "b3*S*I3 - a3*I3",
            "R":  "a1*I1 + a2*I2 + a3*I3",
        },
        "measurements": {"y1": "S", "y2": "I1", "y3": "I2", "y4": "I3", "y5": "R"},
        "non_identifiable": [],
        "state_variables": ["S", "I1", "I2", "I3", "R"],
        "measurement_variables": ["y1", "y2", "y3", "y4", "y5"],
        "parameter_variables": ["a1", "a2", "a3", "b1", "b2", "b3"],
        "time_interval": [0.0, 12.0],
    },
    {
        "name": "receptor_subtype_binding_branch",
        "ode_system": {
            "L":  "-kon1*L*(R1tot - Ca) + koff1*Ca - kon2*L*(R2tot - Cb) + koff2*Cb",
            "Ca": "kon1*L*(R1tot - Ca) - koff1*Ca",
            "Cb": "kon2*L*(R2tot - Cb) - koff2*Cb",
        },
        "measurements": {"y1": "L", "y2": "Ca + Cb"},
        "non_identifiable": [],
        "state_variables": ["L", "Ca", "Cb"],
        "measurement_variables": ["y1", "y2"],
        "parameter_variables": ["R1tot", "R2tot", "kon1", "kon2", "koff1", "koff2"],
        "time_interval": [0.0, 8.0],
    },
    {
        "name": "receptor_subtype_binding_observed_control",
        "ode_system": {
            "L":  "-kon1*L*(R1tot - Ca) + koff1*Ca - kon2*L*(R2tot - Cb) + koff2*Cb",
            "Ca": "kon1*L*(R1tot - Ca) - koff1*Ca",
            "Cb": "kon2*L*(R2tot - Cb) - koff2*Cb",
        },
        "measurements": {"y1": "L", "y2": "Ca", "y3": "Cb"},
        "non_identifiable": [],
        "state_variables": ["L", "Ca", "Cb"],
        "measurement_variables": ["y1", "y2", "y3"],
        "parameter_variables": ["R1tot", "R2tot", "kon1", "kon2", "koff1", "koff2"],
        "time_interval": [0.0, 8.0],
    },
]

for s in branch:
    if s["name"] in existing:
        raise SystemExit(f"duplicate system name already in base: {s['name']}")
    base["systems"].append(s)

out = CFG / "systems_quoll_broad.json"
json.dump(base, open(out, "w"), indent=2)
print(f"wrote {len(base['systems'])} systems -> {out}")
print("branch systems appended:", [s["name"] for s in branch])
