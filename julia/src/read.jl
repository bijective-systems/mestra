# The reader.
#
# Section 29: opening a file reads no array.  Everything below the
# attribute and dataspace level is read only when it is asked for,
# and a slot can be read for a range of rows on its own.

const ROOT_ATTRS = Set(["format", "writer", "created", "aligned",
                        "generalisation_group"])
const ROOT_GROUPS = Set(["keys", "scalars", "categories", "supports",
                         "callables", "notes", "private"])

struct ScaleIndex
    all::Vector{Pair{String,HDF5.Dataset}}
end

"""The link name of the scale on each C-order axis of `d`, or nothing
where no single scale is attached."""
function axis_scale_names(d::HDF5.Dataset, idx::ScaleIndex)
    cdims, _ = disk_shape(d)
    out = Union{String,Nothing}[]
    for axis in 0:(length(cdims) - 1)
        n = num_scales(d, axis)
        push!(out, n == 1 ? attached_scale_name(d, axis, idx.all) : nothing)
    end
    return out
end

function slot_ldims(d::HDF5.Dataset, idx::ScaleIndex)
    return Symbol[n === nothing ? :unknown : logical_dim(n)
                  for n in axis_scale_names(d, idx)]
end

sattr(a::Dict{String,RawAttr}, name) =
    haskey(a, name) && a[name].value isa AbstractString ?
    String(a[name].value) : nothing
fattr(a::Dict{String,RawAttr}, name) =
    haskey(a, name) && a[name].value isa Real && !(a[name].value isa Bool) ?
    Float64(a[name].value) : nothing
iattr(a::Dict{String,RawAttr}, name) =
    haskey(a, name) && a[name].value isa Real && !(a[name].value isa Bool) ?
    Int(a[name].value) : nothing
battr(a::Dict{String,RawAttr}, name) =
    haskey(a, name) ? (a[name].value === true) : nothing

"""
    Mestra.read(path; lazy = true) -> Dataset

Open a `.mes` file.  With `lazy = true`, which is the default, this
reads attributes and dataspaces only, so it reports the row count, the
keys with their roles and bounds, the supports with their ids and
every slot with its attributes without touching an array.  Ask for an
array with `Mestra.values(ds, slot)`, or for a range of rows with
`Mestra.rows(ds, slot, 1:10)`.

With `lazy = false` every stored array is read at once.
"""
function read(path::AbstractString; lazy::Bool = true)
    HDF5.h5open(String(path), "r") do f
        read_dataset(f, String(path), lazy)
    end
end

function read_dataset(f::HDF5.File, path::String, lazy::Bool)
    idx = ScaleIndex(collect_scales(f))
    root = own_attrs(f)
    ds = Dataset(writer = something(sattr(root, "writer"), ""),
                 created = something(sattr(root, "created"), ""))
    ds.format = something(sattr(root, "format"), "")
    ds.aligned = something(battr(root, "aligned"), true)
    ds.generalisation_group = sattr(root, "generalisation_group")
    ds.path = path
    ds.lazy = lazy
    for (name, a) in root
        name in ROOT_ATTRS || push!(ds.extra_root_attrs, a)
    end
    sort!(ds.extra_root_attrs, by = a -> a.name)

    ds.nrows = haskey(f, "row") && f["row"] isa HDF5.Dataset ?
               disk_shape(f["row"])[1][1] : 0
    for g in ROOT_GROUPS
        haskey(f, g) && f[g] isa HDF5.Group && push!(ds.container_groups, g)
    end

    if haskey(f, "categories")
        for name in keys(f["categories"])
            d = f["categories"][name]
            ti, recs = read_string_records(d)
            ds.categories[name] = CategoryTable(
                name, [String(strip_nul(r)) for r in recs], ti.size)
        end
    end

    if haskey(f, "keys")
        for name in keys(f["keys"])
            ds.keys[name] = read_key(f["keys"][name], name, idx, lazy)
        end
    end

    if haskey(f, "scalars")
        for name in keys(f["scalars"])
            ds.scalars[name] = read_slot(f["scalars"][name], name, :scalar,
                                         nothing, idx, lazy)
        end
    end

    if haskey(f, "row_support")
        ds.row_support = Int32.(vec(HDF5.read(f["row_support"])))
    end

    if haskey(f, "supports")
        for name in keys(f["supports"])
            push!(ds.supports, read_support(f["supports"][name], name, idx,
                                            lazy))
        end
    end

    if haskey(f, "callables")
        for id in keys(f["callables"])
            g = f["callables"][id]
            a = own_attrs(g)
            ds.callables[id] = CallableRef(id, sattr(a, "type");
                                           repr = sattr(a, "repr"),
                                           dict = read_dict(g, toplevel = true))
        end
    end

    haskey(f, "notes") && (ds.notes = snapshot_group(f["notes"], "notes"))
    haskey(f, "private") &&
        (ds.private = snapshot_group(f["private"], "private"))
    for name in keys(f)
        obj = f[name]
        obj isa HDF5.Group || continue
        name in ROOT_GROUPS && continue
        push!(ds.extra_root_groups, snapshot_group(obj, name))
    end
    return ds
