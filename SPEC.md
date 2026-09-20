mestra: specification, draft version 0
======================================

Date: 2026-09-19. Status: draft for discussion. Normative language
("must", "may") is used so that the rules are unambiguous, but nothing in
this draft is frozen. The spec text is CC-BY-4.0.

This document defines a data model and its serialisation. It does not
define a mesh format for solvers, a model format for fitted surrogate
state, or a database. Those live elsewhere; this format carries the
data they consume and produce, with enough declared structure that a
reader can check it and generic tools can act on it.


1. Purpose
----------

One container for:

  - parametric data: many simulations over design parameters and
    operating conditions;
  - time-dependent data: trajectories, including inside a parametric
    family;
  - scalar quantities of interest, with or without any field;
  - fields on shared supports: meshes, one-dimensional axes, or none;
  - the outputs of surrogate models, in the same shape as the data
    they were trained on, including uncertainty;

The single most important thing the format states is alignment
(section 8): every row shares one support, so node k means the same
thing in every row. Tools built on the format rely on that; it makes
it explicit and checkable instead of assumed.


2. Concepts
-----------

Row          One observation. A row is one point in the space that was
             sampled: a design, at an operating point, at a time.

Key          A per-row column that locates the row in that space. Every
             key carries a role (section 3).

Scalar       A per-row quantity of interest, with units.

Support      The structure a field lives on. Kinds: `mesh` (nodes with
             coordinates, cells with connectivity), `axis` (nodes along
             one coordinate, no cells; frequency bands, observer
             angles, a ground track), `none` (used only for scalars).

Array        A field-like quantity on a support: a node array or a cell
             array. Every array declares what it varies along (section
             5), its units, its components, and its location.

Label        An integer array with a category table: regions, CAD face
             ids, topology groups, materials. Labels are how regions
             are represented; there are no separate set structures.

Group        A key whose role is `group`: a label per row that says
             which rows belong together (member of a family,
             trajectory, split). One group is declared the unit of
             generalisation (section 7).

Callable     An object that maps keys in to values out. Any array or
             scalar slot may hold stored data or a reference to a
             callable that produces it. Section 10.

Metadata     The format version, the writer, and the time. Section 11.
             Lineage and audit history are not part of the format.

Public and   Everything above is public. A file may carry a private
private      group that readers treat as opaque bytes. Section 12.


3. Roles
--------

Every key and every array carries exactly one role. The validator is
driven by this table.

Key roles (per row):

  design       0..n  continuous; a family's geometry or design
                     parameters
  condition    0..n  continuous; operating point (Mach, load, ...)
  time         0..1  monotonic within each trajectory group; units
                     required
  categorical  0..n  integer with a category table
  group        0..n  integer with a category table; exactly one is the
                     unit of generalisation (section 7); a group may
                     declare a parent group
  split        0..1  categorical with categories from {train,
                     validation, test, holdout}; informational
  id           0..1  unique per row; string or integer
  status       0..1  categorical; the category table is the file's
                     own (converged, failed, partial are recommended;
                     a producer may add its own, such as
                     extrapolated); rows whose status is not converged
                     must be excluded from modelling unless asked for

Array roles (per support):

  coordinates  exactly 1 per mesh or axis support; components equal
               the spatial dimension (axis: 1)
  field        0..n  a physical quantity; units required; components
               1 (scalar), d (vector), d*d (tensor); location node or
               cell
  label        0..n  integer, location node or cell; a category table
               is optional, and when absent the values are their own
               categories (CAD face ids, for example)
  weight       0..1 per location; integration weights (node or cell
               measure); computed from connectivity, never imported
  normal       0..1  unit normals; location node or cell; components d;
               computed from connectivity, never imported
  derived      0..n  a quantity computed from other arrays; must carry
               `derived_from` (names) and `recipe` (a string naming
               the operation)

Scalars carry the role `scalar` implicitly and require units.

Units are strings in the UDUNITS grammar that CF uses ("Pa", "m s-1",
"W m-2", "1" for dimensionless). In version 0 a string the validator
cannot parse is a warning, not an error; tools may convert between
parseable units and must refuse to combine unparseable ones.


4. Dimensions and axis order
----------------------------

Every dataset carries named dimensions. The logical names are:

  row        the observation index
  group:<k>  the category index of group key k (for arrays that vary
             along a group)
  draw       an uncertainty draw index (section 9)
  node       nodes of a support
  cell       cells of a support
  component  vector or tensor components
  index      flat connectivity storage
  cell_plus_one  the cell offsets, one longer than `cell`
  key        unused; keys are separate datasets, not one matrix

The logical order of an array is (row | group | none, [draw], node |
cell, component). On disk, arrays are stored in that order in C
(row-major) layout. A reader in a column-major language returns
whatever order is natural for it, but must expose the dimension names
so that permutation is by name, never by position. Two readers in two
languages must agree on the value at (row r, node n, component c).

Section 21 gives the name each of these has on disk and how the
dimension scales are written.


5. Varies-along
---------------

Every array declares `varies`:

  none         one instance shared by every row; leading dimension
               absent
  row          one instance per row; leading dimension `row`
  group:<k>    one instance per category of group key k; leading
               dimension `group:<k>`; the row's category selects the
               instance

Coordinates use the same mechanism, with one exception: the
coordinates of an `axis` support must have `varies = none`, because
they are part of that support's identity (section 20). A fixed mesh
has coordinates with
`varies = none`; a parametric family has `varies = group:member`; a
moving mesh in a transient has `varies = row`. Coordinates are always
absolute positions; a support has exactly one coordinates array and
displacements are never stored as coordinates. A persisted
displacement is a `derived` array with recipe "minus reference", where
`reference` names a row or a group category on the coordinates array,
never the previous row, so nothing accumulates or drifts. Connectivity
does not vary (section 8).


6. Supports
-----------

A file carries a list of supports. Each has:

  kind         mesh | axis | none
  n_nodes      integer (0 for none)
  n_cells      integer (0 for axis and none)
  support_id   content hash for cross-file identity (section 8)

Mesh cells are stored VTK-style, in one structure, mixed types
allowed: `cell_types (cell)`, `cell_offsets (cell + 1)`,
`cell_connectivity (index)`. There are no blocks; regions are labels.
A support with no cells carries none of those three datasets; the
allowed cell type codes and the rules on the offsets are in section
20.

Each row references exactly one support. When the file declares at
most one support it omits the per-row reference and sets
`aligned = true` (sections 8 and 22).

Weights and normals, when present, are arrays with those roles,
recomputed from coordinates and connectivity by the writer or by a
tool; an importer must not copy them from an upstream exporter.


