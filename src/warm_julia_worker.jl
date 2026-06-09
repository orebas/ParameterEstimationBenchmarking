#!/usr/bin/env julia

using Dates
using JSON

const END_OF_LOG = "===END==="
const STDOUT_FILENAME = "stdout.txt"
const STDERR_FILENAME = "stderr.txt"
const FAILURE_REASON_FILENAME = "failure_reason.txt"

function parse_indices(parts)
    out = Int[]
    for raw in parts
        for token in split(raw, ',')
            s = strip(token)
            isempty(s) && continue
            if occursin('-', s)
                a, b = split(s, '-', limit = 2)
                append!(out, parse(Int, a):parse(Int, b))
            else
                push!(out, parse(Int, s))
            end
        end
    end
    return sort(unique(out))
end

function write_failure(cell_dir::AbstractString, err)
    try
        open(joinpath(cell_dir, FAILURE_REASON_FILENAME), "w") do io
            println(io, "julia_exception")
            showerror(io, err, catch_backtrace())
            println(io)
        end
    catch
    end
end

function run_cell(bench::AbstractString, run::AbstractString, index::Int, instances, config)
    instance = instances[index + 1]
    @assert instance["index"] == index

    cell_dir = joinpath(bench, config["FILETREE"], run, instance["id"])
    script_path = joinpath(cell_dir, "script.jl")
    stdout_path = joinpath(cell_dir, STDOUT_FILENAME)
    stderr_path = joinpath(cell_dir, STDERR_FILENAME)
    mkpath(cell_dir)

    status = 0
    open(stdout_path, "w") do out
        open(stderr_path, "w") do err
            println(out, "### Run on: ", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
            println(out, "### Warm Julia worker PID: ", getpid())
            println(out, "### Warm Julia worker index: ", index)
            flush(out)

            t0 = time()
            try
                redirect_stdout(out) do
                    redirect_stderr(err) do
                        cell_module = Module(Symbol("WarmCell_", index, "_", time_ns()))
                        Base.include(cell_module, script_path)
                    end
                end
            catch caught
                status = 1
                write_failure(cell_dir, caught)
                println(err, "ERROR: warm Julia worker caught exception")
                showerror(err, caught, catch_backtrace())
                println(err)
                println(out, "Total time: ", time() - t0)
                println(out, END_OF_LOG)
            finally
                flush(out)
                flush(err)
            end
        end
    end
    GC.gc()
    return status
end

function main()
    if length(ARGS) < 4
        println(stderr, "Usage: julia --startup-file=no src/warm_julia_worker.jl <bench> <run> <software> <index...>")
        exit(2)
    end

    bench = abspath(ARGS[1])
    run = ARGS[2]
    _software = ARGS[3]
    indices = parse_indices(ARGS[4:end])
    isempty(indices) && exit(0)

    config = JSON.parsefile(joinpath(bench, "config", "config.json"))
    instances = JSON.parsefile(joinpath(bench, "huge_json.json"))["instances"]
    @assert minimum(indices) >= 0
    @assert maximum(indices) <= length(instances) - 1

    println("### RUNNING ESTIMATION SCRIPTS (WARM JULIA WORKER) ###")
    println("BENCH               ", bench)
    println("RUN                 ", run)
    println("INDICES             ", join(indices, ","))

    failures = 0
    for index in indices
        failures += run_cell(bench, run, index, instances, config)
    end
    exit(failures == 0 ? 0 : 1)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
