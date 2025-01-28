#!/usr/bin/env python3

import os
import sys
import re
import json
import numpy as np
import shlex
import subprocess
import chevron
from scipy.integrate import solve_ivp
from pprint import pprint
#from julia.api import Julia
#import csv
import pandas as pd
pd.set_option("display.precision",16)
from collections import defaultdict

import argparse
from datetime import datetime
from pathlib import Path
from termcolor import colored

from shared import *

SCIML_DAT_STR = {
"biohydrogenation": "(sol[1, :]), (sol[2, :])",
"crauste":"(sol[1, :]), (sol[2, :]), (sol[3, :] .+ sol[4, :]), (sol[5, :])",
"daisy-mamil3": "vcat(sol[1, :]), vcat(sol[2, :])",
"daisy-mamil4": "(sol[1, :]), (sol[2, :]), (sol[3, :] + sol[4, :])",
"harmonic": "vcat(sol[1, :]), vcat(sol[2, :])",
"hiv": "(sol[4, :]), (sol[5, :]), (sol[1, :]), (sol[2, :] .+ sol[3, :])",
"lotka-volterra": "sol[1, :]",
"seir": "(sol[3, :]), (sol[4, :])",
"vanderpol": "(sol[1, :]), (sol[2, :])",
"fitzhugh-nagumo": "(sol[1, :])"
}

def generate_instance(system, instance_name, param_vals, initial_vals):
    state_variables = system["state-variables"]
    states = {}
    for i, varname in enumerate(state_variables):
        states.update({
            varname: initial_vals[i]
        })
    parameter_variables = system["parameter-variables"]
    parameters = {}
    for i, varname in enumerate(parameter_variables):
        parameters.update({
            varname: param_vals[i]
        })
    instance = {
        "name": instance_name,
        "system-name": system["name"],
        "initial": states,
        "parameters": parameters,
        "time": {"start": TIME_INTERVAL[0], "end": TIME_INTERVAL[1], "count": NUM_PTS},
        "count": NUM_PTS,
    }
    return instance

#this really really needs to be cleaned up
def convert_instance(system, instance_name, param_vals, initial_vals):
    state_variables = system["state-variables"]
    states = []
    for i, varname in enumerate(state_variables):
        states.append({
            "varname": varname,
            "value": initial_vals[i],
            "comma": ", " if i < len(state_variables)-1 else "",
            "space": " " if i < len(state_variables)-1 else "",
        })
    parameter_variables = system["parameter-variables"]
    parameters = []
    for i, varname in enumerate(parameter_variables):
        parameters.append({
            "varname": varname,
            "comma": ", " if i < len(parameter_variables)-1 else "",
            "space": " " if i < len(parameter_variables)-1 else "",
            "true": param_vals[i]
        })
    instance = {
        "name": instance_name,
        "system-name": system["name"],
        "states": states,
        "parameters": parameters,
        "time_start": TIME_INTERVAL[0],
        "time_end": TIME_INTERVAL[1],
        "count": NUM_PTS,
    }
    return instance

