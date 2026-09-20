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

The names, the argument order, the defaults and the messages here are
the ones every implementation has, which `docs/api-conventions.md`
settles; where Julia differs from the other three it is in syntax
only, and this document says so where it happens.


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

Those are attributes, and opening a file reads no number. The numbers
come from `Mestra.values`:

    Mestra.values(ds, ds.keys["mach"])[2]     # 0.8
    Mestra.values(ds, ds["pressure"])         # the whole array

`ds.keys["mach"].values` and `ds["pressure"].data` are where they are
kept once read, and asking for either before it is read says so and
names `Mestra.values` rather than handing back `nothing`.
`Mestra.materialised(x)` is the question without the error, and
`Mestra.read(path; lazy = false)` or `Mestra.materialise!(ds)` reads
everything at once.

`Mestra.info(path)` prints the whole of what a file declares -- every
key with its role, units, bounds, category, trajectory group and
parent, every support with its kind, counts and id, and every slot
with the name of each of its axes, its shape, its units and where its
numbers come from -- and reads no array to do it:

    julia> Mestra.info("vectors/cases/mesh_two_rows/case.mes")
    ...case.mes: mestra/0, 2 row(s), aligned, written by ...
      unit of generalisation: member
    keys
      mach    condition    units 1  bounds [0.1, 0.9]
      member  group        category member
    supports
      s0  mesh   6 node(s), 2 cell(s)  96df395d80ef5484...
    slots
      /scalars/cl                        (row) 2  units 1  data
      /supports/s0/node_arrays/pressure  (row, node, component)
                                         2x6x1  field  units Pa  data

(one line a slot; the last one is wrapped here to fit this page.)


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


Strict by default, and what that refuses
----------------------------------------

`Mestra.read` refuses a file that breaks one of the structural rules
of `docs/api-conventions.md` section 2 -- `Mestra.STRUCTURAL_RULES`,
which is **E01, E16, E19, E25, E26, E29, E30, E40** and **E41** --
with a `MestraError` naming the first it finds. Those rules are what a
file is made of rather than what it means, so deciding them costs
attributes, dataspaces, link types and dimension scales and not one
array element: a strict read still opens a file that declares a
trillion numbers it does not hold, and `Mestra.read(path;
max_elements = 8)` opens a file whose smallest array has more.

A semantic fault never stops a read. A missing unit, a split that
leaks, a support id that does not match its cells: those are what a
user opens a file to find out, and `Mestra.validate` and `Mestra.info`
are how they find out.

    Mestra.read(path; strict = false)

opens a structurally broken file too, and lists what the reader would
not follow or could not read in `ds.findings`. That is the call for a
file you are inspecting rather than trusting, and it is the one the
hostile corpus exercises.

`Mestra.validate(path; structural = true)` is the same pass on its
own, for when you want the findings rather than the refusal.


Checking a file
---------------

    r = Mestra.validate("some.mes")
    r.errors        # rule ids of section 14, sorted, no duplicates
    r.warnings
    r.findings      # each with its rule, its path and a sentence

    julia> Mestra.report(r)          # or Mestra.report("some.mes")
    W01 /keys/split: the rows of member `wing_a` are on both sides of
        the split, so this is not a generalisation test
    0 error(s), 1 warning(s)

`Mestra.report` prints `<id> <path>: <message>` a finding and ends on
`<n> error(s), <m> warning(s)`, which is the output every
implementation prints, so two languages' reports on one file can be
read against each other line for line.

A file with an empty `errors` list is conforming; warnings are
reported and the file is still accepted.

One rule says one thing about one object: a rule that could fire on
every row of a long file -- W02 on the status, W03 on a non-finite
value, W04 on a key outside its bounds -- fires once, and the message
carries how many rows it is about and the first three of them. Row
indices in a finding count from zero, as the file's own rows do.

