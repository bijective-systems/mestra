# Building a dataset from arrays.
#
# A handful of calls with sensible defaults: the dimensions follow
# from the names the caller gives the axes, the bounds follow from the
# data unless the caller says otherwise, and a support fills in its own
# id.  Anything that cannot legally be written raises a MestraError
# naming the rule of section 14 it breaks.

"""Turn an array the caller holds into the orientation this package
keeps, given the name of each of its axes.  The file's order is
(row | group | nothing, [draw], node | cell, component); the stored
orientation reverses it, so the array's linear memory is the file's
byte order."""
function to_stored(data::AbstractArray, dims, want::Vector{Symbol})
    dims = Symbol[Symbol(d) for d in dims]
    length(dims) == ndims(data) || throw(MestraError(nothing,
        "dims names $(length(dims)) axes for an array of $(ndims(data))"))
    a = data
    if !(:component in dims) && :component in want
        a = reshape(a, size(a)..., 1)
        dims = vcat(dims, :component)
    end
    Set(dims) == Set(want) || throw(MestraError(nothing,
        "the array's axes are $(Tuple(dims)) where the slot needs " *
        "$(Tuple(want))"))
    perm = [findfirst(==(d), dims) for d in reverse(want)]
    return permutedims(collect(a), perm)
end

default_dims(data::AbstractArray) =
    ndims(data) == 1 ? [:node] :
    ndims(data) == 2 ? [:row, :node] :
    ndims(data) == 3 ? [:row, :node, :component] :
    throw(MestraError(nothing, "name the axes with `dims`"))

"""
    add_category_table!(ds, name, entries)

A category table.  Category ids are the zero-based positions of the
entries (section 21), so the first entry is id 0.
"""
function add_category_table!(ds::Dataset, name::AbstractString, entries)
    ds.categories[String(name)] = CategoryTable(name, collect(entries))
    push!(ds.container_groups, "categories")
    return ds.categories[String(name)]
end

"""
    add_key!(ds, name, values; role, units, bounds = :auto, ...)

A per-row key column.  `bounds = :auto` takes the declared bounds from
the data, which is what a producer usually means; pass
`bounds = nothing` for none and `bounds = (lo, hi)` to state them.
The row count follows from the first key added.
"""
function add_key!(ds::Dataset, name::AbstractString, values;
                  role::Symbol, units = nothing, bounds = :auto,
                  category = nothing, trajectory_group = nothing,
                  parent = nothing, eltype = nothing)
    role in KEY_ROLES || throw(MestraError("E02",
        "`$(role)` is not a key role of section 3"))
    vals = collect(values)
    T = eltype === nothing ? default_key_eltype(role, vals) : eltype
    vals = T === String ? String.(vals) : convert(Vector{T}, vals)
    if isempty(ds.keys) && isempty(ds.scalars)
        ds.nrows = length(vals)
    end
    length(vals) == ds.nrows || throw(MestraError("E16",
        "key `$(name)` has $(length(vals)) rows where the dataset has " *
        "$(ds.nrows)"))
    lo, hi = nothing, nothing
    if bounds === :auto
        if role in (:design, :condition, :time) && !isempty(vals)
            finite = Float64[x for x in vals if isfinite(x)]
            isempty(finite) ||
                ((lo, hi) = (minimum(finite), maximum(finite)))
        end
    elseif bounds !== nothing
        lo, hi = Float64(bounds[1]), Float64(bounds[2])
    end
    if role in (:categorical, :group, :split, :status) && category === nothing
        throw(MestraError("E39",
            "a $(role) key requires a `category` table (section 19)"))
    end
    if role in (:design, :condition, :time) && units === nothing
        throw(MestraError("E39", "a $(role) key requires `units`"))
    end
    k = KeyColumn(name, role; units = units, lower = lo, upper = hi,
                  category = category, trajectory_group = trajectory_group,
                  parent = parent, eltype = T,
                  strsize = T === String ?
                            maximum(vcat([ncodeunits(s) for s in vals], 1)) : 1,
                  values = vals, path = "/keys/" * String(name))
    ds.keys[String(name)] = k
    push!(ds.container_groups, "keys")
    role === :group && ds.generalisation_group === nothing &&
        (ds.generalisation_group = String(name))
    return k
end