def get_settings(system, instance):
    instance_name = instance["name"]
    time = instance["time"]
    state_variables = system["state-variables"]
    states = []
    for i, varname in enumerate(state_variables):
        states.append({
            "varname": varname,
            "comma": ", " if i < len(state_variables)-1 else "",
            "space": " " if i < len(state_variables)-1 else "",
        })
    measurement_variables = system["measurement-variables"]
    measurements = []
    for i, varname in enumerate(measurement_variables):
        measurements.append({
            "varname": varname,
            "comma": ", " if i < len(measurement_variables)-1 else "",
            "space": " " if i < len(measurement_variables)-1 else "",
        })
    parameter_variables = system["parameter-variables"]
    parameters = []
    for i, varname in enumerate(parameter_variables):
        parameters.append({
            "varname": varname,
            "comma": ", " if i < len(parameter_variables)-1 else "",
            "space": " " if i < len(parameter_variables)-1 else "",
            "true": instance['parameters'][varname],
        })
    components = []
    for i, state_var in enumerate(state_variables):
        components.append({
            "state_var": state_var,
            "state_expr": system["ode-system"][state_var],
            "comma": ", " if i < len(state_variables)-1 else "",
        })
    measured_quantities = []
    for i, measure_var in enumerate(system['measurement-variables']):
        measured_quantities.append({
            "measurement": measure_var,
            "measurement_expression": system['measurements'][measure_var],
            "index": i+1,
            "comma": ", " if i < len(measurement_variables)-1 else "",
        })

    initial_conditions = []
    for i, state_var in enumerate(state_variables):
        initial_conditions.append({
            "value": instance['initial'][state_var],
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
        "lower_bound": SEARCH_BOUNDS[0],
        "upper_bound": SEARCH_BOUNDS[1]
    }

    return settings

def main(args):
    np.random.seed(0)

    # For a unique ID
    now = datetime.now()
    identifier = now.strftime("%Y-%m-%d-%H-%M")
    output_dir = Path(identifier).absolute().resolve()

    # Read systems' definitions
    with open(args.systems) as systems_json:
        systems = json.load(systems_json)

    print(f"""
###  GENERATING SYNTHETIC DATA  ###

GENERATOR           {args.template_data_generation}
ESTIMATOR           {args.template_estimation}

NUM_TESTS:          {NUM_TESTS}
TIME_INTERVAL:      {TIME_INTERVAL}
PARAM_INTERVAL:     {PARAM_INTERVAL}
NUM_PTS:            {NUM_PTS}
NOISE_LEVEL:        {NOISE_LEVEL}
SEARCH_BOUNDS:      {SEARCH_BOUNDS}

SYSTEMS:            {", ".join(systems['names'])}

OUTPUT_DIR:         {output_dir}
  DATA_GENERATION:  {output_dir / DATA_GENERATION_DIR}
  DATA:             {output_dir / DATA_DIR}
""")

    # Create output directories
    if os.path.exists(output_dir):
        warn(f"Directory {output_dir} exists.")
        exit(1)

    os.makedirs(output_dir)
    os.makedirs(output_dir / DATA_GENERATION_DIR)
    os.makedirs(output_dir / DATA_DIR)
    
    with open(output_dir / "systems.json", "w") as systems_json:
        json.dump(systems, systems_json)

    # Generate data and populate instances
    instances = {"instances":[]}
    instance_stash = defaultdict()
    for system in systems["systems"]:
        print(system["name"])
        instance_basename = system["name"] + "_"

        i = 0
        while i < NUM_TESTS:        
            instance_name = instance_basename + str(i)
            data_filepath = output_dir / DATA_DIR / (instance_name + ".csv")
            data_generation_filepath = output_dir / DATA_GENERATION_DIR / (instance_name + ".jl")

            param_values = np.random.uniform(low=PARAM_INTERVAL[0], high=PARAM_INTERVAL[1], size=len(system["parameter-variables"])).round(3).tolist()
            state_values = np.random.uniform(low=PARAM_INTERVAL[0], high=PARAM_INTERVAL[1], size=len(system["state-variables"])).round(3).tolist()

            instance = generate_instance(system, instance_name, param_values, state_values)
            instances["instances"].append(convert_instance(system, instance_name, param_values, state_values))
            instance_stash[instance_name] = instance
            
            settings = get_settings(system, instance)
            settings.update({'data_filepath' : data_filepath})
            
            with open(args.template_data_generation, 'r') as template:
                julia_file = chevron.render(template, settings)
            
            with open(data_generation_filepath, 'w') as output_file:
                output_file.write(julia_file)
            
            print(instance_name)
            cmd = shlex.split('julia ' + str(data_generation_filepath))
            try:
                output = subprocess.check_output(cmd)
                i += 1 # this is crazy and I love it.
            except subprocess.CalledProcessError:
                print("Error excepted. Settings:")
                print("init conds = {}".format(instance["initial"]))
                print("params = {}".format(instance["parameters"]))
                continue
            
    # Ia-R'lyehl Cihuiha flgagnl id Ia!
    content = chevron.render(open(args.template_instances, "r"), instances)
    content = ",".join(content.split(",")[:-1]) + "\n]\n}"
    with open(output_dir / "instances.json", 'w') as outfile:
        outfile.write(content)
    
        print(f"""
###  GENERATING NOISY DATA  ###

""")
    
    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        copy_dir = output_dir / f"copy_{mnemonic}"
        os.makedirs(copy_dir / DATA_DIR)
        os.makedirs(copy_dir / ESTIMATION_DIR)
        os.makedirs(copy_dir / ESTIMATION_RESULTS_DIR)
        print(f"NOISE LEVEL {noise_level}  :  {copy_dir}")
        print(f"  DATA               : {copy_dir / DATA_DIR}")
        print(f"  ESTIMATION         : {copy_dir / ESTIMATION_DIR}")
        print(f"  ESTIMATION_RESULTS : {copy_dir / ESTIMATION_RESULTS_DIR}")
        
    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        copy_dir = output_dir / f"copy_{mnemonic}"
        for system in systems["systems"]:
            print(system["name"])
            instance_basename = system["name"] + "_"
            for i in range(NUM_TESTS):
                instance_name = instance_basename + str(i)
                instance = instance_stash[instance_name]
                
                data_filepath_orig = output_dir / DATA_DIR / (instance_name + ".csv")
                data_filepath_noisy = copy_dir / DATA_DIR / (instance_name + ".csv")
                estimation_filepath = copy_dir / ESTIMATION_DIR / (instance_name + ".jl")
                estimation_result_filepath = copy_dir / ESTIMATION_RESULTS_DIR / (instance_name + ".csv")

                df = pd.read_csv(data_filepath_orig, header=None, index_col=False)
                if noise_level == 0:
                    df = df
                else:
                    df.loc[:, df.columns != df.columns[0]] *= (1 + np.random.normal(scale=noise_level, size=(len(df), len(df.columns)-1)))

                df.to_csv(data_filepath_noisy, index=False, header=False)
                
                settings = get_settings(system, instance)
                settings["data_filepath"] = data_filepath_noisy
                settings["estimation_result_filepath"] = estimation_result_filepath
                settings["at_time"] = (TIME_INTERVAL[1] - TIME_INTERVAL[0])/2 + TIME_INTERVAL[0]
                settings["data_expr"] = SCIML_DAT_STR[system["name"]]
                with open(estimation_filepath, 'w') as output_file:
                    testfile = chevron.render(open(args.template_estimation), settings)
                    output_file.write(testfile)

if __name__=='__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--systems', default="jsons/systems.json")
    parser.add_argument('-i', '--template_instances', default="templates/json_template_instances.json")
    parser.add_argument('-g', '--template_data_generation', default="templates/julia_template_for_data_generation.jl")
    parser.add_argument('-e', '--template_estimation', default="templates/julia_template_for_estimation_odepe.jl")
    args = parser.parse_args()
    main(args)

