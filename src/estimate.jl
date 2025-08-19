#!/usr/bin/env julia

function aaad_gpr_pivot(xs::AbstractArray{T}, ys::AbstractArray{T}) where {T}
    @assert length(xs) == length(ys) "Input arrays must have same length"

    # 1. Normalize y values
    y_mean = mean(ys)
    y_std = std(ys)
    ys_normalized = (ys .- y_mean) ./ max(y_std, 1e-8)  # Avoid division by very small numbers

    # Configure initial GP hyperparameters
    initial_lengthscale = log(std(xs) / 8)
    initial_variance = 0.0
    initial_noise = -2.0

    # Add small amount of jitter to avoid numerical issues
    kernel = SEIso(initial_lengthscale, initial_variance)
    jitter = 1e-8
    ys_jitter = ys_normalized .+ jitter * randn(length(ys))

    # 2. Do GPR approximation on normalized data with suppressed warnings
    local gp
    gp = GP(xs, ys_jitter, MeanZero(), kernel, initial_noise)
    GaussianProcesses.optimize!(gp; method = LBFGS(linesearch = LineSearches.BackTracking()))

    # Create a function that evaluates the GPR prediction and denormalizes the output
    function denormalized_gpr(x)
        pred, _ = predict_f(gp, [x])
        return y_std * (pred[1]) + y_mean
    end

    return denormalized_gpr
end

using JSON3
using Printf
using Dates

# Define constants (similar to shared.py)
const AVAILABLE_SOFTWARE = ["pe", "odepe", "sciml"]
const END_OF_LOG = "=== END OF LOG ==="
const STDOUT_FILENAME = "stdout.txt"
const STDERR_FILENAME = "stderr.txt"

function warn(msg)
    println(stderr, "\033[93mWARN: $msg\033[0m")
end

function info(msg)
    println("\033[94mINFO: $msg\033[0m")
end

function get_script_path(args, instance)
    print(args)
    print(args["dir"])
    if args["software"] in ["pe", "odepe", "sciml"]
        return joinpath(args["dir"], args["config"]["FILETREE"], args["software"], instance["id"], "script.jl")
    else
        error("Unsupported software for Julia runner: $(args["software"])")
    end
end

# Minimal "tee" IO
struct TeeIO{A<:IO,B<:IO} <: Base.AbstractPipe
    a::A
    b::B
end

Base.unsafe_write(t::TeeIO, p::Ptr{UInt8}, n::UInt) = (
    Base.unsafe_write(t.a, p, n);
    Base.unsafe_write(t.b, p, n)
)
Base.write(t::TeeIO, x::UInt8) = (write(t.a, x); write(t.b, x))
Base.flush(t::TeeIO) = (flush(t.a); flush(t.b))

function run_single_script(args, instance)
    script_path = get_script_path(args, instance)
    stdout_filepath = joinpath(args["dir"], args["config"]["FILETREE"], args["software"], instance["id"], STDOUT_FILENAME)
    stderr_filepath = joinpath(args["dir"], args["config"]["FILETREE"], args["software"], instance["id"], STDERR_FILENAME)
    
    println("Running: $(instance["id"])")
    println("  Script: $script_path")
    
    # Redirect stdout and stderr to files
    stdout_file = open(stdout_filepath, "w")
    stderr_file = open(stderr_filepath, "w")
    
    start_time = time()
    
    try
        redirect_stdout(TeeIO(stdout, stdout_file))
        redirect_stderr(TeeIO(stderr, stderr_file))
        
        try
            # Include and run the script in the current session
            # This avoids Julia compilation overhead
            include(script_path)
        catch e
            # Restore original streams to print error
            # redirect_stdout(original_stdout)
            # redirect_stderr(original_stderr)
            
            # Log error to stderr file
            println(stderr_file, "ERROR: $e")
            println(stderr_file, "Stacktrace:")
            for (exc, bt) in Base.catch_stack()
                showerror(stderr_file, exc, bt)
                println(stderr_file)
            end
            
            warn("Error for $(instance["id"]): $e")
        finally
            # Always restore original streams
            # redirect_stdout(original_stdout)
            # redirect_stderr(original_stderr)
        end
        
    finally
        elapsed_time = time() - start_time
        println(stdout_file, "\n\nTime: $elapsed_time\n$END_OF_LOG")
        close(stdout_file)
        close(stderr_file)
    end
end

function parse_array_string(array_str)
    indices = Int[]
    for part in split(array_str, ',')
        if '-' in part
            range_parts = split(part, '-')
            start_idx = parse(Int, range_parts[1])
            end_idx = parse(Int, range_parts[2])
            append!(indices, start_idx:end_idx)
        else
            push!(indices, parse(Int, part))
        end
    end
    return sort(unique(indices))
end

function _main(args)
    # Load instances
    huge_json_path = joinpath(args["dir"], "huge_json.json")
    instances_data = JSON3.read(read(huge_json_path, String))
    instances = instances_data["instances"]
    
    # Run each script in sequence within the same Julia session
    for index in args["array"]
        instance = instances[index + 1]  # Julia is 1-indexed, but data is 0-indexed
        @assert instance["index"] == index
        run_single_script(args, instance)
    end
end

function main()
    if length(ARGS) != 3
        println(stderr, "Usage: julia estimate.jl <dir> <software> <array>")
        println(stderr, "  dir: The directory generated by generate_data.py")
        println(stderr, "  software: The software to run estimation for ($(join(AVAILABLE_SOFTWARE, ", ")))")
        println(stderr, "  array: Array indices of jobs, e.g., 0,3,4-11")
        exit(1)
    end
    
    dir = abspath(ARGS[1])
    software = ARGS[2]
    array_str = ARGS[3]
    
    # Validate software
    if !(software in AVAILABLE_SOFTWARE)
        error("Software must be one of: $(join(AVAILABLE_SOFTWARE, ", "))")
    end
    
    # Load config
    config_path = joinpath(dir, "config", "config.json")
    config = JSON3.read(read(config_path, String))
    
    # Load instances to get count
    huge_json_path = joinpath(dir, "huge_json.json")
    instances_data = JSON3.read(read(huge_json_path, String))
    total_instances = length(instances_data["instances"])
    
    info("There are $total_instances instances in total: 0-$(total_instances-1).")
    
    # Parse array indices
    array_indices = parse_array_string(array_str)
    
    # Validate array indices
    @assert 0 <= minimum(array_indices)
    @assert maximum(array_indices) < total_instances
    
    filetree_path = joinpath(dir, config["FILETREE"], software)
    @assert isdir(filetree_path) "Directory does not exist: $filetree_path"
    
    println("""
###  RUNNING ESTIMATION SCRIPTS (JULIA SINGLE SESSION)  ###

SOFTWARE            $software
ARRAY               $array_indices
DIR                 $dir

OUTPUT:             $dir
    RESULTS:        $filetree_path
""")
    
    args = Dict(
        "dir" => dir,
        "software" => software,
        "array" => array_indices,
        "config" => config
    )
    
    _main(args)
    
    info("All estimation scripts completed successfully!")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
