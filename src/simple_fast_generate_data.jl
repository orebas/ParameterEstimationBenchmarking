#!/usr/bin/env julia

"""
Simple fast data generation script that includes individual data generation files
in a loop to avoid Julia startup overhead.

Usage: julia simple_fast_generate_data.jl <output_directory>

This script assumes you have already run generate_data.py to create the individual 
.jl files, and this script will execute them all in a single Julia session.
"""

using Pkg; Pkg.activate(joinpath(dirname(@__DIR__), "environments/julia_odepe"))
using JSON

function main()
    if length(ARGS) < 1
        println("Usage: julia simple_fast_generate_data.jl <output_directory>")
        println("Example: julia simple_fast_generate_data.jl results/EXAMPLE")
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
    config_path = joinpath(output_dir, "config", "config.json")
    config = JSON.parsefile(config_path)
    data_gen_dir = joinpath(output_dir, config["FILETREE"], config["DATA_GENERATION_DIR"])
    data_csv_dir = joinpath(output_dir, config["FILETREE"], config["DATA_DIR"])

    println("Fast data generation starting...")
    println("Output directory: $output_dir")
    println("Data generation scripts: $data_gen_dir")
    
    instances_to_generate = filter(f -> endswith(f, ".jl"), readdir(data_gen_dir))
    already_computed = map(f -> chopsuffix(f, ".csv"), readdir(data_csv_dir))
    instances_to_generate = filter(f -> !(chopsuffix(f, ".jl") in already_computed), instances_to_generate)

    jl_files = []
    for instance in instances_to_generate
        push!(jl_files, joinpath(data_gen_dir, instance))
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

    println("Failed:\n", failed)

    exit(length(failed) != 0)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
