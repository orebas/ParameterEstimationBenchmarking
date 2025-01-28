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
#import csv
import pandas as pd
pd.set_option("display.precision",16)

import argparse
from datetime import datetime
from pathlib import Path

from shared import *

MAX_PROCS = 3

def poll_all(procs):
    for p in list(procs):
        poll = p['p'].poll()
        if poll is not None:
            procs.remove(p)
            p['logs'].close()
            if p['p'].returncode != 0:
                warn(f"Failed: {p['mnemonic']} / {p['file']}")

def main():
    output_dir = Path(sys.argv[1])
    procs = []
    for (mnemonic, noise_level) in NOISE_LEVEL.items():
        copy_dir = output_dir / f"copy_{mnemonic}"
        results_dir = copy_dir / ESTIMATION_RESULTS_DIR
        print(f"\nNOISE LEVEL: {noise_level}")
        print(f"  CLEANING RESULTS: {results_dir}")
        for root, dirs, files in os.walk(results_dir):
            for file in files:
                os.remove(Path(root) / file)
        print(f"  RUNNING FILES IN: {copy_dir / ESTIMATION_DIR}")
        for root, dirs, files in os.walk(copy_dir / ESTIMATION_DIR):
            for file in files:
                while len(procs) >= MAX_PROCS:
                    poll_all(procs)             
                print("    ", file)
                cmd = shlex.split('julia ' + str(Path(root) / file))
                log_file = open(str(copy_dir / ESTIMATION_RESULTS_DIR / (file + ".log")), "w")
                try:
                    p = Popen(cmd, stdout=log_file, stderr=log_file)
                    procs.append(dict(mnemonic=mnemonic, file=file, p=p, logs=log_file))
                except subprocess.CalledProcessError:
                    print("Error excepted. Settings:")
                    print(file)
                    continue
    while len(procs) > 0:
        poll_all(procs)  
    
if __name__ == "__main__":
    main()

