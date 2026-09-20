#!/usr/bin/env julia
# Where the Julia reader spends the time.
#
#     julia --project=<julia> profile_jl.jl open|validate FILE [LINES]
#
# Runs the operation once to compile it, then once more under the
# sampling profiler, and prints the flat profile: the functions the
# samples landed in, most first.

using Mestra
using Profile

function main(args)
    op, path = args[1], args[2]
    lines = length(args) > 2 ? parse(Int, args[3]) : 25
    f = op == "open" ? () -> Mestra.read(path) :
        op == "validate" ? () -> Mestra.validate(path) :
        error("open or validate")
    f()                       # compile, and warm the page cache
    Profile.clear()
    Profile.init(; n = 10_000_000, delay = 0.005)
    @profile f()
    Profile.print(format = :flat, sortedby = :count, mincount = 20)
    println("\n(only the entries with at least 20 samples are shown)")
end

main(ARGS)
