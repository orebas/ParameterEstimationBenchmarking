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
from statistics import median, mean 

import argparse
from datetime import datetime
from pathlib import Path

from shared import *

def main():
    output_dir = Path(sys.argv[1])
    
    systems_filepath = output_dir / "systems.json"
    with open(systems_filepath, "r") as systems_file:
        systems = json.load(systems_file)

    instances_filepath = output_dir / "instances.json"
    with open(instances_filepath, "r") as instances_file:
        instances = json.load(instances_file)
        
    data = defaultdict(dict)
    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        copy_dir = output_dir / f"copy_{mnemonic}"
        for root, dirs, files in os.walk(copy_dir / ESTIMATION_RESULTS_DIR):
            for file in files: 
                if not file.endswith(".csv"):
                    continue
                df = pd.read_csv(Path(root) / file)
                file, index = "_".join(file.rstrip(".csv").split("_")[:-1]), file.rstrip(".csv").split("_")[-1]
                if not file in data[mnemonic]:
                    data[mnemonic][file] = {}
                data[mnemonic][file][index] = df  

    results = {}
    statistic = "MRAE"
    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        results[mnemonic] = {}
        for system in systems["systems"]:
            results[mnemonic][system["name"]] = {}
            
            # !!! No system at all in data
            if system["name"] not in data[mnemonic]:
                warn(f"Not found {mnemonic} / {system['name']}")
                continue

            instance_basename = system["name"] + "_"
            for i in range(NUM_TESTS):
                instance_name = instance_basename + str(i)
                found_instance = False
                instance = 0
                for inst in instances["instances"]:
                    if inst["name"] == instance_name:
                        found_instance = True
                        instance = inst
                        break
                assert found_instance
                
                if str(i) not in data[mnemonic][system["name"]]:
                    warn(f"Not found {mnemonic} / {system['name']} / {str(i)}")
                    continue

                solutions = data[mnemonic][system["name"]][str(i)]
                true_sol = deepcopy(instance['parameters'])
                true_sol.update(instance['initial'])
                header = solutions.columns
                min_mrae = math.inf
                results[mnemonic][system["name"]]["vars"] = [k for k, v in true_sol.items()]
                nvars = len(results[mnemonic][system["name"]]["vars"])
                results[mnemonic][system["name"]][str(i)] = [["empty" for i in range(nvars)], ["empty" for i in range(nvars)], []]
                for j in range(len(solutions)):
                    row = solutions.iloc[j, :]
                    our_sol = {header[i].rstrip("(t)") : row.iloc[i] for i in range(len(header))}
                    mrae = 0
                    for (var, val) in true_sol.items():
                        our_val = our_sol[str(var)]
                        _mrae = abs(val - our_val) / val
                        mrae += _mrae
                    mrae = mrae / len(header)
                    if mrae < min_mrae:
                        min_mrae = mrae
                        arr = [[], [], []]
                        arr[2].append(round(min_mrae, ndigits=3))
                        for var in results[mnemonic][system["name"]]["vars"]:
                            our_val = our_sol[str(var)]
                            true_val = true_sol[str(var)]
                            arr[0].append(round(true_val, ndigits=3))
                            arr[1].append(round(our_val, ndigits=3))
                        results[mnemonic][system["name"]][str(i)] = arr

    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        copy_dir = output_dir / f"copy_{mnemonic}"
        results_dir = copy_dir / RESULTS_DIR
        results_dir.mkdir(exist_ok=True)
        print(f"CLEANING RESULTS  : {results_dir}")
        for root, dirs, files in os.walk(results_dir):
            for file in files:
                os.remove(Path(root) / file)  
        print(f"WRITING RESULTS TO: {results_dir}")

        for system in systems["systems"]:
            with open(results_dir / (system["name"] + ".csv"), 'w') as csvfile:
                if system["name"] not in results[mnemonic]:
                    warn(f"Not generating data for {mnemonic} / {system['name']}")
                    continue
                ncols = len(results[mnemonic][system["name"]]["vars"]) + 2
                csvwriter = csv.writer(csvfile, delimiter=',')    
                for i in range(NUM_TESTS):
                    if str(i) not in results[mnemonic][system["name"]]:
                        warn(f"No data for {mnemonic} / {system['name']} / {str(i)}")
                        csvwriter.writerow([""] + results[mnemonic][system["name"]]["vars"] + [statistic])
                        csvwriter.writerow(ncols * [""])
                        csvwriter.writerow(["True"] + (ncols - 1) * [""])
                        csvwriter.writerow(["Estimated"] + (ncols - 1) * ["failed"])
                    else:
                        csvwriter.writerow([""] + results[mnemonic][system["name"]]["vars"] + [statistic])
                        csvwriter.writerow(["True"] + results[mnemonic][system["name"]][str(i)][0] + [""])
                        csvwriter.writerow(["Estimated"] + results[mnemonic][system["name"]][str(i)][1] + results[mnemonic][system["name"]][str(i)][2])
                        csvwriter.writerow(ncols * [""])
    
    print("COMPILING SUMMARY FILES")
    results_dir = output_dir / RESULTS_DIR
    results_dir.mkdir(exist_ok=True)
    print(f"CLEANING RESULTS: {results_dir}")
    for root, dirs, files in os.walk(results_dir):
        for file in files:
            os.remove(Path(root) / file)  
    
    with open(results_dir / "results.csv", "w") as csv_file:
        csvwriter = csv.writer(csv_file)
        
        for (mnemonic, noise_level) in NOISE_LEVEL.items():
            csvwriter.writerow([f"noise level {noise_level}"] + 3*[""])
            csvwriter.writerow([""] + ["RMAE mean"] + ["RMAE median"] + ["RMAE min"])
            for system in systems["systems"]:
                if system["name"] not in results[mnemonic]:
                    csvwriter.writerow(["", "N/A", "N/A", "N/A"])
                stats = [results[mnemonic][system["name"]][str(i)][2] if str(i) in results[mnemonic][system["name"]] else [] for i in range(NUM_TESTS)]
                stats = filter(lambda x: len(x) > 0 and isinstance(x[0], float), stats)
                stats = [x[0] for x in stats]
                if len(stats) == 0:
                    stat_mean, stat_median, stat_min = "N/A", "N/A", "N/A"
                else:
                    stat_mean = mean(stats)
                    stat_median = median(stats)
                    stat_min = min(stats)
                csvwriter.writerow([system["name"]] + [stat_mean, stat_median, stat_min])
            csvwriter.writerow(["", "", "", ""])

if __name__=='__main__':
    main()

