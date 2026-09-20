mestra in C++
=============

A reader, a writer and a validator for the `.mes` format of SPEC.md,
with the integration weights the format says a writer computes rather
than imports, in plain C++17 over the HDF5 C API and `hdf5_hl`. No
other dependency: the SHA-256 of section 24 is written out here, and
the tests read the conformance corpus with a small Python script
rather than a framework.

SPEC.md is the normative document and `vectors/` is the conformance
corpus. Nothing in this directory is the reference; when this code and
the specification disagree, the specification is right.


Building
--------

You need CMake, a C++17 compiler, and HDF5 with its headers and the
high-level `H5DS` dimension-scale API. Point `HDF5_ROOT` at the HDF5
installation:

    cmake -S cpp -B cpp/build -DHDF5_ROOT="$HDF5_ROOT"
    cmake --build cpp/build -j

That gives you `libmestra` and the `mestra-cli` tool in `cpp/build`.

To run the tests you also need a Python 3 with `h5py`, which the
conformance driver uses for the read-write comparison of section 30.
If the Python CMake picks up is not that one, name it:

    cmake -S cpp -B cpp/build -DHDF5_ROOT="$HDF5_ROOT" \
          -DPython3_EXECUTABLE="$(which python3)"
    cmake --build cpp/build -j
    ctest --test-dir cpp/build --output-on-failure

The suite has six tests. `unit` is pure C++ checks: the SHA-256
vectors and the three worked digests of section 24, the units parser,
the dictionary codec's value types, the worked affine example of
section 27, one dataset built from plain vectors and validated, and
the conventions of `docs/api-conventions.md` one rule at a time.
`corpus` runs every case of `vectors/cases` through `mestra-cli`.
`private_roundtrip` builds a file whose `/private` holds subgroups,
datasets, filters, dimension scales and dtypes the public part
forbids, and requires the round trip to be structurally equal, which
no corpus case covers. `metadata_open` puts the metadata open of
conventions section 7 against the whole read on every file there is,
and requires them to name the same structural rules and the open to
name nothing the read does not. `shared_hostile` runs the corpus's own hostile
subset and `hostile` this implementation's; both are described at the
end of this file.

Three corpus files are generated rather than committed, because of
their size: the two deep hostile files and `cases/wide_keys`, whose
4200 row-dimensioned datasets all attach to one `row` scale. Run

    python vectors/generate.py --hostile-deep --wide

before `ctest`, once, and not again while a test is reading
`vectors/`.

The library is compiled with `-Wall -Wextra -Wpedantic -Wshadow
-Wconversion -Wsign-conversion` and builds warning-free, and with
`-ffp-contract=off` so that no multiply and add are fused into one
rounding step. Section 27 fixes the summation order of the affine
callable and the corpus compares float64 results bit for bit, so the
contraction has to be off for the last bit to come out right.


