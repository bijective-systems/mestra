mestra for Python
=================

A reader, a writer, a validator and a little post-processing for the
mestra format: rows of observations over design parameters, operating
conditions and time; scalar quantities and fields on shared supports;
and the claim that rows are index-aligned, stated so that a reader
can check it.

The format itself is `../SPEC.md`. Two files are listed object by
object in `../docs/example.md`, and the conformance corpus every
implementation runs is `../vectors/`. The specification and that
corpus define the format between them; no implementation is the
reference, this one included.

The names, the argument order, the defaults and the messages are the
same in all four languages, and `../docs/api-conventions.md` is where
they are decided. Where Python differs from MATLAB, Julia or C++ it
is in syntax only: a keyword argument for a name-value pair, a method
on the object the call is about for an explicit first argument.

Runtime dependencies are numpy and h5py, and nothing else. netCDF4
and h5netcdf are optional and only used by checks; xarray is optional
and only used by one adapter.


Install
-------

    pip install -e python/

That gives you the `mestra` package and the `mestra` command. To run
the tests you also need pytest:

    python -m pytest python/tests


Five minutes
------------

Open a file. Nothing is read from disk until you ask for a value, so
opening a large file is cheap: an open reads attributes, dataspaces,
link types and dimension-scale structure, and a category table in
full, and never a slot's data or a dataset inside a callable's
dictionary. It costs about a second on a file with a thousand
columns, and grows with the number of them and not with its square.

    import mestra

    ds = mestra.read("run.mes")
    print(ds)                       # rows, keys, supports, aligned
    print(ds.n_rows, ds.aligned)
    print(ds.key_names())           # the file's key order

Look at a key. Every key carries a role, and a design, condition or
time key carries units and may carry the bounds it is valid over.

    mach = ds.keys["mach"]
    print(mach.role, mach.units, mach.lower, mach.upper)
    print(mach.values[:5])

Read a field. Every array knows the name of each of its axes, so a
value is found by name and never by axis position. A reader in a
column-major language may hand the same array back in the reverse
order; what both agree on is the value at (row 1, node 3, component
0).

    pressure = ds.supports["s0"].node_arrays["pressure"]
    print(pressure.dims)            # ('row', 'node', 'component')
    print(pressure.values.at(row=1, node=3, component=0))

The coordinates are `ds.supports["s0"].coordinates`, because a
support has exactly one coordinates array and it is part of what the
support is; every other array is in `node_arrays` or `cell_arrays`.

Read one row range without touching anything else:

    part = pressure.read(slice(0, 4))
    print(part.shape, part.dims)

Check a file:

    report = mestra.validate("run.mes")
    print(report.ok, report.error_ids, report.warning_ids)
    for finding in report.findings:
        print(finding)          # E11 /scalars/cl: a scalar carries...

Close it when you are done, or use it as a context manager:

    with mestra.read("run.mes") as ds:
        ...

`mestra.read(path, lazy=False)` reads every value at once and closes
the file for you.

A callable's dictionary is a value like any other: `ds.callables`
knows every id as soon as the file is open, and reads one dictionary
the first time you ask for that callable. `lazy=False` asks for all
of them before it closes the file, so a callable you got that way
works afterwards.


Build a file from arrays
------------------------

