The MATLAB interface
====================

A reader, a writer, a validator and the reference callable for the
open dataset format, written for base MATLAB and nothing else. No
toolbox is needed: the HDF5 work is done through the low-level
interface that ships with MATLAB (H5F, H5G, H5D, H5A, H5S, H5T, H5P
and H5DS), the keys table is a plain `table`, and the tests use
`matlab.unittest`. The SHA-256 the format needs is written out in
MATLAB rather than taken from Java, so nothing here depends on a
virtual machine being loaded.

Everything is under the package `mestra`. Nothing writes to the global
namespace.


Five minutes
------------

Put the `matlab` directory on the path and read a file:

    addpath('<this repository>/matlab')

    d = mestra.read('vectors/cases/mesh_two_rows/case.mes');
    d                       % a one-screen summary

    d.nRows                 % 2
    d.keyNames()            % {'mach', 'member'}
    d.key('mach').units     % '1'
    d.supportNames()        % {'s0'}
    d.support('s0').nNodes  % 6

Get a field out and put it the way round you want:

    a = d.nodeArray('s0', 'pressure');
    a.dims                  % {'component', 'node', 'row'}
    p = mestra.permute(a.values, a.dims, {'row', 'node', 'component'});
    p(2, 4, 1)              % 204

See what is in a file, without reading any array:

    mestra.info('case.mes')

Check a file:

    r = mestra.validate('case.mes');
    r.valid                 % true
    mestra.report(r)        % one line per finding, then the summary
    W02 /keys/status: 2 of 6 rows have a status other than converged
        (rows 1, 4); a row that is not converged is excluded from
        modelling unless it is asked for
    0 error(s), 1 warning(s)

Build one from arrays and write it:

    d = mestra.Dataset();
    d.addCategoryTable('member', {'wing_a', 'wing_b'});
    d.addKey('mach', [0.4 0.8], 'condition', '1');
    d.addKey('member', int32([0 1]), 'group', 'Category', 'member');
    d.setGeneralisationGroup('member');

    % six nodes, two components, one instance per family member
    coords = cat(3, [0 1 2 0 1 2; 0 0 0 1 1 1], ...
                    [0 1.5 3 0 1.5 3; 0 0 0 1 1 1]);
    d.addMeshSupport('s0', coords, uint8([9 9]), int64([0 4 8]), ...
                     int64([0 1 4 3 1 2 5 4]), 'm', ...
                     'Dims', {'component', 'node', 'group:member'});

    pressure = [101 102 103 104 105 106
                201 202 203 204 205 206];
    d.addNodeArray('s0', 'pressure', pressure, 'field', 'Pa', ...
                   'Dims', {'row', 'node'});
    d.addNodeArray('s0', 'cad_edge_t', linspace(0, 1, 6), 'field', '1', ...
                   'Dims', {'component', 'node'});
    d.addScalar('cl', [0.25 0.55], '1');

    mestra.write(d, 'two_rows.mes');

The support id, the component counts, the dimension names, the key
bounds, the chunking and the unlimited row dimension are all filled in
for you, and `mestra.write` refuses to leave behind a file its own
validator rejects.

`Dims` names the axes of the array you hand over, in that array's own
order. A name the slot needs and your array does not have (`component`
above) becomes an axis of length one, and `Dims` settles what the
array varies along: `cad_edge_t` above names no `row` axis, so it is
one array shared by every row and nothing has to say so twice.

MATLAB has no one-dimensional array, so `linspace(0, 1, 6)` is 1-by-6
and takes two names. The leading singleton is the component axis.


What you can build, and in what order
-------------------------------------

Every implementation of this format takes a builder's arguments in one
order, so that a user moving between MATLAB, Python, Julia and C++
meets the same call in four idioms (`docs/api-conventions.md`, section
1). The order is **the name, the values, then the role and the
units**; everything else is a name-value pair, which is MATLAB's own
idiom. The role and the units may be given positionally or by name,
and the two spellings build the same thing:

    d.addKey('mach', [0.4 0.8], 'condition', '1');
    d.addKey('mach', [0.4 0.8], 'Role', 'condition', 'Units', '1');

