#!/usr/bin/env julia
# Time the Julia reader on a list of files.
#
#     julia --project=<julia> time_jl.jl SLOT R0 R1 FILE [FILE ...]
#
# Prints one line per file:
#
#     <file> open=<s> validate=<s> rows=<s> full=<s> rss=<MiB>
#
# `open` is Mestra.read, lazily, which section 29 says must read
# attributes and dataspaces only; `validate` is Mestra.validate;
# `rows` is Mestra.rows for the half-open row range [R0, R1) given in
# the zero-based terms the other drivers use, and `full` is the whole
# slot through Mestra.values. Each is timed three times and the
# smallest is kept, unless the first attempt took more than five
# seconds. R1 may be `-` for the file's row count.

using Mestra
using Printf

const REPS = 3
const LONG = 5.0

function best(f)
    times = Float64[]
    for _ in 1:REPS
        GC.gc()
        t = time_ns()
        f()
        push!(times, (time_ns() - t) / 1e9)
        times[end] > LONG && break
    end
    minimum(times)
end

"""The slot named by a section 30 path."""
function slot_of(ds, path)
    parts = split(path, '/'; keepempty = false)
    if parts[1] == "scalars"
        return ds.scalars[parts[2]]
    elseif parts[1] == "keys"
        return ds.keys[parts[2]]
    elseif parts[1] == "supports"
        sup = ds.supports[Mestra.support_by_name(ds, parts[2])]
        parts[3] == "node_arrays" && return sup.node_arrays[parts[4]]
        parts[3] == "cell_arrays" && return sup.cell_arrays[parts[4]]
        parts[3] == "coordinates" && return sup.coordinates
    end
    error("a slot path this driver does not know: $(path)")
end

"""Compile everything before anything is timed.

Julia compiles a method the first time it is called, so the first
`Mestra.read` of a session costs seconds that have nothing to do with
the file. This runs each operation once, untimed, on the first file.
"""
function warm(path, slot, r0)
    ds = Mestra.read(path)
    Mestra.validate(path)
    s = slot_of(ds, slot)
    Mestra.rows(ds, s, (r0 + 1):min(ds.nrows, r0 + 1))
    nothing
end

function main(args)
    slot, r0s, r1s = args[1], args[2], args[3]
    r0 = parse(Int, r0s)
    warm(args[4], slot, r0)
    for path in args[4:end]
        ds = Ref{Any}(nothing)
        t_open = best(() -> (ds[] = Mestra.read(path)))
        t_val = best(() -> Mestra.validate(path))
        d = ds[]
        n = d.nrows
        r1 = r1s == "-" ? n : parse(Int, r1s)
        s = slot_of(d, slot)
        t_rows = best(() -> Mestra.rows(d, s, (r0 + 1):r1))
        t_full = best(() -> Mestra.rows(d, s, 1:n))
        @printf("%s open=%.4f validate=%.4f rows=%.4f full=%.4f rss=%.1f\n",
                basename(path), t_open, t_val, t_rows, t_full,
                Sys.maxrss() / 2^20)
        flush(stdout)
    end
end

main(ARGS)