Five minutes with the tool
--------------------------

    mestra-cli validate FILE
        one finding per line, as "<id> <path>: <message>", and then
        the summary line "<n> error(s), <m> warning(s)". That is the
        form docs/api-conventions.md section 5 fixes for the tool of
        every language, so the same file through `mestra validate` and
        through this reads the same way. A fault that no rule of
        section 14 covers carries no identifier and is printed as
        "! <path>: <why>", so a file is never reported clean because
        the thing wrong with it has no name. It exits 1 when the file
        is rejected and 0 otherwise, so warnings alone still exit 0.

            E11 /scalars/power: a scalar with no `units`
            W02 /keys/status: 7 row(s) whose status is not converged;
                rows 5, 6, 7
            1 error(s), 1 warning(s)

        A rule that could fire once per row -- W02, W03, W04 -- is
        reported once with the count and the first three rows, and
        never once per row.

    mestra-cli validate --ids FILE
        the identifiers alone, "E <id>" and "W <id>" one per line,
        which is what a shell script wants.

    mestra-cli validate --metadata FILE
        the same pass restricted to what a metadata open reads
        (conventions section 7): attributes, dataspaces, link types,
        dimension-scale structure, and of datasets only a category
        table and /row_support. It answers "would `info` and
        `read_header` refuse this file, and with which identifiers"
        without reading a slot to find out. `--ids` combines with it.

    mestra-cli read FILE
        check the file, refuse it with the findings if the validator
        rejects it, and otherwise read the whole of it and
        say what came back: the row count, how
        many keys, scalars, supports and callables, and how many array
        values.

    mestra-cli info FILE
        what the file holds, in the fields section 5 of the
        conventions lists: for every key its name, role, units,
        bounds, category, trajectory group and parent; for every
        support its kind, its counts and its id; for every slot its
        shape with the axes named, its units, its source, and for a
        callable slot the callable id and the output.

            key time role=time units=s lower=0 upper=9
                trajectory_group=trajectory
            support s0 kind=mesh n_nodes=8 n_cells=3 support_id=96df...
              node_array pressure (row, node, component) 6x8x1
                role=field varies=row components=1 units=Pa source=data

        It checks the file first and refuses it the way `read` does;
        past that it reads attributes and dataspaces only, so it opens
        a large file as fast as a small one. `validate --metadata`
        says what that open alone decides.

    mestra-cli integrate FILE SLOT [WEIGHT]
        one slot integrated over its support, one value per row and
        component. It says which weight array it used and whether it
        had to compute one, because the file carried none.

    mestra-cli stats FILE SLOT [BY]
        count, missing, minimum, mean, maximum and deviation for one
        slot, grouped by the label BY when one is named. The grouping
        column is headed with the label's own name.

    mestra-cli probe FILE SLOT ROW NODE COMPONENT [DRAW]
        one stored value. Any index may be `-` when the slot has no
        such axis, and any index may instead be given by name:

            mestra-cli probe f.mes /supports/s0/coordinates \
                instance=1 node=2 component=0

        The axis names are row, instance, draw, node, cell,
        cell_plus_one, component and index. A float64 slot prints
        "%.17e" and an integer slot plain decimal, which is the form
        section 30 asks a probe for.

    mestra-cli support-id FILE SUPPORT
        the digest of section 24, computed from the stored arrays and
        not read from the attribute.

    mestra-cli roundtrip IN OUT
        read IN and write OUT. Both ends check: the read is strict and
        the write validates, so a round trip that finishes is a round
        trip between two files that validate.

    mestra-cli evaluate FILE KEYS.csv OUT
        evaluate every callable slot on a keys table and write the
        result, and say what was written and how many rows. KEYS.csv
        has one line of column names and one line per table row.

    mestra-cli rows FILE SLOT BEGIN END
        one slot for the half-open row range, reading no other slot
        and no row outside the range (section 29).

    mestra-cli cost FILE [SLOT]
        seconds for a metadata open, a validation and one lazy row
        read of SLOT, each the library call alone and all three in one
        process. `info` and `read` validate before they print, which
        is the tool's policy and not the library's cost, so this is
        the command to time a file with. The conformance driver prints
        it for `wide_keys`.

            open 3.047
            validate 1.991
            rows 0.056
            findings 0 0

    mestra-cli dict-dump FILE CALLABLE
        a callable's dictionary, one line per leaf.

    mestra-cli dict-roundtrip FILE CALLABLE OUT
        write that dictionary back into OUT, for a codec round trip.


Five minutes with the library
-----------------------------

Everything is behind one header:

    #include "mestra/mestra.hpp"

`docs/api-conventions.md` is normative for the shape of this API: the
names, the argument order, the defaults and the messages are the same
in all four languages, and where an idiom forces a difference the
difference is in syntax only. What follows is that document in C++.

Reading. `mestra::read` gives a `Dataset` value type, and every array
in it carries its dimension names, so a caller permutes by name and
never by axis position:

    const mestra::Dataset d = mestra::read("family.mes");
    const mestra::Support* s = d.support("s0");
    const mestra::Array& p = s->node_arrays.front().data;
    p.dims;                    // "row", "node", "component"
    p.at_f64({1, 3, 0});       // row 1, node 3, component 0

