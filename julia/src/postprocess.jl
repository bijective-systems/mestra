# Generic post-processing.
#
# Everything here is written against the format and nothing else: the
# roles, `varies`, the labels and their category tables, the weight
# role, the time key with its trajectory group, and the unit of
# generalisation.  None of it knows what a dataset is about, and none
# of it needs to.

"""
    field_statistics(ds, slot; by = nothing) -> Vector{NamedTuple}

Per-row statistics of one field, one entry per row and component, and
per region label when `by` names a label array on the same support.
The label's category table gives each region its name where it has one
(section 3: labels are how regions are represented).

    field_statistics(ds, ds["pressure"])
    field_statistics(ds, ds["pressure"], by = "region")
"""
function field_statistics(ds::Dataset, s::Slot;
                          by::Union{Nothing,AbstractString} = nothing)
    v = permute_to_logical(ds, s)
    axis = s.location === :cell ? :cell : :node
    nrows = :row in dimnames(v) ? size(v, axisindex(v, :row)) : 1
    ncomp = size(v, axisindex(v, :component))
    nsite = size(v, axisindex(v, axis))
    groups = label_groups(ds, s, by, nsite)
    out = NamedTuple[]
    for r in 1:nrows, c in 1:ncomp, (gname, sites) in groups
        x = Float64[element(v, r, i, c) for i in sites]
        finite = filter(isfinite, x)
        push!(out, (row = r, component = c, region = gname,
                    n = length(x), n_finite = length(finite),
                    mean = isempty(finite) ? NaN : sum(finite) / length(finite),
                    std = stdev(finite),
                    min = isempty(finite) ? NaN : minimum(finite),
                    max = isempty(finite) ? NaN : maximum(finite)))
    end
    return out
end

field_statistics(ds::Dataset, name::AbstractString; kwargs...) =
    field_statistics(ds, ds[name]; kwargs...)

function stdev(x::Vector{Float64})
    length(x) < 2 && return NaN
    m = sum(x) / length(x)
    return sqrt(sum((xi - m)^2 for xi in x) / length(x))
end

"""The array in the order the specification states it, so that the
code below can index it by name without permuting every element."""
function permute_to_logical(ds::Dataset, s::Slot)
    v = values(ds, s)
    want = Symbol[]
    :row in dimnames(v) && push!(want, :row)
    for d in dimnames(v)
        startswith(String(d), "group:") && push!(want, d)
    end
    :draw in dimnames(v) && push!(want, :draw)
    push!(want, :node in dimnames(v) ? :node : :cell)
    push!(want, :component)
    return permute(v, Tuple(want))
end

function element(v::DimArray, row::Int, site::Int, comp::Int)
    idx = ones(Int, ndims(v))
    for (i, d) in pairs(dimnames(v))
        d === :row && (idx[i] = row)
        (d === :node || d === :cell) && (idx[i] = site)
        d === :component && (idx[i] = comp)
        startswith(String(d), "group:") && (idx[i] = row)
    end
    return Float64(v[idx...])
end

"""Sites grouped by a label array, or one group holding all of them."""
function label_groups(ds::Dataset, s::Slot,
                      by::Union{Nothing,AbstractString}, nsite::Int)
    by === nothing && return [("all", collect(1:nsite))]
    sup = ds.supports[support_by_name(ds, s.support)]
    store = s.location === :cell ? sup.cell_arrays : sup.node_arrays
    haskey(store, by) || throw(MestraError(nothing,
        "no label array called `$(by)` beside $(s.name)"))
    lab = store[by]
    lab.role === :label || throw(MestraError(nothing,
        "`$(by)` has role $(lab.role), not label"))
    lv = vec(parent(values(ds, lab)))
    names = lab.category !== nothing && haskey(ds.categories, lab.category) ?
            ds.categories[lab.category].entries : String[]
    out = Tuple{String,Vector{Int}}[]
    for u in sort(unique(lv))
        name = 0 <= u < length(names) ? names[u + 1] : string(u)
        push!(out, (name, findall(==(u), lv)))
    end
    return out
end

"""
    integrate(ds, slot; weight, region = nothing, by = nothing)
        -> Matrix{Float64}

Integrate a field over a support with a weight array, optionally over
one region of a label.  The result is (row, component).  The weight
must be an array with role `weight` at the same location; section 6
says a weight is recomputed from the connectivity and never imported,
which is a property of the file, not of this function.

    integrate(ds, ds["pressure"], weight = "measure",
              by = "region", region = "inlet")
"""
function integrate(ds::Dataset, s::Slot; weight::AbstractString,
                   region::Union{Nothing,AbstractString} = nothing,
                   by::Union{Nothing,AbstractString} = nothing)
    sup = ds.supports[support_by_name(ds, s.support)]
    store = s.location === :cell ? sup.cell_arrays : sup.node_arrays
    haskey(store, weight) || throw(MestraError(nothing,
        "no array called `$(weight)` beside $(s.name)"))
    w = store[weight]
    w.role === :weight || throw(MestraError(nothing,
        "`$(weight)` has role $(w.role), not weight"))
    wv = vec(parent(values(ds, w)))
    v = permute_to_logical(ds, s)
    axis = s.location === :cell ? :cell : :node
    nsite = size(v, axisindex(v, axis))
    ncomp = size(v, axisindex(v, :component))
    nrows = :row in dimnames(v) ? size(v, axisindex(v, :row)) : 1
    sites = collect(1:nsite)
    if region !== nothing
        by === nothing && throw(MestraError(nothing,
            "name the label with `by` when asking for one region"))
        groups = label_groups(ds, s, by, nsite)
        i = findfirst(g -> g[1] == region, groups)
        i === nothing && throw(MestraError(nothing,
            "no region called `$(region)` in label `$(by)`"))
        sites = groups[i][2]
    end
    out = zeros(Float64, nrows, ncomp)
    for r in 1:nrows, c in 1:ncomp
        acc = 0.0
        for i in sites
            acc += wv[i] * element(v, r, i, c)
        end
        out[r, c] = acc
    end
    return out