Eleven calls reach a complete file. The dimensions, the bounds, the
component axis, the support id and the alignment flag are filled in.

    import numpy as np
    import mestra

    xy = np.array([[0., 0.], [1., 0.], [2., 0.],
                   [0., 1.], [1., 1.], [2., 1.]])

    ds = mestra.Dataset(writer="my tool 1")
    ds.add_key("mach", [0.40, 0.80], role="condition", units="1",
               lower=0.1, upper=0.9)
    ds.add_category_table("member", ["wing_a", "wing_b"])
    ds.add_key("member", [0, 1], role="group", category="member")
    ds.set_generalisation_group("member")
    ds.add_scalar("cl", [0.25, 0.55], units="1")

    support = ds.add_support(
        "s0",
        coordinates=np.stack([xy, xy * [1.5, 1.0]]),
        varies="group:member",
        cells=(np.array([9, 9]),                  # two quadrilaterals
               np.array([0, 4, 8]),
               np.array([0, 1, 4, 3, 1, 2, 5, 4])))
    support.add_node_array("pressure",
                           [[101., 102., 103., 104., 105., 106.],
                            [201., 202., 203., 204., 205., 206.]],
                           units="Pa", dims=("row", "node"))
    ds.add_category_table("region", ["inlet", "outlet"])
    support.add_cell_array("region", [0, 1], role="label",
                           category="region", dims=("cell",))

    mestra.write(ds, "built.mes")

The calls, in the order the conventions give them:

    add_key(name, values, role, units)
    add_scalar(name, values, units)
    add_category_table(name, entries)
    set_generalisation_group(name)
    add_support(name, kind, coordinates, cells, units)
    support.add_node_array(name, values, units, dims)
    support.add_cell_array(name, values, units, dims)
    add_callable(id, callable)
    support.add_callable_slot(name, units, callable, output)
    ds.add_callable_slot(name, units, callable, output)

Everything after `values` is a keyword argument, which is Python's
spelling of the name-value pairs the other languages use; the order
is the order above. The support is the receiver of the two array
builders, which is Python's spelling of the support-first argument
order.

### Naming your array's axes

`dims` names the axes of the array you are passing, in your own axis
order. The builder reads `varies` off it, reads the component count
off the component axis or adds one of length one, and stores the
array in the order section 19 requires.

    support.add_node_array("pressure", p, units="Pa",
                           dims=("row", "node"))
    support.add_node_array("velocity", v, units="m s-1",
                           dims=("component", "node"))

The names are `row`, `group:<k>`, `draw`, `node` or `cell`, and
`component`. Name every axis your array has, and no more: the
component axis is the one you may leave out, and the builder adds it
with length one. A `varies` that disagrees with `dims` is refused at
build time:

    >>> support.add_node_array("p", p, units="Pa",
    ...                        dims=("row", "node"), varies="none")
    MestraError: E04: p: varies says 'none' and dims says 'row';
    change one of them

Without `dims`, `varies` is worked out from the shape by finding the
axis whose length is the support's, and a shape that fits two
readings is refused rather than guessed.

### A few more things worth knowing

  - `role` is one of the roles of the specification: design,
    condition, time, categorical, group, split, id or status for a
    key, and coordinates, field, label, weight, normal or derived for
    an array;
  - a design, condition or time key carries `units`; a categorical,
    group, split, id or status key carries `category`, naming a table
    `add_category_table` has already written, instead. The ids are
    the positions of the entries in that table, counting from 0;
  - `categories=[...]` on a key or a label is sugar for exactly
    `add_category_table(<the name>, [...])` and `category=<the
    name>`, and nothing else. `add_category_table` is the way the
    documents show, because it is the way in all four languages;
  - the unit of generalisation is a property of the dataset:
    `set_generalisation_group(name)`, naming a key of role group.
    `add_key(..., generalisation=True)` is sugar for that call;
  - the bounds of a design, condition or time key default to the
    observed finite range, so that the same arrays give the same file
    in every language and W04 and W08 can be decided on it. Pass
    `lower` and `upper` to declare a wider domain of validity
    instead, or `bounds=None` to leave them out;
  - the status words of section 3 are `converged`, `failed` and
    `partial`. A producer may add its own, and only `converged` means
    the row is fit for modelling: anything else is W02;
  - a support is `kind="mesh"` with `cells=`, `kind="axis"` for nodes
    along one coordinate and no cells, or `kind="none"` for a file of
    scalars. The kind follows from what you pass when you leave it
    out;
  - `trajectory_group=` on a time key names the group key whose
    categories are the trajectories (section 7); without it a
    transient file is a pile of rows;
  - the component axis is always present, with length 1 for a
    single-component quantity, and it is added for you.