7. Groups, trajectories, and the unit of generalisation
------------------------------------------------------

A group key partitions rows. Common groups: `member` (which geometry
of a family), `trajectory` (which time series), `case` (which run).
Groups may nest: `trajectory` may declare `parent = member`.

Exactly one group is declared the unit of generalisation. A split
that places rows of one unit on both sides is not a generalisation
test; the validator warns, and tools built on the format should
refuse by default.

A trajectory is the set of rows sharing one value of the group that
the time key declares as its `trajectory_group`. Within a trajectory,
time must be strictly increasing. Trajectories may have different
lengths and irregular time steps.


8. The alignment claim and support identity
---------------------------------------------

A file is aligned when it declares at most one support, so that every
row is on the same one. That is a structural fact of the file, not a
separate claim: an aligned file carries `aligned = true` and no
per-row reference, an unaligned file carries `aligned = false` and a
per-row reference for every row, and the validator checks both against
the supports the file declares (section 22). Index-aligned operations
(per-node comparison across rows, coordinate ensembles, reduced bases
over nodes) are valid only on aligned files, and tools must check the
flag, not assume it.

Files with several supports are valid and unaligned. They can hold
benchmark datasets with varying meshes; the validator reports the
number of supports so that a user knows which operations apply.

Connectivity never varies within a support. Two rows with different
connectivity are on different supports by definition.

Each support also carries a `support_id`: a content hash over
(n_nodes, cell_types, cell_offsets, cell_connectivity) and, for axis
supports, the axis coordinates, computed as SHA-256 over the arrays
serialised as little-endian bytes in that order. Coordinates of mesh
supports are excluded because they may vary. The id adds nothing
inside one file; its purpose is across files: a callable declaring the
support it produces on, several callables being composed, a prediction
compared against a truth file, rows appended from a second file. In
every such case "same support" is an id comparison, not an array
comparison, and a mismatch is an error before any data is read.

9. Uncertainty
--------------

Model outputs are stored as arrays and scalars with the same roles as
data, plus:

  statistic    value | mean | std | quantile | draw
  of           the name of the base quantity this is a statistic of
  quantile     a number in (0, 1) when statistic = quantile

Draws carry the `draw` dimension. Draws of a field are joint across
nodes: draw k of pressure is one whole field. How many draws, from
which seed, in what batches, are the producer's business and its
records, not the format's; the file may repeat them as optional
metadata, and nothing in the format depends on them.

Summaries (mean, std, quantiles) are derived from draws by an open
routine, so a card's numbers can be recomputed from the file.


10. Callables
-------------

A callable is any object that conforms to four things and nothing
more:

  call        keys in, values out: given a keys table (one column per
              key the file declares, any number of rows), return the
              values for the slots it serves, shaped as those slots
              would be stored: (row, [draw], node | cell, component)
              for arrays, (row) for scalars
  to_dict     a nested dictionary of arrays, numbers, and strings
              that fully represents it
  from_dict   the inverse, dispatched on a `type` string
  repr        optional, a one-line description for printing

Everything else a callable knows (its algorithm, fitted state, its
own records, evaluation parameters such as draw count, seed, and
batch size) is inside its dictionary and is its own business. The
format does not constrain it, and future models are integrated by
conforming to the four things above.

Any array or scalar slot may hold stored data or a reference to a
callable. The slot's attributes (role, units, components, statistic)
describe what the slot is in either case; its location and its support
are given by where it sits in the file and are not attributes (section
19); the
content attribute `source` is `data` or `callable:<id>`, and for
callables that serve several slots, `output` names which of the
callable's outputs fills this slot. A callable is stored once under
`/callables/<id>` and may be referenced by any number of slots. A slot
holding data is a dataset; a slot served by a callable is a group with
the same attributes and no data (section 19).

A file with callable slots may have zero rows, and may also have rows
(section 22). With zero rows its key columns
carry only their attributes and bounds, which is the domain the
callable is valid over. Evaluating the file on a keys table yields a
file with the same slots, now holding data. Distillation is that
operation on a grid. Composition is a file whose slots reference
several callables that share a support; the checks are support_id
equality and the intersection of the key bounds.

Storage of a callable is by the codec in section 17: the dictionary
maps to an HDF5 group so that every language round-trips it
identically. The `type` string is public so a reader knows which tool
can evaluate the callable; the dictionary's contents are opaque to
any reader that does not own the type.

11. Metadata
------------

A file carries the minimum a reader needs to open it, and no more:

  format          "mestra/0"; authoritative over the extension
  writer          the tool and version that wrote the file
  created         ISO 8601 timestamp, UTC

An optional `notes` group may hold free-form attributes (a solver
name, a dataset licence, a comment). Nothing in the format depends on
them and no tool may require them.

Lineage, history, upstream links, validation records, sign-off, and
evaluation parameters are deliberately not part of the format. They
are the audit trail, they belong to the callable and the tool that
produced it, and they live in the private part or in that tool's own
records.

12. Public and private
----------------------

Everything in sections 2 through 11 is public: an open reader must be
able to read all of it with no dependency on any proprietary tool.

A callable's dictionary is opaque to readers that do not own its
`type`: they may copy it and must not interpret it. A file may also
carry a `private` group for a producer's own records (lineage,
validation, history) in whatever representation it chooses; readers
treat it the same way and must not require anything in it. Writers
must not place any public information only in either place. A
distilled lookup table is stored data and therefore public; the
callable that produced it, its history, and its validation records
are not.


13. Container
-------------

HDF5. The layout is constrained so that a valid file is also a valid
netCDF-4 file: named dimensions as dimension scales, attributes as
strings or numbers, groups for structure, and, in the data and in the
attributes this format defines, no compound types, no object
references, no HDF5 enums and no variable-length types. The HDF5
dimension scale machinery is exempt from that sentence: its
DIMENSION_LIST is a variable-length list of object references and its
REFERENCE_LIST is a compound, and netCDF-4 itself is built on them, so
a file cannot carry named dimensions without them. A reader ignores
those attributes (section 18).

Strings in tables and in attributes
are fixed-length UTF-8 (section 18). Arrays are chunked along `row`,
which is an unlimited dimension in every file, and may be compressed
with gzip and shuffle (section 23). The extension is `.mes`; the root
attribute `format` is authoritative, not the extension.

