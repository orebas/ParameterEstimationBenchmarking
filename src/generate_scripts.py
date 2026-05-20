#!/usr/bin/env python3

import os
import sys
import re
import json
import tqdm
import numpy as np
import shlex
import subprocess
import chevron
from pprint import pprint
from subprocess import Popen, PIPE
import shutil
import pandas as pd
pd.set_option("display.precision",16)

import argparse
from datetime import datetime
from pathlib import Path
from termcolor import colored
from copy import deepcopy

from shared import warn, info, get_settings, AVAILABLE_SOFTWARE, JULIA_ENVIRONMENTS, get_file_meta_header, cell_seed

DEFAULT_CONFIG_VALUES = {
    "PATH_TO_AMIGO2": "",
    "ODEPE_POLISH": "true",
    "POLISH_MAXTIME": 1200.0,
    "POLISH_DIVERGENCE_FACTOR": 10.0,
    "POLISH_STAGNATION_WINDOW": 50,
    "POLISH_ODE_MAXITERS": 20000,
}

TEMPLATE_ESTIMATION = {
    "pe"     : "templates/julia_template_for_estimation_pe.jl",
	"odepe"  : "templates/julia_template_for_estimation_odepe.jl",
    "amigo2" : "templates/amigo2.m.template",
    "iqm"    : {
        "script":   "templates/iqm.m.template",
        "csv":      "templates/iqm_experiment.csv.template",
        "exp":      "templates/iqm_experiment.exp.template",
        "models":   "templates/iqm_model.txt.template"
    },
    "sciml" : "templates/julia_template_for_estimation_sciml.jl",
    # Kernel-variant templates archived 2026-05-06; preserved for old-benchmark regen.
    "odepe_kernel_se"         : "templates/archive/julia_template_for_estimation_odepe_kernel_se.jl",
    "odepe_kernel_rq"         : "templates/archive/julia_template_for_estimation_odepe_kernel_rq.jl",
    "odepe_kernel_se_plus_rq" : "templates/archive/julia_template_for_estimation_odepe_kernel_se_plus_rq.jl",
    "odepe_kernel_se_times_rq": "templates/archive/julia_template_for_estimation_odepe_kernel_se_times_rq.jl",
    "odepe_multipoint"        : "templates/julia_template_for_estimation_odepe_multipoint.jl",
    # Numbat-era ODEPE variants. Both polish/nopolish render from the same template;
    # the only difference is `ODEPE_POLISH` injected via SOFTWARE_OVERRIDES below.
    "odepe_v2_polish"         : "templates/julia_template_for_estimation_odepe_v2.jl",
    "odepe_v2_nopolish"       : "templates/julia_template_for_estimation_odepe_v2.jl",
    "odepe_shade"             : "templates/julia_template_for_estimation_odepe_shade.jl",
}

SOFTWARE_COMMENT = {
    "pe"    : "#",
    "odepe" : "#",
    "amigo2": "%",
    "iqm"   : "%",
    "sciml" : "#",
    "odepe_kernel_se"         : "#",
    "odepe_kernel_rq"         : "#",
    "odepe_kernel_se_plus_rq" : "#",
    "odepe_kernel_se_times_rq": "#",
    "odepe_multipoint"        : "#",
    "odepe_v2_polish"         : "#",
    "odepe_v2_nopolish"       : "#",
    "odepe_shade"             : "#",
}

FILE_EXT = {'pe': 'jl', 'odepe': 'jl', 'sciml': 'jl', 'amigo2': 'm', 'iqm': 'm',
            'odepe_kernel_se': 'jl', 'odepe_kernel_rq': 'jl',
            'odepe_kernel_se_plus_rq': 'jl', 'odepe_kernel_se_times_rq': 'jl',
            'odepe_multipoint': 'jl',
            'odepe_v2_polish': 'jl', 'odepe_v2_nopolish': 'jl',
            'odepe_shade': 'jl'}

# Per-software Mustache overrides applied AFTER get_settings(). Lets us render
# multiple distinct runs from a single template — e.g. odepe_v2 polish/nopolish
# from one file by toggling {{ODEPE_POLISH}}.
SOFTWARE_OVERRIDES = {
    "odepe_v2_polish":   {"ODEPE_POLISH": "true"},
    "odepe_v2_nopolish": {"ODEPE_POLISH": "false"},
}