end

integrate(ds::Dataset, name::AbstractString; kwargs...) =
    integrate(ds, ds[name]; kwargs...)

"""
    time_series(ds, slot; node, trajectory, component = 1)
        -> (times, values)

One node's history along a trajectory.  A trajectory is the set of
rows sharing one value of the group the time key names as its
`trajectory_group` (section 7); `trajectory` is that group's category
name or its id.  The rows come back in time order, which the file
guarantees is the row order but this does not rely on.
"""
function time_series(ds::Dataset, s::Slot; node::Integer, trajectory,
                     component::Integer = 1)
    tkey = findfirst_key(ds, :time)
    tkey === nothing && throw(MestraError(nothing,
        "this file declares no time key, so it holds no trajectory"))
    t = ds.keys[tkey]
    gname = t.trajectory_group
    gname === nothing && throw(MestraError(nothing,
        "the time key names no `trajectory_group`"))
    haskey(ds.keys, gname) || throw(MestraError(nothing,
        "no group key called `$(gname)`"))
    gid = category_id(ds, ds.keys[gname], trajectory)
    gvals = values(ds, ds.keys[gname])
    tvals = values(ds, t)
    rows = findall(==(gid), gvals)
    v = permute_to_logical(ds, s)
    times = Float64[tvals[r] for r in rows]
    xs = Float64[element(v, r, Int(node), Int(component)) for r in rows]
    order = sortperm(times)
    return (times[order], xs[order])
end

time_series(ds::Dataset, name::AbstractString; kwargs...) =
    time_series(ds, ds[name]; kwargs...)

findfirst_key(ds::Dataset, role::Symbol) =
    findfirst(n -> ds.keys[n].role === role, key_order(ds)) === nothing ?
    nothing : key_order(ds)[findfirst(n -> ds.keys[n].role === role,
                                      key_order(ds))]

function category_id(ds::Dataset, k::KeyColumn, what)
    what isa Integer && return what
    k.category !== nothing && haskey(ds.categories, k.category) ||
        throw(MestraError(nothing, "key `$(k.name)` names no category table"))
    i = findfirst(==(String(what)), ds.categories[k.category].entries)
    i === nothing && throw(MestraError(nothing,
        "no category called `$(what)` in table `$(k.category)`"))
    return i - 1
end

"""
    grouped_split(ds; fractions = ("train" => 0.8, "test" => 0.2),
                  seed = 0) -> Dict{String,Vector{Int}}

Split the rows into named parts that never cut a unit of
generalisation in half: whole units move together, so the split is a
generalisation test.  The file's unit of generalisation is the group
key named by `generalisation_group` (section 7); a file that declares
none is refused, because there is then nothing to honour.

The result maps each part's name to the one-based row indices in it.
"""
function grouped_split(ds::Dataset;
                       fractions = ["train" => 0.8, "test" => 0.2],
                       seed::Integer = 0)
    g = ds.generalisation_group
    g === nothing && throw(MestraError(nothing,
        "this file names no unit of generalisation, so a split cannot " *
        "honour one; declare `generalisation_group` (section 7)"))
    haskey(ds.keys, g) || throw(MestraError(nothing,
        "`generalisation_group` names `$(g)`, which is not a key"))
    gv = values(ds, ds.keys[g])
    units = sort(unique(gv))
    order = shuffled(length(units), seed)
    units = units[order]
    names = [String(first(p)) for p in fractions]
    weights = [Float64(last(p)) for p in fractions]
    total = sum(weights)
    counts = [floor(Int, length(units) * w / total) for w in weights]
    while sum(counts) < length(units)
        counts[argmax(weights)] += 1
    end
    out = Dict{String,Vector{Int}}()
    at = 1
    for (i, name) in pairs(names)
        mine = Set(units[at:(at + counts[i] - 1)])
        at += counts[i]
        out[name] = findall(u -> u in mine, gv)
    end
    return out
end

"""A deterministic shuffle, so that a split is reproducible without
pulling in a random number generator."""
function shuffled(n::Int, seed::Integer)
    idx = collect(1:n)
    state = UInt64(seed) * 0x9e3779b97f4a7c15 + 0x1234567
    for i in n:-1:2
        state = state * 6364136223846793005 + 1442695040888963407
        j = Int(state >> 33) % i + 1
        idx[i], idx[j] = idx[j], idx[i]
    end
    return idx
end

"""
    split_leaks(ds) -> Dict

The units of generalisation that the file's own `split` key places on
more than one side, which is what W01 reports.  Empty when the split
is a generalisation test, and empty when the file declares no split.
"""
function split_leaks(ds::Dataset)
    out = Dict{Any,Vector{String}}()
    g = ds.generalisation_group
    g === nothing && return out
    skey = findfirst_key(ds, :split)
    skey === nothing && return out
    haskey(ds.keys, g) || return out
    gv = values(ds, ds.keys[g])
    sv = values(ds, ds.keys[skey])
    table = ds.keys[skey].category
    names = table !== nothing && haskey(ds.categories, table) ?
            ds.categories[table].entries : String[]
    bag = Dict{Any,Set{String}}()
    for (i, u) in pairs(gv)
        i <= length(sv) || break
        s = sv[i]
        label = 0 <= s < length(names) ? names[s + 1] : string(s)
        push!(get!(bag, u, Set{String}()), label)
    end
    for (u, parts) in bag
        length(parts) > 1 && (out[u] = sort(collect(parts)))
    end
    return out
end
