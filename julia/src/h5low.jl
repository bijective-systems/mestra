# Low-level HDF5 helpers.
#
# Everything this file does is fixed by SPEC.md sections 18 to 23: the
# attribute encodings, the fixed-length UTF-8 strings, the dimension
# scales, the chunk shapes and the filters.  Nothing above this file
# is allowed to reach for the raw API.

const MACHINERY_ATTRS = Set([
    "CLASS", "NAME", "DIMENSION_LIST", "REFERENCE_LIST",
    "DIMENSION_LABELS", "_Netcdf4Dimid", "_Netcdf4Coordinates",
    "_nc3_strict", "_NCProperties",
])

# Section 21: the NAME attribute of a dimension scale with no
# coordinate variable.  53 characters, then the length in ten columns.
const DIM_SENTENCE = "This is a netCDF dimension but not a netCDF variable."

dim_scale_name(length::Integer) = @sprintf("%s%10d", DIM_SENTENCE, length)

# --------------------------------------------------------- datatypes

"""Fixed-length UTF-8, NUL-padded (sections 18 and 19)."""
function fixed_string_type(nbytes::Integer)
    t = HDF5.API.h5t_copy(HDF5.API.H5T_C_S1)
    HDF5.API.h5t_set_size(t, max(1, Int(nbytes)))
    HDF5.API.h5t_set_cset(t, HDF5.API.H5T_CSET_UTF8)
    HDF5.API.h5t_set_strpad(t, HDF5.API.H5T_STR_NULLPAD)
    return HDF5.Datatype(t)
end

le(t) = HDF5.Datatype(HDF5.API.h5t_copy(t))

scalar_space() = HDF5.Dataspace(HDF5.API.h5s_create(HDF5.API.H5S_SCALAR))

"""The number of elements a dataspace holds.  HDF5.jl does not wrap
H5Sget_simple_extent_npoints, so this is the product of the extents,
with a scalar dataspace counting one."""
function space_npoints(sp::HDF5.Dataspace)
    n = HDF5.API.h5s_get_simple_extent_ndims(sp)
    n == 0 && return 1
    dims, _ = HDF5.API.h5s_get_simple_extent_dims(sp)
    return Int(prod(dims))
end

"""What an HDF5 datatype is, as sections 18 and 19 name the kinds."""
struct TypeInfo
    class::Symbol      # :string, :int, :float, :other
    size::Int          # bytes
    signed::Bool
    little::Bool
    vlen::Bool
    cset::Int
    strpad::Int
end

function type_info(t::HDF5.Datatype)
    cls = HDF5.API.h5t_get_class(t)
    size = Int(HDF5.API.h5t_get_size(t))
    if cls == HDF5.API.H5T_STRING
        vlen = HDF5.API.h5t_is_variable_str(t)
        return TypeInfo(:string, size, false, true, vlen,
                        Int(HDF5.API.h5t_get_cset(t)),
                        Int(HDF5.API.h5t_get_strpad(t)))
    elseif cls == HDF5.API.H5T_INTEGER
        sign = HDF5.API.h5t_get_sign(t) == HDF5.API.H5T_SGN_2
        order = HDF5.API.h5t_get_order(t)
        return TypeInfo(:int, size, sign, order == HDF5.API.H5T_ORDER_LE,
                        false, 0, 0)
    elseif cls == HDF5.API.H5T_FLOAT
        order = HDF5.API.h5t_get_order(t)
        return TypeInfo(:float, size, true, order == HDF5.API.H5T_ORDER_LE,
                        false, 0, 0)
    else
        return TypeInfo(:other, size, false, true, false, 0, 0)
    end
end

"""The Julia element type an on-disk numeric type maps to."""
function julia_eltype(ti::TypeInfo)
    ti.class === :int && ti.size == 1 && return Int8
    ti.class === :int && ti.size == 2 && return (ti.signed ? Int16 : UInt16)
    ti.class === :int && ti.size == 4 && return (ti.signed ? Int32 : UInt32)
    ti.class === :int && ti.size == 8 && return (ti.signed ? Int64 : UInt64)
    ti.class === :int && ti.size == 1 && return Int8
    ti.class === :float && ti.size == 4 && return Float32
    ti.class === :float && ti.size == 8 && return Float64
    ti.class === :string && return String
    return Nothing
