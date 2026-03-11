#!/usr/bin/env python3

import os
import sys
import json
import numpy as np
import shlex
import subprocess
import chevron
import pandas as pd
pd.set_option("display.precision",16)
import shutil

import argparse
from datetime import datetime
from pathlib import Path
from subprocess import PIPE

from shared import warn, get_settings, JULIA_ENVIRONMENTS, get_file_meta_header
    
def generate_instance(args, system, instance_id, param_vals, initial_vals):
    state_values = { 
        varname: initial_vals[i] 
        for i, varname in enumerate(system["state_variables"]) 
    }
    parameter_values = {
        varname: param_vals[i]
        for i, varname in enumerate(system["parameter_variables"]) 
    }
    # Use per-model time_interval if available, otherwise fall back to global config
    time_interval = system.get("time_interval", args.config['TIME_INTERVAL'])
    instance = {
        "id": instance_id,
        "state_values": state_values,
        "parameter_values": parameter_values,
        "time": {"start": time_interval[0], "end": time_interval[1], "count": args.config['NUM_PTS']},
        "count": args.config['NUM_PTS'],
        "non_identifiable": system["non_identifiable"]
    }
    instance = instance | system.copy()
    instance["noise_free_measurements"] = system.get("noise_free_measurements", [])
    instance["fixed_initial_conditions"] = system.get("fixed_initial_conditions", {})
    return instance