Nothing has to be guessed at to tell the two apart: a role is one of
the words in section 3 of the specification and a unit is a UDUNITS
string, and the two vocabularies do not overlap.

    d.addCategoryTable(name, entries)
                            a category table. Ids are the positions,
                            so the first entry is id 0. This is the
                            one way to attach one; the key or the
                            label then names it with 'Category'
    d.addKey(name, values, role, units)
                            a key column. Roles: design, condition,
                            time, categorical, group, split, id,
                            status. Also 'Lower', 'Upper',
                            'Category', 'TrajectoryGroup', 'Parent'
    d.setGeneralisationGroup(name)
                            name the group key that is the unit of
                            generalisation
    d.addScalar(name, values, units)
                            a per-row quantity. Also 'Callable' and
                            'Output' for one served by a callable
    d.addMeshSupport(name, coordinates, cellTypes, cellOffsets, ...
                     cellConnectivity, units, 'Dims', ...)
                            a mesh support and its coordinates, with
                            the support id computed for you
    d.addAxisSupport(name, coordinates, units, 'Dims', ...)
                            an axis support: nodes along one
                            coordinate, no cells
    d.addSupport(name, 'none', 0)
                            a support that is no support, for a slot
                            that lives on nothing
    d.setCoordinates(support, values, units, 'Dims', ...)
                            the coordinates of a support already added
    d.addNodeArray(support, name, values, role, units, 'Dims', ...)
    d.addCellArray(support, name, values, role, units, 'Dims', ...)
                            an array. Roles: coordinates, field,
                            label, weight, normal, derived; the
                            default is field. Also 'Category' on a
                            label, 'DerivedFrom' and 'Recipe' on a
                            derived array, 'Statistic', 'Of' and
                            'Quantile' on a summary
    d.addCallable(id, callable)
                            store a callable under an id
    d.addCallableSlot(support, name, role, units, callable, output, ...
                      'Location', 'node', 'Components', n)
                            an array slot served by that callable
    d.setRowSupport(values) which support each row is on, in an
                            unaligned file

Two defaults are worth knowing because they are the same in every
language. A key of role design, condition or time whose bounds you do
not give records **the observed finite minimum and maximum**, so that
the same arrays written anywhere give the same file and W04 and W08
are decidable on it; pass 'Lower' and 'Upper' when you want a wider
domain of validity than the data you happen to have. And an array's
`Dims` settles what it **varies along**, so you never state it twice:

    'Dims', {'row', 'node'}             varies along rows
    'Dims', {'group:member', 'node'}    one instance per member
    'Dims', {'component', 'node'}       one instance, shared

Passing `Varies` as well is allowed and is checked: a `Varies` that
disagrees with `Dims` is refused when you build the array, with the
identifier of the rule the file would have broken, and not by the
validator after the file is on disk.

A builder refuses what it can see at the time you call it, always
with the rule identifier: a role that is not a role (E02), a field, a
scalar or a coordinates array with no units (E11, E39), a `Varies`
that disagrees with `Dims` (E16 or E04), a callable slot that does not
declare its width (E31) or does not name its callable (E14), an array
whose node or cell count disagrees with its support (E05), a value
outside the category table it names (E10), an axis support whose
coordinates would vary (E35), a callable with no type (E15) and a unit
of generalisation that is not a group key (E03). Everything else the
validator knows is checked when you write, because that is where a
file can be seen whole.


Writing refuses to write a bad file
-----------------------------------

`mestra.write` builds the file, validates it, and only then puts it at
the path you gave. On any error nothing is written, the file that was
there is untouched, and the error carries the identifier of the first
rule broken and every finding in its message:

    mestra.write(d, 'out.mes');
    Error using mestra.write
    E16: mestra.write refused to write out.mes because its own
    validator rejects it:
    E16 /supports/s0/node_arrays/cad_edge_t: the leading extent is 1
        where 2 rows are on this support
    1 error(s), 0 warning(s)
    Fix the dataset, or pass 'Check', false to write it anyway

Warnings never stop a write: they are findings about a file that is
conforming all the same.

To write a file that is invalid on purpose, which is what the
conformance corpus is full of, say so:

    mestra.write(d, 'err_e16.mes', 'Check', false);


Weights, integration and the four post-processing verbs
-------------------------------------------------------

The specification says a weight array is "computed from connectivity,
never imported", so this package computes one:

    mestra.computeWeights(d, 's0', 'cell');    % the cell measure
    mestra.computeWeights(d, 's0', 'node');    % its lumped share

The measure is the cell's own: the length of a line, the area of a
triangle, a quadrilateral or a polygon, the volume of a tetrahedron, a
hexahedron, a wedge or a pyramid, and zero for a vertex. A quadratic
cell, code 21 to 27, has curved edges and is refused by name rather
than measured by its corner nodes, because that number would look
right and be wrong; compute the one you want and store it as a
`derived` array, where the recipe is written down. An `axis` support
has no cells, and a node's weight there is the share of the segments
either side of it. The array is stored with role `weight`, with
`recomputed` set, and with the units of the coordinates raised to the
support's dimension.

