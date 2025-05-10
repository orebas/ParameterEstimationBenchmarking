#!/usr/bin/env python3

import os
import sys
import re
import json
import numpy as np
import shlex
import subprocess
import chevron
from pprint import pprint
import pandas as pd
pd.set_option("display.precision",16)
from collections import defaultdict

import argparse
from datetime import datetime
from pathlib import Path
from termcolor import colored

FT = 'files'

def warn(msg):
    print(colored("[WARN] " + msg, "red"))
    
def generate_instance(args, system, instance_id, param_vals, initial_vals):
    state_variables = system["state_variables"]
    state_values = { 
        varname: initial_vals[i] 
        for i, varname in enumerate(system["state_variables"]) 
    }
    parameter_values = {
        varname: param_vals[i]
        for i, varname in enumerate(system["parameter_variables"]) 
    }
    instance = {
        "id": instance_id,
        "state_values": state_values,
        "parameter_values": parameter_values,
        "time": {"start": args.config['TIME_INTERVAL'][0], "end": args.config['TIME_INTERVAL'][1], "count": args.config['NUM_PTS']},
        "count": args.config['NUM_PTS'],
    }
    instance = instance | system.copy()
    return instance

def get_settings(args, instance):
    state_variables = instance["state_variables"]
    states = []
    for i, varname in enumerate(state_variables):
        states.append({
            "varname": varname,
            "value": instance['state_values'][varname],
            "comma": ", " if i < len(state_variables)-1 else "",
            "space": " " if i < len(state_variables)-1 else "",
        })
    parameter_variables = instance["parameter_variables"]
    parameters = []
    for i, varname in enumerate(parameter_variables):
        parameters.append({
            "varname": varname,
            "comma": ", " if i < len(parameter_variables)-1 else "",
            "space": " " if i < len(parameter_variables)-1 else "",
            "true": instance['parameter_values'][varname]
        })
    instance = instance | {
        "states": states,
        "parameters": parameters,
        "time_start": args.config['TIME_INTERVAL'][0],
        "time_end": args.config['TIME_INTERVAL'][1],
        "count": args.config['NUM_PTS'],
    }
    
    instance_name = instance["name"]
    time = instance["time"]
    state_variables = instance["state_variables"]
    states = []
    for i, varname in enumerate(state_variables):
        states.append({
            "varname": varname,
            "comma": ", " if i < len(state_variables)-1 else "",
            "space": " " if i < len(state_variables)-1 else "",
        })
    measurement_variables = instance["measurement_variables"]
    measurements = []
    for i, varname in enumerate(measurement_variables):
        measurements.append({
            "varname": varname,
            "comma": ", " if i < len(measurement_variables)-1 else "",
            "space": " " if i < len(measurement_variables)-1 else "",
        })
    parameter_variables = instance["parameter_variables"]
    parameters = []
    for i, varname in enumerate(parameter_variables):
        parameters.append({
            "varname": varname,
            "comma": ", " if i < len(parameter_variables)-1 else "",
            "space": " " if i < len(parameter_variables)-1 else "",
            "true": instance['parameter_values'][varname],
        })
    components = []
    for i, state_var in enumerate(state_variables):
        components.append({
            "state_var": state_var,
            "state_expr": instance["ode_system"][state_var],
            "comma": ", " if i < len(state_variables)-1 else "",
        })
    measured_quantities = []
    for i, measure_var in enumerate(instance['measurement_variables']):
        measured_quantities.append({
            "measurement": measure_var,
            "measurement_expression": instance['measurements'][measure_var],
            "index": i+1,
            "comma": ", " if i < len(measurement_variables)-1 else "",
        })

    initial_conditions = []
    for i, state_var in enumerate(state_variables):
        initial_conditions.append({
            "value": instance['state_values'][state_var],
            "comma": ", " if i < len(state_variables)-1 else "",
        })


    settings = {
        "name": instance_name, #re.sub(".jl$", "" , instance_name),
        "states": states,
        "num_states": len(states),
        "measurements": measurements,
        "num_measurements": len(measurements),
        "parameters": parameters,
        "num_parameters": len(parameters),
        "components": components,
        "measured_quantities": measured_quantities,
        "initial_conditions": initial_conditions,
        "time_start": instance["time"]["start"],
        "time_end": instance["time"]["end"],
        "time_count": instance["time"]["count"],
        "lower_bound": args.config['SEARCH_BOUNDS'][0],
        "upper_bound": args.config['SEARCH_BOUNDS'][1]
    }

    return settings

