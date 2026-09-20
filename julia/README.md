Mestra: the Julia interface to mestra
=====================================

`mestra` is an open container for simulation and surrogate data: rows
of observations over design parameters, operating conditions and time;
scalar quantities and fields on shared supports; and the claim that
rows are index-aligned, stated so that a reader can check it. The
format is written `mestra`, lower case, everywhere. The package is
`Mestra` because Julia capitalises package names, and nothing else
about the name changes.

This directory holds a reader, a writer, a validator, the dictionary
codec, the callable protocol with its `affine` reference callable,
evaluation, and a little generic post-processing. It depends on HDF5.jl
and SHA only. It is not the reference implementation: SPEC.md and the
golden files under `vectors/` define conformance between them, and this
package runs the whole corpus in its own tests.


Getting started
---------------

    julia --project=julia
    julia> using Mestra
    julia> ds = Mestra.read("vectors/cases/mesh_two_rows/case.mes")
    mestra Dataset (mestra/0), 2 rows, aligned
      keys     : mach, member
      scalars  : cl
      support s0 (mesh, 6 nodes, 2 cells) 96df395d
        node arrays: pressure
        cell arrays: region

Opening a file reads attributes and dataspaces and no array at all, so
that is cheap however large the file is. Everything the file declares
is there to look at:

    ds.nrows                      # 2
    ds.aligned                    # true: every row is on one support
    ds.keys["mach"].role          # :condition
    ds.keys["mach"].lower         # 0.1, the domain the file is valid over
    ds.supports[1].support_id     # the content hash of section 24
    ds["pressure"].units          # "Pa"
    ds["pressure"].varies         # "row"


The axis order, and why you never count axes
--------------------------------------------

This is the one thing to read before anything else.

The format stores an array in the order (row, [draw], node | cell,
component), in C (row-major) layout. Julia is column major, so HDF5
hands the same bytes back with the axes **reversed**: a field the file
holds as (row, node, component) arrives as (component, node, row).
That is correct and expected, and a MATLAB reader does the same thing.
What two readers in two languages must agree on is the value at
(row r, node n, component c), found by the dimension names and never by
the axis positions.

So every array comes back as a `DimArray` carrying the name of each of
its axes, in the order that array actually has them:

    v = Mestra.values(ds, ds["pressure"])
    Mestra.dimnames(v)            # (:component, :node, :row)
    size(v)                       # (1, 6, 2)

Ask for the order you want by name. This is the idiom:

    p = Mestra.permute(v, (:row, :node, :component))
    Mestra.dimnames(p)            # (:row, :node, :component)
    p[2, 4, 1]                    # 204.0: row 2, node 4, component 1

Or read one element by name, without permuting anything:

    Mestra.at(v; row = 2, node = 4, component = 1)      # 204.0

Indices are one based here, as everywhere else in Julia. The
conformance corpus counts from zero, so its probe of (row 1, node 3,
component 0) is this one.

The names you can use are `:row`, `:node`, `:cell`, `:component`,
`:draw`, `:cell_plus_one` and `:index`, plus the leading axis of an
array that varies along a group, which is named after the group key,
for example `Symbol("group:member")`. `:instance` is an accepted alias
for whichever axis that is, and `:node` also answers for a cell array's
`:cell` axis, so the same code reads both:

    c = Mestra.values(ds, ds.supports[1].coordinates)
    Mestra.dimnames(c)      # (:component, :node, Symbol("group:member"))
    Mestra.at(c; instance = 2, node = 3, component = 1)   # 3.0

A reader that took the axes by position would answer 105.0 to the first
question and would be wrong. Asking for a name the array does not have
raises an error rather than returning a number from the wrong place.


Reading one slot, for a range of rows
-------------------------------------

Section 29 asks a reader to be able to read one slot for a range of
rows without touching any other slot or any row outside the range.
That is `rows`:

    Mestra.rows(ds, ds["pressure"], 1:2)

The range is one based. In an unaligned file a row-varying array on a
support holds one entry per row that references that support, in the
file's row order, so the range indexes that support's own rows and not
the file's row numbers (section 22). `Mestra.materialise!(ds)` reads
everything at once if you would rather have it all in memory, and
`Mestra.read(path; lazy = false)` does that on opening.


Checking a file
---------------

    r = Mestra.validate("some.mes")
    r.errors        # rule ids of section 14, sorted, no duplicates
    r.warnings
    r.findings      # each with its rule, its path and a sentence