Then four verbs, which take a slot by name and a label by name:

    mestra.integrate(d, slot)
                        sum a field against the weight array at its
                        location. With no weight array in the file
                        one is computed for the call, which the call
                        says; 'Weight' names another by name
    mestra.fieldStatistics(d, slot, 'By', label)
                        count, minimum, maximum, mean and standard
                        deviation per row, and per group of a label
                        when 'By' names one. The grouping column is
                        named after the label and is absent when
                        there is no label. A scalar may be named
                        instead, and is reported over the rows
    mestra.timeSeries(d, slot, node, trajectory)
                        one node's history through one trajectory, in
                        time order
    mestra.groupedSplit(d, fractions, 'Seed', seed)
                        assign whole units of generalisation to named
                        parts. No unit is ever on two sides, no named
                        part is ever empty when there are at least as
                        many units as parts, and a file with no
                        declared unit of generalisation is refused.
                        The seed is 0 by default and the shuffle is
                        this package's own, so MATLAB's global random
                        state does not move the answer

For example:

    d = mestra.read('family.mes');
    mestra.computeWeights(d, 's0', 'node');
    lift = mestra.integrate(d, 'pressure');
    lift.values                        % one number per row
    lift.units                         % 'Pa m2'

    t = mestra.fieldStatistics(d, 'pressure', 'By', 'cad_face_id');
    s = mestra.groupedSplit(d, struct('train', 0.8, 'test', 0.2));

**Which way the rows are counted.** A row index you index an array
with is counted from 1, as MATLAB counts: `readRows`, `groupedSplit`
and the `node` of `timeSeries` are all one-based. A row index in a
statement *about a file* is the file's own, counted from 0: the `row`
column of `fieldStatistics` and `timeSeries`, and every row a
validator finding names. That way a MATLAB line indexes, and a report
in MATLAB names the same row as a report in any other language.


Validator output
----------------

`mestra.validate` returns; `mestra.report` prints. Every
implementation prints the same two things (`docs/api-conventions.md`,
section 5): one line per finding, `<id> <path>: <message>`, and then
`<n> error(s), <m> warning(s)`.

    r = mestra.validate('case.mes');
    n = mestra.report(r);             % prints, and returns the errors
    if n > 0, exit(1); end

A rule fires **once per object**, so a report has one line per thing
that is wrong and not one line per way of noticing it. A rule that
could fire once per row, W02, W03 and W04, fires once with the count
and the first three rows, which is what makes a report on a file of
1,800 rows still a report:

    W04 /keys/mach: 2 of 6 rows are outside the declared bounds
        [0.2, 0.7] (rows 1, 4); widen the bounds or leave those rows
        out

`mestra.info` prints what is in a file without reading any array: for
every key its name, role, units, bounds, category, trajectory group
and parent; for every support its kind, its counts and its id; for
every slot its shape with the axes named, its units and its source,
and for a callable slot the callable id and the output it fills.

    mestra.info('transient_fixed_mesh.mes')
    transient_fixed_mesh.mes
      format mestra/0, writer mestra corpus 0
      created 2026-09-19T00:00:00Z
      5 row(s), aligned, unit of generalisation run

      keys
        amplitude    design       units 1  bounds [0.5, 2.5]
        diffusivity  design       units m2 s-1  bounds [0.01, 0.05]
        run          group        category run
        t            time         units s  trajectory group run
      ...
      supports
        s0  kind mesh, 6 node(s), 2 cell(s)
          id 96df395d80ef5484...
          coordinates  (node=6 component=2), coordinates, units m, ...
          node u  (row=5 node=6 component=1), field, units K, ...

A shape is printed in the file's own axis order, because that is the
order the file states. What `mestra.read` hands you in MATLAB is the
reverse of it, and you permute by name.


The axis order, and the one idiom to learn
------------------------------------------

HDF5 stores an array in C order and MATLAB is column major, so **every
array this package hands you has its axes reversed with respect to the
file**. The file's logical order is

    (row | group | nothing, [draw], node | cell, component)

so a MATLAB array comes back as

    (component, node | cell, [draw], row | group)

