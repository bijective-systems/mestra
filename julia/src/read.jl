# The reader.
#
# Section 29: opening a file reads no array.  Everything below the
# attribute and dataspace level is read only when it is asked for,
# and a slot can be read for a range of rows on its own.
#
# A file is untrusted input.  The reader opens a child only through a
# hard link, checks what kind of object it got before using it, checks
# every declared shape before sizing anything from it, and records what
# it would not follow (E40) or could not read (E41) in `ds.findings`
# rather than failing the whole open.

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
    cdims, _ = try
        disk_shape(d)
    catch
        return Union{String,Nothing}[]
    end
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
function read(path::AbstractString; lazy::Bool = true,
              max_elements::Integer = DEFAULT_MAX_ELEMENTS)
    isfile(String(path)) || throw(MestraError("E01",
        "no file at $(path)"))
    f = try
        HDF5.h5open(String(path), "r")
    catch e
        throw(MestraError("E01",
            "$(path) is not a file this reader can open as HDF5: " *
            first(sprint(showerror, e), 200)))
    end
    try
        return read_dataset(f, String(path), lazy, Int(max_elements))
    finally
        close(f)
    end
end

note!(ds::Dataset, rule, path, msg) =
    push!(ds.findings, Finding(rule, String(path), String(msg)))

"""Report every child of `g` this reader will not follow (E40), and
return the names it will."""
function hard_children!(ds::Dataset, g, path::AbstractString)
    out = String[]
    for (name, kind) in child_links(g)
        if kind === :hard
            push!(out, name)
        else
            note!(ds, "E40", "$(path)/$(name)",
                  "a $(kind) link; this reader follows hard links only")
        end
    end
    return out
end