The report names rules by identifier and nothing else, as the corpus
does. Retired identifiers (E07, W09) are never emitted. A file with an
empty `errors` list is conforming; warnings are reported and the file
is still accepted.


A file is untrusted input
-------------------------

A `.mes` file is something somebody else wrote, and every number in it
about itself -- how many elements a dataset has, how many values a
filter declares, how deep its groups go -- is that somebody's claim.
This reader checks each claim before it acts on it, and answers a file
it will not read with a finding or with a `MestraError` rather than by
falling over.

What it refuses:

  - **a link that is not a hard link**, anywhere in the public tree.
    A soft link may point at nothing or in a circle, and an external
    link would open another file on this file's say-so. The link is
    asked what kind it is before anything opens it, and anything but a
    hard link is reported as **E40** and never followed;
  - **more than it will hold in memory**. A read is refused above
    `max_elements`, which defaults to 2^31 and is a keyword on `read`,
    `values` and `rows`, and above `Mestra.MAX_READ_BYTES[]`, which
    defaults to 1 GiB. The chunk is checked too, because the library
    reads a whole chunk at a time, so one row of a dataset with a
    three-gigabyte chunk is refused as well. A file may declare a
    trillion elements and hold none; validating one and reading one
    row of it cost what the row costs;
  - **an object it cannot read**, which is reported as **E41** with
    its path, after which the pass carries on. One unreadable object
    never hides what comes after it;
  - **more depth than anything needs**. Every walk is iterative or
    capped at 64 levels, so a file with thirty thousand nested groups
    is reported and not followed. The units parser is capped the same
    way.

Where the reader can carry on it does: `Mestra.read` returns the
dataset and puts what it would not follow or could not read in
`ds.findings`, each a `Finding` with its rule, its path and a
sentence. `Mestra.validate` never throws on a file it can open, and
answers one it cannot with E01. Opening a file that is not HDF5 at all
raises a `MestraError` with rule E01.

`julia/test/hostile/` holds the files this is tested against, and
`make_hostile.py` is what wrote them.


Building a dataset from arrays
------------------------------

A handful of calls, with the dimensions, the bounds and the support id
filled in for you:

    ds = Mestra.Dataset(writer = "my tool 1")
    Mestra.add_category_table!(ds, "member", ["wing_a", "wing_b"])
    Mestra.add_key!(ds, "mach", [0.4, 0.8]; role = :condition, units = "1")
    Mestra.add_key!(ds, "member", [0, 1]; role = :group,
                    category = "member")
    Mestra.add_scalar!(ds, "cl", [0.25, 0.55]; units = "1")

    s = Mestra.add_mesh_support!(ds, "s0";
            coordinates = [0.0 0.0; 1.0 0.0; 2.0 0.0;
                           0.0 1.0; 1.0 1.0; 2.0 1.0],
            dims = (:node, :component),
            cell_types = UInt8[9, 9],
            cell_offsets = Int64[0, 4, 8],
            cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])

    Mestra.add_node_array!(ds, s, "pressure",
                           [101.0 102 103 104 105 106;
                            201.0 202 203 204 205 206]; units = "Pa")

    Mestra.write(ds, "out.mes")

`dims` names the axes of the array you hand over, in the order your
array has them. It defaults to `(:row, :node)` for a matrix and
`(:row, :node, :component)` for a three-axis array, and a missing
component axis is added for you with length one, because the component
dimension is always present in the file (section 19). `varies` follows
from the leading name unless you state it.

The defaults that are filled in:

  - `lower` and `upper` on a design, condition or time key come from
    the data. Pass `bounds = (lo, hi)` to state them, or
    `bounds = nothing` for none;
  - `support_id` is computed from the cells, or from the node count and
    the coordinates for an axis support;
  - `aligned` follows from the number of supports, and a file with more
    than one needs `set_row_support!`;
  - `components` follows from the component axis;
  - `created` is now, in UTC.

Anything that cannot legally be written raises a `MestraError` naming
the rule of section 14 that it breaks:

    julia> Mestra.add_key!(ds, "mestra_x", [1.0]; role = :condition,
                           units = "1"); Mestra.write(ds, "bad.mes")
    ERROR: mestra: E33: key name mestra_x begins with the reserved prefix

Files this package writes are conforming netCDF-4 files: fixed-length
NUL-padded UTF-8 strings, dimension scales created and attached with
the H5DS API, chunking along an unlimited `row`, no filter but gzip and
shuffle, no fill value, and object time tracking off, so two runs of
the writer produce the same bytes. `ncdump -h` on one of them lists
`row`, `node`, `component_1`, `group_member` and the rest by name.