Layout sketch. Sections 18 to 25 are the normative detail; `?` marks
an optional attribute. Every axis of every dataset also carries a
dimension scale, named as section 21 requires.

    /                          attrs: format, writer, created,
                               aligned, generalisation_group?
    /row                       dimension scale, unlimited
    /component_<n>             dimension scale, one per component
                               count used
    /draw_<n>                  dimension scale, one per draw count
                               used
    /group_<k>                 dimension scale, one per group key
    /category_<t>              dimension scale, one per category table
    /keys/<name>               (row; may be empty)  attrs: role, units,
                               lower?, upper?, category?,
                               trajectory_group?, parent?
    /scalars/<name>            (row)  attrs: units, source, output?,
                               statistic?, of?, quantile?
                               a group with the same attributes and no
                               data when source is a callable
    /categories/<name>         (category_<name>)  fixed-length strings
    /row_support               (row)  int32; present only when the
                               file declares more than one support
    /supports/<s>              attrs: kind, n_nodes, n_cells,
                               support_id
      /node                    dimension scale
      /cell                    dimension scale, absent when n_cells=0
      /cell_plus_one           dimension scale, absent when n_cells=0
      /index                   dimension scale, absent when n_cells=0
      /coordinates             (row|group|-, node, component)
                               attrs: role, varies, units, components,
                               source
      /cell_types              (cell)       uint8
      /cell_offsets            (cell_plus_one)  int64
      /cell_connectivity       (index)      int64
      /node_arrays/<name>      (row|group|-, [draw], node, component)
                               attrs: role, units, varies, components,
                               source,
                               output?, statistic?, of?, quantile?,
                               category?, recomputed?,
                               derived_from?, recipe?, reference?
                               a group with the same attributes and no
                               data when source is a callable
      /cell_arrays/<name>      same, over cell
    /callables/<id>            attrs: type, repr?; the dictionary as a
                               group by the codec of sections 17
                               and 25
    /notes                     optional free-form attributes
    /private                   opaque


14. Validator
-------------

Every rule has an identifier. The identifiers are stable: within a
major version a rule is never renumbered and a retired rule's
identifier is never reused. The conformance corpus (section 30) names
rules by identifier and nothing else.

Errors (the file is rejected):

  E01  `format` missing or not "mestra/<n>" with n this reader
       accepts
  E02  a key or array without a role, or with a role not in section 3
  E03  a role's cardinality violated (two time keys; no coordinates
       on a mesh or axis support; two coordinates arrays on one
       support; two units of generalisation)
  E04  an array whose leading dimension disagrees with `varies`
  E05  an array whose node or cell count disagrees with its support
  E06  a row referencing a support that does not exist
  E07  `aligned = true` with rows on more than one support
  E08  a `support_id` that does not match the stored arrays
  E09  time not strictly increasing within a trajectory
  E10  a categorical, group, label, or status value outside its
       category table
  E11  a field or scalar without units
  E12  a quantile statistic without a quantile, or a statistic
       without `of`
  E13  a derived array without `derived_from` and `recipe`
  E14  a slot whose `source` names a callable id that does not exist
  E15  a callable group without `type`
  E16  a stored slot whose leading dimension disagrees with the row
       count
  E17  `format`, `writer`, or `created` missing
  E18  public information present only under `/private`

The rules below come from the byte-level layout of sections 18 to 25.

  E19  an attribute whose HDF5 type is not the one section 18
       requires for it: a variable-length string, a string that is
       not UTF-8 with NUL padding, an integer that is not int64, a
       float that is not float64, a boolean that is not int8 or whose
       value is not 0 or 1
  E20  a dataset whose dtype is not allowed for its role (section 19)
  E21  a cell type code not in the table of section 20
  E22  a cell whose node count disagrees with its cell type
  E23  `cell_offsets` that does not start at 0, is not
       non-decreasing, or whose last value is not the length of
       `cell_connectivity`
  E24  a connectivity value outside [0, n_nodes)
  E25  an axis of a dataset with no dimension scale attached, more
       than one scale attached, or a scale whose name is not the one
       section 21 requires
  E26  a fixed-length string that is not valid UTF-8, or that holds a
       NUL byte anywhere but in its trailing padding
  E27  `row` not an unlimited dimension, or a row-dimensioned dataset
       that is not chunked
  E28  `/row_support` present when `aligned = true`, or absent when
       `aligned = false`
  E29  a dataset with a filter other than gzip at level 1 to 9 and
       shuffle
  E30  a slot with `source = data` stored as a group, or a slot with
       `source = callable:<id>` stored as a dataset
  E31  an array slot without `components`, or whose `components`
       disagrees with the length of its component dimension
  E32  a callable dictionary holding something section 25 says is not
       representable: a ragged or mixed nested list, a
       zero-dimensional dataset, a disallowed dtype, a string with an
       embedded NUL, or a top-level key `type` or `repr`
  E33  a name that is not a legal netCDF-4 name, or a producer-chosen
       name that begins with `mestra_`
  E34  a group-varying array whose leading dimension length differs
       from the number of categories of its group key
  E35  an `axis` support whose coordinates do not have `varies = none`
  E36  a `source` that is neither `data` nor `callable:<id>`
  E37  `aligned = true` with more than one support declared
  E38  a mesh support missing `cell_types`, `cell_offsets` or
       `cell_connectivity`, or an `axis` or `none` support carrying
       any of them

Warnings (the file is accepted; the reader must report):

  W01  a split that places rows of one generalisation unit on both
       sides
  W02  rows with status other than converged
  W03  non-finite values in a field or scalar, with the row and name
  W04  a key value outside its declared bounds
  W05  more than one support (index-aligned operations unavailable)
  W06  weights or normals present but not marked as recomputed
  W07  a group key with no category table entry for some value
  W08  the observed range of a key differs from its declared bounds
       by more than a stated tolerance (possibly stale bounds)
  W09  a categorical key stored as floating point
  W10  a units string the validator cannot parse
  W11  an attribute or a group this reader does not know, ignored
       under section 28
  W12  a chunk shape that is not the default of section 23
  W13  a fixed-length string dataset whose size is larger than its
       longest element needs
  W14  `created` that is not an ISO 8601 UTC timestamp
  W15  a support that no row references


15. Conformance
---------------

The spec plus a corpus of golden files define conformance. Each
golden file ships with the expected outcome of every validator rule
and the expected value at named coordinates (row r, node n, component
c), in every language's natural axis order. Every reader and writer,
in every language, runs the corpus in its own test suite. No
implementation is the reference.


16. Decisions taken on 2026-09-19, and what is still open
----------------------------------------------------------