function read_dataset(f::HDF5.File, path::String, lazy::Bool,
                      max_elements::Int = DEFAULT_MAX_ELEMENTS)
    idx = ScaleIndex(collect_scales(f))
    root = own_attrs(f)
    ds = Dataset(writer = something(sattr(root, "writer"), ""),
                 created = something(sattr(root, "created"), ""))
    ds.format = something(sattr(root, "format"), "")
    ds.aligned = something(battr(root, "aligned"), true)
    ds.generalisation_group = sattr(root, "generalisation_group")
    ds.path = path
    ds.lazy = lazy
    ds.max_elements = max_elements
    for (name, a) in root
        name in ROOT_ATTRS || push!(ds.extra_root_attrs, a)
    end
    sort!(ds.extra_root_attrs, by = a -> a.name)

    rowscale = hard_child(f, "row")
    ds.nrows = rowscale isa HDF5.Dataset && !isempty(disk_shape(rowscale)[1]) ?
               disk_shape(rowscale)[1][1] : 0

    rootnames = hard_children!(ds, f, "")
    for g in ROOT_GROUPS
        g in rootnames && hard_child(f, g) isa HDF5.Group &&
            push!(ds.container_groups, g)
    end

    cats = "categories" in rootnames ? hard_child(f, "categories") : nothing
    if cats isa HDF5.Group
        for name in hard_children!(ds, cats, "/categories")
            d = hard_child(cats, name)
            if !(d isa HDF5.Dataset)
                note!(ds, "E41", "/categories/$(name)",
                      "a category table that is not a dataset")
                continue
            end
            try
                ti, recs = read_string_records(d;
                                               max_elements = max_elements)
                ds.categories[name] = CategoryTable(
                    name, [String(strip_nul(r)) for r in recs], ti.size)
            catch e
                note!(ds, rule_of(e), "/categories/$(name)", message_of(e))
            end
        end
    end

    kg = "keys" in rootnames ? hard_child(f, "keys") : nothing
    if kg isa HDF5.Group
        for name in hard_children!(ds, kg, "/keys")
            obj = hard_child(kg, name)
            if !(obj isa HDF5.Dataset)
                note!(ds, "E41", "/keys/$(name)",
                      "a key that is not a dataset; section 19 says a key " *
                      "is a dataset over `row`")
                continue
            end
            try
                ds.keys[name] = read_key(ds, obj, name, idx, lazy)
            catch e
                note!(ds, rule_of(e), "/keys/$(name)", message_of(e))
            end
        end
    end

    sg = "scalars" in rootnames ? hard_child(f, "scalars") : nothing
    if sg isa HDF5.Group
        for name in hard_children!(ds, sg, "/scalars")
            obj = hard_child(sg, name)
            obj === nothing && continue
            try
                ds.scalars[name] = read_slot(ds, obj, name, :scalar,
                                             nothing, idx, lazy)
            catch e
                note!(ds, rule_of(e), "/scalars/$(name)", message_of(e))
            end
        end
    end

    rs = "row_support" in rootnames ? hard_child(f, "row_support") : nothing
    if rs isa HDF5.Dataset
        try
            ds.row_support = Int32.(vec(safe_read(rs;
                                                  max_elements = max_elements)))
        catch e
            note!(ds, rule_of(e), "/row_support", message_of(e))
        end
    end

    sup = "supports" in rootnames ? hard_child(f, "supports") : nothing
    if sup isa HDF5.Group
        for name in hard_children!(ds, sup, "/supports")
            obj = hard_child(sup, name)
            if !(obj isa HDF5.Group)
                note!(ds, "E41", "/supports/$(name)",
                      "a support that is not a group")
                continue
            end
            try
                push!(ds.supports, read_support(ds, obj, name, idx, lazy))
            catch e
                note!(ds, rule_of(e), "/supports/$(name)", message_of(e))
            end
        end
    end

    cg = "callables" in rootnames ? hard_child(f, "callables") : nothing
    if cg isa HDF5.Group
        for id in hard_children!(ds, cg, "/callables")
            g = hard_child(cg, id)
            if !(g isa HDF5.Group)
                note!(ds, "E41", "/callables/$(id)",
                      "a callable that is not a group")
                continue
            end
            a = own_attrs(g)
            dict = try
                read_dict(ds, g, "/callables/$(id)"; toplevel = true,
                          max_elements = max_elements)
            catch e
                note!(ds, rule_of(e), "/callables/$(id)", message_of(e))
                Dict{String,Any}()
            end
            ds.callables[id] = CallableRef(id, sattr(a, "type");
                                           repr = sattr(a, "repr"),
                                           dict = dict)
        end
    end

    for (name, field) in (("notes", :notes), ("private", :private))
        name in rootnames || continue
        g = hard_child(f, name)
        g isa HDF5.Group || continue
        try
            setfield!(ds, field, snapshot_group(ds, g, name, "/" * name, 0))
        catch e
            note!(ds, rule_of(e), "/" * name, message_of(e))
        end
    end
    for name in rootnames
        name in ROOT_GROUPS && continue
        obj = hard_child(f, name)
        obj isa HDF5.Group || continue
        try
            push!(ds.extra_root_groups,
                  snapshot_group(ds, obj, name, "/" * name, 0))
        catch e
            note!(ds, rule_of(e), "/" * name, message_of(e))
        end
    end
    return ds
end

rule_of(e) = e isa MestraError && e.rule !== nothing ? e.rule : "E41"
message_of(e) = e isa MestraError ? e.msg :
                first(sprint(showerror, e), 200)

function read_key(ds::Dataset, d, name::String, idx::ScaleIndex,
                  lazy::Bool)
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
    if !lazy
        try
            k.values = read_column(d; max_elements = ds.max_elements)
        catch e
            note!(ds, rule_of(e), k.path, message_of(e))
        end
    end
    return k
end

function read_column(d::HDF5.Dataset;
                     max_elements::Integer = DEFAULT_MAX_ELEMENTS)
    return vec(safe_read(d; max_elements = max_elements))
end

function read_slot(ds::Dataset, obj, name::String, location::Symbol,
                   support::Union{Nothing,String}, idx::ScaleIndex,
                   lazy::Bool)
    a = own_attrs(obj)
    path = try
        HDF5.name(obj)
    catch
        "?"
    end
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
        if !lazy
            try
                s.data = safe_read(obj; max_elements = ds.max_elements)
            catch e
                note!(ds, rule_of(e), path, message_of(e))
            end
        end
    end
    return s
end

