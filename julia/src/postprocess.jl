# Generic post-processing.
#
# Everything here is written against the format and nothing else: the
# roles, `varies`, the labels and their category tables, the weight
# role, the time key with its trajectory group, and the unit of
# generalisation.  None of it knows what a dataset is about, and none
# of it needs to.
#
# Each helper takes the dataset, then the slot, which may be its name,
# and names a label with `by`, which is the shape every language has
# (`docs/api-conventions.md` section 4).

"""What an array varies along, as a string, for a slot that may not
say."""
varies_of(s::Slot) = s.varies === nothing ? "none" : s.varies

"""How many rows a slot has an instance for: its own rows when it
varies along `row`, one when it varies along nothing, and the file's
rows when it varies along a group, since each row then picks the
instance its category names."""
function row_count(ds::Dataset, s::Slot)
    v = varies_of(s)
    v == "row" && return isempty(s.dshape) ? ds.nrows : s.dshape[1]
    v == "none" && return 1
    return max(ds.nrows, 1)
end

"""Which instance of an array each row reads: itself for `row`, the
only one there is for `none`, and the category of the group key for
`group:<k>`, which is the mechanism of section 5 and not the row
number."""
function instances_for(ds::Dataset, varies::AbstractString, nrows::Int)
    varies == "row" && return collect(1:nrows)
    varies == "none" && return ones(Int, nrows)
    g = String(varies)[7:end]
    haskey(ds.keys, g) || throw(MestraError("E04", "/keys/" * g,
        "an array varies along group key `$(g)`, which this file does " *
        "not declare"))
    gv = values(ds, ds.keys[g])
    return Int[Int(gv[r]) + 1 for r in 1:min(nrows, length(gv))]
end

"""
    field_statistics(ds, slot; by = nothing) -> Vector{NamedTuple}

Per-row statistics of one field, one entry per row and component, and
per region when `by` names a label array on the same support.  The
entry then carries a column named after that label, whose value is the
category name where the label has a table and the value itself where
it has none; with no `by` there is no such column at all.

    field_statistics(ds, "pressure")
    field_statistics(ds, "pressure", by = "region")
      # (row = 1, component = 1, region = "inlet", n = 3, ...)
"""
function field_statistics(ds::Dataset, s::Slot;
                          by::Union{Nothing,AbstractString} = nothing)
    s.location === :scalar && throw(MestraError(nothing, s.path,
        "`field_statistics` summarises a field over the nodes or cells " *
        "of a support, and `$(s.name)` is a scalar, which is one number " *
        "a row: its values are `Mestra.values(ds, ds[\"$(s.name)\"])`"))
    v = permute_to_logical(ds, s)
    axis = s.location === :cell ? :cell : :node
    nrows = row_count(ds, s)
    inst = instances_for(ds, varies_of(s), nrows)
    ncomp = size(v, axisindex(v, :component))
    nsite = size(v, axisindex(v, axis))
    groups = label_groups(ds, s, by, nsite)
    out = NamedTuple[]
    for r in 1:length(inst), c in 1:ncomp, (gname, sites) in groups
        x = Float64[element(v, inst[r], i, c) for i in sites]
        finite = filter(isfinite, x)
        stats = (n = length(x), n_finite = length(finite),
                 mean = isempty(finite) ? NaN : sum(finite) / length(finite),
                 std = stdev(finite),
                 min = isempty(finite) ? NaN : minimum(finite),
                 max = isempty(finite) ? NaN : maximum(finite))
        label = by === nothing ? NamedTuple() :
                NamedTuple{(Symbol(by),)}((gname,))
        push!(out, merge((row = r, component = c), label, stats))
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

"""One element of an array in logical order, by instance, site and
component."""
function element(v::DimArray, inst::Int, site::Int, comp::Int)
    idx = ones(Int, ndims(v))
    for (i, d) in pairs(dimnames(v))
        d === :row && (idx[i] = inst)
        (d === :node || d === :cell) && (idx[i] = site)
        d === :component && (idx[i] = comp)
        startswith(String(d), "group:") && (idx[i] = inst)
    end
    return Float64(v[idx...])
end

"""Sites grouped by a label array, or one group holding all of them."""
function label_groups(ds::Dataset, s::Slot,
                      by::Union{Nothing,AbstractString}, nsite::Int)
    by === nothing && return [("all", collect(1:nsite))]
    sup = named_support(ds, s.support)
    store = s.location === :cell ? sup.cell_arrays : sup.node_arrays
    haskey(store, by) || throw(MestraError(nothing, s.path,
        "no array called `$(by)` beside `$(s.name)` on support " *
        "`$(sup.name)`; `by` names a label array at the same location"))
    lab = store[by]
    lab.role === :label || throw(MestraError("E02", lab.path,
        "`$(by)` has role $(lab.role), not label; `by` names a label"))
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
    integrate(ds, slot; weight = nothing, by = nothing, region = nothing)
        -> Matrix{Float64}

