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

The public API, each name with a docstring of its own:

    Reading    read, values, rows, materialise!, materialised, info
    Rules      STRUCTURAL_RULES, the ones a strict read refuses with
    Writing    write
    Checking   validate, report, structural_diff, structurally_equal
    Axes       DimArray, dimnames, permute, at
    Model      Dataset, KeyColumn, Slot, Support, CategoryTable,
               CallableRef, support_id, support_order, key_order,
               array_slots, all_slots
    Building   Dataset(...), add_key!, add_scalar!, add_category_table!,
               set_generalisation_group!, add_mesh_support!,
               add_axis_support!, add_none_support!, add_node_array!,
               add_cell_array!, add_callable!, add_callable_slot!,
               set_callable_coordinates!,
               add_callable_scalar!, set_callable!, set_row_support!,
               set_notes!, set_private!
    Weights    compute_weights, compute_weights!
    Callables  Callable, to_dict, from_dict, register_callable!,
               callable, build_callable, Affine, affine, evaluate
    Codec      read_dict, write_dict
    After      field_statistics, integrate, time_series, grouped_split,
               split_leaks
    Errors     MestraError, ValidationReport, Finding
    Limits     DEFAULT_MAX_ELEMENTS, MAX_READ_BYTES, MAX_DEPTH

`DimArray`, `dimnames`, `permute`, `at` and `MestraError` are
exported; everything else is reached as `Mestra.name`, because `read`,
`write` and `values` would otherwise shadow the ones in Base.

See `julia/README.md` for the way in, `../docs/guide.md` for what the
format means and `../SPEC.md` for the rules.
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
include("info.jl")
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