Taken:

  1. Extension `.mes`.
  2. Units in the UDUNITS grammar; unparseable is a warning in v0.
  3. Fixed-length UTF-8 strings for category tables.
  4. `split` is a key role.
  5. Coordinates are positions, one array per support; displacement
     only as a derived array relative to a declared reference.
  6. Hashes are support identity for cross-file checks, not an
     in-file claim; alignment is structural.
  7. A callable is exactly call, to_dict, from_dict, and an optional
     repr; it fills slots, is stored once by the codec with a public
     `type`, and everything else is inside its own dictionary.
  8. Provenance, lineage, history, validation, sign-off, and
     evaluation parameters are not part of the format; the file
     carries format, writer, and created, plus optional notes.

  9. `status` is a key role with an open category table; label
     category tables are optional.
 10. Bounds live on the key columns; there is no separate domain
     group, and a file with callable slots may have zero rows.

Taken on 2026-09-19 while pinning the byte layout (sections 18 to 30):

 11. A file with callable slots may also carry rows, for example the
     training design. What decides whether a slot holds data is its
     `source` and never the row count. Said explicitly in section 22;
     this closes the one item that was open.
 12. The component dimension is always present, with length 1 for a
     single-component quantity; the draw dimension is present only
     when the slot holds draws.
 13. `row` is an unlimited dimension in every file, which is what
     makes a zero-row file a legal netCDF-4 file.
 14. A slot served by a callable is a group; a slot holding data is a
     dataset.
 15. float32 is not allowed anywhere; a producer that computes in
     single precision widens on write.
 16. A zero-dimensional array in a callable's dictionary is stored as
     an attribute, because no rule that preserved it as an array
     could round-trip in MATLAB and C++ as well as in Python.

Still open: nothing.


17. Dictionary codec
--------------------

`to_dict` yields a nested dictionary whose leaves are numeric arrays,
numbers, booleans, or strings. It maps to an HDF5 group as follows,
so that every language round-trips it identically:

  nested dictionary   a subgroup with the key as its name
  numeric array       a dataset, C order, with a dimension scale on
                      each axis named `mestra_<dataset>_d<i>`
  number or boolean   an attribute on the enclosing group
  string              an attribute on the enclosing group,
                      fixed-length UTF-8
  list of numbers     a one-dimensional dataset
  list of strings     a one-dimensional fixed-length string dataset
  null                an attribute with the reserved string "\0null"
  anything else       not representable; the writer must refuse

The dimension scale names are per dataset because two datasets in one
group may have different lengths on the same axis number, and the
reserved prefix keeps them apart from dictionary keys.

Key names must be valid netCDF-4 names and must not begin with
`mestra_`, which is reserved for the container everywhere in the file.
Attribute order and key order are not
significant. A reader reconstructs the dictionary and hands it to
`from_dict` for the group's `type`. Section 25 fixes the cases this
table leaves open.

18. Attribute encodings
-----------------------

Every attribute this specification names has exactly one encoding. A
writer must use it; a reader must refuse an attribute stored any other
way (E19).

  boolean   H5T_STD_I8LE (int8), scalar dataspace, value 0 for false
            and 1 for true. No other value is legal.
  integer   H5T_STD_I64LE (int64), scalar dataspace.
  float     H5T_IEEE_F64LE (float64), scalar dataspace. NaN and the
            infinities may appear in datasets; an attribute that
            declares a bound or a quantile must be finite.
  string    a fixed-length HDF5 string, scalar dataspace, with
            character set H5T_CSET_UTF8 and padding H5T_STR_NULLPAD.

A writer must not use a variable-length string anywhere in the file.

The size of a string attribute is the number of bytes in the UTF-8
encoding of the value, or 1 when the value is the empty string, since
HDF5 has no zero-size string type. The stored bytes are that encoding,
padded on the right with NUL bytes to the declared size. A reader
strips trailing NUL bytes and then decodes UTF-8. A string value must
not contain a NUL byte; the null sentinel below is the only exception.

A list of strings is never an attribute. Where a list of names is
needed in an attribute (`derived_from`), the value is a single string
holding the names separated by one space; names cannot contain a
space, so this is unambiguous.

Null sentinel. The reserved value of section 17 is a string attribute
whose stored bytes are exactly 0x00 0x6E 0x75 0x6C 0x6C, that is one
NUL byte followed by "null", with size 5. Because no other string may
contain a NUL byte, the sentinel cannot be confused with a value. It
occurs only inside a callable's dictionary.

The netCDF-C string reader alters a value that begins with a NUL byte;
it reports the sentinel as "null" rather than as the five stored
bytes. The sentinel is therefore exact only through an HDF5 reader.
This costs nothing, because the sentinel occurs only inside a
callable's dictionary, which a generic netCDF tool copies and does not
interpret, and because a conforming reader reads the codec through
HDF5 and compares the raw bytes.

Names. Every group, dataset, attribute and dimension name in the file
must be a legal netCDF-4 name: not empty, no "/" and no NUL, not
beginning or ending with a space, and built from letters, digits,
underscore, hyphen, "." and "+". Names a producer chooses (keys,
scalars, category tables, arrays, support groups, callable ids,
dictionary keys) must not begin with `mestra_`, which this format
reserves everywhere in the file and not only in the codec (E33).

Attributes written by the HDF5 dimension scale machinery and by
netCDF-C are not part of this format and a reader must ignore them
wherever they appear: CLASS, NAME, DIMENSION_LIST, REFERENCE_LIST,
DIMENSION_LABELS, _Netcdf4Dimid, _Netcdf4Coordinates, _nc3_strict and
_NCProperties.


19. Dataset encodings
---------------------

Every numeric dataset is little-endian and in C (row-major) order. The
format has no missing-value convention: a writer must not set an HDF5
fill value and must not write a `_FillValue` attribute, a reader must
ignore one if it finds it, and every element the file declares must be
written. Missing floating-point data is NaN, which the validator
reports (W03). Missing integer data has no representation; use a
status key or a category for it.

Dtypes by role. Any other dtype is an error (E20). float32 is not
allowed anywhere: a producer that computes in single precision widens
on write, so that two readers never disagree about a value.

  coordinates, field, derived, weight, normal   float64
  a scalar under /scalars                       float64
  label                                         int32 or int64
  key with role design, condition, time         float64
  key with role categorical, group, split,
      status                                    int32 or int64
  key with role id                              int64, or a
                                                fixed-length UTF-8
                                                string
  /row_support                                  int32
  cell_types                                    uint8
  cell_offsets                                  int64
  cell_connectivity                             int64
  /categories/<name>                            fixed-length UTF-8
                                                string
  a dataset inside a callable's dictionary      section 25

