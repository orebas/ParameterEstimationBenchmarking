from termcolor import colored

def warn(msg):
    print(colored("[WARN] " + msg, "red"))

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
        "data": '\n'.join([' '.join([str(instance['data'][j][i]) for j in range(1, len(instance['data']))]) for i in range(len(instance['data'][0]))]),
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
    