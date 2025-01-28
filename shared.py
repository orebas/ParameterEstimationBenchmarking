from termcolor import colored

NUM_TESTS       = 1
TIME_INTERVAL   = [-1.0, 1.0]
PARAM_INTERVAL  = [0.1, 0.9]
NUM_PTS         = 1001
NOISE_LEVEL     = {"0": 0, "1em8": 1e-8, "1em6": 1e-6, "1em4": 1e-4, "1em2": 1e-2}
SEARCH_BOUNDS   = [-3.0, 3.0]

DATA_GENERATION_DIR     = "data_generation"
DATA_DIR                = "data"
ESTIMATION_DIR          = "estimation"
ESTIMATION_RESULTS_DIR  = "estimation_results"
RESULTS_DIR             = "results"

def warn(msg):
    print(colored("[WARN] " + msg, "red"))