default_key_eltype(role::Symbol, vals) =
    role in (:design, :condition, :time) ? Float64 :
    role === :id ? (isempty(vals) || vals[1] isa AbstractString ?
                    String : Int64) : Int32

"""
    add_scalar!(ds, name, values; units, ...)

A per-row quantity of interest.  `units` is required (E11).
"""
function add_scalar!(ds::Dataset, name::AbstractString, values;
                     units::AbstractString, statistic = nothing,
                     of = nothing, quantile = nothing, deflate = nothing,
                     shuffle::Bool = false)
    vals = convert(Vector{Float64}, collect(values))
    if isempty(ds.keys) && isempty(ds.scalars)
        ds.nrows = length(vals)
    end
    length(vals) == ds.nrows || throw(MestraError("E16",
        "scalar `$(name)` has $(length(vals)) rows where the dataset has " *
        "$(ds.nrows)"))
    s = Slot(name, :scalar; units = units, source = "data",
             statistic = statistic, of = of, quantile = quantile,
             ldims = [:row], dshape = [length(vals)], eltype = Float64,
             deflate = deflate, shuffle = shuffle,
             data = vals, path = "/scalars/" * String(name))
    ds.scalars[String(name)] = s
    push!(ds.container_groups, "scalars")
    return s
end

"""
    add_mesh_support!(ds, name; coordinates, cell_types, cell_offsets,
                      cell_connectivity, units = "m", dims, varies)

A mesh support.  `coordinates` is (node, component) by default, and
`dims` names its axes when it is anything else -- (:row, :node,
:component) for a moving mesh, (:instance, :node, :component) with
`varies = "group:member"` for a parametric family.  The support id is
computed from the cells (section 24).
"""
function add_mesh_support!(ds::Dataset, name::AbstractString;
                           coordinates, cell_types, cell_offsets,
                           cell_connectivity, units::AbstractString = "m",
                           dims = nothing, varies = nothing)
    types = UInt8.(collect(cell_types))
    offsets = Int64.(collect(cell_offsets))
    conn = Int64.(collect(cell_connectivity))
    dims === nothing && (dims = ndims(coordinates) == 2 ?
                                [:node, :component] :
                                [:row, :node, :component])
    n_nodes = size(coordinates, findfirst(==(:node), Symbol.(dims)))
    s = Support(name, "mesh"; n_nodes = n_nodes, n_cells = length(types),
                cell_types = types, cell_offsets = offsets,
                cell_connectivity = conn)
    s.coordinates = make_array_slot(ds, s, "coordinates", coordinates, :node;
                                    role = :coordinates, units = units,
                                    dims = dims, varies = varies)
    push!(ds.supports, s)
    push!(ds.container_groups, "supports")
    s.support_id = support_id(s)
    return s
end

"""
    add_axis_support!(ds, name; coordinates, units)

A one-dimensional axis: nodes along one coordinate, no cells.  Its
coordinate is part of its identity, so it must not vary (E35).
"""
function add_axis_support!(ds::Dataset, name::AbstractString;
                           coordinates, units::AbstractString)
    c = ndims(coordinates) == 1 ? reshape(collect(coordinates),
                                          length(coordinates), 1) :
        collect(coordinates)
    s = Support(name, "axis"; n_nodes = size(c, 1), n_cells = 0)
    s.coordinates = make_array_slot(ds, s, "coordinates", c, :node;
                                    role = :coordinates, units = units,
                                    dims = [:node, :component],
                                    varies = "none")
    push!(ds.supports, s)
    push!(ds.container_groups, "supports")
    s.support_id = support_id(s)
    return s
end

"""
    add_none_support!(ds, name)

A support of kind none: no nodes, no cells and no coordinates.  It
exists so that a slot may say it lives on no support.
"""
function add_none_support!(ds::Dataset, name::AbstractString)
    s = Support(name, "none"; n_nodes = 0, n_cells = 0)
    push!(ds.supports, s)
    push!(ds.container_groups, "supports")
    s.support_id = support_id(s)
    return s
end