### What a mistake says

Every builder refuses at build time, naming the rule of section 14
and the argument to change, anything the validator would refuse in
the file:

    >>> ds.add_key("mestra_mach", [1.0], role="condition", units="1")
    MestraError: E33: mestra_mach: names beginning with mestra_ are
    reserved for the container

    >>> support.add_node_array("pressure", p)
    MestraError: E11: pressure: a field carries units; pass units=
    ("1" for a dimensionless one)

    >>> support.add_node_array("p", np.zeros((6, 6)), units="Pa")
    MestraError: E04: p: a node array of shape (6, 6) on a support of
    6 nodes is either (node, component) or (row, node); say which
    with varies

`write` validates before it writes and refuses on any error, with the
findings; warnings do not stop it. A writer that emits a file its own
validator rejects is the one failure mode an open format cannot
afford, because the file outlives the session that made it.
`mestra.write(ds, path, check=False)` writes whatever is there, which
is how a test makes a file to be refused.

Everything a file said about its own layout survives being read and
written again: a chunk shape that is not the default, a compression
filter, a string column wider than its longest entry, an attribute
this version does not know, and a group it must not interpret.


Callables
---------

Any slot may hold stored data or name a callable that produces it. A
callable is four things and nothing more: `__call__(keys)`,
`to_dict()`, `from_dict(d)`, and an optional one-line `__repr__`.
Everything else it knows lives inside its own dictionary and is its
own business.

`affine` is the one type this package defines, so that the protocol,
the codec and evaluation can be tested with no proprietary model:

    m = mestra.Affine(
        ["mach", "alpha"],
        {"cl": {"A": [[2.0, 0.1]], "b": [0.05], "shape": []}})
    m({"mach": [0.5], "alpha": [4.0]})["cl"]      # 1.45

Evaluating a file on a keys table gives a file with the same slots,
now holding data. Distillation is that operation on a grid, and what
comes out is a plain data file with no callables in it:

    with mestra.read("model.mes") as ds:
        table = {"mach": np.linspace(0.1, 0.9, 9),
                 "alpha": np.zeros(9)}
        out = mestra.evaluate(ds, table)
    mestra.write(out, "table.mes")

Writing a callable file is two calls: store the callable under an id,
then give each slot it serves. A callable slot holds no values, so it
says how many components it has.

    ds = mestra.Dataset(writer="my tool 1")
    ds.add_key("mach", [], role="condition", units="1",
               lower=0.1, upper=0.9)       # zero rows: the domain
    ds.add_key("alpha", [], role="condition", units="degree",
               lower=0.0, upper=8.0)
    ds.add_callable("m1", m)

    support = ds.add_support("s0", coordinates=xy, cells=cells)
    support.add_callable_slot("pressure", units="Pa", callable="m1",
                              output="pressure", components=1)
    ds.add_callable_slot("cl", units="1", callable="m1", output="cl")

    mestra.write(ds, "model.mes")

`callable` is the id you gave `add_callable`, or the object itself;
`output` names which of the callable's outputs fills this slot, and
defaults to the slot's name. A slot naming a callable the dataset
does not hold is refused at build time with E14.

Adding a type of your own is a subclass and one registration call:

    class Lookup(mestra.Callable):
        type = "lookup"

        def __call__(self, keys): ...
        def to_dict(self): ...

        @classmethod
        def from_dict(cls, d): ...

    mestra.register_callable(Lookup)

A file whose callable type you do not have still reads: its
dictionary comes back whole, it can be copied and written out
unchanged, and calling it is refused rather than guessed. An empty
list of strings in one comes back as an empty numpy string array and
not as `[]`, because section 25 gives `[]` -- "an empty list with no
element type known" -- the empty float64 dataset, and the two must
stay apart across a round trip.


