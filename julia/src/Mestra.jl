"""
    Mestra

A reader, a writer and a validator for `mestra`, the open container for
simulation and surrogate data.  The format is written `mestra`, lower
case, everywhere; the package is `Mestra` because Julia capitalises
package names.

Julia is column major and the format is stored in C order, so every
array arrives with its axes reversed from the order the specification
states.  Nothing here takes an axis by position: an array comes back
as a `DimArray` carrying the name of each axis, and `permute` reorders
by those names.

    ds = Mestra.read("case.mes")
    v  = Mestra.values(ds, ds["pressure"])        # (component, node, row)
    p  = Mestra.permute(v, (:row, :node, :component))
    p[2, 4, 1]                                     # row 2, node 4, comp 1

See `julia/README.md` for a five-minute tour.
"""
module Mestra

using HDF5
using Printf: @sprintf
import SHA

export DimArray, dimnames, permute, at, MestraError

include("h5low.jl")
include("model.jl")
include("dims.jl")
include("units.jl")
include("supportid.jl")
include("codec.jl")
include("callables.jl")
include("read.jl")
include("write.jl")
include("validate.jl")
include("evaluate.jl")
include("build.jl")
include("weights.jl")
include("postprocess.jl")
include("compare.jl")

function __init__()
    register_callable!("affine", Affine)
    return nothing
end

end # module