Integrate a field over its support, optionally over one region of a
label.  The result is (row, component).

With no `weight`, this uses the weight array at the slot's location on
its support, and computes one from the connectivity when the file has
none, saying so; `weight` names one instead.  Section 3 says a weight
is computed from the connectivity and never imported, so a file that
has one got it from `compute_weights!`.

    integrate(ds, "pressure")
    integrate(ds, "pressure", by = "region", region = "inlet")
"""
function integrate(ds::Dataset, s::Slot; weight = nothing,
                   region::Union{Nothing,AbstractString} = nothing,
                   by::Union{Nothing,AbstractString} = nothing)
    s.location === :scalar && throw(MestraError(nothing, s.path,
        "`integrate` sums a field over the nodes or cells of a support, " *
        "and `$(s.name)` is a scalar, which is one number a row"))
    sup = named_support(ds, s.support)
    v = permute_to_logical(ds, s)
    axis = s.location === :cell ? :cell : :node
    nsite = size(v, axisindex(v, axis))
    ncomp = size(v, axisindex(v, :component))
    nrows = row_count(ds, s)
    inst = instances_for(ds, varies_of(s), nrows)
    wm, wvaries = weights_for(ds, s, sup, weight, nsite)
    winst = instances_for(ds, wvaries, nrows)
    sites = collect(1:nsite)
    if region !== nothing
        by === nothing && throw(MestraError(nothing, s.path,
            "name the label with `by` when asking for one region"))
        groups = label_groups(ds, s, by, nsite)
        i = findfirst(g -> g[1] == region, groups)
        i === nothing && throw(MestraError(nothing, s.path,
            "no region called `$(region)` in label `$(by)`; it has " *
            join(["`" * g[1] * "`" for g in groups], ", ")))
        sites = groups[i][2]
    end
    out = zeros(Float64, length(inst), ncomp)
    for r in 1:length(inst), c in 1:ncomp
        acc = 0.0
        for i in sites
            acc += wm[winst[r], i] * element(v, inst[r], i, c)
        end
        out[r, c] = acc
    end
    return out
end

integrate(ds::Dataset, name::AbstractString; kwargs...) =
    integrate(ds, ds[name]; kwargs...)

"""The weights to integrate a slot with, as (instance, site), and what
they vary along: the file's own weight array at that location, the one
`weight` names, or one computed from the connectivity, which says so
because it is not in the file."""
function weights_for(ds::Dataset, s::Slot, sup::Support, weight,
                     nsite::Int)
    location = s.location === :cell ? :cell : :node
    store = location === :cell ? sup.cell_arrays : sup.node_arrays
    if weight === nothing
        found = sort([n for (n, a) in store if a.role === :weight],
                     by = codeunits)
        if isempty(found)
            w, varies, units = weight_matrix(ds, sup, location)
            @info "no weight array at the $(location)s of support " *
                  "`$(sup.name)`, so one was computed from the " *
                  "connectivity" units = string(units) keep =
                  "Mestra.compute_weights!(ds, \"$(sup.name)\", :$(location))"
            return (w, varies)
        end
        length(found) == 1 || throw(MestraError("E03",
            "/supports/$(sup.name)",
            "this support carries $(length(found)) weight arrays at its " *
            "$(location)s, " * join(["`" * n * "`" for n in found], ", ") *
            "; name one with `weight`"))
        weight = found[1]
    end
    name = String(weight)
    haskey(store, name) || throw(MestraError(nothing, s.path,
        "no array called `$(name)` at the $(location)s of support " *
        "`$(sup.name)`"))
    w = store[name]
    w.role === :weight || throw(MestraError("E02", w.path,
        "`$(name)` has role $(w.role), not weight"))
    p = permute_to_logical(ds, w)
    a = collect(parent(p))
    first(dimnames(p)) in (:node, :cell) && (a = reshape(a, 1, size(a)...))
    wm = Float64.(a[:, :, 1])
    size(wm, 2) == nsite || throw(MestraError("E05", w.path,
        "$(size(wm, 2)) weights for $(nsite) $(location)s"))
    return (wm, varies_of(w))
end

"""
    time_series(ds, slot; node, trajectory, component = 1)
        -> (times, values)

One node's history along a trajectory.  A trajectory is the set of
rows sharing one value of the group the time key names as its
`trajectory_group` (section 7); `trajectory` is that group's category
name or its id.  The rows come back in time order, which the file
guarantees is the row order but this does not rely on.