def main(args):
    np.random.seed(0)

    with open(args.config, 'r') as io:
        args.config_path = args.config
        args.config = json.load(io)
    with open(args.systems, 'r') as io:
        args.systems_path = args.systems
        args.systems = json.load(io)
        
    # Form a unique ID
    parent = Path(__file__).parent.parent.resolve()
    if args.directory is None:
        identifier = datetime.now().strftime("%Y_%m_%d_%H_%M")
    else:
        identifier = args.directory
    output_dir = (parent / Path(identifier)).absolute().resolve()
    
    print(f"""
###  GENERATING SYNTHETIC DATA  ###

SYSTEMS:            {args.systems_path}
  {", ".join(map(lambda sys: sys['name'], args.systems['systems']))}

CONFIG:             {args.config_path}
  TEMPLATE          {args.config['TEMPLATE_GENERATION']}
  NUM_TESTS:        {args.config['NUM_TESTS']}
  TIME_INTERVAL:    {args.config['TIME_INTERVAL']}
  PARAM_INTERVAL:   {args.config['PARAM_INTERVAL']}
  NUM_PTS:          {args.config['NUM_PTS']}
  NOISE_LEVEL:      {args.config['NOISE_LEVEL']}
  NOISE_TYPE:       {args.config['NOISE_TYPE']}
  SEARCH_BOUNDS:    {args.config['SEARCH_BOUNDS']}

ENV:
  JULIA             {(parent / JULIA_ENVIRONMENTS["odepe"]).as_posix()}

OUTPUT:             {output_dir.as_posix()}
  SCRIPTS:          {(output_dir / args.config['FILETREE'] / args.config['DATA_GENERATION_DIR']).as_posix()}
  DATA:             {(output_dir / args.config['FILETREE'] / args.config['DATA_DIR']).as_posix()}
  HUGE_JSON:        {(output_dir / 'huge_json.json').as_posix()}
""")

    # Create output directories
    if os.path.exists(output_dir):
        warn(f"Directory {output_dir} already exists.")
        answer = input("Would you like to redo the generation? (y/n) ")
        if answer.lower() == 'y':
            warn(f"Removing existing directory {output_dir}")
            shutil.rmtree(output_dir)
        else:
            warn(f"Try running the script again or delete previous directory. Directory {output_dir} already exists.")
            exit(1)

    os.makedirs(output_dir)
    os.makedirs(output_dir / args.config['FILETREE'])
    os.makedirs(output_dir / args.config['FILETREE'] / args.config['DATA_GENERATION_DIR'])
    os.makedirs(output_dir / args.config['FILETREE'] / args.config['DATA_DIR'])
    os.makedirs(output_dir / "config")
    
    with open(output_dir / "config" / "config.json", "w") as io:
        json.dump(args.config, io, indent=2)
    with open(output_dir / "config" / "systems.json", "w") as io:
        json.dump(args.systems, io, indent=2)

    # Generate data and populate instances
    instance_stash = {}
    
    instances_to_generate = []
    for system in args.systems["systems"]:
        for i in range(args.config['NUM_TESTS']):
            instance_name = system["name"] + "_" + str(i)
            instances_to_generate.append(instance_name)

    while instances_to_generate:
        for instance_name in instances_to_generate:
            system = args.systems["systems"][[system["name"] for system in args.systems["systems"]].index("_".join(instance_name.split("_")[:-1]))]
            data_filepath = Path("..") / args.config['DATA_DIR'] / (instance_name + ".csv")
            data_generation_filepath = output_dir / args.config['FILETREE'] / args.config['DATA_GENERATION_DIR'] / (instance_name + ".jl")
            log_filepath = output_dir / args.config['FILETREE'] / args.config['DATA_GENERATION_DIR'] / (instance_name + "_logs.txt")

            param_values = np.random.uniform(low=args.config['PARAM_INTERVAL'][0], high=args.config['PARAM_INTERVAL'][1], size=len(system["parameter_variables"])).round(3).tolist()

            # Bicycle model: reject Cf/Cr > 2.5 (oversteer bifurcation)
            if system["name"] == "bicycle_model":
                cf_idx = system["parameter_variables"].index("Cf")
                cr_idx = system["parameter_variables"].index("Cr")
                for _ in range(100):
                    if param_values[cf_idx] / param_values[cr_idx] <= 2.5:
                        break
                    param_values = np.random.uniform(
                        low=args.config['PARAM_INTERVAL'][0],
                        high=args.config['PARAM_INTERVAL'][1],
                        size=len(system["parameter_variables"])
                    ).round(3).tolist()

            state_values = np.random.uniform(low=args.config['PARAM_INTERVAL'][0], high=args.config['PARAM_INTERVAL'][1], size=len(system["state_variables"])).round(3).tolist()

            # Override ICs for states with fixed initial conditions (e.g., oscillator inputs)
            fixed_ics = system.get("fixed_initial_conditions", {})
            for idx, varname in enumerate(system["state_variables"]):
                if varname in fixed_ics:
                    state_values[idx] = fixed_ics[varname]

            instance = generate_instance(args, system, instance_name, param_values, state_values)
            instance_stash[instance_name] = instance
            
            settings = get_settings(args, instance)
            settings.update({'data_filepath'  : data_filepath.as_posix()})
            julia_env_abs = str((parent / "environments" / "julia_odepe").resolve())
            settings.update({'julia_env_path' : f'raw"{julia_env_abs}"'})

            with open(parent / args.config['TEMPLATE_GENERATION'], 'r') as template:
                julia_file = chevron.render(template, settings, warn=True)

            file_meta_header = get_file_meta_header("#")
            with open(data_generation_filepath, 'w') as output_file:
                output_file.write(file_meta_header + julia_file)

        cmd = shlex.split('julia ' + str(Path('src/simple_fast_generate_data.jl').as_posix()) + ' ' + str(output_dir) + ' ' + "\"" + ",".join(instances_to_generate) + "\"")
        try:
            output = subprocess.run(
                cmd,
                check=True,
                stdout=sys.stdout,
                stderr=sys.stderr,
            )
        except subprocess.CalledProcessError as err:
            warn("Error from {}".format(cmd))    
    
        instances = {"instances":[]}
        print(f"""
    ###  GENERATING NOISY DATA  ###

    OUTPUT:             {output_dir / args.config['FILETREE'] / args.config['DATA_DIR_NOISY']}
    """)

        instances_to_generate = []
        for (mnemonic, noise_level) in args.config['NOISE_LEVEL'].items():
            for system in args.systems["systems"]:
                print(mnemonic, system["name"])
                instance_basename = system["name"] + "_"
                for i in range(args.config['NUM_TESTS']):
                    instance_name = instance_basename + str(i)
                    
                    data_filepath_orig = output_dir / args.config['FILETREE'] / args.config['DATA_DIR'] / (instance_name + ".csv")

                    if not os.path.exists(data_filepath_orig):
                        if instance_name not in set(instances_to_generate):
                            instances_to_generate.append(instance_name)
                            warn(f"Need to regenerate data for {instance_name}")
                        continue

                    df = pd.read_csv(data_filepath_orig, header=None, index_col=False)
                    if noise_level == 0:
                        df = df
                    else:
                        assert args.config['NOISE_TYPE'] in ("ADDITIVE", "MULTIPLICATIVE")
                        # Skip noise on time column (0) and noise-free measurement columns
                        noise_free = set(system.get("noise_free_measurements", []))
                        meas_vars = system["measurement_variables"]
                        noisy_cols = [i+1 for i, mv in enumerate(meas_vars) if mv not in noise_free]
                        if noisy_cols:
                            if args.config['NOISE_TYPE'] == "ADDITIVE":
                                df.loc[:, noisy_cols] += list(df[noisy_cols].mean()) * np.random.normal(scale=noise_level, size=(len(df), len(noisy_cols)))
                            elif args.config['NOISE_TYPE'] == "MULTIPLICATIVE":
                                df.loc[:, noisy_cols] *= (1 + np.random.normal(scale=noise_level, size=(len(df), len(noisy_cols))))
                            else:
                                assert False

                    instance = {}
                    instance = instance | instance_stash[instance_name]
                    instance['id'] = instance['id'] + "_" + mnemonic
                    instance['data'] = df.values.T.tolist()
                    instances['instances'].append(instance)

                    instance_path = output_dir / args.config['FILETREE'] / args.config['DATA_DIR_NOISY'] / instance['id']
                    os.makedirs(instance_path, exist_ok=True)
                    df.to_csv(instance_path / 'data.csv', index=False, header=False)
        
    instances['instances'] = [instance | {'index': i} for i, instance in enumerate(instances['instances'])]

    with open(output_dir / "huge_json.json", "w") as io:
        json.dump(instances, io, indent=None)

    print(f"Generated instances: {len(instances['instances'])}")
        
if __name__=='__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("config", help="The file config.json")
    parser.add_argument("systems", help="The file systems.json")
    parser.add_argument("-d", "--directory", help="The name of the generated directory")
    args = parser.parse_args()
    
    main(args)