def get_sciml_measurements(instance):
    import re
    subs = {}
    # Use symbolic solution indexing (MTK v11 compatible) instead of positional
    subs = subs | {x : f"sol[{x}]" for x in instance["state_variables"]}
    subs = subs | {x : f"p[length(ic) + {1+idx}]" for idx, x in enumerate(instance["parameter_variables"])}
    subs = subs | {'*' : '.*'}
    subs = dict((re.escape(k), v) for k, v in subs.items())
    pattern = re.compile("|".join(subs.keys()))
    sciml_measurements = ','.join([pattern.sub(lambda m: subs[re.escape(m.group(0))], value) for key, value in instance["measurements"].items()])
    return sciml_measurements

def _test_get_sciml_measurements():
    instance = {"state_variables": ["x"], "parameter_variables": [], "measurements": {"y1" : "x/x"}}
    assert get_sciml_measurements(instance) == "sol[x]/sol[x]"
    instance = {"state_variables" : ["x1", "x2"], "parameter_variables": ["a", "b"], "measurements": {"y1": "x1", "y2": "a*x1^2 + b * b * x2"}}
    assert get_sciml_measurements(instance) == "sol[x1],p[length(ic) + 1].*sol[x1]^2 + p[length(ic) + 2] .* p[length(ic) + 2] .* sol[x2]"