`node` is the node or cell to follow, and is left out for a scalar,
which has one value a row.
"""
function time_series(ds::Dataset, s::Slot; node = nothing, trajectory,
                     component::Integer = 1)
    tkey = findfirst_key(ds, :time)
    tkey === nothing && throw(MestraError("E03", "/keys",
        "this file declares no time key, so it holds no trajectory"))
    t = ds.keys[tkey]
    gname = t.trajectory_group
    gname === nothing && throw(MestraError("E39", t.path,
        "the time key names no `trajectory_group`, so its rows are not " *
        "grouped into trajectories (section 7)"))
    haskey(ds.keys, gname) || throw(MestraError("E39", t.path,
        "`trajectory_group` names `$(gname)`, which is not a key"))
    gid = category_id(ds, ds.keys[gname], trajectory)
    gvals = values(ds, ds.keys[gname])
    tvals = values(ds, t)
    rows = findall(==(gid), gvals)
    if s.location === :scalar
        node === nothing || throw(MestraError(nothing, s.path,
            "`$(s.name)` is a scalar, which has one value a row; leave " *
            "`node` out"))
        xs = Float64[values(ds, s)[r] for r in rows]
    else
        node === nothing && throw(MestraError(nothing, s.path,
            "say which node to follow with `node`"))
        v = permute_to_logical(ds, s)
        inst = instances_for(ds, varies_of(s), row_count(ds, s))
        xs = Float64[element(v, inst[r], Int(node), Int(component))
                     for r in rows]
    end
    times = Float64[tvals[r] for r in rows]
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
        throw(MestraError("E39", k.path,
            "key `$(k.name)` names no category table, so `$(what)` cannot " *
            "be looked up; pass the category id instead"))
    i = findfirst(==(String(what)), ds.categories[k.category].entries)
    i === nothing && throw(MestraError("E10", k.path,
        "no category called `$(what)` in table `$(k.category)`, which has " *
        join(["`" * e * "`" for e in ds.categories[k.category].entries],
             ", ")))
    return i - 1
end

"""
    grouped_split(ds, fractions = ["train" => 0.8, "test" => 0.2];
                  seed = 0) -> Dict{String,Vector{Int}}

Split the rows into named parts that never cut a unit of
generalisation in half: whole units move together, so the split is a
generalisation test.  The file's unit of generalisation is the group
key named by `generalisation_group` (section 7); a file that declares
none is refused, because there is then nothing to honour.

SPEC.md section 31 is the algorithm, to the letter, so that one seed
names one split in every language: the units are ordered by their
category names as UTF-8 bytes and never by their ids, one splitmix64
draw is taken per unit in that order, the units are sorted by their
draw, the parts are filled in the order of their names, and their
sizes are the largest remainders of `fraction * units` with every part
left holding at least one.

Every named part gets at least one unit, whatever the fractions say,
as long as there are at least as many units as parts; fewer units than
parts is refused rather than answered with an empty part.  `seed`
defaults to 0 and is the whole of the randomness, so writing it down
is enough to write down the split.

The result maps each part's name to the one-based row indices in it.
`fractions` is any ordered collection of name-to-weight pairs, or a
`Dict`, whose parts are then taken in name order so that the answer
does not depend on how the dictionary happened to be built.

    grouped_split(ds)                                  # 80/20, seed 0
    grouped_split(ds, Dict("train" => 8, "test" => 2); seed = 7)
"""
function grouped_split(ds::Dataset,
                       fractions = ["train" => 0.8, "test" => 0.2];
                       seed::Integer = 0)
    g = ds.generalisation_group
    g === nothing && throw(MestraError("E39", "/",
        "this file names no unit of generalisation, so a split cannot " *
        "honour one; call `set_generalisation_group!(ds, name)` " *
        "(section 7)"))
    haskey(ds.keys, g) || throw(MestraError("E39", "/",
        "`generalisation_group` names `$(g)`, which is not a key"))
    parts = normalise_fractions(fractions)
    isempty(parts) && throw(MestraError(nothing, "/",
        "`fractions` names no parts"))
    weights = Float64[last(p) for p in parts]
    all(w -> w >= 0, weights) && sum(weights) > 0 ||
        throw(MestraError(nothing, "/",
            "a fraction is a share of the units, so none is negative and " *
            "they do not add up to nothing; these are " *
            join(weights, ", ")))
    gv = values(ds, ds.keys[g])
    units = split_units(ds, ds.keys[g], seed)
    n, k = length(units.ids), length(parts)
    n >= k || throw(MestraError(nothing, "/keys/" * g,
        "$(n) unit(s) of generalisation cannot fill $(k) parts without " *
        "leaving one empty; ask for fewer parts, or group the rows " *
        "differently"))
    counts = share_out(n, weights)
    out = Dict{String,Vector{Int}}()
    at = 1
    for (i, p) in pairs(parts)
        mine = Set(units.dealt[at:(at + counts[i] - 1)])
        at += counts[i]
        out[first(p)] = findall(u -> u in mine, gv)
    end
    return out
end

"""
    split_units(ds, key, seed)
        -> (ids, names, draws, dealt)

