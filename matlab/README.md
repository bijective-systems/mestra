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

Check a file:

    r = mestra.validate('case.mes');
    r.valid                 % true
    r.errors                % {}
    r.warnings              % {}
    for f = r.findings
        fprintf('%s %s %s\n', f.id, f.path, f.message);
    end

Build one from arrays and write it:

    d = mestra.Dataset();
    d.addCategory('member', {'wing_a', 'wing_b'});
    d.addKey('mach', 'condition', [0.4 0.8], 'Units', '1', ...
             'Lower', 0.1, 'Upper', 0.9);
    d.addKey('member', 'group', int32([0 1]), 'Category', 'member');
    d.generalisationGroup = 'member';

    % six nodes, two components, one instance per family member
    coords = cat(3, [0 1 2 0 1 2; 0 0 0 1 1 1], ...
                    [0 1.5 3 0 1.5 3; 0 0 0 1 1 1]);
    d.addMeshSupport('s0', coords, uint8([9 9]), int64([0 4 8]), ...
                     int64([0 1 4 3 1 2 5 4]), 'Units', 'm', ...
                     'Varies', 'group:member', ...
                     'Dims', {'component', 'node', 'group:member'});

    pressure = [101 102 103 104 105 106
                201 202 203 204 205 206];
    d.addNodeArray('s0', 'pressure', pressure, 'field', 'Units', 'Pa', ...
                   'Dims', {'row', 'node'});
    d.addScalar('cl', [0.25 0.55], 'Units', '1');

    mestra.write(d, 'two_rows.mes');

The support id, the component counts, the dimension names, the
chunking and the unlimited row dimension are all filled in for you.
`Dims` names the axes of the array you hand over, in that array's own
order; a name the slot needs and your array does not have (`component`
above) becomes an axis of length one.


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

Reading a file from a later major version raises `mestra:E01` and
reads nothing; the specification is explicit that such a file must not
be read partially.


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


What is in the package
----------------------

    mestra.read(path)                 everything, into a mestra.Dataset
    mestra.open(path)                 the same without reading any array
    mestra.write(dataset, path)       a conforming file
    mestra.validate(path)             errors and warnings by rule id
    mestra.evaluate(dataset, table)   callable slots made into data
    mestra.permute(array, names, wanted)
                                      reorder axes by dimension name
    mestra.supportId(support)         the content hash of a support

    mestra.Dataset                    the data model and the builder
    mestra.Callable                   the four-method protocol
    mestra.Affine                     the reference callable
    mestra.Registry                   callable types by their type string
    mestra.Array                      an array leaf of a dictionary

Every public function and class carries its own help text; `help
mestra.read` and `doc mestra.Dataset` work as usual.