The rules are E01 to E41 and W01 to W15. E07 and W09 are retired and
are never emitted. Four of them are easy to confuse with each other,
so, as section 14 now settles them:

  - **E11** is units absent from a field or a scalar. Units on a key,
    on coordinates and on a derived array are **E39**, and `weight`
    and `normal` need no units at all;
  - **E16** is a length disagreeing with a row count, on a slot whose
    leading dimension is `row`, on a key column or on `/row_support`,
    and it also catches a key or scalar dataset that is not
    one-dimensional. A slot that varies along `none` or a group has
    no row dimension and is E04 or E34 instead;
  - **E25** does not fire where the dimension's name follows from an
    attribute another rule already checks: the leading axis against
    `varies` is E04, the node or cell count is E05, and the component
    count is E31. A dimension scale is not subject to it, and a scale
    with `CLASS` and no `NAME` is;
  - **E18** is reported beside the rule that found a missing public
    attribute, in a file that also carries `/private`. Nothing here
    interprets `/private`, which section 29 forbids.

**E40** and **E41** are the two that a well-formed file never needs;
the next section is what they are for.


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
  - **an object that is not the kind the format requires**, such as a
    key that is a group or a support that is a dataset. There is
    nothing there to read as what it must be, so it is **E41** beside
    the rule that names the shape;
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

One trap in that last one is worth naming, because section 21 now
does. Asking HDF5 for the *path* of a dimension scale attached to an
axis makes it search the group hierarchy, and on a deeply nested file
that search runs off the stack and takes the process with it. This
reader never asks: the link name of every scale comes from a map built
during its own bounded walk of the file, and an attached scale is
matched against that map.

A lazy read and a row-range read are not subject to the element cap,
because they never materialise the whole dataset, so a file may be
readable one way and E41 the other. That is what section 29 says, and
the corpus states which is which.

Where the reader can carry on it does: `Mestra.read(path;
strict = false)` returns the dataset and puts what it would not follow
or could not read in `ds.findings`, each a `Finding` with its rule, its
path and a sentence. A strict read, which is the default, refuses the
same file instead, with the first of those rules it finds.
`Mestra.validate` never throws on a file it can open, and
answers one it cannot with E01. Opening a file that is not HDF5 at all
raises a `MestraError` with rule E01.

Two sets of files test this. `vectors/hostile` is the shared subset
every language runs: fifteen files with a looser contract than the
corpus's, where the validator must report at least the ids
`expected.json` requires, may report more, and must finish cleanly
inside ten seconds. Its two thirty-thousand-group files are generated
rather than committed, so run

    python vectors/generate.py --hostile-deep

before the suite if you want them; the tests say so and carry on
without them. `julia/test/hostile/` is this package's own set, written
by `make_hostile.py`, which goes further in a few places the shared
subset does not reach.


Building a dataset from arrays
------------------------------

A handful of calls, with the dimensions, the bounds and the support id
filled in for you. Every one of them takes the thing it adds to first,
then the name, then the values, and then what the format needs to know
about them, which is the order every language has:

    ds = Mestra.Dataset(writer = "my tool 1")
    Mestra.add_category_table!(ds, "member", ["wing_a", "wing_b"])
    Mestra.add_key!(ds, "mach", [0.4, 0.8]; role = :condition, units = "1")
    Mestra.add_key!(ds, "member", [0, 1]; role = :group,
                    category = "member")
    Mestra.set_generalisation_group!(ds, "member")
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

    Mestra.compute_weights!(ds, s, :node)
    Mestra.write(ds, "out.mes")

**A category table is added before whatever names it**, and the key or
label then names it with `category`. There is no way to pass the
entries inline, in any language.

**The unit of generalisation is a property of the dataset**, set with
`set_generalisation_group!(ds, name)`, naming a key of role `group`
(section 7). It is what `grouped_split` keeps whole and what
`split_leaks` and W01 are about, and both refuse without it. The first
group key you add takes the job until this says otherwise, which is
what to call when a file has more than one.