The units of generalisation of a group key, in the order section 31
puts them -- by the category name of each id as UTF-8 bytes, so that
two files holding the same units in tables written in two orders split
the same way -- with the splitmix64 draw taken for each, and `dealt`,
the ids sorted by that draw.  `ids`, `names` and `draws` are the
worked example's table of section 31, and the four together are the
whole of what the algorithm knows about a file.
"""
function split_units(ds::Dataset, k::KeyColumn, seed::Integer)
    ids = sort(unique(values(ds, k)))
    names = String[unit_name(ds, k, i) for i in ids]
    order = sortperm(names, by = codeunits)
    ids, names = ids[order], names[order]
    state = seed % UInt64
    draws = UInt64[]
    for _ in ids
        state, draw = splitmix64(state)
        push!(draws, draw)
    end
    by_draw = sortperm(eachindex(ids),
                       by = i -> (draws[i], codeunits(names[i])))
    return (ids = ids, names = names, draws = draws, dealt = ids[by_draw])
end

"""A unit as the file names it: the entry of the key's category table,
and the id itself where the key has no table."""
function unit_name(ds::Dataset, k::KeyColumn, id)
    table = k.category
    entries = table !== nothing && haskey(ds.categories, table) ?
              ds.categories[table].entries : String[]
    return (id isa Integer && 0 <= id < length(entries)) ?
           entries[Int(id) + 1] : string(id)
end

"""One step of splitmix64, which is the generator section 31 names:
sixty-four bits of state, no more, and the same stream in every
language with wrapping unsigned arithmetic.  Gives the new state and
the draw."""
function splitmix64(state::UInt64)
    state += 0x9e3779b97f4a7c15
    z = state
    z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return (state, z ⊻ (z >> 31))
end

"""The parts of a split, in the order they are filled, which is name
order whatever order they were given in: the same fractions and the
same seed then give the same split, whether they arrived as a vector
of pairs, a dictionary or a named tuple."""
normalise_fractions(f::AbstractDict) =
    sort([String(k) => Float64(f[k]) for k in Base.keys(f)],
         by = p -> codeunits(first(p)))
normalise_fractions(f) =
    sort([String(first(p)) => Float64(last(p)) for p in pairs_of(f)],
         by = p -> codeunits(first(p)))

pairs_of(f::NamedTuple) = pairs(f)
pairs_of(f) = f

"""How many units each part gets, for parts already in name order:
the floor of `fraction * units` each, the units left over one each to
the largest remainders, and then, while a part holds none, one unit
from the part holding most.  Ties are broken by part name throughout,
which is the index order here.  That is section 31's paragraph on the
sizes, and it is what leaves no part empty."""
function share_out(n::Int, weights::Vector{Float64})
    total = sum(weights)
    exact = Float64[n * w / total for w in weights]
    counts = Int[floor(Int, e) for e in exact]
    over = sortperm(eachindex(counts),
                    by = i -> (-(exact[i] - counts[i]), i))
    for i in 1:(n - sum(counts))
        counts[over[i]] += 1
    end
    while any(==(0), counts)
        empty = findfirst(==(minimum(counts)), counts)
        from = findfirst(==(maximum(counts)), counts)
        counts[from] > 1 || break
        counts[from] -= 1
        counts[empty] += 1
    end
    return counts
end

"""
    split_leaks(ds) -> Dict

The units of generalisation that the file's own `split` key places on
more than one side, which is what W01 reports.  An empty dictionary
means the split is a generalisation test and nothing else: a file with
no split key, or no unit of generalisation, is refused rather than
answered with the same empty dictionary.
"""
function split_leaks(ds::Dataset)
    g = ds.generalisation_group
    g === nothing && throw(MestraError("E39", "/",
        "this file names no unit of generalisation, so nothing can leak " *
        "across its split; call `set_generalisation_group!(ds, name)`"))
    haskey(ds.keys, g) || throw(MestraError("E39", "/",
        "`generalisation_group` names `$(g)`, which is not a key"))
    skey = findfirst_key(ds, :split)
    skey === nothing && throw(MestraError("E03", "/keys",
        "this file declares no key of role split, so there is no split " *
        "for a unit to leak across"))
    out = Dict{Any,Vector{String}}()
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