end

function uint8_eltype(ti::TypeInfo)
    ti.class === :int && ti.size == 1 && !ti.signed && return UInt8
    return julia_eltype(ti)
end

# -------------------------------------------------------- attributes

"""An attribute exactly as it is stored, so that E19 and E26 can be
decided and so that an unknown attribute can be copied unchanged."""
struct RawAttr
    name::String
    ti::TypeInfo
    raw::Vector{UInt8}       # the stored bytes, for a scalar attribute
    npoints::Int
    value::Any               # decoded: Bool, Int64, Float64, String, ...
end

function strip_nul(raw::AbstractVector{UInt8})
    last = length(raw)
    while last > 0 && raw[last] == 0x00
        last -= 1
    end
    return raw[1:last]
end

function decode_raw(ti::TypeInfo, raw::Vector{UInt8}, npoints::Int)
    if ti.class === :string
        if ti.vlen
            return nothing          # never legal; E19 reports it
        end
        if npoints == 1
            return String(strip_nul(raw))
        end
        out = String[]
        for i in 1:npoints
            chunk = raw[((i - 1) * ti.size + 1):(i * ti.size)]
            push!(out, String(strip_nul(chunk)))
        end
        return out
    elseif ti.class === :int
        T = julia_eltype(ti)
        T === Nothing && return nothing
        vals = reinterpret(T, raw)
        if ti.size == 1
            return npoints == 1 ? (vals[1] != 0) : [v != 0 for v in vals]
        end
        return npoints == 1 ? Int64(vals[1]) : Int64.(collect(vals))
    elseif ti.class === :float
        T = julia_eltype(ti)
        T === Nothing && return nothing
        vals = reinterpret(T, raw)
        return npoints == 1 ? Float64(vals[1]) : Float64.(collect(vals))
    end
    return nothing
end

"""Read one attribute exactly as stored."""
function read_raw_attr(obj, name::AbstractString)
    a = HDF5.open_attribute(obj, name)
    try
        t = HDF5.datatype(a)
        ti = type_info(t)
        sp = HDF5.dataspace(a)
        npoints = space_npoints(sp)
        if ti.vlen
            return RawAttr(String(name), ti, UInt8[], npoints, nothing)
        end
        raw = Vector{UInt8}(undef, ti.size * max(npoints, 1))
        HDF5.API.h5a_read(a, t, raw)
        return RawAttr(String(name), ti, raw, npoints,
                       decode_raw(ti, raw, npoints))
    finally
        close(a)
    end
end

function raw_attrs(obj)
    out = RawAttr[]
    for name in keys(HDF5.attributes(obj))
        push!(out, read_raw_attr(obj, name))
    end
    return out
end

"""Every attribute of `obj` that this format owns, by name."""
function own_attrs(obj)
    d = Dict{String,RawAttr}()
    for name in keys(HDF5.attributes(obj))
        name in MACHINERY_ATTRS && continue
        d[name] = read_raw_attr(obj, name)
    end
    return d
end


# writing

function write_string_attr(obj, name::AbstractString, value::AbstractString)
    write_raw_string_attr(obj, name, Vector{UInt8}(codeunits(value)))
end

function write_raw_string_attr(obj, name::AbstractString,
                               bytes::Vector{UInt8})
    n = max(1, length(bytes))
    padded = vcat(bytes, zeros(UInt8, n - length(bytes)))
    dt = fixed_string_type(n)
    sp = scalar_space()
    a = HDF5.create_attribute(obj, String(name), dt, sp)
    try
        HDF5.API.h5a_write(a, dt, padded)
    finally
        close(a)
    end
    return nothing
end

function write_scalar_attr(obj, name::AbstractString, value, dt::HDF5.Datatype)
    sp = scalar_space()
    a = HDF5.create_attribute(obj, String(name), dt, sp)
    try
        HDF5.API.h5a_write(a, dt, [value])
    finally
        close(a)
    end
    return nothing
end

write_bool_attr(obj, name, v::Bool) =
    write_scalar_attr(obj, name, Int8(v ? 1 : 0), le(HDF5.API.H5T_STD_I8LE))
write_int_attr(obj, name, v::Integer) =
    write_scalar_attr(obj, name, Int64(v), le(HDF5.API.H5T_STD_I64LE))