end

function read_key(d, name::String, idx::ScaleIndex, lazy::Bool)
    a = own_attrs(d)
    role = sattr(a, "role")
    ti = type_info(HDF5.datatype(d))
    T = ti.class === :string ? String : julia_eltype(ti)
    _, chunk, _ = dataset_layout(d)
    k = KeyColumn(name, role === nothing ? nothing : Symbol(role);
                  units = sattr(a, "units"), lower = fattr(a, "lower"),
                  upper = fattr(a, "upper"), category = sattr(a, "category"),
                  trajectory_group = sattr(a, "trajectory_group"),
                  parent = sattr(a, "parent"), eltype = T,
                  strsize = ti.class === :string ? ti.size : 1,
                  chunk = chunk, path = "/keys/" * name)
    lazy || (k.values = read_column(d))
    return k
end

function read_column(d::HDF5.Dataset)
    ti = type_info(HDF5.datatype(d))
    ti.class === :string && return read_strings(d)
    return vec(HDF5.read(d))
end

function read_slot(obj, name::String, location::Symbol,
                   support::Union{Nothing,String}, idx::ScaleIndex,
                   lazy::Bool)
    a = own_attrs(obj)
    path = HDF5.name(obj)
    role = sattr(a, "role")
    s = Slot(name, location; support = support,
             source = something(sattr(a, "source"), ""),
             output = sattr(a, "output"),
             role = role === nothing ? nothing : Symbol(role),
             varies = sattr(a, "varies"), units = sattr(a, "units"),
             components = iattr(a, "components"),
             statistic = sattr(a, "statistic"), of = sattr(a, "of"),
             quantile = fattr(a, "quantile"), category = sattr(a, "category"),
             recomputed = haskey(a, "recomputed") ? battr(a, "recomputed") :
                          nothing,
             derived_from = sattr(a, "derived_from"),
             recipe = sattr(a, "recipe"), reference = sattr(a, "reference"),
             path = path)
    if obj isa HDF5.Dataset
        cdims, _ = disk_shape(obj)
        _, chunk, filters = dataset_layout(obj)
        s.dshape = cdims
        s.ldims = slot_ldims(obj, idx)
        ti = type_info(HDF5.datatype(obj))
        s.eltype = ti.class === :string ? String : uint8_eltype(ti)
        s.chunk = chunk
        for (fid, cd) in filters
            fid == 1 && (s.deflate = isempty(cd) ? 1 : cd[1])
            fid == 2 && (s.shuffle = true)
        end
        lazy || (s.data = HDF5.read(obj))
    end
    return s
end

function read_support(g, name::String, idx::ScaleIndex, lazy::Bool)
    a = own_attrs(g)
    s = Support(name, something(sattr(a, "kind"), "");
                n_nodes = something(iattr(a, "n_nodes"), 0),
                n_cells = something(iattr(a, "n_cells"), 0),
                support_id = something(sattr(a, "support_id"), ""))
    haskey(g, "cell_types") &&
        (s.cell_types = UInt8.(vec(HDF5.read(g["cell_types"]))))
    haskey(g, "cell_offsets") &&
        (s.cell_offsets = Int64.(vec(HDF5.read(g["cell_offsets"]))))
    haskey(g, "cell_connectivity") &&
        (s.cell_connectivity = Int64.(vec(HDF5.read(g["cell_connectivity"]))))
    if haskey(g, "coordinates")
        s.coordinates = read_slot(g["coordinates"], "coordinates", :node,
                                  name, idx, lazy)
        # An axis support's identity includes its coordinates, so they
        # are read even when the rest is lazy (section 24).
        if s.kind == "axis" && s.coordinates.data === nothing &&
           g["coordinates"] isa HDF5.Dataset
            s.coordinates.data = HDF5.read(g["coordinates"])
        end
    end
    if haskey(g, "node_arrays")
        for n in keys(g["node_arrays"])
            s.node_arrays[n] = read_slot(g["node_arrays"][n], n, :node,
                                         name, idx, lazy)
        end
    end
    if haskey(g, "cell_arrays")
        for n in keys(g["cell_arrays"])
            s.cell_arrays[n] = read_slot(g["cell_arrays"][n], n, :cell,
                                         name, idx, lazy)
        end
    end
    return s
