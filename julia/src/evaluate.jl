# Evaluating a file on a keys table (sections 10 and 22).

"""
    evaluate(ds, table) -> Dataset

Evaluate every callable slot on a keys table and return a dataset with
the same slots, now holding data.  The table is the keys table of
section 26: a `Dict{String,Vector{Float64}}` of key name to column,
with the row order the evaluation order, so output row i is the result
for table row i.  A `NamedTuple` of columns and a `(matrix, names)`
pair are accepted too.

A callable returns one `Prediction` per output (section 10).  A slot
whose statistic is value or mean, or none, takes the prediction's
mean; a slot whose statistic is band takes its uncertainty and is
given the prediction's level and method.

Distillation is this operation on a grid.  The result has no file
behind it until it is written, and what it carries is settled by
`docs/api-conventions.md` section 7: every callable slot is now a
stored slot, so there is no `/callables` group at all; `/notes` is
carried, because the content is the same; `/private` is not, because a
producer's records describe the file they were written into.  The
support id is unchanged, so a tool knows the evaluated file and the
model file are about the same mesh after reading one attribute.
"""
function evaluate(ds::Dataset, table)
    t = normalise_keys(table)
    n = keys_table_rows(t)
    out = deepcopy(ds)
    # Read anything still on disk before the result stops pointing at
    # the file it came from.
    out.path === nothing || materialise!(out)
    out.path = nothing
    out.lazy = false
    out.nrows = n

    for name in key_order(ds)
        haskey(t, name) || throw(MestraError(nothing,
            "the keys table has no column `$(name)`, which this file " *
            "declares; section 26 asks for one column per key"))
    end
    for (name, k) in out.keys
        col = t[name]
        length(col) == n || throw(MestraError(nothing,
            "column `$(name)` has $(length(col)) rows, not $(n)"))
        k.values = k.eltype === String ? String.(collect(col)) :
                   convert(Vector{k.eltype}, collect(col))
        k.chunk = nothing
    end

    cache = Dict{String,Any}()
    for s in all_slots(out)
        if !is_callable_slot(s)
            if !isempty(s.ldims) && first(s.ldims) === :row && s.dshape[1] != n
                throw(MestraError("E16",
                    "slot $(s.name) holds $(s.dshape[1]) rows of stored " *
                    "data, which a table of $(n) rows would contradict"))
            end
            continue
        end
        id = callable_id(s)
        if !haskey(cache, id)
            haskey(out.callables, id) || throw(MestraError("E14",
                "no callable with id `$(id)`"))
            cache[id] = build_callable(out.callables[id])(t)
        end
        outputs = cache[id]
        name = something(s.output, s.name)
        haskey(outputs, name) || throw(MestraError(nothing,
            "callable `$(id)` produces no output called `$(name)`"))
        record = outputs[name]
        record isa Prediction || throw(MestraError(nothing,
            "callable `$(id)` returned something that is not a " *
            "Prediction for output `$(name)` (section 10)"))
        materialise_slot!(s, part_of(record, s, id, name), n)
    end
    # `docs/api-conventions.md` section 7: evaluating a file turns
    # every callable slot into a stored slot, so the result has no
    # callable to keep and `/callables` is absent from an evaluated
    # file rather than present and empty.  That is what the other
    # three writers leave, and it is what section 13 says a container
    # group with nothing in it is.
    empty!(out.callables)
    delete!(out.container_groups, "callables")
    return out
end

"""Section 10: which part of the record fills a slot is its statistic.
A band slot takes the uncertainty and, with it, the level and the
method the record states."""
function part_of(record::Prediction, s::Slot, id, name)
    st = something(s.statistic, "value")
    if st == "band"
        record.uncertainty === nothing && throw(MestraError("E12", s.path,
            "this band slot takes the uncertainty of output `$(name)` and " *
            "the callable `$(id)` returned none; a band without a level " *
            "cannot be stored, so drop the slot or give the model a band"))
        s.level = record.level
        s.method = record.method
        return record.uncertainty
    end
    st in ("value", "mean") && return record.mean
    throw(MestraError("E12", s.path,
        "a callable serves value, mean and band slots; this one is $(st)"))
end

"""Give a slot the data a callable produced, and the shape and the
dimension names that go with it."""
function materialise_slot!(s::Slot, data::Array{Float64}, nrows::Int)
    s.source = "data"
    s.output = nothing
    s.data = data
    s.eltype = Float64
    s.dshape = collect(reverse(size(data)))
    if s.location === :scalar
        length(s.dshape) == 1 || throw(MestraError(nothing,
            "a scalar slot takes a one-dimensional result"))
        s.ldims = [:row]
    else
        s.varies = something(s.varies, "row")
        s.ldims = [logical_dim(n) for n in canonical_disk_dims(s)]
        length(s.ldims) == length(s.dshape) || throw(MestraError(nothing,
            "callable output for $(s.name) has $(length(s.dshape)) axes " *
            "where the slot has $(length(s.ldims))"))
        s.components = s.dshape[end]
    end
    s.chunk = nothing
    return s
end

"""
    callable(ds, id) -> Callable

Build the callable the file carries, if this reader owns its `type`.
"""
function callable(ds::Dataset, id::AbstractString)
    haskey(ds.callables, id) || throw(MestraError("E14",
        "no callable with id `$(id)`"))
    return build_callable(ds.callables[id])
end