write_float_attr(obj, name, v::Real) =
    write_scalar_attr(obj, name, Float64(v), le(HDF5.API.H5T_IEEE_F64LE))

"""Copy an attribute back out exactly as it came in."""
function write_raw_attr(obj, a::RawAttr)
    if a.ti.class === :string && !a.ti.vlen && a.npoints == 1
        write_raw_string_attr(obj, a.name, a.raw)
    elseif a.ti.class === :int && a.ti.size == 1
        write_bool_attr(obj, a.name, a.value === true)
    elseif a.ti.class === :int
        write_int_attr(obj, a.name, a.value)
    elseif a.ti.class === :float
        write_float_attr(obj, a.name, a.value)
    else
        error("cannot copy attribute $(a.name)")
    end
end

# ---------------------------------------------------------- datasets

"""The on-disk shape of a dataset, in C order, with its maximum."""
function disk_shape(d::HDF5.Dataset)
    sp = HDF5.dataspace(d)
    dims, maxdims = HDF5.API.h5s_get_simple_extent_dims(sp)
    return (Int.(dims), [m == HDF5.API.H5S_UNLIMITED ? -1 : Int(m)
                         for m in maxdims])
end

function dataset_layout(d::HDF5.Dataset)
    dcpl = HDF5.get_create_properties(d)
    layout = HDF5.API.h5p_get_layout(dcpl)
    chunk = nothing
    if layout == HDF5.API.H5D_CHUNKED
        c, _ = HDF5.API.h5p_get_chunk(dcpl)
        chunk = Int.(c)
    end
    nf = HDF5.API.h5p_get_nfilters(dcpl)
    filters = Tuple{Int,Vector{Int}}[]
    for i in 0:(nf - 1)
        flags = Ref{Cuint}()
        nelem = Ref{Csize_t}(16)
        cd = Vector{Cuint}(undef, 16)
        namebuf = Vector{UInt8}(undef, 256)
        fid = HDF5.API.h5p_get_filter(dcpl, i, flags, nelem, cd,
                                      length(namebuf), namebuf, C_NULL)
        push!(filters, (Int(fid), Int.(cd[1:Int(nelem[])])))
    end
    return (layout == HDF5.API.H5D_CHUNKED ? :chunked :
            layout == HDF5.API.H5D_CONTIGUOUS ? :contiguous : :other,
            chunk, filters)
end

"""Raw bytes of a whole dataset, in the file's own datatype."""
function read_raw_dataset(d::HDF5.Dataset)
    t = HDF5.datatype(d)
    ti = type_info(t)
    sp = HDF5.dataspace(d)
    n = space_npoints(sp)
    n == 0 && return ti, UInt8[], 0
    raw = Vector{UInt8}(undef, ti.size * n)
    HDF5.API.h5d_read(d, t, HDF5.API.H5S_ALL, HDF5.API.H5S_ALL,
                      HDF5.API.H5P_DEFAULT, raw)
    return ti, raw, n
end

"""A fixed-length string dataset, as the raw record bytes."""
function read_string_records(d::HDF5.Dataset)
    ti, raw, n = read_raw_dataset(d)
    recs = Vector{Vector{UInt8}}(undef, n)
    for i in 1:n
        recs[i] = raw[((i - 1) * ti.size + 1):(i * ti.size)]
    end
    return ti, recs
end

read_strings(d::HDF5.Dataset) =
    [String(strip_nul(r)) for r in read_string_records(d)[2]]

"""Create a dataset with object times off, as section 30 requires."""
function make_dcpl(; chunk = nothing, deflate = nothing, shuffle = false)
    dcpl = HDF5.DatasetCreateProperties()
    # Section 30: object time tracking off, so that two runs of a
    # writer produce the same bytes.  HDF5.jl initialises the property
    # list on the first set, so this must come before the raw calls.
    dcpl.obj_track_times = false
    if chunk !== nothing
        # The raw API is C order throughout, which is the order every
        # shape in the specification is written in.
        HDF5.API.h5p_set_chunk(dcpl, length(chunk),
                               HDF5.API.hsize_t[chunk...])
    end
    if shuffle
        HDF5.API.h5p_set_shuffle(dcpl)
    end
    if deflate !== nothing
        HDF5.API.h5p_set_deflate(dcpl, deflate)
    end
    return dcpl