A read is strict: it refuses a file that breaks a structural rule --
E01, E16, E19, E25, E26, E29, E30, E40, E41, and a fault no rule
covers -- with every finding in the message. A semantic fault, a
missing unit or a split that straddles a generalisation unit, never
stops a read, so that a reader still works on the files a user most
needs to look at. `mestra::read(path, {/*strict=*/false})` reads what
it can and lists what it refused in `Dataset::not_read`.

A strict read costs one validation pass over the file.
`mestra::read_header` is the metadata open of section 29 and of
section 7 of the conventions: it reads attributes, dataspaces, link
types and dimension-scale structure, and of datasets only a category
table and `/row_support`, which are the two that are not slots. It
refuses the same nine structural rules with the same identifiers a
read would give, so an open never hands back something a read would
refuse; it reads no slot and no dataset inside a callable's
dictionary, so it stays the cheap path. `mestra::validate_metadata`
is that pass on its own, and `mestra-cli validate --metadata` prints
it. `mestra::read_slot_rows(path, slot, begin, end)` reads one slot
for a row range without touching the rest.

The two passes are checked against each other on every file there is
-- all 75 corpus cases, the 15 shared hostile files and the 12 here --
and they name the same structural rules on every one of them, and the
open names nothing the read does not.

Writing. Build a dataset from plain vectors. The builders fill in the
dimension names, the shapes, the bounds and the support id, so that
what a caller states is what a caller meant:

    mestra::Dataset d;
    d.writer = "my tool 1.0";
    d.created = "2026-09-19T00:00:00Z";
    d.set_generalisation_group("member");

    d.add_category_table("member", {"wing_a", "wing_b"});
    d.add_key("mach", {0.4, 0.8}, "condition", "1");
    d.add_category_key("member", {0, 1}, "group", "member");
    d.add_scalar("cl", {0.25, 0.55}, "1");

    d.add_mesh_support("s0", 6, {9, 9}, {0, 4, 8},
                       {0, 1, 4, 3, 1, 2, 5, 4});
    mestra::Support* s = d.support("s0");
    mestra::set_coordinates(*s, coordinates, "m",
                            {"group:member", "node", {"component", 2}});
    mestra::add_node_array(*s, "pressure", pressure, "Pa",
                           {"row", "node"});

    mestra::write(d, "family.mes");

Fetch by name (`d.support("s0")`) rather than holding a reference
across a later `add_`: `add_key`, `add_scalar`, `add_category_table`
and `add_mesh_support` keep their vectors sorted, which invalidates
references into them. The example above does that throughout, and so
should yours.

Four things in those calls are worth saying out loud.

*The order is the name, then the values, then what they mean.*
`add_key(name, values, role, units)`, `add_scalar(name, values,
units)`, `add_node_array(support, name, values, units, dims)`. It is
the same order in Python, MATLAB and Julia.

*`dims` names the axes of the array you flattened, in your own axis
order.* From it the builder works out `varies` -- a `row` axis means
row, a `group:<k>` axis means that group, neither means none -- and
`components`, adding a component axis of length one when you named
none. A bare name is an axis whose length the builder derives: `node`
and `cell` from the support, and the one remaining unknown from the
number of values. When two lengths are unknown, give one:

    {"row", "node", {"component", 3}}

The type is `mestra::Dims`, a vector of `mestra::Dim`, and a `Dim` is
a dimension name with an optional length, so a bare string and a
braced pair both belong in the list.

The names may be in any order, and the builder permutes into the
stored order of section 4 rather than asking you to:

    // (node, row) data, written as (row, node, component)
    mestra::add_node_array(*s, "pressure", by_node, "Pa",
                           {"node", "row"});

There is no `varies` argument and no mutable `varies` to assign to
afterwards. Assigning to `varies` or `components` on a slot that
already holds data does not reshape it, so `write` refuses such a slot
with E04 or E31 before it opens anything. Build the slot again with
the `dims` you meant.