def main(args):
    assert args.software in AVAILABLE_SOFTWARE or args.software == 'all'
    
    if args.software == 'all':
        args.software = AVAILABLE_SOFTWARE
    else:
        args.software = [args.software]
    
    args.dir = Path(args.dir)
    parent = Path(__file__).parent.parent.resolve()
    
    with open(args.dir / args.config, 'r') as io:
        args.config = DEFAULT_CONFIG_VALUES | json.load(io)

    with open(args.dir / 'huge_json.json', 'r') as io:
        instances = json.load(io)

    # Per-system catalog: read algebraic_multiplicity from config/systems.json
    # (the repo-level config, which has the catalog field). Older benchmark
    # snapshots' bench-dir-local systems.json may predate the field — we
    # fall back to the repo-level config so reruns of older benchmarks
    # still get up-to-date M values without copying the catalog into the
    # snapshot.
    repo_systems_json = parent / "config" / "systems.json"
    if not repo_systems_json.exists():
        repo_systems_json = args.dir / "config" / "systems.json"
    with open(repo_systems_json, "r") as io:
        _systems_doc = json.load(io)
    multiplicity_by_system = {
        s["name"]: int(s.get("algebraic_multiplicity", 1))
        for s in _systems_doc.get("systems", [])
    }
    
    for software in args.software:
        print(f"""
###  GENERATING RUNNABLE FILES  ###

SOFTWARE            {software}
PATH_TO_AMIGO2      {args.config['PATH_TO_AMIGO2']}

CONFIG              {args.config}
TEMPLATE            {TEMPLATE_ESTIMATION[software]}

OUTPUT:             {args.dir}
    SCRIPTS:        {args.dir / args.config['FILETREE'] / args.run}
""")

        if os.path.exists(args.dir / args.config['FILETREE'] / args.run):
            warn(f"Directory {args.dir / args.config['FILETREE'] / args.run} exists.")
            exit(-1)
        
        shutil.copytree(args.dir / args.config['FILETREE'] / args.config['DATA_DIR_NOISY'], args.dir / args.config['FILETREE'] / args.run)
    
        for instance in instances['instances']:
            print(instance['id'])

            settings = deepcopy(args.config)
            settings = settings | get_settings(args, instance)
            settings["id"] = instance["id"]
            settings["data_filepath"] = 'data.csv'
            settings["estimation_result_filepath"] = 'result.csv'
            settings["at_time"] = (settings["time_end"] - settings["time_start"])/2 + settings["time_start"]
            settings["data_expr"] = get_sciml_measurements(instance)
            settings["path_to_src"] = args.config["PATH_TO_AMIGO2"]
            settings["harness_root"] = str(parent)

            # Per-cell deterministic seed — surfaced in templates that need one
            # (notably odepe_shade, where Metaheuristics.SHADE takes an explicit `shade_seed`).
            # `instance['id']` has shape `{system_name}_{instance_idx}_{noise_mnemonic}`,
            # but `system_name` itself can contain underscores (e.g. `daisy_mamil3`).
            # Use `instance['name']` as the bare system name so the parse is unambiguous.
            _suffix = instance['id'].removeprefix(instance['name'] + "_")
            _instance_idx_str, _noise_mnemonic = _suffix.rsplit("_", 1)
            _instance_idx = int(_instance_idx_str)
            _seed = cell_seed(instance['name'], _instance_idx, _noise_mnemonic)
            settings["cell_seed"] = _seed
            settings["shade_seed"] = _seed

            # Algebraic multiplicity from the per-system catalog. Threaded into
            # the ODEPE v2 template via `{{algebraic_multiplicity}}`. When the
            # template renders, ODEPE truncates result.csv to M rows.
            # `nothing` literal (Julia) when no catalog value, preserving
            # legacy K=20 behavior.
            _M = multiplicity_by_system.get(instance['name'])
            settings["algebraic_multiplicity"] = str(_M) if _M is not None else "nothing"

            # Per-software Mustache overrides (e.g. odepe_v2 polish/nopolish toggle)
            settings.update(SOFTWARE_OVERRIDES.get(software, {}))

            file_meta_header = get_file_meta_header(SOFTWARE_COMMENT[software])

            if software in ['pe','odepe','sciml','amigo2',
                            'odepe_kernel_se','odepe_kernel_rq','odepe_kernel_se_plus_rq','odepe_kernel_se_times_rq',
                            'odepe_multipoint',
                            'odepe_v2_polish','odepe_v2_nopolish','odepe_shade']:
                julia_env_name = {"pe": "julia_pe", "odepe": "julia_odepe", "sciml": "julia_sciml",
                                  "odepe_kernel_se": "julia_odepe", "odepe_kernel_rq": "julia_odepe",
                                  "odepe_kernel_se_plus_rq": "julia_odepe", "odepe_kernel_se_times_rq": "julia_odepe",
                                  "odepe_multipoint": "julia_odepe",
                                  "odepe_v2_polish": "julia_odepe", "odepe_v2_nopolish": "julia_odepe",
                                  "odepe_shade": "julia_odepe"}.get(software, "")
                if julia_env_name:
                    julia_env_abs = str((parent / "environments" / julia_env_name).resolve())
                    settings.update({'julia_env_path' : f'raw"{julia_env_abs}"'})
                else:
                    settings.update({'julia_env_path' : '""'})
                with open(args.dir / args.config['FILETREE'] / args.run / instance['id'] / f'script.{FILE_EXT[software]}', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]), settings, warn=True)
                    output_file.write(file_meta_header + testfile)
            elif software in ['iqm']:
                os.makedirs(args.dir / args.config['FILETREE'] / args.run / instance['id'] / 'project', exist_ok=True)
                os.makedirs(args.dir / args.config['FILETREE'] / args.run / instance['id'] / 'project' / 'models', exist_ok=True)
                os.makedirs(args.dir / args.config['FILETREE'] / args.run / instance['id'] / 'project' / 'experiments' / 'data', exist_ok=True)
                with open(args.dir / args.config['FILETREE'] / args.run / instance['id'] / f'script.{FILE_EXT[software]}', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]['script']), settings, warn=True)
                    output_file.write(file_meta_header + testfile)
                with open(args.dir / args.config['FILETREE'] / args.run / instance['id'] / 'project' / 'experiments' / 'data' / 'experiment.csv', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]['csv']), settings)
                    output_file.write(file_meta_header + testfile)
                with open(args.dir / args.config['FILETREE'] / args.run / instance['id'] / 'project' / 'experiments' / 'data' / 'experiment.exp', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]['exp']), settings)
                    output_file.write(file_meta_header + testfile)
                with open(args.dir / args.config['FILETREE'] / args.run / instance['id'] / 'project' / 'models' / 'models.txt', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]['models']), settings)
                    output_file.write(file_meta_header + testfile)
    
if __name__ == "__main__":
    _test_get_sciml_measurements()

    parser = argparse.ArgumentParser()
    parser.add_argument("dir", help="The directory generated by generate_data.py.")
    parser.add_argument("-s", "--software", help="The software to generate scripts for. Possible choices are: {}.".format(', '.join(AVAILABLE_SOFTWARE)), required=True)
    parser.add_argument("-c", "--config", help="The path to config.", required=False, default='config/config.json')
    parser.add_argument("-r", "--run", help="Run id.", required=True)
    args = parser.parse_args()

    main(args)