A node array stored as `(row, node, component)` is returned as a
MATLAB array of size `(component, node, row)`. That is correct and
expected. What two readers in two languages must agree on is the value
at (row r, node n, component c), and that is found by the dimension
names and never by the axis positions.

Every array carries its dimension names in its `dims` field, in the
same order as its own axes, so you never have to count:

    a = d.nodeArray('s0', 'pressure');
    p = mestra.permute(a.values, a.dims, {'row', 'node'});

`mestra.permute(array, names, wanted)` is the whole idiom. A name in
`wanted` that the array does not have becomes an axis of length one; a
name the array has and `wanted` leaves out is dropped when its length
is one and is an error otherwise, so nothing is folded away quietly.

The leading axis of an array that varies along a group key is named
`group:<key>`, for example `group:member`. The conformance corpus
calls that axis `instance`, and `mestra.permute` and the builder's
`Dims` accept either.


Reading a big file without reading it
-------------------------------------

`mestra.read` reads everything. When you only want to know what is in
a file, or you want one slot for a range of rows, use `mestra.open`
and `readRows`:

    d = mestra.open('big.mes');       % attributes and dataspaces only
    d.nRows
    d.key('mach').lower               % the bounds, with no array read

    chunk = d.readRows('/supports/s0/node_arrays/pressure', [1 100]);
    chunk.dims                        % names the axes of chunk.values

`readRows` takes the slot's path and an inclusive, one-based row range
and touches only the chunks that hold those rows. Nothing else in the
file is read.


Callables
---------

A callable maps keys in to values out, and is exactly four things:
`call`, `toDict`, a static `fromDict`, and an optional `disp`. The one
type this package defines is `affine`:

    A = mestra.Affine({'mach', 'alpha'}, struct( ...
            'cl', struct('A', [2.0 0.1], 'b', 0.05, 'shape', []), ...
            'pressure', struct('A', [1 0; 2 0; 3 0.5; 4 0.5; 5 1; 6 1], ...
                               'b', [0; 0.1; 0.2; 0.3; 0.4; 0.5], ...
                               'shape', [6 1])));

    t = table(0.5, 4.0, 'VariableNames', {'mach', 'alpha'});
    out = A.call(t);
    out('cl').data                    % 1.45

The keys table is a MATLAB `table` whose variable names are the key
names. `mestra.evaluate` runs a whole file on one:

    d = mestra.read('affine_zero_rows.mes');
    e = mestra.evaluate(d, t);        % every callable slot now holds data
    e.scalar('cl').values             % 1.45
    mestra.write(e, 'evaluated.mes');

The dot product is accumulated over the keys in the declared key order
and `b` is added last, with no fused multiply-add, because the corpus
compares float64 results bit for bit and the other orders differ in
the last place.

To add a type of your own, subclass `mestra.Callable`, implement the
three methods, and register it:

    mestra.Registry.register('my_type', @MyType.fromDict, 'MyType');

A file whose callable type is not registered still reads: the
dictionary comes back unchanged and is not interpreted.


The dictionary a callable stores
--------------------------------

A dictionary is a `containers.Map` with character keys. Its leaves
are a nested `containers.Map`, a `double` (a float), an `int64` (an
integer), a `logical` (a boolean), a `char` row vector (a string), the
value `missing` (a null), or a `mestra.Array` (an array or a list).

The wrapper exists because a number is stored as an attribute and an
array as a dataset, and MATLAB cannot tell a scalar from a
one-element array. `mestra.Array` holds its contents with the file's
own subscripts, so `A.data(i, j)` is the element at file position
(i-1, j-1):

    mestra.Array(0.05)            % a dataset of shape (1)
    mestra.Array([2.0 0.1])       % shape (1, 2)
    mestra.Array(int64([6; 1]))   % shape (2)
    mestra.Array(["a"; "b"])      % a list of two strings

A column vector is a list and a row vector is a one-row matrix; pass
the shape when neither is what you mean.


Errors
------

A mistake raises a MATLAB error whose identifier names the rule it
breaks, so a caller can catch exactly the one it expects:

    try
        mestra.write(d, 'out.mes');
    catch err
        err.identifier      % 'mestra:E32'
        err.message         % what was wrong, in words
    end

The message says the same thing in the same order in every language
(`docs/api-conventions.md`, section 6): the rule identifier first,
then the object's path, then what to do about it, and in a builder,
which argument to change.

    E16: /supports/s0/node_arrays/cad_edge_t: Dims names the axes
    {component, node}, so this array varies along none, and Varies
    says row; the two disagree. Drop Varies and let Dims settle it,
    or name a row axis in Dims

