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
from subprocess import Popen, PIPE
#from julia.api import Julia
import csv
import pandas as pd
pd.set_option("display.precision",16)
from collections import defaultdict
import math
from copy import deepcopy

import argparse
from datetime import datetime
from pathlib import Path

from shared import *

def main():
    output_dir = Path(sys.argv[1])
        
    instances_filepath = output_dir / "instances.json"
    with open(instances_filepath, "r") as instances_file:
        instances = json.load(instances_file)
        
    data = defaultdict(dict)
    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        print(f"\nNOISE LEVEL: {noise_level}")
        copy_dir = output_dir / f"copy_{mnemonic}"
        for root, dirs, files in os.walk(copy_dir / ESTIMATION_RESULTS_DIR):
            for file in files: 
                if not file.endswith(".csv"):
                    continue
                print("  ", file)
                df = pd.read_csv(Path(root) / file)
                data[mnemonic][file.rstrip(".csv")] = df  
    
    results = {}
    statistic = "MRAE"
    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        results[mnemonic] = {}
        for instance in instances["instances"]:
            if instance["name"] not in data[mnemonic]:
                warn(f"Not found: {mnemonic} / {instance['name']}")
                continue
            ### THIS THING IS ...... !!
            system_name, idx = "_".join(instance["name"].split("_")[:-1]), instance["name"].split("_")[-1]
            results[mnemonic][system_name] = {}
            solutions = data[mnemonic][instance["name"]]
            true_sol = deepcopy(instance['parameters'])
            true_sol.update(instance['initial'])
            header = solutions.columns
            min_mrae = math.inf
            results[mnemonic][system_name]["vars"] = [k for k, v in true_sol.items()]
            for i in range(len(solutions)):
                row = solutions.iloc[i, :]
                our_sol = {header[i].rstrip("(t)") : row.iloc[i] for i in range(len(header))}
                mrae = 0
                for (var, val) in true_sol.items():
                    our_val = our_sol[str(var)]
                    _mrae = abs(val - our_val) / val
                    mrae += _mrae
                mrae = mrae / len(header)
                if mrae < min_mrae:
                    min_mrae = mrae
                    if idx not in results[mnemonic][system_name]:
                        results[mnemonic][system_name][idx] = {}
                    results[mnemonic][system_name][idx][statistic] = round(min_mrae, ndigits=3)
                    for (var, val) in true_sol.items():
                        our_val = our_sol[str(var)]
                        results[mnemonic][system_name][idx][str(var)] = (val, our_val)                        
                        
    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        copy_dir = output_dir / f"copy_{mnemonic}"
        results_dir = copy_dir / RESULTS_DIR
        results_dir.mkdir(exist_ok=True)
        print(f"CLEANING RESULTS: {results_dir}")
        print(f"WRITING RESULTS TO: {results_dir}")
        for root, dirs, files in os.walk(results_dir):
            for file in files:
                os.remove(Path(root) / file)  
        for system_name, system_variants in results[mnemonic].items():
            ncols = len(system_variants["vars"]) + 2
            with open(results_dir / (system_name + ".csv"), 'w') as csvfile:
                csvwriter = csv.writer(csvfile, delimiter=',')
                for idx, variant_results in system_variants.items():
                    if isinstance(variant_results, dict):
                        csvwriter.writerow([""] + system_variants["vars"] + [statistic])
                        csvwriter.writerow(["True"] + [variant_results[var][0] for var in system_variants["vars"]] + [system_variants[idx][statistic]])
                        csvwriter.writerow(["Estimated"] + [variant_results[var][1] for var in system_variants["vars"]] + [""])
                        csvwriter.writerow(ncols * [""])

    # results_dir = output_dir / RESULTS_DIR
    # os.mkdir(results_dir, exist_ok=True)
    # print(f"CLEANING RESULTS: {results_dir}")
    # for root, dirs, files in os.walk(results_dir):
    #     for file in files:
    #         os.remove(Path(root) / file)  
    
if __name__=='__main__':
    main()