Weights and integration
-----------------------

Section 3 says a weight array is computed from the connectivity and
never imported, so this package computes one:

    weights = mestra.compute_weights(support, "node")
    weights = mestra.compute_weights(support, "cell")

The array carries the role `weight`, the units of the coordinates
raised to the dimension of the cells, and the `recomputed` flag, and
is called `weight` at both locations unless you pass `name=`.
Calling it again recomputes it.

A cell's measure is the measure of the simplices it decomposes into,
in the node order section 20 fixes: length for a line, area for a
triangle, a polygon and a quadrilateral, volume for a tetrahedron, a
hexahedron, a wedge and a pyramid, and the counting measure for a
vertex. The quadratic types of section 20 are refused by name,
because the straight cell through a curved cell's corners is not the
cell; so is a support whose cells are not all of one dimension,
because a length and an area do not add up. A node's weight is its
lumped share of the cells that touch it. An `axis` support has no
cells, so its nodes are the ends of the segments between them, which
is the trapezoid rule over its own coordinate.


Post-processing
---------------

Four operations that need nothing but the format, so they run the
same on solver output and on a model's predictions.

    from mestra import post

    stats = post.field_statistics(ds, "pressure")
    stats = post.field_statistics(ds, "pressure", by="region")
    print(stats.as_text())              # lines
    for row in stats.as_table():        # a dictionary per row
        print(row["region"], row["mean"])

    total = post.integrate(ds, "pressure")
    inlet = post.integrate(ds, "pressure", by="region",
                           region="inlet")

    times, values = post.time_series(ds, "u", 12, "r001")

    parts = post.grouped_split(ds, {"train": 0.8, "test": 0.2},
                               seed=0)

`field_statistics` takes a slot by name and a label by name, and the
output is keyed by the label's own name: `by="cad_face_id"` gives you
a column called `cad_face_id`, and no `by` gives you no grouping
column at all. A scalar works too, and is reported over the rows,
grouped by a categorical, group, split or status key.

`integrate` uses the weight array at the slot's location on its
support. When the file has none it computes one from the
connectivity, says so with a warning and does not store it;
`mestra.compute_weights` stores one. `weight=` names another array to
use instead.

The split moves whole units of generalisation, so no case lands on
both sides of it, and every named part gets at least one unit
whenever there are at least as many units as parts. `seed` defaults
to 0, so that two people who write down the call get the same split.
A file that names no unit of generalisation cannot be split this way
and the call is refused, because a split by row would score a model
on a case it has already seen; and fewer units than parts is refused
too, rather than handing back an empty test set.
`post.split_leaks(ds)` says which units a split already in the file
places on both sides.

A name that is not in the file is your mistake and not the file's, so
it is raised with no rule identifier and lists what is there instead.
The rule identifiers stay for findings about a file, so that catching
E05 catches a malformed file and not a typo.


The command line
----------------

A finding prints as `<id> <path>: <message>`, and a run ends with
`<n> error(s), <m> warning(s)`. Every language's tool prints that.

    $ mestra validate run.mes
    0 error(s), 0 warning(s)

    $ mestra validate suspect.mes
    E11 /supports/s0/node_arrays/pressure: a field carries units
    1 error(s), 0 warning(s)

    $ mestra info run.mes
    run.mes
      mestra/0 written by 'a tool 1' on 2026-09-19T00:00:00Z
      2 row(s), aligned, generalisation unit member
      keys
        mach             condition    units 1  bounds [0.1, 0.9]
        member           group        categories member (wing_a, ...)
      scalars
        cl               (row) 2      scalar  units 1  data
      support s0  mesh, 6 node(s), 2 cell(s)
        id 96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a1...
        coordinates      (group:member, node, component) 2x6x2 ...
        pressure         (row, node, component) 2x6x1  field ...
        region           (cell, component) 2x1  label  data