*Bounds default to the observed finite range.* A key with no `lower`
and `upper` given records the smallest and largest finite value it
holds, so that the same arrays give the same file in every language
and W04 and W08 are decidable on it. A caller who wants a wider domain
of validity assigns `lower` and `upper` on the key that comes back;
those are plain attributes and assigning them takes effect.

*What a file said about its own layout survives being read and
written again.* A chunk shape that is not the default of section 23,
and a compression filter -- gzip at levels 1 to 9 and shuffle, which
are the two section 23 allows -- come back off the file into
`Dataset::chunk_overrides` and `Dataset::filters`, by HDF5 path, and
`write` puts them back in the pipeline order they were in. A dataset
built from plain vectors carries neither and gets the default and no
compression, because section 23 makes compression a writer's choice;
what a round trip must not do is drop a filter the file had, which on
a real dataset grows it by a sixth every time. The corpus case is
`compressed_field` and the comparison is structural equality.

*A dimension scale is created with the properties of section 21.*
Attribute creation order tracked and indexed, and object time tracking
off, on the scale's own creation property list and on nothing else in
the file. The first gives the scale a version 2 object header, so that
its REFERENCE_LIST lives in the file's heap: without it no scale takes
more than 4085 attachments, and the 4086th fails after deleting the
list it was extending, leaving a file every reader and every validator
accepts. The second keeps the file byte reproducible, because a
version 2 header records four timestamps unless it is told not to.
`H5Pset_attr_phase_change` asks for the same thing and is silently
ignored under the default library version bounds, which this writer
leaves at the default everywhere. An attachment that fails anyway is
refused with a message naming the REFERENCE_LIST it destroyed and the
section, because the file left behind has to be deleted rather than
kept. The corpus cases are `wide_keys`, which could not be written at
all without the rule, and `err_e42`, which breaks it on purpose.

*`write` validates first and refuses on any error.* It builds the file
beside the name you gave and moves it into place only once it
validates, so a refusal leaves nothing behind. The Error carries the
first rule identifier and every finding in its message.
`mestra::WriteOptions` with `check = false` writes the file anyway,
for the one caller who wants a file the validator rejects.

The builders, in full. Every one of them refuses at build time, with
the rule identifier and which argument to change, whatever the
validator would refuse at read time.

    Dataset::add_key(name, values, role, units)
    Dataset::add_category_key(name, ids, role, category, dtype)
    Dataset::add_scalar(name, values, units)
    Dataset::add_category_table(name, entries)
    Dataset::set_generalisation_group(name)
    Dataset::add_mesh_support(name, n_nodes, cell_types, cell_offsets,
                              connectivity)
    Dataset::add_axis_support(name, coordinates, units)
    Dataset::add_none_support(name)
    Dataset::add_callable(id, callable)
    Dataset::add_callable(id, type, dict)

    set_coordinates(support, values, units, dims)
    add_node_array(support, name, values, units, dims)
    add_cell_array(support, name, values, units, dims)
    add_node_label(support, name, values, category, dims, dtype)
    add_cell_label(support, name, values, category, dims, dtype)
    add_callable_node_array(support, name, units, dims, callable,
                            output)
    add_callable_cell_array(support, name, units, dims, callable,
                            output)
    add_callable_scalar(dataset, name, units, callable, output)

    compute_weights(support, location, options)

A category table is added once with `add_category_table` and named by
the key or label that uses it; there is no inline form.
`add_category_key` is the convenience for a key whose column is
integer category ids, and it is `add_key` with `category` in the place
of `units`. A label names its table the same way, through the
`category` argument of `add_node_label` and `add_cell_label`, and a
label that names none has values that are their own categories.

What a builder does not take, you assign, on the object
`d.key(name)`, `d.scalar(name)` or `d.support(name)` gives back:

    d.key("time")->trajectory_group = "trajectory";
    d.key("trajectory")->parent = "member";
    slot.statistic = "quantile";   // with `of` and `quantile`,
    slot.of = "pressure";          //   section 9
    slot.quantile = 0.95;
    slot.role = "derived";         // with `derived_from`, `recipe`
    slot.derived_from = "coordinates";   //   and `reference`,
    slot.recipe = "minus reference";     //   section 5
    slot.reference = "group:member=wing_a";