A fixed-length string dataset has character set H5T_CSET_UTF8 and
padding H5T_STR_NULLPAD, as in section 18. Its size is the largest
UTF-8 byte length among its elements, or 1 when every element is
empty; shorter elements are padded on the right with NUL bytes. A
reader strips trailing NUL bytes and decodes UTF-8. A size larger than
the longest element needs is legal and draws a warning (W13).

Shapes. The logical order of an array is (row | group:<k> | nothing,
[draw], node | cell, component), stored in that order. Three rules
make the shape of every slot decidable without reading it:

  - the leading dimension is present when `varies` is `row` or
    `group:<k>` and absent when `varies` is `none` (E04);
  - the component dimension is always present, with length 1 for a
    single-component quantity. This holds for every array role,
    including labels and one-component fields. A reader therefore
    never has to guess whether a trailing axis is a component axis;
  - the draw dimension is present only when the slot holds draws,
    that is when `statistic` is `draw`. A slot with `statistic` of
    `value`, `mean`, `std` or `quantile` has no draw dimension.

A dataset under /scalars has exactly one dimension, `row`. A dataset
under /keys has exactly one dimension, `row`. Neither carries a
component dimension.

Zero rows. The `row` dimension is always an HDF5 unlimited dimension
(section 21), so a file with no rows stores each row-dimensioned
dataset with shape (0, ...) and the rest of its extents as usual. A
zero-length extent is legal only for the `row` dimension and for a
zero-length axis of a dictionary dataset (section 25); every other
dimension has length one or more.

Slots. A slot whose `source` is `data` is a dataset. A slot whose
`source` is `callable:<id>` is an empty HDF5 group carrying the slot's
attributes and no datasets (E30). A group is used because a callable
slot has no shape and no row count of its own, and this makes the two
kinds of slot distinguishable without reading any data, with rows
present or absent.

Required attributes, by object:

  /                       format (string), writer (string), created
                          (string), aligned (boolean);
                          generalisation_group (string) when the file
                          declares any group key
  /keys/<name>            role (string); units (string) for design,
                          condition and time; category (string) for
                          categorical, group, split and status;
                          optional lower and upper (float);
                          trajectory_group (string) on the time key
                          when the file declares any group key;
                          optional parent (string) on a group key
  /scalars/<name>         units (string), source (string), components
                          is not used; output (string) when source is
                          a callable; optional statistic, of, quantile
  /categories/<name>      no required attribute
  /row_support            no required attribute
  /supports/<s>           kind (string), n_nodes (integer), n_cells
                          (integer), support_id (string)
  /supports/<s>/coordinates
                          role = "coordinates", varies (string),
                          units (string), components (integer),
                          source (string)
  /supports/<s>/node_arrays/<name> and .../cell_arrays/<name>
                          role (string), varies (string), components
                          (integer), source (string); units (string)
                          for field and derived; category (string)
                          when a label uses a table; recomputed
                          (boolean) on weight and normal;
                          derived_from (string) and recipe (string)
                          on derived, with optional reference;
                          output (string) when source is a callable;
                          optional statistic, of, quantile
  /callables/<id>         type (string), optional repr (string)

`components` is required on every array slot, and for a slot that
holds data it must equal the length of its component dimension (E31).
It is the only way a callable slot can declare its width.

`location` and `support` are not attributes. A slot's location is
`node` when it sits under `node_arrays` and `cell` when it sits under
`cell_arrays`; its support is the support group it sits under; a
scalar has neither. `source` is either the string `data` or the string
`callable:<id>` and nothing else (E36).


20. Cells and cell types
------------------------

`cell_types` holds VTK cell type codes as uint8. The allowed codes in
version 0, with the number of nodes each takes:

  code  cell                      nodes
     1  vertex                        1
     3  line                          2
     5  triangle                      3
     7  polygon                       3 or more
     9  quadrilateral                 4
    10  tetrahedron                   4
    12  hexahedron                    8
    13  wedge                         6
    14  pyramid                       5
    21  quadratic line                3
    22  quadratic triangle            6
    23  quadratic quadrilateral       8
    24  quadratic tetrahedron        10
    25  quadratic hexahedron         20
    26  quadratic wedge              15
    27  quadratic pyramid            13

Any other code is an error (E21). The order of the nodes within a cell
is the VTK order for that code; this format adds nothing to it.

`cell_offsets` has length n_cells + 1. Its first value is 0, its
values are non-decreasing, and its last value is the length of
`cell_connectivity` (E23). Cell j occupies the half-open range
[cell_offsets[j], cell_offsets[j+1]) of `cell_connectivity`. The
length of that range must equal the node count of cell_types[j], or be
3 or more when cell_types[j] is 7 (E22). Every value in
`cell_connectivity` must be in [0, n_nodes) (E24).

A support of kind `axis` or `none` has n_cells = 0 and carries no
`cell_types`, `cell_offsets` or `cell_connectivity` dataset and no
`cell` dimension (E38). A support of kind `none` has n_nodes = 0 and
no coordinates; it exists so that a slot may declare that it lives on
no support, and scalars do not reference it.

An `axis` support has exactly one coordinates array and that array
must have `varies = none` (E35). The axis coordinate is part of the
support's identity (section 24), so it cannot differ between rows; a
one-dimensional quantity that does differ between rows is a field on
the axis, not the axis.


21. Named dimensions on disk
----------------------------

Every axis of every dataset in the file must have exactly one HDF5
dimension scale attached to it (E25). This is what makes the file a
netCDF-4 file and what lets a reader in a column-major language
permute by name.

A dimension scale dataset is written exactly as netCDF-C writes a
dimension that has no coordinate variable:

  - one-dimensional, dtype H5T_IEEE_F32BE, length equal to the
    dimension's length;
  - attribute CLASS = "DIMENSION_SCALE";
  - attribute NAME = the 53-character string

      This is a netCDF dimension but not a netCDF variable.

    followed by the dimension's length as a decimal integer right
    justified in ten columns, which is the C format "%s%10d" and
    gives a 63-character value;
  - no values are written into it and a reader must not read any.

Setting CLASS and NAME is what H5DSset_scale does, with NAME given as
the string above; attaching is H5DSattach_scale. A writer that calls
those two functions produces the layout netCDF-C expects.

The dimension's name is the scale dataset's HDF5 link name and not its
NAME attribute, which holds the sentence above in every file. A reader
must take the name from the link, because a reader that took it from
NAME would find every dimension in the file called the same thing.
H5DS API calls and library wrappers that report a "dimension label"
return NAME, so this is worth checking early in each language.

A dimension scale that is unlimited is chunked with chunk length 1,
which is what netCDF-C writes; a scale that is not unlimited is
contiguous. No value is ever stored in either, so the choice is
visible only in the file's bytes.