`info` prints, for every key, its name, role, units, bounds,
category, trajectory group and parent; for every support, its kind,
counts and id; and for every slot, its shape under the name of each
axis, its units, its source, and for a callable slot the callable's
id and the output it takes.

`validate` exits non-zero when a file has an error, so it fits in a
build. `--quiet` prints the summary line alone. With several files
each one's findings are introduced by its name, because a finding's
own path is a path inside a file, and the summary counts the run.


What the validator reports
--------------------------

Errors mean the file is rejected; warnings mean it is accepted and
the reader must say so. Both are the identifiers of the
specification's validator section, and they are stable: a rule is
never renumbered within a major version and a retired rule's
identifier is never reused.

    report = mestra.validate("run.mes")
    report.ok                # no error
    report.error_ids         # ['E11']
    report.warning_ids       # ['W03', 'W05']
    report.errors[0].where   # the object the finding is about

One object draws a rule once. A rule that could be broken on every
row - W02, W03, W04, and W01 and E09, which are per unit and per
trajectory - is reported once with the count and the first three:

    W02 /keys/status: 5 rows of 12 with a status other than converged
        (the first is 'failed'), at row 1, 3, 4 and 2 more; section
        3's words are converged, failed, partial, and a row that is
        not converged is left out of modelling unless it is asked for

`mestra.validate` also takes a dataset that is already in memory. It
then checks everything except the byte-level rules, which are about a
file and not about a dataset. It reads the key and scalar columns, so
that W01, W02, W03 and W04 say the same thing about a dataset as they
do about the file; it does not read the arrays on a support, because
a dataset opened lazily should not have every field pulled into
memory by a check.


The public API
--------------

    read(path, lazy=True,           a Dataset, reading nothing yet;
         strict=True)               strict refuses a file whose
                                    storage it cannot vouch for
    write(dataset, path,            a file laid out as the spec says,
          check=True)               validated first
    validate(path_or_dataset)       a Report of findings by rule id
    evaluate(dataset, keys_table)   the same slots, holding data
    compute_weights(support,        the measure of section 3, from
                    location)       the connectivity
    support_ids(path)               the digest of every support

    Dataset      keys, scalars, categories, supports, callables,
                 row_support, notes, n_rows, aligned, and the calls
                 that build one: add_key, add_scalar,
                 add_category_table, set_generalisation_group,
                 add_support, add_callable, add_callable_slot,
                 set_row_support
    Support      kind, n_nodes, n_cells, the cell arrays, the
                 coordinates, node_arrays, cell_arrays, support_id,
                 add_node_array, add_cell_array, add_callable_slot
    Key          role, units, lower, upper, category,
                 trajectory_group, parent, values, read(rows)
    ScalarSlot   units, source, statistic, of, quantile, values,
                 read(rows)
    ArraySlot    the same, plus role, varies, components, location,
                 category, recomputed, derived_from, recipe,
                 reference, dims
    NamedArray   values, dims, at(**names), transpose(*names)
    Callable     the protocol; Affine, register_callable,
                 callable_types, keys_table
    Report       errors, warnings, findings, error_ids,
                 warning_ids, unclassified (E40 and E41), ok
    MestraError  raised with the rule id it breaks, or with none when
                 the mistake is the caller's and not the file's

    mestra.post  field_statistics, integrate, time_series,
                 grouped_split, split_leaks, compute_weights
    mestra.units parse, is_parseable, same_dimensions

The coordinates of a support are `support.coordinates`, and every
other array is in `support.node_arrays` or `support.cell_arrays`.

`Dataset.to_xarray()` is there too, when xarray is installed.


Files you did not write
-----------------------

A reader opens files from other people, and a file is not a promise.
This one is written to treat every file as untrusted input: whatever
is wrong with it, the answer is a finding or a refusal that names the
rule, never a crash, a hang, or an allocation that takes the machine
with it.