Those are plain attributes with no shape behind them, so assigning
them takes effect. `varies` and `components` are the two that do not,
and the builders are the only way to set them.

Weights and integration. Section 3 of the specification says a weight
array is computed from connectivity and never imported, so this
library computes them:

    mestra::compute_weights(*d.support("s0"), mestra::Location::Cell);

That adds an array of role `weight` with the cell measure -- length,
area or volume by cell type -- in the coordinate units raised to the
support's dimension, with `recomputed` set and the `varies` of the
coordinates, so a family of meshes gets one instance per member.
`Location::Node` gives the lumped share of the adjacent cell measure
instead; an `axis` support has no cells and takes its node weights
from the spacing of its own coordinates. Calling it twice replaces
rather than adds, because a support carries one weight array per
location.

Measured here: line, triangle, quadrilateral, polygon, tetrahedron,
hexahedron, wedge and pyramid. A surface cell of any shape goes
through Newell's method, which is exact for a polygon that is not
convex and gives the projected area for one that is not planar; a
volume cell is a signed sum of tetrahedra. The quadratic cell types of
section 20 are refused by name, with the cell index, rather than
approximated by their corner nodes, and so is a mesh whose cells are
not all of one dimension.

    const mestra::Integral i = mestra::integrate(d, "pressure");
    i.at(row);              // one value per row and component
    i.units;                // the slot's units times the weight's
    i.weight_recomputed;    // the file had none, so one was computed

`integrate` uses the weight array at the slot's location on its
support by default, computes one on the fly when the file has none and
says so in the result, and takes `IntegrateOptions::weight` to name
another by name. A slot served by a callable is refused: evaluate the
file first.

    const mestra::FieldStatistics f =
        mestra::field_statistics(d, "pressure", "region");
    f.group_by;             // "region", never a fixed word
    f.groups;               // the category names, one per row
    f.count; f.missing; f.minimum; f.mean; f.maximum; f.deviation;

`field_statistics` groups by a label on the same support at the same
location, and the grouping column is named after the label. Without
`by` there is no grouping column at all. A non-finite value is not a
value: it is this format's spelling of missing floating-point data
(W03), so it is counted in `missing` and left out of the rest.
`deviation` is the population standard deviation over the `count`
finite values.

Validating. Every finding carries the rule identifier and nothing else
identifies it:

    const mestra::Report r = mestra::validate("family.mes");
    for (const mestra::Finding& f : r.errors) {
        std::cerr << f.id << " " << f.where << ": " << f.message << "\n";
    }
    r.error_ids();     // sorted, without duplicates

There is one finding per rule per object, and a rule that could fire
once per row -- W02, W03, W04 -- reports once with the count and the
first three rows in its message.

Callables. A callable is exactly four things: `call`, `to_dict`, a
static `from_dict` dispatched on a `type` string through
`CallableRegistry`, and an optional `repr`. `affine` is the one type
this package defines, so that the protocol and the codec can be
conformance-tested without any proprietary model:

    mestra::KeysTable table;
    table.add_column("mach", {0.5});
    table.add_column("alpha", {4.0});
    const mestra::Dataset out = mestra::evaluate(d, table);

The keys table of section 26 is a struct holding the key names beside
one vector per key, looked up by name through `column(name)`, because
C++ has no run-time member names. That is the form section 26 now
gives for this language.

A callable goes into a dataset with `d.add_callable("m1", model)`,
which takes the type, the dictionary and the optional one-line `repr`
from the object itself; `add_callable_node_array`,
`add_callable_cell_array` and `add_callable_scalar` then point slots
at it by id and output. A callable slot stores nothing, so it has no
values for a component axis to take a length from: write
`{"row", "node", {"component", 3}}`.

To add your own callable type, derive from `mestra::Callable` and
register a factory:

    mestra::CallableRegistry::register_type(
        "my_model", [](const mestra::Dict& d) {
            return std::unique_ptr<mestra::Callable>(new MyModel(d));
        });

