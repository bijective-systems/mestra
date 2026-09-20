# Integration weights, computed from the connectivity.
#
# Section 3 says a weight array is "computed from connectivity, never
# imported", and it names no formula, so this file is the formula:
# the measure of a cell from its type and its nodes, and for a node
# the lumped share of the cells it belongs to.  Nothing here is per
# file or per family; a cell type is measured for every file or it is
# refused for every file, and the refusal says which code it met.

"""The topological dimension of each cell type of section 20, which is
the power of length its measure has."""
const CELL_DIM = Dict{Int,Int}(1 => 0, 3 => 1, 5 => 2, 7 => 2, 9 => 2,
                               10 => 3, 12 => 3, 13 => 3, 14 => 3,
                               21 => 1, 22 => 2, 23 => 2, 24 => 3,
                               25 => 3, 26 => 3, 27 => 3)

"""The cell types this package measures: the straight-sided ones.  A
quadratic cell's measure is an integral over its curved geometry,
which this version does not compute and will not approximate
silently."""
const MEASURED_CELLS = (3, 5, 7, 9, 10, 12, 13, 14)

# The straight-sided decompositions, in a cell's own node order
# (section 20 keeps VTK's): a polygon and a quadrilateral fan into
# triangles from their first node, a hexahedron into five tetrahedra,
# a wedge into three, a pyramid into two.  Each is exact for the
# planar-faced cell.
const HEX_TETS = ((1, 2, 3, 6), (1, 3, 6, 8), (1, 3, 4, 8),
                  (1, 5, 6, 8), (3, 6, 7, 8))
const WEDGE_TETS = ((1, 2, 3, 4), (2, 3, 4, 5), (3, 4, 5, 6))
const PYRAMID_TETS = ((1, 2, 3, 5), (1, 3, 4, 5))

sub3(a, b) = (a[1] - b[1], a[2] - b[2], a[3] - b[3])
cross3(a, b) = (a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3],
                a[1] * b[2] - a[2] * b[1])
dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
norm3(a) = sqrt(a[1]^2 + a[2]^2 + a[3]^2)

triangle_area(a, b, c) = 0.5 * norm3(cross3(sub3(b, a), sub3(c, a)))
tetra_volume(a, b, c, d) =
    abs(dot3(sub3(b, a), cross3(sub3(c, a), sub3(d, a)))) / 6

"""One node of one instance as a three-vector, whatever the support's
spatial dimension."""
@inline function point3(coords::AbstractArray{Float64,3}, inst::Int, i::Int)
    d = size(coords, 3)
    return (coords[inst, i, 1],
            d >= 2 ? coords[inst, i, 2] : 0.0,
            d >= 3 ? coords[inst, i, 3] : 0.0)
end

"""The measure of one cell: its length, its area or its volume,
according to its type."""
function cell_measure(code::Int, pts, path)
    code == 3 && return norm3(sub3(pts[2], pts[1]))
    if code == 5 || code == 7 || code == 9
        a = 0.0
        for i in 2:(length(pts) - 1)
            a += triangle_area(pts[1], pts[i], pts[i + 1])
        end
        return a
    end
    code == 10 && return tetra_volume(pts[1], pts[2], pts[3], pts[4])
    tets = code == 12 ? HEX_TETS : code == 13 ? WEDGE_TETS :
           code == 14 ? PYRAMID_TETS : nothing
    tets === nothing && throw(unmeasured(code, path))
    return sum(tetra_volume(pts[t[1]], pts[t[2]], pts[t[3]], pts[t[4]])
               for t in tets)
end

unmeasured(code::Int, path) = MestraError("E21", path,
    haskey(CELL_DIM, code) ?
    "this package does not measure cell type $(code); it measures " *
    "the straight-sided types " * join(MEASURED_CELLS, ", ") *
    ", and a quadratic cell's measure is an integral over its curved " *
    "geometry that it will not approximate silently" :
    "cell type $(code) is not one of section 20")

"""The dimension every cell of a support has, which is the dimension
its measure has.  Cells of two dimensions in one support have no one
measure, so that is refused rather than added up."""
function cell_dimension(types::Vector{UInt8}, path)
    dims = Set{Int}()
    for t in types
        code = Int(t)
        code in MEASURED_CELLS || throw(unmeasured(code, path))
        push!(dims, CELL_DIM[code])
    end
    length(dims) <= 1 || throw(MestraError(nothing, path,
        "this support has cells of dimension " *
        join(sort(collect(dims)), " and ") * ", which have no one " *
        "measure between them; weigh a support whose cells are all of " *
        "one dimension"))
    return isempty(dims) ? 0 : first(dims)
end

"""The coordinates as (instance, node, component), with one instance
when they do not vary, and what they vary along."""
function coordinate_instances(ds::Dataset, sup::Support)
    c = sup.coordinates
    c === nothing && throw(MestraError("E03", "/supports/$(sup.name)",
        "this support carries no coordinates, so there is nothing to " *
        "measure"))
    p = permute_to_logical(ds, c)
    a = Array{Float64}(collect(parent(p)))
    first(dimnames(p)) in (:node, :cell) &&
        (a = reshape(a, 1, size(a)...))
    return (a, c.varies === nothing ? "none" : c.varies)
end

