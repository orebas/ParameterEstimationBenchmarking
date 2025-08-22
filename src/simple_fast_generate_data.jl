#!/usr/bin/env julia

"""
Simple fast data generation script that includes individual data generation files
in a loop to avoid Julia startup overhead.

Usage: julia simple_fast_generate_data.jl <output_directory>

This script assumes you have already run generate_data.py to create the individual 
.jl files, and this script will execute them all in a single Julia session.
"""

using Pkg
using JSON

function main()
    if length(ARGS) < 1
        println("Usage: julia simple_fast_generate_data.jl <output_directory>")
        println("Example: julia simple_fast_generate_data.jl 2025_08_21_15_30")
        exit(1)
    end
    
    output_dir = ARGS[1]
    
    # Check if output directory exists
    if !isdir(output_dir)
        println("Error: Output directory '$output_dir' does not exist.")
        println("Please run generate_data.py first to create the directory structure.")
        exit(1)
    end
    
    # Find the data generation directory
    data_gen_dir = nothing
    config_path = joinpath(output_dir, "config", "config.json")
    
    if isfile(config_path)
        config = JSON.parsefile(config_path)
        data_gen_dir = joinpath(output_dir, config["FILETREE"], config["DATA_GENERATION_DIR"])
    else
        # Try to find it automatically
        possible_paths = [
            joinpath(output_dir, "scripts", "data_generation"),
            joinpath(output_dir, "src", "data_generation"),
            joinpath(output_dir, "data_generation")
        ]
        for path in possible_paths
            if isdir(path)
                data_gen_dir = path
                break
            end
        end
    end
    
    if data_gen_dir === nothing || !isdir(data_gen_dir)
        println("Error: Could not find data generation directory.")
        println("Expected structure: <output_dir>/<filetree>/<data_generation_dir>/")
        exit(1)
    end
    
    println("Fast data generation starting...")
    println("Output directory: $output_dir")
    println("Data generation scripts: $data_gen_dir")
    
    # Find all .jl files in the data generation directory
    jl_files = []
    for file in readdir(data_gen_dir)
        if endswith(file, ".jl") && !endswith(file, "_logs.txt")
            push!(jl_files, joinpath(data_gen_dir, file))
        end
    end
    
    if isempty(jl_files)
        println("Error: No .jl files found in $data_gen_dir")
        println("Please run generate_data.py first to generate the individual scripts.")
        exit(1)
    end
    
    println("Found $(length(jl_files)) data generation scripts")
    println("Each script contains its own environment activation and package loading.")
    
    # Execute each data generation script
    successful = 0
    failed = []
    
    println("\nExecuting data generation scripts:")
    println("=" ^ 50)
    
    for (i, jl_file) in enumerate(jl_files)
        script_name = basename(jl_file)
        print("[$i/$(length(jl_files))] $script_name ... ")
        
        try            
            # Include and execute the script
            include(joinpath(dirname(@__DIR__), jl_file))            
            println("✓")
            successful += 1 
        catch e
            println("✗ Error: $(typeof(e))")
            push!(failed, basename(jl_file))
        end
    end
    
    println("\n" * "=" ^ 50)
    println("Fast data generation complete!")
    println("Successful: $successful")
    println("Failed: $(length(failed))")
    println("Total: $(length(jl_files))")

    println("Failed:\n", join(map(x -> rstrip(x, ".jl"), failed), ","))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