def main(args):
    np.random.seed(0)

    with open(args.config, 'r') as io:
        args.config = json.load(io)
    with open(args.systems, 'r') as io:
        args.systems = json.load(io)
        
    # For a unique ID
    identifier = datetime.now().strftime("%Y_%m_%d_%H_%M")
    output_dir = Path(identifier).absolute().resolve()

    print(f"""
###  GENERATING SYNTHETIC DATA  ###

GENERATOR           {args.config['TEMPLATE_GENERATION']}
ESTIMATOR           {args.config['TEMPLATE_ESTIMATION']}

NUM_TESTS:          {args.config['NUM_TESTS']}
TIME_INTERVAL:      {args.config['TIME_INTERVAL']}
PARAM_INTERVAL:     {args.config['PARAM_INTERVAL']}
NUM_PTS:            {args.config['NUM_PTS']}
NOISE_LEVEL:        {args.config['NOISE_LEVEL']}
NOISE_TYPE:         {args.config['NOISE_TYPE']}
SEARCH_BOUNDS:      {args.config['SEARCH_BOUNDS']}

SYSTEMS:            {", ".join(map(lambda sys: sys['name'], args.systems['systems']))}

OUTPUT_DIR:         {output_dir}
  DATA_GENERATION:  {output_dir / FT / args.config['DATA_GENERATION_DIR']}
  DATA:             {output_dir / FT / args.config['DATA_DIR']}
""")

    # Create output directories
    if os.path.exists(output_dir):
        warn(f"Try running the script again or delete previous directory. Directory {output_dir} exists.")
        exit(1)

    os.makedirs(output_dir)
    os.makedirs(output_dir / FT)
    os.makedirs(output_dir / FT / args.config['DATA_GENERATION_DIR'])
    os.makedirs(output_dir / FT / args.config['DATA_DIR'])
    os.makedirs(output_dir / "config")
    
    with open(output_dir / "config" / "config.json", "w") as io:
        json.dump(args.config, io, indent=2)
    with open(output_dir / "config" / "systems.json", "w") as io:
        json.dump(args.systems, io, indent=2)

    # Generate data and populate instances
    # instances = {"instances":[]}
    instance_stash = defaultdict()
    for system in args.systems["systems"]:
        print(system["name"])
        instance_basename = system["name"] + "_"

        i = 0
        while i < args.config['NUM_TESTS']:        
            instance_name = instance_basename + str(i)
            data_filepath = output_dir / FT / args.config['DATA_DIR'] / (instance_name + ".csv")
            data_generation_filepath = output_dir / FT / args.config['DATA_GENERATION_DIR'] / (instance_name + ".jl")

            param_values = np.random.uniform(low=args.config['PARAM_INTERVAL'][0], high=args.config['PARAM_INTERVAL'][1], size=len(system["parameter_variables"])).round(3).tolist()
            state_values = np.random.uniform(low=args.config['PARAM_INTERVAL'][0], high=args.config['PARAM_INTERVAL'][1], size=len(system["state_variables"])).round(3).tolist()

            instance = generate_instance(args, system, instance_name, param_values, state_values)
            instance_stash[instance_name] = instance
            
            settings = get_settings(args, instance)
            settings.update({'data_filepath' : data_filepath})
            
            with open(args.config['TEMPLATE_GENERATION'], 'r') as template:
                julia_file = chevron.render(template, settings)
            
            with open(data_generation_filepath, 'w') as output_file:
                output_file.write(julia_file)
            
            print(instance_name)
            cmd = shlex.split('julia ' + str(data_generation_filepath))
            try:
                output = subprocess.check_output(
                    cmd,
                    stderr=subprocess.DEVNULL
                )
                i += 1
            except subprocess.CalledProcessError as err:
                warn("Error when running {}".format(cmd))
                warn("Trying again with different parameter values.")
                continue

    instances = {"instances":[]}
    print(f"""
###  GENERATING NOISY DATA  ###

""")

    for (mnemonic, noise_level) in args.config['NOISE_LEVEL'].items():
        copy_dir = output_dir / FT / f"copy_{mnemonic}"
        os.makedirs(copy_dir / FT / args.config['DATA_DIR'])
        os.makedirs(copy_dir / FT / args.config['ESTIMATION_DIR'])
        os.makedirs(copy_dir / FT / args.config['ESTIMATION_RESULTS_DIR'])
        print(f"NOISE LEVEL {noise_level}  :  {copy_dir}")
        print(f"  DATA               : {copy_dir / FT / args.config['DATA_DIR']}")
        print(f"  ESTIMATION         : {copy_dir / FT / args.config['ESTIMATION_DIR']}")
        print(f"  ESTIMATION_RESULTS : {copy_dir / FT / args.config['ESTIMATION_RESULTS_DIR']}")
        print()
        
    for (mnemonic, noise_level) in args.config['NOISE_LEVEL'].items():
        copy_dir = output_dir / FT / f"copy_{mnemonic}"
        for system in args.systems["systems"]:
            print(mnemonic, system["name"])
            instance_basename = system["name"] + "_"
            for i in range(args.config['NUM_TESTS']):
                instance_name = instance_basename + str(i)
                
                data_filepath_orig = output_dir / FT / args.config['DATA_DIR'] / (instance_name + ".csv")
                data_filepath_noisy = copy_dir / FT / args.config['DATA_DIR'] / (instance_name + ".csv")
                estimation_filepath = copy_dir / FT / args.config['ESTIMATION_DIR'] / (instance_name + ".jl")
                estimation_result_filepath = copy_dir / FT / args.config['ESTIMATION_RESULTS_DIR'] / (instance_name + ".csv")

                df = pd.read_csv(data_filepath_orig, header=None, index_col=False)
                if noise_level == 0:
                    df = df
                else:
                    assert args.config['NOISE_TYPE'] in ("ADDITIVE", "MULTIPLICATIVE")
                    if args.config['NOISE_TYPE'] == "ADDITIVE":
                        df.loc[:, df.columns != df.columns[0]] += list(df[df.columns[1:]].mean()) * np.random.normal(scale=noise_level, size=(len(df), len(df.columns)-1))
                    elif args.config['NOISE_TYPE'] == "MULTIPLICATIVE": 
                        df.loc[:, df.columns != df.columns[0]] *= (1 + np.random.normal(scale=noise_level, size=(len(df), len(df.columns)-1)))
                    else:
                        exit(1)

                df.to_csv(data_filepath_noisy, index=False, header=False)

                instance = {}
                instance = instance | instance_stash[instance_name]
                instance['id'] = mnemonic + "_" + instance['id']
                instance['data'] = df.values.T.tolist()
                instances['instances'].append(instance)
                
                # settings = get_settings(args, instance)
                # settings["data_filepath"] = data_filepath_noisy
                # settings["estimation_result_filepath"] = estimation_result_filepath
                # settings["at_time"] = (args.config['TIME_INTERVAL'][1] - args.config['TIME_INTERVAL'][0])/2 + args.config['TIME_INTERVAL'][0]
                # settings["data_expr"] = system["sciml_measurements"]
                # with open(estimation_filepath, 'w') as output_file:
                #     testfile = chevron.render(open(args.config['TEMPLATE_ESTIMATION']), settings)
                #     output_file.write(testfile)

    with open(output_dir / "instances.json", "w") as io:
        json.dump(instances, io, indent=None)
        
if __name__=='__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("config", help="The file config.json")
    parser.add_argument("systems", help="The file systems.json")
    args = parser.parse_args()
    
    main(args)
