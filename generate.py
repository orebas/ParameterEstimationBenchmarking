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

from shared import warn, get_settings
    
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

def main(args):
    np.random.seed(0)

    with open(args.config, 'r') as io:
        args.config_path = args.config
        args.config = json.load(io)
    with open(args.systems, 'r') as io:
        args.systems_path = args.systems
        args.systems = json.load(io)
        
    # For a unique ID
    identifier = datetime.now().strftime("%Y_%m_%d_%H_%M")
    output_dir = Path(identifier).absolute().resolve()

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

OUTPUT:             {output_dir}
  SCRIPTS:          {output_dir / args.config['FILETREE'] / args.config['DATA_GENERATION_DIR']}
  DATA:             {output_dir / args.config['FILETREE'] / args.config['DATA_DIR']}
  HUGE_JSON:        {output_dir / 'huge_json.json'}
""")

    # Create output directories
    if os.path.exists(output_dir):
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
    # instances = {"instances":[]}
    instance_stash = defaultdict()
    for system in args.systems["systems"]:
        print(system["name"])
        instance_basename = system["name"] + "_"

        i = 0
        while i < args.config['NUM_TESTS']:        
            instance_name = instance_basename + str(i)
            data_filepath = output_dir / args.config['FILETREE'] / args.config['DATA_DIR'] / (instance_name + ".csv")
            data_generation_filepath = output_dir / args.config['FILETREE'] / args.config['DATA_GENERATION_DIR'] / (instance_name + ".jl")
            log_filepath = output_dir / args.config['FILETREE'] / args.config['DATA_GENERATION_DIR'] / (instance_name + ".txt")
 

            param_values = np.random.uniform(low=args.config['PARAM_INTERVAL'][0], high=args.config['PARAM_INTERVAL'][1], size=len(system["parameter_variables"])).round(3).tolist()
            state_values = np.random.uniform(low=args.config['PARAM_INTERVAL'][0], high=args.config['PARAM_INTERVAL'][1], size=len(system["state_variables"])).round(3).tolist()

            instance = generate_instance(args, system, instance_name, param_values, state_values)
            instance_stash[instance_name] = instance
            
            settings = get_settings(args, instance)
            settings.update({'data_filepath' : data_filepath.as_posix()})
            
            with open(args.config['TEMPLATE_GENERATION'], 'r') as template:
                julia_file = chevron.render(template, settings, warn=True)
            
            with open(data_generation_filepath, 'w') as output_file:
                output_file.write(julia_file)
            
            print(instance_name)
            cmd = shlex.split('julia ' + data_generation_filepath.as_posix())
            logs_io = open(log_filepath, 'a+')
            try:
                output = subprocess.run(
                    cmd,
                    check=True,
                    stdout=sys.stdout,
                    stderr=sys.stdout
                )
                i += 1
            except subprocess.CalledProcessError as err:
                warn("Error when running {}".format(cmd))
                warn("Trying again with different parameter values.")
                continue
            finally:
                logs_io.close()

    instances = {"instances":[]}
    print(f"""
###  GENERATING NOISY DATA  ###

OUTPUT:             {output_dir / args.config['FILETREE'] / args.config['DATA_DIR_NOISY']}
""")
        
    for (mnemonic, noise_level) in args.config['NOISE_LEVEL'].items():
        for system in args.systems["systems"]:
            print(mnemonic, system["name"])
            instance_basename = system["name"] + "_"
            for i in range(args.config['NUM_TESTS']):
                instance_name = instance_basename + str(i)
                
                data_filepath_orig = output_dir / args.config['FILETREE'] / args.config['DATA_DIR'] / (instance_name + ".csv")

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

                instance = {}
                instance = instance | instance_stash[instance_name]
                instance['id'] = mnemonic + "_" + instance['id']
                instance['data'] = df.values.T.tolist()
                instances['instances'].append(instance)

                instance_path = output_dir / args.config['FILETREE'] / args.config['DATA_DIR_NOISY'] / instance['id']
                os.makedirs(instance_path)
                df.to_csv(instance_path / 'data.csv', index=False, header=False)

    with open(output_dir / "huge_json.json", "w") as io:
        json.dump(instances, io, indent=None)
        
if __name__=='__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("config", help="The file config.json")
    parser.add_argument("systems", help="The file systems.json")
    args = parser.parse_args()
    
    main(args)