end

# An object this reader does not own is copied, never interpreted.
function snapshot_group(g::HDF5.Group, name::String)
    attrs = RawAttr[a for a in raw_attrs(g) if !(a.name in MACHINERY_ATTRS)]
    dsets = RawDatasetCopy[]
    groups = RawGroupCopy[]
    for n in keys(g)
        obj = g[n]
        if obj isa HDF5.Group
            push!(groups, snapshot_group(obj, n))
        else
            ti, raw, _ = read_raw_dataset(obj)
            cdims, cmax = disk_shape(obj)
            _, chunk, _ = dataset_layout(obj)
            push!(dsets, RawDatasetCopy(n, ti, cdims, cmax, chunk, raw,
                RawAttr[a for a in raw_attrs(obj)
                        if !(a.name in MACHINERY_ATTRS)]))
        end
    end
    return RawGroupCopy(name, attrs, dsets, groups)
end

# ------------------------------------------------------ reading values

"""
    values(ds, slot) -> DimArray

The whole of one slot, with the name of each axis in the Julia order.
Julia is column major and this format is stored in C order, so the
axes arrive reversed: a field the file holds as (row, node, component)
comes back as (component, node, row).  Ask for the order you want with
`permute(v, (:row, :node, :component))`, never by axis position.
"""
function values(ds::Dataset, s::Slot)
    s.data === nothing || return DimArray(s.data, julia_dims(s))
    is_callable_slot(s) && throw(MestraError(nothing,
        "slot $(s.name) is served by callable $(callable_id(s)) and " *
        "holds no data; evaluate the dataset first"))
    ds.path === nothing && throw(MestraError(nothing,
        "slot $(s.name) holds no data and this dataset has no file"))
    a = HDF5.h5open(ds.path, "r") do f
        HDF5.read(f[s.path])
    end
    return DimArray(a, julia_dims(s))
end

"""
    values(ds, name::AbstractString) -> DimArray

The slot called `name`, found as `ds[name]` finds it.
"""
values(ds::Dataset, name::AbstractString) = values(ds, ds[name])

"""
    values(ds, key::KeyColumn) -> Vector

One key column.
"""
function values(ds::Dataset, k::KeyColumn)
    k.values === nothing || return k.values
    ds.path === nothing && throw(MestraError(nothing,
        "key $(k.name) holds no data and this dataset has no file"))
    return HDF5.h5open(ds.path, "r") do f
        read_column(f[k.path])
    end
end

"""
    rows(ds, slot, range) -> DimArray

One slot for a range of rows, reading no other slot and no row outside
the range (section 29).  `range` is one based.  For a row-varying
array in an unaligned file the range indexes that support's own rows,
in the file's row order, which section 22 says is not the file's row
number.
"""
function rows(ds::Dataset, s::Slot, range::AbstractUnitRange)
    is_callable_slot(s) && throw(MestraError(nothing,
        "slot $(s.name) is served by a callable and holds no data"))
    jdims = julia_dims(s)
    axis = findfirst(==(:row), jdims)
    axis === nothing && throw(MestraError(nothing,
        "slot $(s.name) has no row dimension"))
    if s.data !== nothing
        sel = ntuple(i -> i == axis ? range : Colon(), length(jdims))
        return DimArray(s.data[sel...], jdims)
    end
    ds.path === nothing && throw(MestraError(nothing,
        "slot $(s.name) holds no data and this dataset has no file"))
    a = HDF5.h5open(ds.path, "r") do f
        d = f[s.path]
        sel = ntuple(i -> i == axis ? range : Colon(), length(jdims))
        d[sel...]
    end
    return DimArray(a, jdims)
end

"""
    rows(ds, name::AbstractString, range) -> DimArray

The slot called `name`, for a range of rows.
"""
rows(ds::Dataset, name::AbstractString, range::AbstractUnitRange) =
    rows(ds, ds[name], range)

"""
    materialise!(ds) -> Dataset

Read every stored array into memory.  A dataset read with
`lazy = false` is already materialised.
"""
function materialise!(ds::Dataset)
    ds.path === nothing && return ds
    HDF5.h5open(ds.path, "r") do f
        for (_, k) in ds.keys
            k.values === nothing && (k.values = read_column(f[k.path]))
        end
        for s in all_slots(ds)
            is_callable_slot(s) && continue
            s.data === nothing && haskey(f, s.path) &&
                (s.data = HDF5.read(f[s.path]))
        end
    end
    ds.lazy = false
    return ds
end