**A time key says which group its trajectories are**, with
`trajectory_group` naming a group key:

    Mestra.add_key!(ds, "t", times; role = :time, units = "s",
                    trajectory_group = "run")

Without it the file is a pile of rows rather than a set of
trajectories, E09 cannot be decided, and `time_series` has nothing to
follow.

**`dims` names the axes of the array you hand over**, in the order
your array has them, and everything else follows from it:

  - `varies` is "row" for a leading `:row` axis, that group for a
    leading `Symbol("group:<key>")` axis, and "none" otherwise;
  - `components` is the length of the component axis, which is added
    for you with length one when your array has none, because the
    component dimension is always present in the file (section 19).

You may pass `varies` as well, and one that says something other than
what `dims` names is refused at build time as E04 rather than written.
`:instance` is the spelling for "whichever group axis this is", and it
needs `varies` to say which group:

    Mestra.add_mesh_support!(ds, "s0";
        coordinates = family,                 # (instance, node, component)
        dims = (:instance, :node, :component),
        varies = "group:member", ...)

Left out, `dims` is read off the shape: `(:node,)` for a vector,
`(:row, :node)` or `(:node, :component)` for a matrix, whichever
agrees with the support, and `(:row, :node, :component)` for a
three-axis array. A square matrix on a support of as many nodes says
nothing about which of the two it is, so it is refused rather than
guessed at:

    julia> Mestra.add_node_array!(ds, s, "p", rand(6, 6); units = "Pa")
    ERROR: mestra: E04 /supports/s0/node_arrays/p: an array of shape
    (6, 6) on a support of 6 nodes is either (node, component) or
    (row, node); say which with `dims`

The defaults that are filled in:

  - `lower` and `upper` on a design, condition or time key are the
    observed finite range of the values. That is what every language
    does, so that the same arrays make the same file and W04 and W08
    are decidable on every file in the world. Pass `lower` and `upper`
    together for a wider domain of validity, or both as `nothing` for
    a file that declares none;
  - `support_id` is computed from the cells, or from the node count and
    the coordinates for an axis support;
  - `aligned` follows from the number of supports, and a file with more
    than one needs `set_row_support!`;
  - `components` follows from the component axis;
  - `created` is now, in UTC.

Anything that cannot legally be written raises a `MestraError` naming
the rule of section 14 that it breaks, the object it is about, and
which argument to change:

    julia> Mestra.add_key!(ds, "mestra_x", [1.0]; role = :condition,
                           units = "1"); Mestra.write(ds, "bad.mes")
    ERROR: mestra: E33 /keys/mestra_x: `mestra_x` begins with the
    reserved prefix `mestra_`; rename the key

`Mestra.write` validates what it has written and refuses to leave a
file the validator rejects: the findings are in the message, nothing
is left at the path, and a file that was already there is untouched.
`Mestra.write(ds, path; check = false)` writes it anyway, which is for
making a file that breaks a rule on purpose.

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

Section 26 now has a Julia row, and this is it: the keys table is a
`Dict{String,Vector{Float64}}` of key name to column, with every column
the same length and the row order the evaluation order, so output row i
is the result for table row i. A `NamedTuple` of columns and a
`(matrix, names)` pair, where the matrix is (rows, keys) and the names
are in the file's key order, are accepted and converted, as Python
accepts its second form. A key with role `id` may hold a
`Vector{String}`.

`affine` is the one callable type the package defines, so that the
protocol, the codec and evaluation can be conformance tested with no
proprietary model. Its dot product is accumulated over the keys in the
declared key order and `b` is added last, with no fused multiply-add,
which is what makes its results bit-identical everywhere.

Writing a model file is the callable and then the slots it fills. The
slot builders are the array builders with `callable` and `output` in
place of the values, and nothing else changes:

    Mestra.add_callable!(ds, "m1", c)
    Mestra.add_callable_scalar!(ds, "cl"; units = "1",
                                callable = "m1", output = "cl")
    Mestra.add_callable_slot!(ds, s, "pressure"; units = "Pa",
                              components = 1, callable = "m1",
                              output = "pressure")