A rule identifier always says something about a *file*. A name that
is not in the file is your mistake and not the file's, so it raises
an error with no rule identifier, and a caller who catches `mestra:E05`
to detect a malformed file never catches a typo with it:

    mestra.integrate(d, 'CL')
    Error using mestra.integrate
    there is no slot called "CL" in this file; it has cl, pressure,
    coordinates

Reading a file from a later major version raises `mestra:E01` and
reads nothing; the specification is explicit that such a file must not
be read partially.


A file is untrusted input
-------------------------

The reader assumes nothing about a file it did not write. Its shapes,
its nesting, its links and its string sizes are numbers someone else
chose, and a reader that follows them wherever they lead can be made
to exhaust memory or run forever on a file of fifteen kilobytes.
Specification section 29 makes that a requirement on readers, and
section 14 gives it two rules of its own:

    E40   a link in the public tree that is not a hard link: a soft
          link, whether it resolves, dangles or loops, or an external
          link, which names another file. None is ever followed
    E41   an object the reader could not read, reported with its
          path: a malformed header or attribute, nesting deeper than
          the cap, or, on an eager read only, a dataset above the
          maximum element count

What the reader refuses, and under which rule:

  * any link but a hard link, E40. A soft link is not resolved, a
    dangling one is not an error, a cycle of them cannot start, and
    an external link never opens the file it names;
  * an attribute that is not encoded as section 18 requires, E19: a
    variable-length string, an array where the format names a scalar,
    an integer that is not int64, a float that is not float64, a
    string where a number belongs or a number where a string does, or
    a boolean holding anything but 0 or 1. The rules are the ones
    `mestra.validate` reports E19 for, asked of the same place, so the
    two cannot disagree;
  * nesting past `maxDepth` levels, and a group already visited in
    this walk, which is how a cycle of hard links ends: E41;
  * an eager read of more than `maxElements`, E41. A lazy read and a
    row-range read are not subject to it, so `mestra.open` and
    `readRows` still work on a file `mestra.read` refuses; a
    fixed-length string wider than `maxStringSize` is E41 too;
  * a filter that is not gzip or shuffle, E29, which section 23 tells
    a reader to refuse;
  * a slot whose `source` says data and which is stored as a group, or
    whose `source` names a callable and which is stored as a dataset,
    E30. Section 19 makes the two kinds of slot tell themselves apart
    without reading any data, and a reader that takes one for the
    other hands back an array that is not there;
  * a leading extent that disagrees with the `row` dimension it is
    attached to, E16. A dataset that says it holds three rows in a
    file of two cannot be lined up against the keys, and handing it
    back would be worse than refusing it;
  * an axis with no dimension scale, more than one, or one this
    reader cannot name, E25;
  * a string whose stored bytes are not valid UTF-8, or which holds a
    NUL anywhere but in its trailing padding, E26. It is checked on a
    string attribute and on the entries of a category table;
  * a member of the wrong kind, E41: a key that is a group, a support
    that is a dataset, a callable that is not a group.

`mestra.limits` reads and changes the four numbers, so a genuinely
large or deeply nested file is a decision you make and not a crash
you get.

By default `mestra.read` and `mestra.open` REFUSE such a file rather
than return it half read, and the error identifier is `mestra:`
followed by the rule above, or `mestra:E01` for another major version
and `mestra:reader` for a file that will not open at all:

    try
        d = mestra.read('from_somewhere_else.mes');
    catch err
        err.identifier      % 'mestra:E40'
    end

    d = mestra.read('from_somewhere_else.mes', 'Strict', false);
    d.skipped               % one line per thing passed over, each
                            % beginning with the rule it breaks

`mestra.validate` always returns. Each pass and each object runs
inside its own guard, so an object that will not read stops that
object and the rest of the file is still checked; the failure is E41
with that object's path, and a link is E40.

A dataset this version of the format does not know, inside a group it
does, is checked. Section 14 excepts two things from the byte-level
rules of sections 18 to 25 -- `/private`, and a group this version
does not know -- and an unknown dataset in a known group is neither,
so it is one of the "public objects only" the rules are checked on.
Only the rules that need nothing this version does not know are
decidable on one: section 23's, which are about the row dimension the
dataset is attached to and not about what the dataset means. So a
contiguous dataset with a row dimension inside a support group is
E27, whatever it is called, and its name is W11 as well when this
version does not know that either.

