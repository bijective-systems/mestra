# What a file says about itself, printed.
#
# Section 29 asks that opening a file read no array, and this is what
# that buys: everything below comes from attributes and dataspaces.
# What is printed is the list of `docs/api-conventions.md` section 5,
# in the same order in every language: for a key its name, role,
# units, bounds, category, trajectory group and parent; for a support
# its kind, its counts and its id; for a slot its shape with the name
# of each axis, its units and its source, and for a callable slot the
# callable and the output it takes.

"""
    info(path; io = stdout)
    info(ds; io = stdout)

Print what a file declares, without reading an array.  A semantic
fault never stops this: a file with a missing unit or a broken split
is exactly the file a reader most needs to look at.

    Mestra.info("case.mes")
"""
function info(path::AbstractString; io::IO = stdout, kwargs...)
    ds = read(String(path); lazy = true, kwargs...)
    return info(ds; io = io, name = String(path))
end

function info(ds::Dataset; io::IO = stdout, name = nothing)
    head = something(name, ds.path, "dataset")
    println(io, head, ": ", ds.format, ", ", ds.nrows, " row(s), ",
            isempty(ds.supports) ? "no support" :
            ds.aligned ? "aligned" : "unaligned",
            ", written by ", ds.writer, " at ", ds.created)
    ds.generalisation_group === nothing ||
        println(io, "  unit of generalisation: ",
                ds.generalisation_group)

    if !isempty(ds.keys)
        println(io, "keys")
        names = key_order(ds)
        w = maximum(length.(names))
        for n in names
            println(io, "  ", rpad(n, w), "  ", key_line(ds, ds.keys[n]))
        end
    end

    if !isempty(ds.categories)
        println(io, "categories")
        for t in sort(collect(Base.keys(ds.categories)), by = codeunits)
            e = ds.categories[t].entries
            println(io, "  ", t, "  ", length(e), ": ",
                    join(e[1:min(6, end)], ", "),
                    length(e) > 6 ? ", ..." : "")
        end
    end

    if !isempty(ds.supports)
        println(io, "supports")
        w = maximum(length(s.name) for s in ds.supports)
        for s in support_order(ds)
            println(io, "  ", rpad(s.name, w), "  ", rpad(s.kind, 5), "  ",
                    s.n_nodes, " node(s), ", s.n_cells, " cell(s)  ",
                    s.support_id)
        end
    end

    slots = all_slots(ds)
    if !isempty(slots)
        println(io, "slots")
        w = maximum(length(s.path) for s in slots)
        for s in slots
            println(io, "  ", rpad(s.path, w), "  ", slot_line(s))
        end
    end

    if !isempty(ds.callables)
        println(io, "callables")
        for id in sort(collect(Base.keys(ds.callables)), by = codeunits)
            c = ds.callables[id]
            println(io, "  ", id, "  type ", something(c.type, "-"),
                    c.repr === nothing ? "" : "  " * c.repr)
        end
    end

    if !isempty(ds.findings)
        println(io, "what the reader would not follow or could not read")
        for f in ds.findings
            println(io, "  ", f)
        end
    end
    return ds
end

"""One key: the fields of section 5, and the ones it does not carry
are left out rather than printed as blanks."""
function key_line(ds::Dataset, k::KeyColumn)
    parts = String[rpad(k.role === nothing ? "-" : String(k.role), 11)]
    k.units === nothing || push!(parts, "units " * k.units)
    (k.lower === nothing || k.upper === nothing) ||
        push!(parts, "bounds [" * string(k.lower) * ", " *
                     string(k.upper) * "]")
    k.category === nothing || push!(parts, "category " * k.category)
    k.trajectory_group === nothing ||
        push!(parts, "trajectory_group " * k.trajectory_group)
    k.parent === nothing || push!(parts, "parent " * k.parent)
    return join(parts, "  ")
end

"""One slot: the shape with the name of every axis, then the units and
where the numbers come from."""
function slot_line(s::Slot)
    parts = String[]
    if !isempty(s.ldims)
        push!(parts, "(" * join(string.(s.ldims), ", ") * ") " *
                     join(s.dshape, "x"))
    elseif s.components !== nothing
        push!(parts, "(row, " *
                     (s.location === :cell ? "cell" : "node") *
                     ", component) " * string(s.components) *
                     " component(s)")
    end
    s.role === nothing || push!(parts, String(s.role))
    push!(parts, "units " * something(s.units, "-"))
    s.statistic === nothing || push!(parts, "statistic " * s.statistic)
    push!(parts, is_callable_slot(s) ?
          "callable " * callable_id(s) * " -> " * something(s.output, "-") :
          "data")
    s.recomputed === true && push!(parts, "recomputed")
    return join(parts, "  ")
end