A model file declares its keys with their bounds and no rows, which is
how it says what it is valid over before anything is evaluated.

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


Weights, and integrating a field
--------------------------------

Section 3 says an integration weight is computed from the connectivity
and never imported, so this package computes it:

    Mestra.compute_weights!(ds, s, :node)     # or :cell
    Mestra.integrate(ds, "pressure")

`compute_weights!` adds an array with role `weight`, named `weight` at
both locations unless you name it, carrying the units of the
coordinates raised to the support's dimension and marked `recomputed`,
which is what W06 asks for. A cell gets its own measure -- the length
of a line, the area of a triangle, a quadrilateral or a polygon, the
volume of a tetrahedron, a hexahedron, a wedge or a pyramid -- and a
node gets the lumped share of the cells it belongs to. An axis support
has no cells, so its nodes share the intervals between them, which is
the same rule with the intervals as the cells. A quadratic cell's
measure is an integral over its curved geometry: it is refused, by
name, rather than approximated silently. Weights follow the
coordinates: a parametric family gets one instance per member and a
moving mesh one per row.

`integrate` uses the weight array at the slot's location by default,
computes one on the fly and says so when the file has none, and takes
`weight = "<name>"` to use a particular one.

    Mestra.integrate(ds, "pressure")
    Mestra.integrate(ds, "pressure", by = "region", region = "inlet")


Post-processing that only needs the format
------------------------------------------

Written against the roles, `varies`, the labels and their category
tables, the weight role, the time key with its trajectory group, and
the unit of generalisation, and against nothing else. Each takes the
dataset, then the slot, by name or as the object:

    Mestra.field_statistics(ds, "pressure")
    Mestra.field_statistics(ds, "pressure", by = "region")
    Mestra.integrate(ds, "pressure")
    Mestra.time_series(ds, "u"; node = 3, trajectory = "r000")
    Mestra.grouped_split(ds, ["train" => 0.8, "test" => 0.2]; seed = 0)
    Mestra.split_leaks(ds)

`field_statistics` gives one entry per row and component, as a
`NamedTuple` of `row`, `component`, `n`, `n_finite`, `mean`, `std`,
`min` and `max`. With `by` it gives one entry per region as well, and
the entry carries a column **named after the label you grouped by** --
`region = "inlet"` for `by = "region"`, `cad_face_id = "11"` for
`by = "cad_face_id"` -- whose value is the category name where the
label has a table and the value itself where it has none. With no
`by` there is no such column at all.

`grouped_split` moves whole units of generalisation, so the split is a
generalisation test. Every named part gets at least one unit, however
the fractions fall, as long as there are at least as many units as
parts; fewer units than parts is refused rather than answered with an
empty part. `seed` defaults to 0 and is the whole of the randomness,
so writing the seed down is writing the split down. The fractions may
be a vector of pairs, a `Dict` or a `NamedTuple`, and the parts are
filled in name order whatever order they were given in, so the same
fractions and seed always give the same split. A file that names no
unit of generalisation is refused rather than guessed at.

`split_leaks` reports the units the file's own `split` key places on
more than one side, which is what W01 warns about. An empty
dictionary means the split is a generalisation test and nothing else:
a file with no split key, or no unit of generalisation, is refused
rather than answered with the same empty dictionary.


The public API
--------------

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

`DimArray`, `dimnames`, `permute`, `at` and `MestraError` are exported;
everything else is reached as `Mestra.name`, because `read`, `write`
and `values` would otherwise shadow the ones in Base.


Running the tests
-----------------

    julia --project=julia -e 'using Pkg; Pkg.test()'

The suite runs the whole conformance corpus: the validator's outcome
for all 70 cases against expected.json, every probe, every support id,
every codec round trip, every worked evaluation, and a read, write and
compare of every case that must validate cleanly. It also opens two
written files with NCDatasets to check that they are netCDF-4 files
with the dimension names the specification asks for.