Where the scales live and what they are called. All file-level scales
are at the root group, because netCDF-4 resolves a dimension in the
group that holds the variable or in any ancestor group, and because
user-chosen names live in subgroups and therefore cannot collide with
them:

  row            unlimited; length equal to the number of rows
  component_<n>  one for each distinct component count n in the file
  draw_<n>       one for each distinct draw count n in the file
  group_<k>      one for each group key k; length equal to the number
                 of categories of k
  category_<t>   one for each category table t under /categories;
                 length equal to the number of entries

Support-local scales are in the support's own group, because their
lengths differ between supports:

  node           length n_nodes
  cell           length n_cells; absent when n_cells is 0
  cell_plus_one  length n_cells + 1; absent when n_cells is 0
  index          length of cell_connectivity

Scales for the datasets inside a callable's dictionary are in the
group that holds the dataset and are named `mestra_<dataset>_d<i>`,
where <dataset> is the dataset's link name and i is the axis number
from 0 (section 25). Per-dataset names are needed because two
dictionary datasets in one group may have different lengths on the
same axis number, and the reserved prefix keeps them apart from
dictionary keys.

Logical name to name on disk:

  row           row
  group:<k>     group_<k>
  draw          draw_<n>, n the draw count
  node          node
  cell          cell
  component     component_<n>, n the component count
  cell_plus_one cell_plus_one
  index         index

A reader recovers the logical name from the name on disk by this
table, and must do so by name and never by position.

The instance index of `varies = group:<k>`. Category ids are the
zero-based positions of the entries in the category table: the first
entry is id 0. A key with role categorical, group, split or status
stores category ids, so its values are in [0, number of entries)
(E10). Instance i of an array with `varies = group:<k>` is the
instance for category id i, in category-table order, and the length of
its leading dimension equals the number of categories of k (E34). A
row's instance is therefore the value of key k in that row, used
directly as an index, with no lookup.

Labels without a category table are the exception: their values are
their own categories (CAD face ids, for example) and may be any
integers.

`row` in a zero-row file. `row` is an unlimited dimension in every
file, so the scale dataset has shape (0,) with an unlimited maximum
when the file has no rows, and shape (n,) with an unlimited maximum
otherwise. Making it unlimited in every file has three effects: a
zero-row file is a netCDF-4 file with an empty record dimension rather
than an illegal zero-length fixed dimension; rows can be appended
without rewriting; and the layout matches what netCDF-C itself writes,
so a round trip through netCDF-C changes nothing. The scale dataset's
own length must equal the row count, so that a reader can learn the
row count from a file that has no row-dimensioned datasets at all.
netCDF-C infers the length of an unlimited dimension from the
variables that use it and ignores the scale dataset's length; the two
must agree.


22. Alignment, row_support, and rows with callable slots
--------------------------------------------------------

`aligned` is a boolean root attribute and it is decidable from the
file:

  - a file that declares at most one support must set aligned = true
    and must not have a /row_support dataset;
  - a file that declares more than one support must set
    aligned = false and must have a /row_support dataset (E28, E37).

A file with no rows and one support is aligned; so is a file with no
supports at all.

/row_support is int32 with one dimension, `row`. Its value for a row
is the zero-based position of that row's support in the file's support
order, and the support order is the order of the support group names
under /supports sorted by their UTF-8 bytes. A value outside
[0, number of supports) is an error (E06). Sorting by bytes is used
because it is the one ordering every language produces identically;
HDF5 link order is not.

Rows and callable slots together. A file may have rows and callable
slots at the same time. When it does, the key columns hold rows, for
example the design the callable was fitted on, and the callable slots
simply hold no data. What decides whether a slot is stored data is its
`source` and nothing else; the row count decides nothing. A file with
rows in which every slot is a callable is valid, and so is a file with
rows in which some slots are data and some are callables. Whether to
publish the training design this way is the producer's choice; it
makes extrapolation warnings and dataset cards possible and it
discloses the design.


23. Chunking, compression and fill
----------------------------------

Every dataset that has a `row` dimension must be chunked, because
`row` is unlimited. Its chunk shape must be (c, ...) where every
non-row extent in the chunk is that dimension's full length and c is
one or more, so that a row range is one contiguous run of chunks and
no other slot is touched. When a single row of a dataset is larger
than 8 MiB, a writer may also chunk the node or cell dimension, and
must then set c to 1.

The default for c: let b be the size in bytes of one row of the
dataset, that is the dtype size times the product of the non-row
extents, with a zero-length extent counted as 1. Then

  c = floor(1048576 / b), or 1 when that is 0;
  c = the row count, when the row count is one or more and c is
      larger than it.

1048576 is 1 MiB. This is a default, not a requirement: a writer may
choose another c and a reader must accept it. A dataset whose chunk
shape is not the default draws a warning (W12), because a corpus file
is expected to use it.

A dataset with no `row` dimension may be contiguous. When it is
chunked or compressed, the default chunk is the whole dataset if that
is 1 MiB or less, and otherwise the same rule applied to its leading
dimension. A dimension scale dataset is never compressed and is
contiguous unless it is unlimited.

Compression. The only filters allowed are gzip at levels 1 to 9 and
shuffle; shuffle may be used with or without gzip. A writer must use
no other filter, must not use fletcher32, and a reader must refuse a
dataset with any other filter (E29). The restriction is portability:
gzip and shuffle are the two filters every HDF5 and netCDF-4 build
has.

Fill. A writer must not set an HDF5 fill value on any dataset, so
every dataset keeps the HDF5 default. A reader must not treat any
value as missing on the strength of a fill value.


24. support_id
--------------

`support_id` is the SHA-256 digest of a byte string built from the
support's arrays, in this order, with nothing between them:

  1. n_nodes as one int64, little-endian;
  2. `cell_types`, as uint8 in storage order;
  3. `cell_offsets`, as int64 little-endian in storage order;
  4. `cell_connectivity`, as int64 little-endian in storage order;
  5. for a support of kind `axis` only, the coordinates array as
     float64 little-endian in storage order, which is (node,
     component) with component of length 1.

A support of kind `axis` or `none` has no cell arrays, so steps 2 to 4
contribute no bytes at all for it; they are not replaced by anything.
Coordinates of a mesh support are not hashed, because they may vary
between rows while the support does not.

The attribute is the digest in lower-case hexadecimal, 64 characters.
A digest that does not match the stored arrays is an error (E08).

