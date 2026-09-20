# Dimension names, and permuting by name.
#
# Julia is column major.  HDF5 stores this format in C order, so an
# array the file holds as (row, node, component) arrives in Julia as
# (component, node, row).  Nothing in this package ever takes an axis
# by position: every array carries its dimension names in the order
# the Julia array actually has, and `permute` reorders by those names.

"""
    DimArray{T,N}

An array together with the name of each of its axes, in the order the
Julia array has them.  `dimnames(a)` gives the names, `permute(a, ...)`
reorders by name, and `at(a; row = 2, node = 4)` reads one element by
name.
"""
struct DimArray{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
    data::A
    dims::NTuple{N,Symbol}
end

DimArray(a::AbstractArray{T,N}, dims) where {T,N} =
    DimArray{T,N,typeof(a)}(a, NTuple{N,Symbol}(Symbol.(dims)))

Base.size(a::DimArray) = size(a.data)
Base.getindex(a::DimArray, i...) = getindex(a.data, i...)
Base.setindex!(a::DimArray, v, i...) = setindex!(a.data, v, i...)
Base.IndexStyle(::Type{<:DimArray{T,N,A}}) where {T,N,A} = IndexStyle(A)
Base.parent(a::DimArray) = a.data

"""The name of each axis, in the order this array has them."""
dimnames(a::DimArray) = a.dims

function Base.show(io::IO, ::MIME"text/plain", a::DimArray)
    print(io, join(size(a), "x"), " DimArray{", eltype(a), "} ",
          "(", join(string.(a.dims), ", "), ")")
end

"""
    axisindex(a, name) -> Int

The position of the axis called `name`.  `:instance` names the leading
axis of an array whose `varies` is `group:<k>`, and `:node` also
answers for a cell array's `:cell` axis, so that the same code reads
both.  Throws when the name is not one of this array's axes.
"""
function axisindex(dims::NTuple{N,Symbol}, name::Symbol) where {N}
    for (i, d) in pairs(dims)
        d === name && return i
    end
    if name === :instance
        for (i, d) in pairs(dims)
            startswith(String(d), "group:") && return i
        end
    end
    if name === :node
        for (i, d) in pairs(dims)
            d === :cell && return i
        end
    end
    if name === :cell
        for (i, d) in pairs(dims)
            d === :node && return i
        end
    end
    throw(MestraError(nothing,
        "no axis called $(name); this array has " *
        join(string.(dims), ", ")))
end

axisindex(a::DimArray, name::Symbol) = axisindex(a.dims, name)

"""
    permute(a::DimArray, order) -> DimArray

Return `a` with its axes in the order named, for example
`permute(v, (:row, :node, :component))`.  Every axis must be named
exactly once.
"""
function permute(a::DimArray, order)
    order = Tuple(Symbol.(order))
    length(order) == ndims(a) || throw(MestraError(nothing,
        "permute needs one name per axis: got $(length(order)) for " *
        "$(ndims(a)) axes"))
    perm = ntuple(i -> axisindex(a, order[i]), length(order))
    length(unique(perm)) == length(perm) || throw(MestraError(nothing,
        "permute names an axis twice"))
    return DimArray(permutedims(a.data, perm), order)
end

"""
    permute(a::AbstractArray, from, to) -> Array

Permute a plain array whose axes are called `from` into the order
`to`.
"""
permute(a::AbstractArray, from, to) =
    parent(permute(DimArray(a, from), to))

"""
    at(a::DimArray; row, node, cell, component, draw, instance, index)

One element, addressed by axis name.  Indices are one based, as
everywhere else in Julia; the conformance corpus counts from zero, so
a test adds one.
"""
function at(a::DimArray; kwargs...)
    idx = ones(Int, ndims(a))
    seen = falses(ndims(a))
    for (name, value) in kwargs
        i = axisindex(a, name)
        idx[i] = value
        seen[i] = true
    end
    for (i, s) in pairs(seen)
        s || size(a, i) == 1 || throw(MestraError(nothing,
            "at() needs an index for axis $(a.dims[i])"))
    end
    return a.data[idx...]
end

# ------------------------------------------- names on disk and logical

"""Section 21: the logical dimension name behind a name on disk."""
function logical_dim(disk::AbstractString)
    disk == "row" && return :row
    disk == "node" && return :node
    disk == "cell" && return :cell
    disk == "cell_plus_one" && return :cell_plus_one
    disk == "index" && return :index
    startswith(disk, "component_") && return :component
    startswith(disk, "draw_") && return :draw
    startswith(disk, "group_") && return Symbol("group:" * disk[7:end])
    startswith(disk, "category_") && return Symbol(disk)
    return Symbol(disk)
end

"""Section 21, the other way: the name a logical dimension has on
disk.  `n` is the length, which `component` and `draw` carry."""
function disk_dim(logical::Symbol, n::Integer)
    logical === :row && return "row"
    logical === :node && return "node"
    logical === :cell && return "cell"
    logical === :cell_plus_one && return "cell_plus_one"
    logical === :index && return "index"
    logical === :component && return "component_$(n)"
    logical === :draw && return "draw_$(n)"
    s = String(logical)
    startswith(s, "group:") && return "group_" * s[7:end]
    return s
end