"""The lumped share of the intervals between neighbouring nodes of an
axis support, which is the same rule as the mesh one with the
intervals as the cells.  The nodes are taken in coordinate order,
which is the only connectivity an axis has."""
function axis_node_weights(x::AbstractVector{Float64})
    n = length(x)
    n == 0 && return Float64[]
    n == 1 && return [0.0]
    ord = sortperm(x)
    w = zeros(Float64, n)
    for k in 1:(n - 1)
        h = (x[ord[k + 1]] - x[ord[k]]) / 2
        w[ord[k]] += h
        w[ord[k + 1]] += h
    end
    return w
end

"""The units of a length raised to a power, or nothing for a unit
string this cannot raise, since a weight needs no units (E11)."""
function unit_power(u::Union{Nothing,AbstractString}, d::Int)
    u === nothing && return nothing
    s = String(strip(String(u)))
    isempty(s) && return nothing
    (d == 1 || s == "1") && return s
    (occursin(' ', s) || occursin('-', s) || occursin('/', s) ||
     occursin('^', s) || isdigit(last(s))) && return nothing
    return s * string(d)
end

"""
    compute_weights(ds, support, location) -> Matrix{Float64}

The weights themselves, as (instance, site): the measure of each cell
for `:cell`, and for `:node` the lumped share of the measure of the
cells each node belongs to.  There is one instance unless the
coordinates vary, in which case there is one per row or per group
category, because a mesh that moves has a measure that moves with it.

`compute_weights!` is the one to call; this is what it computes.
"""
function compute_weights(ds::Dataset, sup::Support, location::Symbol)
    return weight_matrix(ds, sup, location)[1]
end

compute_weights(ds::Dataset, name::AbstractString, location::Symbol) =
    compute_weights(ds, named_support(ds, name), location)

function weight_matrix(ds::Dataset, sup::Support, location::Symbol)
    path = "/supports/$(sup.name)"
    location in (:node, :cell) || throw(MestraError(nothing, path,
        "weights live at the nodes or at the cells; pass `location` as " *
        "`:node` or `:cell`"))
    coords, varies = coordinate_instances(ds, sup)
    ninst, nnode, _ = size(coords)
    if sup.kind == "axis"
        location === :cell && throw(MestraError("E38", path,
            "a support of kind axis has no cells; ask for `:node` weights"))
        w = zeros(Float64, ninst, nnode)
        for i in 1:ninst
            w[i, :] = axis_node_weights(Float64[coords[i, n, 1]
                                                for n in 1:nnode])
        end
        return (w, varies, unit_power(sup.coordinates.units, 1))
    end
    sup.kind == "mesh" || throw(MestraError(nothing, path,
        "a support of kind $(sup.kind) has no measure"))
    types, offsets, conn =
        sup.cell_types, sup.cell_offsets, sup.cell_connectivity
    (types === nothing || offsets === nothing || conn === nothing) &&
        throw(MestraError("E41", path,
            "this support's cells were not read, so there is no " *
            "connectivity to measure"))
    dim = cell_dimension(types, path * "/cell_types")
    ncell = length(types)
    out = zeros(Float64, ninst, location === :cell ? ncell : nnode)
    for j in 1:ncell
        nodes = Int[conn[k] + 1 for k in (offsets[j] + 1):offsets[j + 1]]
        for i in 1:ninst
            m = cell_measure(Int(types[j]),
                             [point3(coords, i, n) for n in nodes],
                             path * "/cell_types")
            if location === :cell
                out[i, j] = m
            else
                share = m / length(nodes)
                for n in nodes
                    out[i, n] += share
                end
            end
        end
    end
    return (out, varies, unit_power(sup.coordinates.units, dim))
end

"""
    compute_weights!(ds, support, location; name = "weight", units)

Add the integration weights of a support to the dataset, at the nodes
or at the cells, and give back the slot.

The array has role `weight`, is named `weight` at both locations
unless you name it, carries the units of the coordinates raised to the
support's dimension, and is marked `recomputed`, which is what W06
asks for.  It varies the way the coordinates vary: a fixed mesh has
one instance, a parametric family one per group category, a moving
mesh one per row.

    s = Mestra.add_mesh_support!(ds, "s0"; ...)
    Mestra.compute_weights!(ds, s, :node)
    Mestra.integrate(ds, "pressure")       # uses it

Section 3 says a weight is computed from the connectivity and never
imported, so this is the only way one gets into a file.
"""
function compute_weights!(ds::Dataset, sup::Support, location::Symbol;
                          name::AbstractString = "weight", units = nothing)
    w, varies, u = weight_matrix(ds, sup, location)
    units === nothing && (units = u)
    axis = location === :cell ? :cell : :node
    data = varies == "none" ? vec(w) : w
    dims = varies == "none" ? (axis,) :
           (Symbol(varies == "row" ? "row" : varies), axis)
    add = location === :cell ? add_cell_array! : add_node_array!
    return add(ds, sup, name, data; role = :weight, units = units,
               dims = dims, recomputed = true)
end

compute_weights!(ds::Dataset, name::AbstractString, location::Symbol;
                 kwargs...) =
    compute_weights!(ds, named_support(ds, name), location; kwargs...)

"""The support called `name`, or a refusal that lists the ones there
are."""
function named_support(ds::Dataset, name::AbstractString)
    i = support_by_name(ds, String(name))
    i === nothing && throw(MestraError(nothing, "/supports",
        "no support called `$(name)`; this file has " *
        (isempty(ds.supports) ? "none" :
         join(["`" * s.name * "`" for s in support_order(ds)], ", "))))
    return ds.supports[i]
end

named_support(::Dataset, ::Nothing) = throw(MestraError("E39", "/",
    "this slot names no support, so it has no nodes or cells to work over"))