Worked example. A mesh support of six nodes and two quadrilaterals:

  n_nodes            6
  cell_types         [9, 9]
  cell_offsets       [0, 4, 8]
  cell_connectivity  [0, 1, 4, 3, 1, 2, 5, 4]

The byte string is 8 + 2 + 24 + 64 = 98 bytes long and begins
06 00 00 00 00 00 00 00 09 09 00 00 .... Its digest is

  96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a19c943936c7

An implementation that reproduces that string has the rule right.
Two more, for the cases with no cells:

  an axis support of four nodes at 0.0, 0.5, 1.0, 1.5
  57467fe7370808bdb0ad01b95d963f59e8bc6762f90f96049453ae33bb05a54c

  a support of kind none, n_nodes 0
  af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc


25. The dictionary codec on disk
--------------------------------

Section 17 gives the mapping. This section fixes the cases an
implementer would otherwise decide alone. Throughout, a "number" is a
Python int or float, a MATLAB scalar double or int64, or a C++
arithmetic scalar; an "array" has one dimension or more.

Scalars and their types. A number, a boolean or a string is an
attribute on the enclosing group, encoded as section 18 requires. The
dtype carries the type, and the three cases are distinct:

  int8      a boolean; the value is 0 or 1 and a reader returns a
            boolean, never an integer
  int64     an integer
  float64   a float
  a string  a string

An integer and a float that happen to be equal are therefore different
values in the file and stay different across a round trip. A boolean
array is an int8 dataset, and int8 means boolean there too.

Zero-dimensional arrays. A zero-dimensional array must be written as
an attribute, that is as the number or boolean it holds, and a reader
returns a number. It must not be written as a zero-dimensional
dataset. The reason is that MATLAB and most C++ containers cannot
represent the difference between a scalar and a zero-dimensional
array, so a rule that preserved the difference would round-trip in
Python and not elsewhere, and the corpus could not state one expected
result. Making the choice at write time costs the writer one line and
makes the round trip exact in all three languages.

Empty arrays. An array with a zero in its shape is a dataset with that
shape, and every zero-length axis must be created with an unlimited
maximum so that the dimension is legal in netCDF-4 (section 21). Its
dtype is kept, so an empty float64 array and an empty int64 array are
different values. An empty list with no element type known must be
written as an empty float64 dataset with shape (0,); a producer that
needs an empty list of strings writes an empty fixed-length string
dataset with shape (0,) and size 1.

Lists. A list of numbers of one type is a one-dimensional dataset; a
list of strings is a one-dimensional fixed-length string dataset. A
nested list is allowed only when it is rectangular and numeric, and it
is then the array it describes. A ragged nested list, a list mixing
numbers and strings, a list of dictionaries and a list of nulls are
not representable and the writer must refuse them (E32).

Allowed dtypes inside a dictionary: int8 (boolean), int32, int64,
float64 and fixed-length UTF-8 strings. Any other dtype, including
float32 and unsigned integers, is not representable and the writer
must refuse it (E32).

Unicode. Strings are UTF-8; the declared size of a fixed-length string
is a count of bytes, not of characters, and a writer must never split
a character across the boundary. A string that contains a NUL byte is
not representable (E32); the null sentinel of section 18 is not a
string value.

Arrays. A numeric array is a dataset in C order, little-endian, with a
dimension scale on each axis named `mestra_<dataset>_d<i>` as section
21 requires.

Key order. Dictionary key order is not significant and a reader must
not depend on it, on HDF5 link order or on attribute order. A writer
creates links and attributes in ascending order of their UTF-8 bytes,
so that the same dictionary produces the same file.

The reserved prefix. A dictionary key must not begin with `mestra_`.
A reader reconstructing a dictionary skips every member and every
attribute whose name begins with `mestra_`, and also the HDF5 and
netCDF machinery attributes listed in section 18.

`type` and `repr`. They are string attributes on the callable's own
group /callables/<id>, not entries of the dictionary: `type` is
required and `repr` is optional and is one line. The dictionary is
stored on that same group, so at its top level the two names are taken
and a writer must refuse a dictionary whose top-level keys include
`type` or `repr` (E32). Nested dictionaries may use both names
freely.

A reader reconstructs the dictionary, reads `type`, and hands the pair
to the `from_dict` registered for that type. A reader that does not
know the type may still copy the group unchanged, and must not
interpret it.


26. The keys table in each language
-----------------------------------

`call` takes a keys table: one column per key the file declares, in
the file's key order, and any number of rows. The file's key order is
the order of the names under /keys sorted by their UTF-8 bytes. The
row order of the table is the evaluation order, and the outputs follow
it: output row i is the result for table row i.

  Python   a mapping from key name to a one-dimensional numpy array,
           with every array the same length. A caller may instead
           pass a two-dimensional array of shape (rows, keys) together
           with a list of key names in the file's key order; an
           implementation must accept both.
  MATLAB   a table whose variable names are the key names.
  C++      a struct of vectors, one vector per key, with the key names
           as the member names, and every vector the same length.

In every language a column of a key with role id may be strings, and
every other column is numeric. A callable reads the columns it
declares and ignores the rest. A missing column that the callable
declares is an error at call time.


27. The affine reference callable
---------------------------------

`affine` is the one callable type this package defines. It exists so
that the protocol, the codec and evaluation can be conformance-tested
in every language with no proprietary model. It is deterministic and
produces no draws.

For each output slot it serves, with x the vector of key values in the
declared key order,

    y = A x + b

and y is reshaped to the slot's shape in C order.

Its `type` is the string `affine`. Its dictionary is exactly:

  keys      a list of key names, as a one-dimensional fixed-length
            UTF-8 string dataset. This is the declared key order, and
            x is built by taking those keys from the keys table in
            that order.
  outputs   a dictionary with one entry per slot the callable serves.
            The entry's name is the value of the slot's `output`
            attribute. Each entry is a dictionary with exactly:
      A       float64, shape (n_out_flat, n_keys)
      b       float64, shape (n_out_flat,)
      shape   int64, one-dimensional: the slot's dimensions after the
              row dimension and in order. For an array slot on a mesh
              or axis support that is [node count, component count].
              For a scalar slot it is the empty int64 array, shape
              (0,).

n_out_flat is the product of `shape`, and the empty product is 1, so a
scalar slot has n_out_flat = 1. n_keys is the length of `keys`. There
is nothing else in the dictionary; a writer must not add to it and a
reader must refuse an `affine` dictionary with any other key.

Evaluation. For a keys table with R rows, build X of shape
(R, n_keys) from the declared keys as float64, compute
Y = X A' + b broadcast over rows, giving (R, n_out_flat), and reshape
each row of Y to `shape` in C order. The slot's stored form is then
(row, node | cell, component) for an array and (row) for a scalar. An
`affine` callable never sets `statistic` to `draw`.

