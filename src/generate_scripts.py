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
import getpass
#from julia.api import Julia
#import csv
import pandas as pd
pd.set_option("display.precision",16)

import argparse
from datetime import datetime
from pathlib import Path
from termcolor import colored

from shared import warn, info, get_settings, AVAILABLE_SOFTWARE, JULIA_ENVIRONMENTS

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
    "sciml" : "templates/julia_template_for_estimation_sciml.jl"
}

SOFTWARE_COMMENT = {
    "pe"    : "#",
    "odepe" : "#",
    "amigo2": "%",
    "iqm"   : "%",
    "sciml" : "#"
}

FILE_EXT = {'pe': 'jl', 'odepe': 'jl', 'sciml': 'jl', 'amigo2': 'm', 'iqm': 'm'}

def get_sciml_measurements(instance):
    import re
    subs = {}
    subs = subs | {x : f"sol[{1+idx}, :]" for idx, x in enumerate(instance["state_variables"])}
    subs = subs | {x : f"p[(length(ic) + {1+idx}):end]" for idx, x in enumerate(instance["parameter_variables"])}
    subs = subs | {'*' : '.*'}
    subs = dict((re.escape(k), v) for k, v in subs.items())
    pattern = re.compile("|".join(subs.keys()))
    sciml_measurements = ','.join([pattern.sub(lambda m: subs[re.escape(m.group(0))], value) for key, value in instance["measurements"].items()])
    return sciml_measurements

instance = {"state_variables" : ["x1", "x2"], "parameter_variables": ["a", "b"], "measurements": {"y1": "x1", "y2": "a*x1^2 + b * b * x2"}}
assert get_sciml_measurements(instance) == ""

def main(args):
    assert args.software in AVAILABLE_SOFTWARE or args.software == 'all'
    
    if args.software == 'all':
        args.software = AVAILABLE_SOFTWARE
    else:
        args.software = [args.software]

    args.dir = Path(args.dir)
    parent = Path(__file__).parent.parent.resolve()
    
    with open(args.dir / 'config' / 'config.json', 'r') as io:
        args.config = json.load(io)
        
    with open(args.dir / 'huge_json.json', 'r') as io:
        instances = json.load(io)
    
    for software in args.software:
        print(f"""
###  GENERATING RUNNABLE FILES  ###

SOFTWARE            {software}
PATH_TO_SRC         {args.config['PATH_TO_SRC']}

TEMPLATE            {TEMPLATE_ESTIMATION[software]}

OUTPUT:             {args.dir}
    SCRIPTS:        {args.dir / args.config['FILETREE'] / software}
""")

        if os.path.exists(args.dir / args.config['FILETREE'] / software):
            warn(f"Deleting existing {args.dir / args.config['FILETREE'] / software}")
            shutil.rmtree(args.dir / args.config['FILETREE'] / software)
        
        shutil.copytree(args.dir / args.config['FILETREE'] / args.config['DATA_DIR_NOISY'], args.dir / args.config['FILETREE'] / software)
    
        for instance in instances['instances']:
            print(instance['id'])

            settings = get_settings(args, instance)
            settings["id"] = instance["id"]
            settings["data_filepath"] = 'data.csv'
            settings["estimation_result_filepath"] = 'result.csv'
            settings["at_time"] = (args.config['TIME_INTERVAL'][1] - args.config['TIME_INTERVAL'][0])/2 + args.config['TIME_INTERVAL'][0]
            settings["data_expr"] = get_sciml_measurements(instance)
            settings["path_to_src"] = args.config["PATH_TO_SRC"]

            comment = SOFTWARE_COMMENT[software]
            file_meta_header = f"""{comment}{comment}{comment} This file is machine-generated.
{comment}{comment}{comment} Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
{comment}{comment}{comment} Author: {getpass.getuser()}
{comment}{comment}{comment} Args: {" ".join(sys.argv)}
{comment}{comment}{comment} Environment: {sys.prefix}

"""
            if software in ['pe','odepe','sciml','amigo2']:
                settings.update({'julia_env_path' : f'joinpath(dirname(dirname(dirname(dirname(dirname(@__DIR__))))), string({JULIA_ENVIRONMENTS[software]}))'})
                with open(args.dir / args.config['FILETREE'] / software / instance['id'] / f'script.{FILE_EXT[software]}', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]), settings, warn=True)
                    output_file.write(file_meta_header + testfile)
            elif software in ['iqm']:
                os.makedirs(args.dir / args.config['FILETREE'] / software / instance['id'] / 'project', exist_ok=True)
                os.makedirs(args.dir / args.config['FILETREE'] / software / instance['id'] / 'project' / 'models', exist_ok=True)
                os.makedirs(args.dir / args.config['FILETREE'] / software / instance['id'] / 'project' / 'experiments' / 'data', exist_ok=True)
                with open(args.dir / args.config['FILETREE'] / software / instance['id'] / f'script.{FILE_EXT[software]}', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]['script']), settings, warn=True)
                    output_file.write(file_meta_header + testfile)
                with open(args.dir / args.config['FILETREE'] / software / instance['id'] / 'project' / 'experiments' / 'data' / 'experiment.csv', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]['csv']), settings)
                    output_file.write(file_meta_header + testfile)
                with open(args.dir / args.config['FILETREE'] / software / instance['id'] / 'project' / 'experiments' / 'data' / 'experiment.exp', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]['exp']), settings)
                    output_file.write(file_meta_header + testfile)
                with open(args.dir / args.config['FILETREE'] / software / instance['id'] / 'project' / 'models' / 'models.txt', 'w') as output_file:
                    testfile = chevron.render(open(parent / TEMPLATE_ESTIMATION[software]['models']), settings)
                    output_file.write(file_meta_header + testfile)
    
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dir", help="The directory generated by generate_data.py.")
    parser.add_argument("-s", "--software", help="The software to generate scripts for. Possible choices are: {}.".format(', '.join(AVAILABLE_SOFTWARE)), required=False, default='all')
    args = parser.parse_args()
    
    main(args)