end

"""A dataspace from a C-order shape, with unlimited marked by -1."""
function make_space(cdims::Vector{Int}, cmax::Vector{Int})
    jd = HDF5.API.hsize_t[cdims...]
    jm = HDF5.API.hsize_t[m < 0 ? HDF5.API.H5S_UNLIMITED :
                          HDF5.API.hsize_t(m) for m in cmax]
    return HDF5.Dataspace(HDF5.API.h5s_create_simple(length(jd), jd, jm))
end

"""Create a dataset and write raw bytes into it.  `cdims` is the
C-order shape, which is what every shape in the specification is."""
function create_raw_dataset(parent, name::AbstractString,
                            dt::HDF5.Datatype, cdims::Vector{Int},
                            cmax::Vector{Int}, raw::Vector{UInt8};
                            chunk = nothing, deflate = nothing,
                            shuffle = false)
    dcpl = make_dcpl(chunk = chunk === nothing ? nothing : Vector{Int}(chunk),
                     deflate = deflate, shuffle = shuffle)
    sp = make_space(cdims, cmax)
    d = HDF5.create_dataset(parent, String(name), dt, sp; dcpl = dcpl)
    if prod(cdims) > 0 && !isempty(raw)
        HDF5.API.h5d_write(d, dt, HDF5.API.H5S_ALL, HDF5.API.H5S_ALL,
                           HDF5.API.H5P_DEFAULT, raw)
    end
    return d
end

"""A group with object times off."""
function create_group(parent, name::AbstractString)
    gcpl = HDF5.GroupCreateProperties()
    gcpl.obj_track_times = false
    lcpl = HDF5._link_properties(String(name))
    return HDF5.create_group(parent, String(name), lcpl, gcpl)
end

# ---------------------------------------------------- dimension scales

"""Create a dimension scale exactly as netCDF-C writes one (21)."""
function create_scale(parent, name::AbstractString, length_::Integer;
                      unlimited::Bool = false)
    len = Int(length_)
    cdims = [len]
    cmax = [unlimited ? -1 : len]
    chunk = unlimited ? [1] : [max(1, len)]
    d = create_raw_dataset(parent, name, le(HDF5.API.H5T_IEEE_F32BE),
                           cdims, cmax, UInt8[]; chunk = chunk)
    HDF5.API.h5ds_set_scale(d, dim_scale_name(len))
    return d
end

is_scale(d::HDF5.Dataset) = HDF5.API.h5ds_is_scale(d)

"""Attach `scale` to C-order axis `axis` (zero based) of `d`."""
attach_scale!(d::HDF5.Dataset, scale::HDF5.Dataset, axis::Integer) =
    HDF5.API.h5ds_attach_scale(d, scale, axis)

num_scales(d::HDF5.Dataset, axis::Integer) =
    Int(HDF5.API.h5ds_get_num_scales(d, axis))

"""The link name of the one scale attached to C-order axis `axis`.

HDF5.jl wraps H5DSget_num_scales, H5DSis_attached, H5DSis_scale,
H5DSset_scale and H5DSattach_scale, but not H5DSiterate_scales, so the
attached scale is found by testing the file's scales with
H5DSis_attached rather than by iterating.  Nothing here needs a ccall.
"""
function attached_scale_name(d::HDF5.Dataset, axis::Integer,
                             candidates::Vector{Pair{String,HDF5.Dataset}})
    for (name, s) in candidates
        if HDF5.API.h5ds_is_attached(d, s, axis)
            return name
        end
    end
    return nothing
end

"""Every dimension scale in the file, as link name => dataset, nearest
group first so that a support-local `row` is found before the file one."""
function collect_scales(f::HDF5.File)
    out = Pair{String,HDF5.Dataset}[]
    function walk(g, prefix)
        for name in keys(g)
            obj = g[name]
            if obj isa HDF5.Dataset
                if haskey(HDF5.attributes(obj), "CLASS") && is_scale(obj)
                    push!(out, name => obj)
                end
            elseif obj isa HDF5.Group
                walk(obj, prefix * "/" * name)
            end
        end
    end
    walk(f, "")
    return out
end