Worked example. Two keys in the order mach, alpha. One scalar slot cl
and one node-array slot pressure on a support of six nodes with one
component:

  cl        A = [[2.0, 0.1]]        b = [0.05]     shape = []
  pressure  A = [[1.0, 0.0],        b = [0.0,      shape = [6, 1]
                 [2.0, 0.0],             0.1,
                 [3.0, 0.5],             0.2,
                 [4.0, 0.5],             0.3,
                 [5.0, 1.0],             0.4,
                 [6.0, 1.0]]             0.5]

On the one-row keys table mach = 0.5, alpha = 4.0:

  cl        = 2.0*0.5 + 0.1*4.0 + 0.05 = 1.45
  pressure  = [0.5, 1.1, 3.7, 4.3, 6.9, 7.5], as shape (1, 6, 1)

docs/examples/affine_zero_rows.mes is this callable, written out.


28. Version handling
--------------------

The root attribute `format` is "mestra/<major>". A reader of
"mestra/0" must refuse any other major version and say so; it must not
try to read it partially (E01). The major version changes only when a
file that a version-0 reader would read would mean something else.

Within a major version:

  - new optional attributes may be added, and a reader that does not
    know an attribute must ignore it and report it (W11);
  - new optional groups may be added at the root and inside a support,
    and a reader that does not know a group must ignore it and report
    it (W11);
  - new roles, new statistics, new cell type codes, new key words for
    `source` and new required attributes are not additive and must not
    be added within a version;
  - nothing this document requires is ever removed, renamed or given a
    different meaning within a version.

A reader must therefore be written so that an unknown name is a report
and not a failure, and a writer must not rely on an older reader
noticing anything it adds.


29. What a reader must offer
----------------------------

These are requirements on readers. They constrain no byte in the file;
the layout of sections 19 to 23 is what makes them possible.

  - Lazy access. A reader must be able to read one slot, for a range
    of rows, without reading any other slot and without reading the
    rows outside the range. Chunking along `row` with the non-row
    extents full (section 23) is what makes that one contiguous run
    of chunks.
  - Opening a file must not read any array. A reader must be able to
    report the row count, the keys with their roles and bounds, the
    supports with their ids, and every slot with its attributes,
    having read attributes and dataspaces only.
  - Dimensions by name. A reader must expose the logical dimension
    name of every axis it returns (section 21), and must permute by
    name. A column-major reader may return whatever order is natural
    for it, provided the names come with it.
  - Unknown things. A reader must ignore what section 28 says to
    ignore, must report it, and must not fail on it.
  - A reader must not require /notes or /private, and must not
    interpret /private.


30. Conformance corpus conventions
----------------------------------

The corpus lives under vectors/. One directory per case, named in
lower case with underscores, holding exactly two files:

  vectors/<case>/case.mes        the golden file
  vectors/<case>/expected.json   what every implementation must find

and one vectors/manifest.json listing the cases:

  {"corpus": 0,
   "cases": [{"name": "<case>", "description": "..."}, ...]}

with `cases` sorted by name.

expected.json is canonical JSON (below) with exactly these fields:

  description   a string, one or two sentences
  validator     {"errors": [ids], "warnings": [ids]}, each a sorted
                list of the rule ids of section 14 that the file must
                produce, with no duplicates. A file that must validate
                cleanly has two empty lists.
  support_ids   an object from support group name to the 64-character
                lower-case hexadecimal digest
  probes        a list of objects, each naming one stored value:
                  slot       the HDF5 path of the dataset, for example
                             "/supports/s0/node_arrays/pressure"
                  row        the row index; omitted when the slot has
                             no row dimension
                  node       the node index, or the cell index for a
                             cell array; omitted when the slot has no
                             node or cell dimension
                  component  the component index; omitted when the
                             slot has no component dimension
                  draw       the draw index; present only when the
                             slot has a draw dimension
                  value      the value, as a decimal string
  codec         an object from callable id to the round trip of that
                callable's dictionary, in the tagged form below

Numbers as text. Every float in expected.json is a string in the C
format "%.17e", which every language produces identically and which
round-trips a float64 exactly: "1.45000000000000000e+00". The three
non-finite values are the strings "nan", "inf" and "-inf". Integers
are JSON numbers. A comparison parses the string to float64 and
requires bit equality, so that no implementation has to agree about
how a float is printed.

Canonical JSON. UTF-8 with no byte order mark; object keys sorted by
their Unicode code points; no whitespace except a single newline at
the end of the file; the separators are "," and ":"; non-ASCII
characters are written literally and not escaped.

The tagged form for a dictionary round trip. Every value is an object
with a tag `t`, so that a dictionary is never confused with a leaf:

  {"t":"dict","v":{ key: value, ... }}
  {"t":"i64","v":42}
  {"t":"f64","v":"2.50000000000000000e+00"}
  {"t":"bool","v":true}
  {"t":"str","v":"affine"}
  {"t":"null"}
  {"t":"array","dtype":"float64","shape":[6,2],"data":[...]}
  {"t":"strings","shape":[2],"data":["mach","alpha"]}

`dtype` is one of "bool", "int32", "int64", "float64". `data` is the
elements flattened in C order; float64 elements are the decimal
strings above, int32 and int64 elements are JSON numbers, bool
elements are true and false.

Golden files must be byte reproducible: two runs of the generator on
one machine must produce identical bytes. Three things are needed.
HDF5 object time tracking must be off, which is `track_times=False` on
every h5py dataset. `created` and `writer` must be fixed values rather
than the time and the version of the run. And the order in which the
generator creates links, attributes and scale attachments must be
fixed, because HDF5 stores the links of a small group in creation
order; an order that comes out of a hash table or a dictionary
iteration is not fixed. The generator is committed, so its order is
the corpus's order and no one has to reconstruct it.

Byte identity across HDF5 versions is not required and must not be
tested, because the HDF5 library decides the superblock and the object
header layout. The normative comparison between two files that should
be the same is structural equality:

  - the same set of object paths;
  - at each path, the same kind (group or dataset);
  - for each dataset, the same dtype including byte order, character
    set and padding, the same shape, the same maximum shape, the same
    chunk shape, the same filters with the same parameters, and
    element-by-element equal contents, with floats compared as bits so
    that NaN equals NaN;
  - at each path, the same set of attribute names excluding the
    machinery names of section 18, and for each, the same dtype and
    the same value;
  - the same dimension scale attached to each axis of each dataset,
    compared by the dimension's name.
