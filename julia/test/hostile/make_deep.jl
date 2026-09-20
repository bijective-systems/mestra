# The two deeply nested hostile files, built here rather than
# committed.
#
# Thirty thousand nested groups is thirty megabytes of object headers
# and nothing else, which is too much to keep in a repository for what
# it says.  make_hostile.py writes the same two files under --deep;
# this builds them with HDF5.jl so that the test suite needs no Python.
#
# What they are for: every walk over a file's groups has to be capped
# or iterative.  A reader that recursed on the call stack would
# overflow it here, and a Julia stack overflow is not an exception a
# caller can catch.

using HDF5
using Printf: @sprintf

const DIM_SENTENCE =
    "This is a netCDF dimension but not a netCDF variable."

function _sattr(obj, name, value)
    raw = Vector{UInt8}(codeunits(String(value)))
    n = max(1, length(raw))
    t = HDF5.API.h5t_copy(HDF5.API.H5T_C_S1)
    HDF5.API.h5t_set_size(t, n)
    HDF5.API.h5t_set_cset(t, HDF5.API.H5T_CSET_UTF8)
    HDF5.API.h5t_set_strpad(t, HDF5.API.H5T_STR_NULLPAD)
    dt = HDF5.Datatype(t)
    sp = HDF5.Dataspace(HDF5.API.h5s_create(HDF5.API.H5S_SCALAR))
    a = HDF5.create_attribute(obj, String(name), dt, sp)
    try
        HDF5.API.h5a_write(a, dt, vcat(raw, zeros(UInt8, n - length(raw))))
    finally
        close(a)
    end
end

function _scale(parent, name, len)
    sp = HDF5.Dataspace(HDF5.API.h5s_create_simple(
        1, HDF5.API.hsize_t[len], HDF5.API.hsize_t[HDF5.API.H5S_UNLIMITED]))
    dcpl = HDF5.DatasetCreateProperties()
    dcpl.obj_track_times = false
    HDF5.API.h5p_set_chunk(dcpl, 1, HDF5.API.hsize_t[1])
    d = HDF5.create_dataset(parent, String(name),
                            HDF5.Datatype(HDF5.API.h5t_copy(
                                HDF5.API.H5T_IEEE_F32BE)), sp; dcpl = dcpl)
    HDF5.API.h5ds_set_scale(d, @sprintf("%s%10d", DIM_SENTENCE, len))
    return d
end

"""
    make_deep(path, parent; levels = 30000)

`levels` nested groups under `/keys` or `/callables`, on top of enough
of a file that a reader gets that far.
"""
function make_deep(path::AbstractString, parent::AbstractString;
                   levels::Integer = 30000)
    h5open(String(path), "w") do f
        _sattr(f, "created", "2026-09-19T00:00:00Z")
        _sattr(f, "format", "mestra/0")
        _sattr(f, "writer", "mestra hostile 0")
        attrs = HDF5.attributes(f)
        attrs["aligned"] = Int8(1)
        row = _scale(f, "row", 2)
        keys_ = HDF5.create_group(f, "keys")
        dcpl = HDF5.DatasetCreateProperties()
        dcpl.obj_track_times = false
        HDF5.API.h5p_set_chunk(dcpl, 1, HDF5.API.hsize_t[2])
        sp = HDF5.Dataspace(HDF5.API.h5s_create_simple(
            1, HDF5.API.hsize_t[2],
            HDF5.API.hsize_t[HDF5.API.H5S_UNLIMITED]))
        mach = HDF5.create_dataset(keys_, "mach",
                                   HDF5.Datatype(HDF5.API.h5t_copy(
                                       HDF5.API.H5T_IEEE_F64LE)), sp;
                                   dcpl = dcpl)
        HDF5.API.h5d_write(mach, HDF5.Datatype(HDF5.API.h5t_copy(
                               HDF5.API.H5T_IEEE_F64LE)),
                           HDF5.API.H5S_ALL, HDF5.API.H5S_ALL,
                           HDF5.API.H5P_DEFAULT, [0.4, 0.8])
        HDF5.API.h5ds_attach_scale(mach, row, 0)
        _sattr(mach, "role", "condition")
        _sattr(mach, "units", "1")
        HDF5.create_group(f, "scalars")
        g = parent == "keys" ? keys_ : HDF5.create_group(f, "callables")
        if parent == "callables"
            g = HDF5.create_group(g, "m1")
            _sattr(g, "type", "deep")
        end
        for _ in 1:levels
            g = HDF5.create_group(g, "g")
        end
        HDF5.attributes(g)["bottom"] = Int64(1)
    end
    return String(path)
end

"""Build both deep files in `dir` and return their paths."""
function make_deep_files(dir::AbstractString; levels::Integer = 30000)
    isdir(dir) || mkpath(dir)
    return [make_deep(joinpath(dir, "deep_keys.mes"), "keys";
                      levels = levels),
            make_deep(joinpath(dir, "deep_callables.mes"), "callables";
                      levels = levels)]
end