A reader that does not know a type may still copy its dictionary and
must not interpret it, which is what `read_dict` and `write_dict` are
for.

What a round trip does with `/private`. Sections 12 and 29 forbid a
reader to interpret that group; they say nothing against copying it,
and a producer that round-trips a file keeps its own records. A whole
read therefore takes an opaque copy of it and `write` puts it back:
the same objects, dtypes, shapes, chunks, filters, attributes,
subgroups and dimension scales, including the encodings section 18
forbids in the public part, because nothing here decides what any of
it means. The copy is the HDF5 library's own object copy into an
in-memory file, whose bytes `Dataset::private_group` carries;
`Dataset::has_private` still says the file had one.

    mestra::Dataset d = mestra::read("from_a_producer.mes");
    mestra::write(d, "back_again.mes");   // /private and all

Two things follow. `mestra::read_header` reads no array (section 29)
and so takes no copy, and a dataset it returns writes no `/private`.
And the group is copied whole, so it is held whole: a `/private`
nested deeper than 64, holding more than 65,536 objects or more than
one gibibyte is **E41**, the identifier for an object this reader
cannot read, rather than a silent truncation or an allocation without
bound.


What this package does not do
-----------------------------

Two of the four post-processing helpers of `docs/api-conventions.md`
section 4 are not here, and will not be:

    time_series(dataset, slot, node, trajectory)
    grouped_split(dataset, fractions, seed)

Both of them are analysis over rows rather than anything the format
decides. A time series is a selection and a sort that a caller writes
in three lines of C++ over the arrays this library already hands them,
with the time key and its `trajectory_group` in their hand; a grouped
split is a random assignment of units of generalisation to parts, and
which random assignment you get would then depend on this library's
choice of generator rather than on the seed you gave it. Neither would
read the same in C++ as in Python, and a helper that gives a different
answer in two languages is worse than no helper.

`compute_weights`, `integrate` and `field_statistics` are here for the
opposite reason. A weight array is computed from connectivity and
never imported, which is a rule of the specification and not a
convenience; an integral is what that weight array is for; and a
label is how this format spells a region, so grouping by one is
reading the file rather than analysing it.

Python and Julia are the implementations that carry the
post-processing helpers. If you need the other two in a C++ pipeline,
the shape they should take is in section 4 of the conventions, and the
two here show what the argument order and the result should look
like.


What the dictionary dump looks like
-----------------------------------

`dict-dump` prints one line per leaf so that a test script can compare
a dictionary without any JSON code on the C++ side. The first field is
the kind, the second the path from `.`, and the rest the value:

    D .                      a nested dictionary
    N ./x                    null
    B ./x 1                  a boolean
    I ./x 42                 an int64
    F ./x 2.50000000000000000e+00      a float64
    S ./x hello              a string
    A ./x float64 2 6 2 ...  an array: dtype, rank, extents, elements
    T ./x 1 2 mach alpha     a string array: rank, extents, elements

Anything outside printable ASCII, and `%` itself, is written `%XX`; a
lone `%` is the empty string. Keys come out in ascending order of
their UTF-8 bytes, which is the order section 25 tells a writer to
visit them in.


A file is untrusted input
-------------------------

A reader of an open format opens files it did not write, and a file is
a program's input and not its instructions. This one is written so
that a crafted file gets an answer rather than a crash, and every
limit below is a stated number rather than whatever the stack happened
to allow.

