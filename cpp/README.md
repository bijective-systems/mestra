mestra in C++
=============

A reader, a writer and a validator for the `.mes` format of SPEC.md,
in plain C++17 over the HDF5 C API and `hdf5_hl`. No other dependency:
the SHA-256 of section 24 is written out here, and the tests read the
conformance corpus with a small Python script rather than a framework.

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

The suite has two tests. `unit` is a handful of pure C++ checks: the
SHA-256 vectors and the three worked digests of section 24, the units
parser, the dictionary codec's value types, the worked affine example
of section 27, and one dataset built from plain vectors and validated.
`corpus` runs every case of `vectors/` through `mestra-cli`.

The library is compiled with `-Wall -Wextra -Wpedantic -Wshadow
-Wconversion -Wsign-conversion` and builds warning-free, and with
`-ffp-contract=off` so that no multiply and add are fused into one
rounding step. Section 27 fixes the summation order of the affine
callable and the corpus compares float64 results bit for bit, so the
contraction has to be off for the last bit to come out right.


Five minutes with the tool
--------------------------

    mestra-cli validate FILE
        the rule identifiers of section 14, one per line, errors as
        "E <id>" and warnings as "W <id>". No output means the file is
        clean. It exits 1 when the file is rejected and 0 otherwise, so
        warnings alone still exit 0.

    mestra-cli read FILE
        check the file, refuse it with the rule identifiers if the
        validator rejects it, and otherwise read the whole of it and
        say what came back: the row count, how
        many keys, scalars, supports and callables, and how many array
        values.

    mestra-cli info FILE
        the row count, the keys with their roles and bounds, the
        supports with their ids, and every slot. It checks the file
        first and refuses it the way `read` does; past that it reads
        attributes and dataspaces only, so it opens a large file as
        fast as a small one.

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
        read IN and write OUT.

    mestra-cli evaluate FILE KEYS.csv OUT
        evaluate every callable slot on a keys table and write the
        result. KEYS.csv has one line of column names and one line per
        table row.

    mestra-cli rows FILE SLOT BEGIN END
        one slot for the half-open row range, reading no other slot
        and no row outside the range (section 29).

    mestra-cli dict-dump FILE CALLABLE
        a callable's dictionary, one line per leaf.

    mestra-cli dict-roundtrip FILE CALLABLE OUT
        write that dictionary back into OUT, for a codec round trip.


Five minutes with the library
-----------------------------

Everything is behind one header:

    #include "mestra/mestra.hpp"

Reading. `mestra::read` gives a `Dataset` value type, and every array
in it carries its dimension names, so a caller permutes by name and
never by axis position:

    const mestra::Dataset d = mestra::read("family.mes");
    const mestra::Support* s = d.support("s0");
    const mestra::Array& p = s->node_arrays.front().data;
    p.dims;                    // "row", "node", "component"
    p.at_f64({1, 3, 0});       // row 1, node 3, component 0

`mestra::read_header` does the same without reading any array, and
`mestra::read_slot_rows(path, slot, begin, end)` reads one slot for a
row range without touching the rest.

Writing. Build a dataset from vectors; the builders fill in the
dimension names, the shapes and the support id:

    mestra::Dataset d;
    d.writer = "my tool 1.0";
    d.created = "2026-09-19T00:00:00Z";
    d.generalisation_group = "member";

    d.add_categories("member", {"wing_a", "wing_b"});
    mestra::Key& mach = d.add_key("mach", "condition", {0.4, 0.8}, "1");
    mach.lower = 0.1;
    mach.upper = 0.9;
    d.add_category_key("member", "group", {0, 1}, "member");
    d.add_scalar("cl", "1", {0.25, 0.55});

    mestra::Support& s = d.add_mesh_support(
        "s0", 6, {9, 9}, {0, 4, 8}, {0, 1, 4, 3, 1, 2, 5, 4});
    mestra::set_coordinates(s, coordinates, 2, "m", "group:member");
    mestra::add_field(s, mestra::Location::Node, "pressure", "Pa",
                      pressure);

    mestra::write(d, "family.mes");

How many instances a `varies = row` or `varies = group:<k>` array
holds follows from the length of the values handed over, so there is
no count to get wrong. `add_key`, `add_scalar` and `add_mesh_support`
keep their vectors sorted, which invalidates references into them, so
fetch by name (`d.support("s0")`) rather than holding a reference
across a later `add_`.

Validating. Every finding carries the rule identifier and nothing else
identifies it:

    const mestra::Report r = mestra::validate("family.mes");
    for (const mestra::Finding& f : r.errors) {
        std::cerr << f.id << " " << f.where << ": " << f.message << "\n";
    }
    r.error_ids();     // sorted, without duplicates

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

To add your own callable type, derive from `mestra::Callable` and
register a factory:

    mestra::CallableRegistry::register_type(
        "my_model", [](const mestra::Dict& d) {
            return std::unique_ptr<mestra::Callable>(new MyModel(d));
        });

A reader that does not know a type may still copy its dictionary and
must not interpret it, which is what `read_dict` and `write_dict` are
for.

One thing a round trip does not carry. Section 29 forbids a reader to
interpret `/private`, so nothing of it is read and `write` does not
reproduce it. `Dataset::has_private` says the file had one; a producer
that needs to keep its private group copies that group itself.


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
itself still reads no dataset, so the library keeps the cheap open and
the tool keeps the safe one.

There are two hostile suites. `vectors/hostile` is the corpus's own,
shared by every language, and its contract is section 30's: the
required identifiers must appear, more are allowed, and `validate`,
`info` and `read` must each refuse inside the timeout the case states.
Two of its fifteen files are generated rather than committed, so run

    python vectors/generate.py --hostile-deep

before `ctest`. `cpp/tests/hostile/` is this implementation's own,
with `make_hostile.py` saying how each file was made. Building with
`-DMESTRA_SANITIZE=ON` adds the address and undefined-behaviour
sanitizers to the whole suite.


What this build has been checked against
----------------------------------------

All 70 corpus cases: the validator outcome, every support id, every
probe, every codec round trip, every worked evaluation, a lazy row
read of every row-dimensioned probe, and, for the 30 cases that
validate without an error, read-write-compare under the structural
equality rule of section 30. Then the fifteen cases of
`vectors/hostile` and the ten of this implementation's own, each
through `validate`, `info` and `read`. The whole of it also runs under
the address and undefined-behaviour sanitizers.

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
