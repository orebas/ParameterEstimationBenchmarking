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

def load_odepe_metadata(path):
    if not path.exists():
        return None
    try:
        with open(path, 'r') as io:
            return json.load(io)
    except Exception:
        return None

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
DIR2                {args.run}

OUTPUT:             {args.dir.as_posix()}
  RESULT (json):    {(args.dir / 'result.json').as_posix()}
  RESULT (csv):     {(args.dir / 'result.csv').as_posix()}
""")

  results = { 'results' : [] }
  for run in args.run:
    software = run.split("_")[0]
    print(software)
    assert software in AVAILABLE_SOFTWARE
    if not (args.dir.resolve().absolute() / args.config['FILETREE'] / run).exists():
      print(f"Results for {run} not found.")
      continue
    print(run)
    for instance in instances['instances']:
      result = {
            'id': instance['id'],
            'name' : instance['name'],
            'run' : run,
            'software': software,
            'finished': False,
            'has_result' : False,
            'result': None,
            'time': None,
            'odepe_status': None,
            'odepe_raw_count': None,
            'odepe_best_count': None,
            'odepe_primary_method': None,
            'odepe_rescue_path': None,
            'odepe_interpolator_source': None,
            'odepe_structural_fix_count': None,
            'odepe_practical_identifiability_status': None,
            'odepe_notes': None,
            'odepe_error': None,
            'odepe_was_terminal_fallback': None,
            'failure_reason': None,
      }
            
      # Verify logs
      log_path = args.dir.resolve().absolute() / args.config['FILETREE'] / run / instance['id'] / STDOUT_FILENAME
      if not log_path.exists():
        warn(f"Results for {run} / {instance['id']} not found.")
        results['results'].append(result)
        continue
      with open(log_path, 'r') as logs:
         output = logs.read()
      if not output.strip().endswith(END_OF_LOG):
        warn(f"Results for {run} / {instance['id']} are bad: wrong end of file.")
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

      cell_dir = args.dir.resolve().absolute() / args.config['FILETREE'] / run / instance['id']

      # ODEPE-family provenance: software is "odepe" (since `run.split("_")[0]` collapses
      # every ODEPE variant — `odepe_multipoint`, `odepe_v2_polish`, `odepe_shade`, etc. —
      # to just "odepe"). All of them write `odepe_metadata.json` in the same schema.
      if software == "odepe":
        metadata_path = cell_dir / "odepe_metadata.json"
        metadata = load_odepe_metadata(metadata_path)
        if metadata is not None:
          best_meta = metadata.get('best', {}) if isinstance(metadata.get('best', {}), dict) else {}
          notes = best_meta.get('notes') or []
          # Terminal-fallback rescue is recorded as :terminal_fallback in `provenance.notes`
          # (set by note_provenance! at the rescue site in ODEPE), and additionally tagged
          # via `provenance.rescue_path = :direct_opt_fallback`. The JSON sidecar stringifies
          # symbols, so the literal strings are what we look for.
          was_terminal_fallback = ('terminal_fallback' in notes) or (best_meta.get('rescue_path') == 'direct_opt_fallback')
          result.update({
              'odepe_status': metadata.get('status'),
              'odepe_raw_count': metadata.get('raw_count'),
              'odepe_best_count': metadata.get('best_count'),
              'odepe_primary_method': best_meta.get('primary_method'),
              'odepe_rescue_path': best_meta.get('rescue_path'),
              'odepe_interpolator_source': best_meta.get('interpolator_source'),
              'odepe_structural_fix_count': len(best_meta.get('structural_fix_set', {})) if isinstance(best_meta.get('structural_fix_set', {}), dict) else None,
              'odepe_practical_identifiability_status': best_meta.get('practical_identifiability_status'),
              'odepe_notes': notes,
              'odepe_error': metadata.get('error'),
              'odepe_was_terminal_fallback': was_terminal_fallback,
          })

      # Read failure_reason.txt if the cell wrote one (either the estimator's own catch
      # block or a SLURM-level wrapper). First line is the category token; rest is detail.
      failure_path = cell_dir / "failure_reason.txt"
      if failure_path.exists():
        try:
          with open(failure_path, 'r') as fr:
            first_line = fr.readline().strip()
            if first_line:
              result['failure_reason'] = first_line
        except Exception:
          pass

      # File-based result.csv branch: ODEPE family + PE + SciML + AMIGO2 (post-numbat).
      # AMIGO2 falls back to stdout-parsing for backward compatibility with bilby-era runs
      # where the AMIGO2 template printed to stdout only and didn't write result.csv.
      result_path = cell_dir / "result.csv"
      if software in ("odepe", "pe", "sciml", "amigo2") and result_path.exists():
        df = pd.read_csv(result_path, header=None, index_col=False)
        data = df.values.T.tolist()
        for i in range(len(data)):
          data[i][0] = data[i][0].removesuffix("(t)")
      elif software == "amigo2" or software == "iqm":
        # AMIGO2 fallback (bilby) or IQM (always stdout): regex-parse stdout.txt.
        stdout_path = cell_dir / STDOUT_FILENAME
        if not stdout_path.exists():
          warn(f"Results for {run} / {instance['id']} not found.")
          results['results'].append(result)
          continue
        with open(stdout_path, 'r') as logs:
          output = logs.read()
        data = parse_output(output, software)
      else:
        warn(f"Results for {run} / {instance['id']} not found.")
        results['results'].append(result)
        continue
      info(f"Found results for {run} / {instance['id']}")
      try:
        data = list(map(list, data))
        required_vars = [*instance['parameter_variables'], *instance['state_variables']]
        data = sorted(data, key=lambda pair: required_vars.index(pair[0]))
        assert set([pair[0] for pair in data]) == set(required_vars)
        result.update({
            'result' : data,
            'has_result' : len(data[0]) > 1,
            'time' : time
        })
        results['results'].append(result)
      except:
        warn(f"Error while processing {run} / {instance['id']}")
        results['results'].append(result)

  if (args.dir / "result.json").exists():
      warn(f"Overwriting existing {args.dir / 'result.json'}")
  with open(args.dir / "result.json", "w") as io:
    json.dump(results, io, indent=None)

  print(f"Collected results: {len(results['results'])}")
  
  info("Generating a CSV..")
  info(f"Instances: {len(instances['instances'])}")
  info(f"Results:   {len(results['results'])}")
  results = {(problem['id'], problem['run']) : problem for problem in results['results']}
  rows_list = []
  for instance in instances['instances']:
    for run in args.run:
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
            'non_identifiable'  : instance['non_identifiable'],
            'noise'             : args.config['NOISE_LEVEL'][instance['id'].split('_')[-1]],
            'finished'          : False,
            'has_result'        : False,
            'software'          : run.split("_")[0],
            'odepe_status'      : None,
            'odepe_raw_count'   : None,
            'odepe_best_count'  : None,
            'odepe_primary_method' : None,
            'odepe_rescue_path' : None,
            'odepe_interpolator_source' : None,
            'odepe_structural_fix_count' : None,
            'odepe_practical_identifiability_status' : None,
            'odepe_notes' : None,
            'odepe_error' : None,
            'odepe_was_terminal_fallback' : None,
            'failure_reason' : None,
        })
        if (instance['id'], run) in results:
            dict1.update({
            'run'               :results[(instance['id'], run)]['run'],
            'software'          : results[(instance['id'], run)]['software'],
            'result'            : results[(instance['id'], run)]['result'],
            'time'              : results[(instance['id'], run)]['time'],
            'finished'          : results[(instance['id'], run)]['finished'],
            'has_result'        : results[(instance['id'], run)]['has_result'],
            'odepe_status'      : results[(instance['id'], run)]['odepe_status'],
            'odepe_raw_count'   : results[(instance['id'], run)]['odepe_raw_count'],
            'odepe_best_count'  : results[(instance['id'], run)]['odepe_best_count'],
            'odepe_primary_method' : results[(instance['id'], run)]['odepe_primary_method'],
            'odepe_rescue_path' : results[(instance['id'], run)]['odepe_rescue_path'],
            'odepe_interpolator_source' : results[(instance['id'], run)]['odepe_interpolator_source'],
            'odepe_structural_fix_count' : results[(instance['id'], run)]['odepe_structural_fix_count'],
            'odepe_practical_identifiability_status' : results[(instance['id'], run)]['odepe_practical_identifiability_status'],
            'odepe_notes'       : results[(instance['id'], run)]['odepe_notes'],
            'odepe_error'       : results[(instance['id'], run)]['odepe_error'],
            'odepe_was_terminal_fallback' : results[(instance['id'], run)].get('odepe_was_terminal_fallback'),
            'failure_reason'    : results[(instance['id'], run)].get('failure_reason'),
            })
        else:
            dict1.update({'run' : run})
        rows_list.append(dict1)
  df = pd.DataFrame(rows_list, columns=['index', 'id', 'true_states', 'true_parameters', 'time_start', 'time_end', 'time_count', 'name', 'non_identifiable', 'noise', 'finished', 'has_result', 'run', 'software', 'result', 'time', 'odepe_status', 'odepe_raw_count', 'odepe_best_count', 'odepe_primary_method', 'odepe_rescue_path', 'odepe_interpolator_source', 'odepe_structural_fix_count', 'odepe_practical_identifiability_status', 'odepe_notes', 'odepe_error', 'odepe_was_terminal_fallback', 'failure_reason'])
  print("DataFrame header:")
  print(df.head())
  print("DataFrame columns:", df.columns)
  
  if (args.dir / "result.csv").exists():
      warn(f"Overwriting existing {args.dir / 'result.csv'}")
  df.to_csv((args.dir / 'result.csv').as_posix())

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dir", help="The directory generated by generate_data.py.")
    parser.add_argument("run", help="The directories generated by generate_scipts.py.")
    args = parser.parse_args()
    args.run = args.run.split(",")
    
    main(args)
