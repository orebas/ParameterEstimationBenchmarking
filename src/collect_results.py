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

def parse_output(output, software):
    if software == "amigo2":
        pairs = re.findall(r"([A-Za-z0-9\_]+)\s+:\s+([0-9.e+-]+)", output)
    elif software == "iqm":
        pairs = re.findall(r"\n([A-Za-z0-9\_]+)[ ]*=[ ]*([0-9.e+-]+[ a-zA-Z0-9]*)", output)
    else:
      warn("Unknown software")
      exit(1)
    return pairs

def main(args):
  args.dir = Path(args.dir)
  with open(args.dir / 'config' / 'config.json', 'r') as io:
    args.config = json.load(io)

  with open(args.dir / 'huge_json.json', 'r') as io:
    instances = json.load(io)
  
  print(f"""
###  COLLECTING BENCHMARK RESULTS  ###

DIR                 {args.dir}
SOFTWARE            {AVAILABLE_SOFTWARE}

OUTPUT:             {args.dir.as_posix()}
  RESULT (json):    {(args.dir / 'result.json').as_posix()}
  RESULT (csv):     {(args.dir / 'result.csv').as_posix()}
""")

  results = { 'results' : [] }
  for software in AVAILABLE_SOFTWARE:
    if not (args.dir.resolve().absolute() / args.config['FILETREE'] / software).exists():
      print(f"Results for {software} not found.")
      continue
    print(software)
    for instance in instances['instances']:
      result = {
            'id': instance['id'],
            'name' : instance['name'],
            'software': software,
            'finished': False,
            'has_result' : False,
            'result': None,
            'time': None
      }
            
      # Verify logs
      log_path = args.dir.resolve().absolute() / args.config['FILETREE'] / software / instance['id'] / STDOUT_FILENAME
      if not log_path.exists():
        warn(f"Results for {software} / {instance['id']} not found.")
        results['results'].append(result)
        continue
      with open(log_path, 'r') as logs:
         output = logs.read()
      if not output.strip().endswith(END_OF_LOG):
        warn(f"Results for {software} / {instance['id']} are bad: wrong end of file.")
        results['results'].append(result)
        continue
      time = 0.
      try:
        time = float(output.strip().split('\n')[-2].split(':')[1])
      except:
        pass
      
      result.update({
          'finished': True,
          'time': time
      })

      if software in ("odepe", "pe", "sciml"):
        result_path = args.dir.resolve().absolute() / args.config['FILETREE'] / software / instance['id'] / f"result.csv"
        if not result_path.exists():
          warn(f"Results for {software} / {instance['id']} not found.")
          results['results'].append(result)
          continue
        df = pd.read_csv(result_path, header=None, index_col=False)
        data = df.values.T.tolist()
        for i in range(len(data)):
          data[i][0] = data[i][0].rstrip("(t)")
      else:
        result_path = args.dir.resolve().absolute() / args.config['FILETREE'] / software / instance['id'] / STDOUT_FILENAME
        if not result_path.exists():
          warn(f"Results for {software} / {instance['id']} not found.")
          results['results'].append(result)
          continue
        with open(result_path, 'r') as logs:
          output = logs.read()
        data = parse_output(output, software)
      info(f"Found results for {software} / {instance['id']}")
      try:
        data = list(map(list, data))
        required_vars = [*instance['parameter_variables'], *instance['state_variables']]
        data = sorted(data, key=lambda pair: required_vars.index(pair[0]))
        assert set([pair[0] for pair in data]) == set(required_vars)
        result.update({
            'result' : data,
            'has_result' : True,
            'time' : time
        })
        results['results'].append(result)
      except:
        warn(f"Error while processing {software} / {instance['id']}")

  if (args.dir / "result.json").exists():
      warn(f"Overwriting existing {args.dir / 'result.json'}")
  with open(args.dir / "result.json", "w") as io:
    json.dump(results, io, indent=None)

  print(f"Collected results: {len(results['results'])}")
  
  info("Generating a CSV..")
  info(f"Instances: {len(instances['instances'])}   (x5 per software in {AVAILABLE_SOFTWARE})")
  info(f"Results:   {len(results['results'])}")
  results = {(problem['id'], problem['software']) : problem for problem in results['results']}
  rows_list = []
  for instance in instances['instances']:
    for software in AVAILABLE_SOFTWARE:
        dict1 = {}
        dict1.update({
            'index'             : instance['index'],
            'id'                : instance['id'],
            'true_states'       : instance['state_values'],
            'true_parameters'   : instance['parameter_values'],
            'time_start'        : instance['time']['start'],
            'time_end'          : instance['time']['end'],
            'time_count'        : instance['time']['count'],
            'name'              : instance['name'],
            'noise'             : args.config['NOISE_LEVEL'][instance['id'].split('_')[-1]],
            'finished'          : False,
            'has_result'        : False
        })
        if (instance['id'], software) in results:
            dict1.update({
            'software'          : results[(instance['id'], software)]['software'],
            'result'            : results[(instance['id'], software)]['result'],
            'time'              : results[(instance['id'], software)]['time'],
            'finished'          : results[(instance['id'], software)]['finished'],
            'has_result'        : results[(instance['id'], software)]['has_result']
            })
        else:
            dict1.update({'software' : software})
        rows_list.append(dict1)
  df = pd.DataFrame(rows_list)
  print("DataFrame header:")
  print(df.head())
  print("DataFrame columns:", df.columns)
  
  if (args.dir / "result.csv").exists():
      warn(f"Overwriting existing {args.dir / 'result.csv'}")
  df.to_csv((args.dir / 'result.csv').as_posix())

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dir", help="The directory generated by generate_data.py.")
    args = parser.parse_args()
    
    main(args)