function read_support(ds::Dataset, g, name::String, idx::ScaleIndex,
                      lazy::Bool)
    a = own_attrs(g)
    s = Support(name, something(sattr(a, "kind"), "");
                n_nodes = something(iattr(a, "n_nodes"), 0),
                n_cells = something(iattr(a, "n_cells"), 0),
                support_id = something(sattr(a, "support_id"), ""))
    base = "/supports/" * name
    children = hard_children!(ds, g, base)
    for (cname, T, setter) in (("cell_types", UInt8,
                                (v) -> (s.cell_types = v)),
                               ("cell_offsets", Int64,
                                (v) -> (s.cell_offsets = v)),
                               ("cell_connectivity", Int64,
                                (v) -> (s.cell_connectivity = v)))
        cname in children || continue
        d = hard_child(g, cname)
        if !(d isa HDF5.Dataset)
            note!(ds, "E41", "$(base)/$(cname)", "not a dataset")
            continue
        end
        try
            setter(T.(vec(safe_read(d; max_elements = ds.max_elements))))
        catch e
            note!(ds, rule_of(e), "$(base)/$(cname)", message_of(e))
        end
    end
    if "coordinates" in children
        c = hard_child(g, "coordinates")
        if c === nothing
            note!(ds, "E41", "$(base)/coordinates", "could not be opened")
        else
            s.coordinates = read_slot(ds, c, "coordinates", :node, name,
                                      idx, lazy)
            # An axis support's identity includes its coordinates, so
            # they are read even when the rest is lazy (section 24).
            if s.kind == "axis" && s.coordinates.data === nothing &&
               c isa HDF5.Dataset
                try
                    s.coordinates.data =
                        safe_read(c; max_elements = ds.max_elements)
                catch e
                    note!(ds, rule_of(e), "$(base)/coordinates",
                          message_of(e))
                end
            end
        end
    end
    for (sub, loc, store) in (("node_arrays", :node, s.node_arrays),
                              ("cell_arrays", :cell, s.cell_arrays))
        sub in children || continue
        sg = hard_child(g, sub)
        sg isa HDF5.Group || continue
        for n in hard_children!(ds, sg, "$(base)/$(sub)")
            obj = hard_child(sg, n)
            obj === nothing && continue
            try
                store[n] = read_slot(ds, obj, n, loc, name, idx, lazy)
            catch e
                note!(ds, rule_of(e), "$(base)/$(sub)/$(n)", message_of(e))
            end
        end
    end
    return s
end

# An object this reader does not own is copied, never interpreted.
# The depth is capped because the file chooses it.
function snapshot_group(ds::Dataset, g::HDF5.Group, name::String,
                        path::String, depth::Int)
    attrs = RawAttr[a for a in raw_attrs(g)
                    if !(a.name in MACHINERY_ATTRS) && a.readable]
    dsets = RawDatasetCopy[]
    groups = RawGroupCopy[]
    if depth >= MAX_DEPTH
        note!(ds, "E41", path,
              "groups nested deeper than $(MAX_DEPTH); this reader " *
              "stops here rather than following a file's own depth")
        return RawGroupCopy(name, attrs, dsets, groups)
    end
    for n in hard_children!(ds, g, path)
        obj = hard_child(g, n)
        obj === nothing && continue
        if obj isa HDF5.Group
            push!(groups, snapshot_group(ds, obj, n, "$(path)/$(n)",
                                         depth + 1))
        else
            try
                ti, raw, _ = read_raw_dataset(obj;
                                              max_elements = ds.max_elements)
                cdims, cmax = disk_shape(obj)
                _, chunk, _ = dataset_layout(obj)
                push!(dsets, RawDatasetCopy(n, ti, cdims, cmax, chunk, raw,
                    RawAttr[a for a in raw_attrs(obj)
                            if !(a.name in MACHINERY_ATTRS) && a.readable]))
            catch e
                note!(ds, rule_of(e), "$(path)/$(n)", message_of(e))
            end
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
function values(ds::Dataset, s::Slot;
                max_elements::Integer = ds.max_elements)
    s.data === nothing || return DimArray(s.data, julia_dims(s))
    is_callable_slot(s) && throw(MestraError(nothing,
        "slot $(s.name) is served by callable $(callable_id(s)) and " *
        "holds no data; evaluate the dataset first"))
    ds.path === nothing && throw(MestraError(nothing,
        "slot $(s.name) holds no data and this dataset has no file"))
    a = HDF5.h5open(ds.path, "r") do f
        d = open_path(f, s.path)
        safe_read(d; max_elements = max_elements)
    end
    return DimArray(a, julia_dims(s))