function make_array_slot(ds::Dataset, sup::Support, name::AbstractString,
                         data, location::Symbol; role::Symbol = :field,
                         units = nothing, dims = nothing, varies = nothing,
                         components = nothing, statistic = nothing,
                         of = nothing, quantile = nothing, category = nothing,
                         recomputed = nothing, derived_from = nothing,
                         recipe = nothing, reference = nothing,
                         eltype = nothing, deflate = nothing,
                         shuffle = false)
    role in ARRAY_ROLES || throw(MestraError("E02",
        "`$(role)` is not an array role of section 3"))
    dims === nothing && (dims = default_dims(data))
    dims = Symbol[Symbol(d) for d in dims]
    want = Symbol[]
    lead = first(dims)
    if lead === :row
        push!(want, :row)
        varies === nothing && (varies = "row")
    elseif lead === :instance || startswith(String(lead), "group:")
        push!(want, lead)
        if varies === nothing
            startswith(String(lead), "group:") || throw(MestraError(nothing,
                "name the group key, as `varies = \"group:member\"` or " *
                "`dims = (Symbol(\"group:member\"), :node, :component)`"))
            varies = String(lead)
        end
        dims[1] = Symbol(varies)
        want[1] = Symbol(varies)
    else
        varies === nothing && (varies = "none")
    end
    statistic == "draw" && push!(want, :draw)
    push!(want, location === :cell ? :cell : :node)
    push!(want, :component)
    stored = to_stored(data, dims, want)
    T = eltype === nothing ? Base.eltype(stored) : eltype
    T === Float64 || T === Int32 || T === Int64 ||
        throw(MestraError("E20", "an array may not be stored as $(T)"))
    dshape = collect(reverse(size(stored)))
    path = "/supports/$(sup.name)/" *
           (name == "coordinates" ? "coordinates" :
            (location === :cell ? "cell_arrays/" : "node_arrays/") *
            String(name))
    return Slot(name, location; support = sup.name, role = role,
                varies = varies, units = units,
                components = components === nothing ? dshape[end] : components,
                statistic = statistic, of = of, quantile = quantile,
                category = category, recomputed = recomputed,
                derived_from = derived_from, recipe = recipe,
                reference = reference,
                ldims = [logical_dim(disk_dim(w, dshape[i]))
                         for (i, w) in pairs(want)],
                dshape = dshape, eltype = T, deflate = deflate,
                shuffle = shuffle,
                data = convert(Array{T}, stored), path = path)
end

"""
    add_node_array!(ds, support, name, data; role = :field, units, dims)

A field-like quantity on the nodes of a support.  `dims` names the
axes of `data`; it defaults to (:row, :node) for a matrix and
(:row, :node, :component) for a three-axis array, and a missing
component axis is added with length one, because the component
dimension is always present (section 19).
"""
function add_node_array!(ds::Dataset, sup::Support, name::AbstractString,
                         data; kwargs...)
    s = make_array_slot(ds, sup, name, data, :node; kwargs...)
    sup.node_arrays[String(name)] = s
    return s
end

"""
    add_cell_array!(ds, support, name, data; role = :field, units, dims)

The same, on the cells.  `dims` names the cell axis `:cell`, or
`:node`, which reads the same way for both.
"""
function add_cell_array!(ds::Dataset, sup::Support, name::AbstractString,
                         data; kwargs...)
    s = make_array_slot(ds, sup, name, data, :cell; kwargs...)
    sup.cell_arrays[String(name)] = s
    return s
end

"""
    add_callable!(ds, id, c::Callable; repr = string(c))

Store a callable under `/callables/<id>` and make it available to
slots.  Fill a slot from it with `set_callable!`.
"""
function add_callable!(ds::Dataset, id::AbstractString, c::Callable;
                       type::Union{Nothing,AbstractString} = nothing,
                       repr::Union{Nothing,AbstractString} = nothing)
    ty = type === nothing ? registered_name(typeof(c)) : String(type)
    ty === nothing && throw(MestraError("E15",
        "no `type` string is registered for $(typeof(c))"))
    ref = CallableRef(id, ty;
                      repr = repr === nothing ? sprint(show, c) : repr,
                      dict = to_dict(c))
    ds.callables[String(id)] = ref
    push!(ds.container_groups, "callables")
    return ref
end

function registered_name(T::Type)
    for (name, registered) in CALLABLE_REGISTRY
        registered === T && return name
    end
    return nothing
end

"""
    set_callable!(slot, id, output)

Make a slot say that a callable fills it: the slot keeps its
attributes and holds no data (section 10).
"""
function set_callable!(s::Slot, id::AbstractString, output::AbstractString)
    s.source = "callable:" * String(id)
    s.output = String(output)
    s.data = nothing
    return s
end

