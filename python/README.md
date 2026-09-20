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
opening a large file is cheap.

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

Read one row range without touching anything else:

    part = pressure.read(slice(0, 4))
    print(part.shape, part.dims)

Check a file:

    report = mestra.validate("run.mes")
    print(report.ok, report.error_ids, report.warning_ids)
    for finding in report.errors + report.warnings:
        print(finding)

Close it when you are done, or use it as a context manager:

    with mestra.read("run.mes") as ds:
        ...

`mestra.read(path, lazy=False)` reads every value at once and closes
the file for you.


Build a file from arrays
------------------------

Eight calls reach a complete file. The dimensions, the bounds, the
component axis, the support id and the alignment flag are filled in.

    import numpy as np
    import mestra

    xy = np.array([[0., 0.], [1., 0.], [2., 0.],
                   [0., 1.], [1., 1.], [2., 1.]])

    ds = mestra.Dataset(writer="my tool 1")
    ds.add_key("mach", [0.40, 0.80], role="condition", units="1",
               lower=0.1, upper=0.9)
    ds.add_key("member", [0, 1], role="group",
               categories=["wing_a", "wing_b"], generalisation=True)
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
                           units="Pa")
    support.add_cell_array("region", [0, 1], role="label",
                           categories=["inlet", "outlet"])

    mestra.write(ds, "built.mes")

A few things worth knowing:

  - `role` is one of the roles of the specification: design,
    condition, time, categorical, group, split, id or status for a
    key, and coordinates, field, label, weight, normal or derived for
    an array.
  - a categorical, group, split or status key stores category ids,
    which are the positions of the entries in its table, and
    `categories=[...]` writes that table for it;
  - the bounds of a design, condition or time key default to the
    observed range; pass `lower` and `upper` to declare the domain
    the file is valid over instead, or `bounds=None` to leave them
    out;
  - an array's `varies` is worked out from its shape when it is not
    given, by finding the axis whose length is the support's. Say
    `varies="group:member"` for an array with one instance per
    member, since no shape can tell that apart from a row axis;
  - the component axis is always present, with length 1 for a
    single-component quantity, and it is added for you.

A mistake names the rule of the specification that it breaks:

    >>> ds.add_key("mestra_mach", [1.0], role="condition", units="1")
    MestraError: E33: mestra_mach: names beginning with mestra_ are
    reserved for the container

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
unchanged, and calling it is refused rather than guessed.


Post-processing
---------------

Four operations that need nothing but the format, so they run the
same on solver output and on a model's predictions.

    from mestra import post

    stats = post.field_statistics(ds, "pressure")
    stats = post.field_statistics(ds, "pressure", label="region")
    for line in stats.as_table():
        print(line)

    total = post.integrate(ds, "pressure", weight="area")
    inlet = post.integrate(ds, "pressure", weight="area",
                           label="region", region="inlet")

    times, values = post.time_series(ds, "u", node=12,
                                     trajectory="r001")

    parts = post.grouped_split(ds, {"train": 0.8, "test": 0.2},
                               seed=0)

The split moves whole units of generalisation, so no case lands on
both sides of it. A file that names no unit of generalisation cannot
be split this way and the call is refused, because a split by row
would score a model on a case it has already seen.
`post.split_leaks(ds)` says which units a split already in the file
places on both sides.


The command line
----------------

    $ mestra validate run.mes
    run.mes: no error and no warning

    $ mestra validate suspect.mes
      E11  /supports/s0/node_arrays/pressure: a field carries units
    suspect.mes: 1 error(s), 0 warning(s): E11

    $ mestra info run.mes
    run.mes
      mestra/0 written by 'a tool 1' on 2026-09-19T00:00:00Z
      2 row(s), aligned, generalisation unit member
      keys
        mach             condition    units 1  bounds [0.1, 0.9]
        member           group        categories member (wing_a, ...)
      scalars
        cl               (row)        scalar  units 1  data
      support s0  mesh, 6 node(s), 2 cell(s)
        id 96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a1...
        coordinates      (group:member, node, component) 2x6x2 ...
        pressure         (row, node, component) 2x6x1  field ...
        region           (cell, component) 2x1  label  data

`validate` exits non-zero when a file has an error, so it fits in a
build.


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

`mestra.validate` also takes a dataset that is already in memory. It
then checks everything except the byte-level rules, which are about a
file and not about a dataset.


The public API
--------------

    read(path, lazy=True)           a Dataset, reading nothing yet
    write(dataset, path)            a file laid out as the spec says
    validate(path_or_dataset)       a Report of findings by rule id
    evaluate(dataset, keys_table)   the same slots, holding data
    support_ids(path)               the digest of every support

    Dataset      keys, scalars, categories, supports, callables,
                 row_support, notes, n_rows, aligned, and the calls
                 that build one: add_key, add_scalar, add_categories,
                 add_support, add_callable, set_row_support
    Support      kind, n_nodes, n_cells, the cell arrays, the
                 coordinates, node_arrays, cell_arrays, support_id,
                 add_node_array, add_cell_array
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
    Report       errors, warnings, error_ids, warning_ids, ok
    MestraError  raised with the rule id it breaks

    mestra.post  field_statistics, integrate, time_series,
                 grouped_split, split_leaks
    mestra.units parse, is_parseable, same_dimensions

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
    link that would open another file are each reported and stepped
    over. Listing a group by name is the one traversal a cycle
    cannot break, so that is how members are found;
  - it walks no deeper than `mestra.limits.MAX_DEPTH` into groups, a
    callable's dictionary, or a group it must copy without
    interpreting;
  - it materialises no more than `mestra.limits.MAX_READ_ELEMENTS`
    in one call. A dataset that declares a thousand billion elements
    is opened, described and refused; a row range of it is an
    ordinary read;
  - it reads filters from the file's own creation property list, so
    a filter with more client-data values than a library expects, or
    an identifier no library has, is E29 and not silence;
  - an attribute stored as an array where the format has a scalar,
    or a string that is not UTF-8, is a rule (E19, E26) and the file
    still reads;
  - the validator catches per object: something the library will not
    convert costs one finding with its path, and every rule after it
    is still reported;
  - a file that will not open at all is E01, from `validate` as a
    report and from `read` as a `MestraError`.

Findings the specification has no identifier for carry the rule
`reader` and appear in `report.unclassified`; `report.ok` is false
while any remain, because something in the file could not be
checked. The same findings from opening a file are on
`dataset.problems`, and what could not be copied is named in
`dataset.lossy`, which `write` refuses rather than writing the file
short.

The limits are module attributes with reasons beside them in
`mestra/limits.py`, and a caller who knows what it is doing can
raise them.

`python/tests/hostile/` holds the files this is tested against, and
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
writes with a netCDF-4 reader. Plus the post-processing, the command
line, the units parser and the builder.

    ruff check python
    mypy --config-file python/pyproject.toml

Licence: Apache-2.0, as the rest of the code in this repository.