end

"""Open an object by its path, following hard links only.  A path with
a soft or external link in it is refused (E40) rather than followed."""
function open_path(f::HDF5.File, path::AbstractString)
    here = f
    for part in split(String(path), '/'; keepempty = false)
        kind = link_type(here, part)
        kind === :hard || throw(MestraError(kind === :missing ? "E41" : "E40",
            "$(path): `$(part)` is a $(kind) link"))
        here = try
            here[String(part)]
        catch e
            throw(MestraError("E41", "$(path): " *
                              first(sprint(showerror, e), 200)))
        end
    end
    return here
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
function values(ds::Dataset, k::KeyColumn;
                max_elements::Integer = ds.max_elements)
    k.values === nothing || return k.values
    ds.path === nothing && throw(MestraError(nothing,
        "key $(k.name) holds no data and this dataset has no file"))
    return HDF5.h5open(ds.path, "r") do f
        read_column(open_path(f, k.path); max_elements = max_elements)
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
function rows(ds::Dataset, s::Slot, range::AbstractUnitRange;
              max_elements::Integer = ds.max_elements)
    is_callable_slot(s) && throw(MestraError(nothing,
        "slot $(s.name) is served by a callable and holds no data"))
    jdims = julia_dims(s)
    axis = findfirst(==(:row), jdims)
    axis === nothing && throw(MestraError(nothing,
        "slot $(s.name) has no row dimension"))
    jsize = julia_size(s)
    isempty(range) || (first(range) >= 1 && last(range) <= jsize[axis]) ||
        throw(MestraError(nothing,
            "rows $(range) outside the $(jsize[axis]) this slot holds"))
    # Size the answer from the range and the shape, both checked, and
    # never from what the file claims the whole slot holds.
    want = element_count([i == axis ? length(range) : jsize[i]
                          for i in 1:length(jsize)])
    want > max_elements && throw(MestraError("E41",
        "that range is $(want) elements, more than the $(max_elements) " *
        "this reader will materialise"))
    if s.data !== nothing
        sel = ntuple(i -> i == axis ? range : Colon(), length(jdims))
        return DimArray(s.data[sel...], jdims)
    end
    ds.path === nothing && throw(MestraError(nothing,
        "slot $(s.name) holds no data and this dataset has no file"))
    a = HDF5.h5open(ds.path, "r") do f
        d = open_path(f, s.path)
        d isa HDF5.Dataset || throw(MestraError("E41",
            "$(s.path) is not a dataset"))
        # The library reads whole chunks, so a chunk this reader
        # would not materialise costs the same for one row.
        check_chunk(d; max_elements = max_elements)
        sel = ntuple(i -> i == axis ? range : Colon(), length(jdims))
        try
            d[sel...]
        catch e
            throw(MestraError("E41", "$(s.path): " *
                              first(sprint(showerror, e), 200)))
        end
    end
    return DimArray(a, jdims)
end

"""
    rows(ds, name::AbstractString, range) -> DimArray

The slot called `name`, for a range of rows.
"""
rows(ds::Dataset, name::AbstractString, range::AbstractUnitRange;
     kwargs...) = rows(ds, ds[name], range; kwargs...)

"""
    materialise!(ds) -> Dataset

Read every stored array into memory.  A dataset read with
`lazy = false` is already materialised.
"""
function materialise!(ds::Dataset)
    ds.path === nothing && return ds
    HDF5.h5open(ds.path, "r") do f
        for (_, k) in ds.keys
            k.values === nothing || continue
            try
                k.values = read_column(open_path(f, k.path);
                                       max_elements = ds.max_elements)
            catch e
                note!(ds, rule_of(e), k.path, message_of(e))
            end
        end
        for s in all_slots(ds)
            is_callable_slot(s) && continue
            s.data === nothing || continue
            try
                d = open_path(f, s.path)
                d isa HDF5.Dataset || continue
                s.data = safe_read(d; max_elements = ds.max_elements)
            catch e
                note!(ds, rule_of(e), s.path, message_of(e))
            end
        end
    end
    ds.lazy = false
    return ds
end