Dimension names are resolved through a map this package builds during
its own bounded walk of the file, keyed by object address. Asking the
library for the path of a scale attached to an axis, which is the
obvious way, makes HDF5 search the group hierarchy and run off the
stack on a deeply nested file; section 21 forbids it and nothing here
does it.

Two hostile suites are run. `vectors/hostile` is the corpus's own,
fifteen files shared by every language, whose contract is that the
required rules must be reported within ten seconds and that reading
must refuse rather than return. Two of its files are thirty-one
megabytes of nested groups and are generated rather than committed:

    python vectors/generate.py --hostile-deep

Without them those two cases are skipped and say so. `tests/hostile/`
is this package's own set of twenty, which goes further in places:
array-valued attributes in three encodings, thirty thousand levels of
nesting built at run time, a cycle of hard links, a declared shape of
ten to the twelve elements, and an object whose read fails in the
middle of a group that must still be checked to the end.
`tests/hostile/make_hostile.py` builds them with h5py, which can say
things MATLAB's HDF5 interface cannot say at all.


One limitation: strings are ASCII here
--------------------------------------

The format puts every string in a fixed-length UTF-8 field and counts
the declared size in bytes. MATLAB's HDF5 interface cannot carry that
faithfully: `H5D.write` and `H5A.write` refuse a character above 127
outright, and `H5D.read` and `H5A.read` decode a fixed-length string
to text before this package sees it, which either replaces the bytes
or turns them into characters and breaks the fixed blocking. Neither
has an option to hand over the bytes, and HDF5 will not convert
between the ASCII and UTF-8 character sets, so there is no way round
it from inside MATLAB.

So this package refuses rather than corrupting. Writing or reading a
string with a byte above 127 raises `mestra:matlabAscii` and says
what happened. Everything else works as it should; keep key names,
category entries, callable ids and string ids to ASCII and nothing in
this paragraph applies. The whole conformance corpus is ASCII, so it
passes in full.


Running the tests
-----------------

    matlab -nodisplay -batch \
        "addpath('<repo>/matlab'); run('<repo>/matlab/tests/run_tests.m')" \
        < /dev/null

The suite runs the whole conformance corpus: the validator's outcome
by rule identifier for every case, every support id, every probe bit
for bit, every dictionary round trip, every worked evaluation, a lazy
row-range read, and, for every file that validates cleanly, a read
then a write then the structural comparison the specification defines.
It prints the counts and exits non-zero on any failure.

Beside it, `ConventionsTest` holds every rule of
`docs/api-conventions.md` this language can be held to: the argument
order, the bounds default, the refusal of a `Varies` that disagrees
with `Dims`, the refusal to write a file the validator rejects, one
finding per rule per object, the per-row rules reporting once with a
count and the first three rows, and the shape of the messages.
`PostTest` holds the weights and the four post-processing verbs, on
shapes whose measure is known by hand.


What is in the package
----------------------

    mestra.read(path)                 everything, into a mestra.Dataset
    mestra.open(path)                 the same without reading any array
    mestra.write(dataset, path)       a conforming file, validated first
    mestra.validate(path)             errors and warnings by rule id
    mestra.report(findings)           print them, and the summary line
    mestra.info(path)                 what is in a file, reading no array
    mestra.evaluate(dataset, table)   callable slots made into data
    mestra.permute(array, names, wanted)
                                      reorder axes by dimension name
    mestra.supportId(support)         the content hash of a support
    mestra.limits(...)                what the reader will not go past

    mestra.computeWeights(dataset, support, location)
                                      the cell measure, or its lumped
                                      share at the nodes
    mestra.integrate(dataset, slot)   a field against those weights
    mestra.fieldStatistics(dataset, slot, 'By', label)
                                      count, min, max, mean, std
    mestra.timeSeries(dataset, slot, node, trajectory)
                                      one node through one trajectory
    mestra.groupedSplit(dataset, fractions)
                                      whole units of generalisation to
                                      named parts

    mestra.Dataset                    the data model and the builder,
                                      whose methods are listed under
                                      "What you can build" above
    mestra.Callable                   the four-method protocol
    mestra.Affine                     the reference callable
    mestra.Registry                   callable types by their type string
    mestra.Array                      an array leaf of a dictionary

The post-processing calls take the dataset first because a MATLAB
support is named by a string and not held as an object; that is the
one place where this package's argument list differs from the shared
convention, and it differs in syntax only.

Every public function and class carries its own help text; `help
mestra.read` and `doc mestra.Dataset` work as usual.