Callables, and evaluating a file
--------------------------------

A callable is exactly four things: call, `to_dict`, `from_dict`, and an
optional one-line `repr`. Everything else it knows is inside its own
dictionary and is its own business.

    c = Mestra.callable(ds, "m1")          # if this reader owns the type
    c(Dict("mach" => [0.5], "alpha" => [4.0]))
    # Dict("cl" => [1.45], "pressure" => ...)

The keys table of section 26 is, in Julia, a `Dict{String,Vector{Float64}}`
of key name to column, with every column the same length and the row
order the evaluation order: output row i is the result for table row i.
A `NamedTuple` of columns and a `(matrix, names)` pair, where the matrix
is (rows, keys) and the names are in the file's key order, are accepted
and converted. A key with role `id` may hold a `Vector{String}`.

`affine` is the one callable type the package defines, so that the
protocol, the codec and evaluation can be conformance tested with no
proprietary model. Its dot product is accumulated over the keys in the
declared key order and `b` is added last, with no fused multiply-add,
which is what makes its results bit-identical everywhere.

Your own type joins by conforming and registering:

    struct MyModel <: Mestra.Callable ... end
    (m::MyModel)(table) = Dict("pressure" => ...)
    Mestra.to_dict(m) = Dict{String,Any}(...)
    Mestra.from_dict(::Type{MyModel}, d) = MyModel(...)
    Mestra.register_callable!("my model", MyModel)

Evaluating a file on a keys table gives a dataset with the same slots,
now holding data, which you can write out:

    out = Mestra.evaluate(ds, Dict("mach" => [0.5], "alpha" => [4.0]))
    Mestra.write(out, "evaluated.mes")

Distillation is that operation on a grid. The written file has the same
support id as the model file, so a tool knows the two are about the
same mesh after reading one attribute.

A callable whose type this reader does not own is still read: its
dictionary comes back as a nested `Dict` under
`ds.callables[id].dict`, to copy and not to interpret.


Post-processing that only needs the format
------------------------------------------

Four things, written against the roles, `varies`, the labels and the
unit of generalisation, and against nothing else:

    Mestra.field_statistics(ds, ds["pressure"])
    Mestra.field_statistics(ds, ds["pressure"], by = "region")
    Mestra.integrate(ds, ds["pressure"]; weight = "measure",
                     by = "region", region = "inlet")
    Mestra.time_series(ds, ds["u"]; node = 3, trajectory = "r000")
    Mestra.grouped_split(ds; fractions = ["train" => 0.8, "test" => 0.2])
    Mestra.split_leaks(ds)

`grouped_split` moves whole units of generalisation, so the split is a
generalisation test; a file that names no unit is refused rather than
guessed at. `split_leaks` reports the units the file's own `split` key
places on more than one side, which is what W01 warns about.


The public API
--------------

    Reading    read, values, rows, materialise!
    Writing    write
    Checking   validate, structural_diff, structurally_equal
    Axes       DimArray, dimnames, permute, at
    Model      Dataset, KeyColumn, Slot, Support, CategoryTable,
               CallableRef, support_id, support_order, key_order,
               array_slots, all_slots
    Building   Dataset(...), add_key!, add_scalar!, add_category_table!,
               add_mesh_support!, add_axis_support!, add_none_support!,
               add_node_array!, add_cell_array!, add_callable!,
               add_callable_slot!, add_callable_scalar!, set_callable!,
               set_row_support!, set_notes!, set_private!
    Callables  Callable, to_dict, from_dict, register_callable!,
               callable, build_callable, Affine, affine, evaluate
    Codec      read_dict, write_dict
    After      field_statistics, integrate, time_series, grouped_split,
               split_leaks
    Errors     MestraError, ValidationReport, Finding
    Limits     DEFAULT_MAX_ELEMENTS, MAX_READ_BYTES, MAX_DEPTH

`DimArray`, `dimnames`, `permute`, `at` and `MestraError` are exported;
everything else is reached as `Mestra.name`, because `read`, `write`
and `values` would otherwise shadow the ones in Base.


Running the tests
-----------------

    julia --project=julia -e 'using Pkg; Pkg.test()'

The suite runs the whole conformance corpus: the validator's outcome
for all 69 cases against expected.json, every probe, every support id,
every codec round trip, every worked evaluation, and a read, write and
compare of every case that must validate cleanly. It also opens two
written files with NCDatasets to check that they are netCDF-4 files
with the dimension names the specification asks for.