What it refuses, and what it says:

  - it follows no link. A soft link, a cyclic one, and an external
    link that would open another file are each E40 and stepped over.
    Listing a group by name is the one traversal a cycle cannot
    break, so that is how members are found;
  - it walks no deeper than `mestra.limits.MAX_DEPTH` into groups, a
    callable's dictionary, or a group it must copy without
    interpreting, and anything deeper is E41;
  - an eager read materialises no more than
    `mestra.limits.MAX_READ_ELEMENTS`, which is 2**31 as section 29
    says to state. A dataset that declares a thousand billion
    elements is opened, described and refused with E41; a lazy read
    and a row range of it are not subject to that limit, so the same
    file can be readable one way and E41 the other. The validator
    uses a far smaller budget of its own and leaves a dataset above
    it unchecked rather than reading it, because section 14 reserves
    the size case for an eager read;
  - it reads filters from the file's own creation property list, so
    a filter with more client-data values than a library expects, or
    an identifier no library has, is E29 and not silence;
  - an attribute stored as an array where the format has a scalar,
    or a string that is not UTF-8, is a rule (E19, E26) and the file
    still reads;
  - the validator catches per object: something the library will not
    convert is E41 with its path, and every rule after it is still
    reported;
  - a file that will not open at all is E01, from `validate` as a
    report and from `read` as a `MestraError`.

Two rules of section 14 are about the reader rather than the format.
**E40** is a link that is not a hard link - a soft link, whether it
resolves, dangles or loops, and an external link - which this reader
never follows. **E41** is an object it could not read: a malformed
header or attribute, a group or a dictionary nested past the depth
cap, or, on an eager read only, a dataset above the stated maximum
element count. Both are ordinary errors; `report.unclassified` is
the two of them together, for a caller that wants to tell what the
file says from what the reader could not do with it. The same
findings from opening a file are on `dataset.problems`, and
`mestra.validate(dataset)` repeats them; what could not be copied is
named in `dataset.lossy`, which `write` refuses rather than writing
the file short, whatever `check` says.

`read` refuses a file that breaks one of the rules it cannot vouch
for what it would return under - E01, E16, E19, E25, E26, E29, E30,
E40, E41, which are `mestra.reader.REFUSED` - and raises a
`MestraError` naming the first of them. Everything else, a role it
does not know or missing units, is the file describing itself badly
while its values still mean what they say, so the file opens. Pass
`strict=False` to take whatever could be read anyway; the findings
are on `dataset.problems` either way. The check reads no more than
`limits.MAX_OPEN_ELEMENTS` of any one dataset, so opening a file
costs a check and not a read.

The limits are module attributes with reasons beside them in
`mestra/limits.py`, and a caller who knows what it is doing can
raise them.

`vectors/hostile` is the shared subset of section 30, fifteen files
with a looser contract: at least the required ids, inside ten
seconds, with every entry point refusing rather than returning.
Generate its two deep files first, as vectors/README.md says:

    python vectors/generate.py --hostile-deep

`python/tests/hostile/` holds this package's own files as well, and
the script that made them. Each is driven in a subprocess with a
timeout, because the only defence against a hang inside a C library
is a process that can be killed. One case is not committed: thirty
thousand nested groups is nine megabytes however it is stored, and
`make_hostile.py --deep` writes it on demand.


Tests
-----

    python -m pytest python/tests

The suite runs the whole conformance corpus: the validator's
outcomes by rule identifier for every case, every probe compared bit
for bit, every support id, every codec round trip, every worked
evaluation, a read-write-compare of every valid case under the
structural equality rule, and an open of everything this package
writes with a netCDF-4 reader. Plus the builder, the weights against
shapes whose measure is known by hand, the post-processing, the
validator's own output shape, the command line and the units parser.

    ruff check python
    mypy --config-file python/pyproject.toml

Licence: Apache-2.0, as the rest of the code in this repository.