What the reader refuses, and says so:

  - an attribute whose dataspace declares more elements than the
    encoding of section 18 implies. Every buffer is sized from the
    count the file declares, never from the encoding, and a count past
    a stated maximum is left unread and reported;
  - a dictionary, a group tree or a dump nested deeper than 64. A
    stack overflow cannot be caught, so the limit is enforced before
    the descent, and a dictionary accounts its own nesting as values
    go in, which makes a deeper one impossible to hold rather than
    merely unsafe to walk;
  - an element count or a byte length whose product overflows, or
    passes the stated maximum of 2^31 elements for an eager read. A
    dataset that declares a trillion elements and stores none is
    refused before anything is allocated. A lazy read and a row-range
    read are not subject to that maximum, because they never
    materialise the whole dataset, so the same file can be readable
    one way and E41 the other (section 29);
  - a link in the public tree that is not a hard link: a soft link,
    whether it resolves, dangles or loops, and an external link, which
    is never opened. Following one would let a file name another file
    on the machine and have this reader open it. The link's own type is
    read before anything is opened, so nothing under a link of either
    kind is ever asked about. That is **E40**;
  - a member of a container group that is neither the kind that
    belongs there, a nesting past the cap, a malformed object, or an
    eager read of a dataset above the maximum element count. Each is
    **E41**, reported with its path while the pass goes on, so that
    one broken object does not hide the rest of the file.

Three things follow from that. The validator reports rather than
fails: one object it cannot read is recorded against its path and the
rest of the file is still checked, because a validator that stops at
the first fault tells a caller almost nothing. A fault that no rule of
section 14 covers is still printed, as `! path: why`, so that a file
is never reported clean because the thing wrong with it has no
identifier. And `info` and `read` check the file before they read it
and refuse with the same identifiers `validate` gives, which is what
the hostile subset of section 30 asks of them; `mestra::read_header`
refuses the structural nine from what a metadata open may read, so the
library's cheap open refuses what its read refuses without reading a
slot to find out.

There are two hostile suites. `vectors/hostile` is the corpus's own,
shared by every language, and its contract is section 30's: the
required identifiers must appear, more are allowed, and `validate`,
`info` and `read` must each refuse inside the timeout the case states.
Two of its fifteen files are generated rather than committed, so run

    python vectors/generate.py --hostile-deep --wide

before `ctest`, which also writes `cases/wide_keys`. `cpp/tests/hostile/` is this implementation's own,
with `make_hostile.py` saying how each file was made. Building with
`-DMESTRA_SANITIZE=ON` adds the address and undefined-behaviour
sanitizers to the whole suite.


What this build has been checked against
----------------------------------------

184 unit checks, including the conventions of
`docs/api-conventions.md` one rule at a time: the argument order, the
bounds default, `dims` deriving `varies` and `components`, the
permutation into stored order, the refusals a builder makes and the
identifiers they carry, `write` refusing a slot whose `varies` was
assigned after the fact, the cell measures against shapes whose
measure is known by hand, the lumped node weights adding up to the
area, the default weight rule, and the statistics of a field with a
missing value in it; and a zero-row callable file built with
`add_callable(id, callable)` and a callable slot, written, validated
and evaluated, whose evaluated form keeps no callable and no
`/callables` group.

All 75 corpus cases: the validator outcome and the shape of the
validator's own output, every support id, every probe, every codec
round trip, every worked evaluation, a lazy row read of every
row-dimensioned probe, and, for the 33 cases that validate without an
error, read-write-compare under the structural equality rule of
section 30, and, for every worked evaluation, that the evaluated file
carries no `/callables` group. Then the fifteen cases of
`vectors/hostile` and the twelve of this implementation's own, each
through `validate`, `info` and `read`, and all 102 files of the three
sets through the metadata open beside the whole read.
The whole of it also runs under the address and undefined-behaviour
sanitizers.

The driver also prints what the largest case costs, because a cost is
a thing a test can watch and not only a thing a study can measure:

    cost   wide_keys   open 3.0 s   validate 2.0 s   one lazy slot read 0.1 s

on 4200 row-dimensioned datasets, each the library call alone. The
seconds are the machine's and nothing asserts on them; what the line
is for is that an open or a validation which became the square of the
dataset count would show here.

Byte identity with the corpus files is not required and section 30
says it must not be tested: the HDF5 library decides the superblock,
the object header layout and where the global heap objects that the
dimension-scale machinery uses are allocated.


Layout of this directory
------------------------

    include/mestra/     the public headers, commented one by one
    src/                the implementation; nothing here is installed
    tools/              mestra-cli
    tests/              the unit checks and the conformance driver