"""
    add_callable_slot!(ds, support, name; location, role, units,
                       components, id, output, varies = "row")

A slot with no data at all, served by a callable.  This is how a model
file declares what it produces before anything is evaluated.
"""
function add_callable_slot!(ds::Dataset, sup::Support, name::AbstractString;
                            location::Symbol = :node, role::Symbol = :field,
                            units::AbstractString, components::Integer,
                            id::AbstractString, output::AbstractString,
                            varies::AbstractString = "row")
    s = Slot(name, location; support = sup.name, role = role, varies = varies,
             units = units, components = components,
             source = "callable:" * String(id), output = String(output),
             path = "/supports/$(sup.name)/" *
                    (location === :cell ? "cell_arrays/" : "node_arrays/") *
                    String(name))
    (location === :cell ? sup.cell_arrays : sup.node_arrays)[String(name)] = s
    return s
end

"""
    add_callable_scalar!(ds, name; units, id, output)

A scalar slot served by a callable.
"""
function add_callable_scalar!(ds::Dataset, name::AbstractString;
                              units::AbstractString, id::AbstractString,
                              output::AbstractString)
    s = Slot(name, :scalar; units = units,
             source = "callable:" * String(id), output = String(output),
             path = "/scalars/" * String(name))
    ds.scalars[String(name)] = s
    push!(ds.container_groups, "scalars")
    return s
end

"""
    set_row_support!(ds, indices)

Which support each row sits on, as zero-based positions in the file's
support order (section 22).  A file with more than one support needs
one; a file with at most one must not have one.
"""
function set_row_support!(ds::Dataset, indices)
    ds.row_support = Int32.(collect(indices))
    return ds
end

# ------------------------------------------------- notes and private

"""An attribute built for writing, in the encoding of section 18."""
function raw_attr(name::AbstractString, value)
    legal_name(name) || throw(MestraError("E33",
        "attribute name `$(name)` is not a legal netCDF-4 name"))
    reserved(name) && throw(MestraError("E33",
        "attribute name `$(name)` begins with the reserved prefix"))
    if value isa Bool
        ti = TypeInfo(:int, 1, true, true, false, 0, 0)
        return RawAttr(String(name), ti, UInt8[value ? 0x01 : 0x00], 1,
                       true, true, value)
    elseif value isa Integer
        ti = TypeInfo(:int, 8, true, true, false, 0, 0)
        return RawAttr(String(name), ti,
                       collect(reinterpret(UInt8, [Int64(value)])), 1,
                       true, true, Int64(value))
    elseif value isa Real
        ti = TypeInfo(:float, 8, true, true, false, 0, 0)
        return RawAttr(String(name), ti,
                       collect(reinterpret(UInt8, [Float64(value)])), 1,
                       true, true, Float64(value))
    elseif value isa AbstractString
        bytes = Vector{UInt8}(codeunits(String(value)))
        isempty(bytes) && (bytes = UInt8[0x00])
        ti = TypeInfo(:string, length(bytes), false, true, false,
                      Int(HDF5.API.H5T_CSET_UTF8),
                      Int(HDF5.API.H5T_STR_NULLPAD))
        return RawAttr(String(name), ti, bytes, 1, true, true,
                       String(value))
    end
    throw(MestraError(nothing,
        "an attribute of a type this format has no encoding for: " *
        "$(typeof(value))"))
end

function attr_group(name::AbstractString, d::AbstractDict)
    attrs = RawAttr[raw_attr(k, d[k])
                    for k in sort(collect(keys(d)), by = codeunits)]
    return RawGroupCopy(String(name), attrs, RawDatasetCopy[],
                        RawGroupCopy[])
end

"""
    set_notes!(ds, attributes)

Free-form attributes under `/notes`: a solver name, a dataset licence,
a comment.  Nothing in the format depends on them and no tool may
require them (section 11).  Pass an empty dictionary to drop the
group.
"""
function set_notes!(ds::Dataset, attributes::AbstractDict)
    ds.notes = attr_group("notes", attributes)
    return ds
end

"""
    set_private!(ds, attributes)

A producer's own records under `/private`.  A reader treats it as
opaque and must not interpret it, and a writer must not put any public
information only there (E18), so this is for lineage, validation and
history and for nothing the format already carries.
"""
function set_private!(ds::Dataset, attributes::AbstractDict)
    ds.private = attr_group("private", attributes)
    return ds
end
