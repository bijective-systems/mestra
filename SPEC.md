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
  key        unused; keys are separate datasets, not one matrix

The logical order of an array is (row | group | none, [draw], node |
cell, component). On disk, arrays are stored in that order in C
(row-major) layout. A reader in a column-major language returns
whatever order is natural for it, but must expose the dimension names
so that permutation is by name, never by position. Two readers in two
languages must agree on the value at (row r, node n, component c).


5. Varies-along
---------------

Every array declares `varies`:

  none         one instance shared by every row; leading dimension
               absent
  row          one instance per row; leading dimension `row`
  group:<k>    one instance per category of group key k; leading
               dimension `group:<k>`; the row's category selects the
               instance

Coordinates use the same mechanism. A fixed mesh has coordinates with
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
  n_nodes      integer
  n_cells      integer (0 for axis and none)
  support_id   content hash for cross-file identity (section 8)

Mesh cells are stored VTK-style, in one structure, mixed types
allowed: `cell_types (cell)`, `cell_offsets (cell + 1)`,
`cell_connectivity (index)`. There are no blocks; regions are labels.

Each row references exactly one support. When every row references
the same support the file may omit the per-row reference and must set
`aligned = true` (section 8).

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

A file is aligned when every row references one support. That is a
structural fact of the file, not a separate claim: an aligned file
carries `aligned = true`, and the validator checks it against the
per-row references. Index-aligned operations (per-node comparison
across rows, coordinate ensembles, reduced bases over nodes) are valid
only on aligned files, and tools must check the flag, not assume it.

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
callable. The slot's attributes (role, units, components, location,
support, statistic) describe what the slot is in either case; the
content attribute `source` is `data` or `callable:<id>`, and for
callables that serve several slots, `output` names which of the
callable's outputs fills this slot. A callable is stored once under
`/callables/<id>` and may be referenced by any number of slots.

A file with callable slots may have zero rows. Its key columns then
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
strings or numbers, groups for structure, no compound types, no object
references, no HDF5 enums, no variable-length compound. Strings in
tables are fixed-length UTF-8. Arrays are chunked along `row` and may
be compressed. The extension is `.mes`; the root attribute `format` is
authoritative, not the extension.

Layout sketch:

    /                          attrs: format, writer, created,
                               aligned, generalisation_group
    /keys/<name>               (row; may be empty)  attrs: role, units,
                               lower?, upper?, category?,
                               trajectory_group?, parent?
    /scalars/<name>            (row)  attrs: units, source, output?,
                               statistic?, of?
    /categories/<name>         (n)    fixed-length strings
    /row_support               (row)  omitted when aligned
    /supports/<id>             attrs: kind, n_nodes, n_cells,
                               support_id
      /coordinates             (row|group|-, node, component)
      /cell_types              (cell)
      /cell_offsets            (cell+1)
      /cell_connectivity       (index)
      /node_arrays/<name>      (row|group|-, [draw], node, component)
                               attrs: role, units, varies, source,
                               output?, statistic?, of?, category?,
                               derived_from?, recipe?, reference?
      /cell_arrays/<name>      same, over cell
    /callables/<id>            attrs: type, repr?; the dictionary as a
                               group by the codec of section 17
    /notes                     optional free-form attributes
    /private                   opaque


14. Validator
-------------

Errors (the file is rejected):

  - `format` missing or not "mestra/<n>" with n this reader accepts
  - a key or array without a role, or with a role not in section 3
  - a role's cardinality violated (two time keys; no coordinates on a
    mesh support; two units of generalisation)
  - an array whose leading dimension disagrees with `varies`
  - an array whose node or cell count disagrees with its support
  - a row referencing a support that does not exist
  - `aligned = true` with rows on more than one support
  - a `support_id` that does not match the stored arrays
  - time not strictly increasing within a trajectory
  - a categorical, group, label, or status value outside its category
    table
  - a field or scalar without units
  - a quantile statistic without a quantile, or a statistic without
    `of`
  - a derived array without `derived_from` and `recipe`
  - a slot whose `source` names a callable id that does not exist
  - a callable group without `type`
  - a stored slot whose leading dimension disagrees with the row
    count, or a file with rows whose slots are all callables
  - `format`, `writer`, or `created` missing
  - public information present only under `/private`

Warnings (the file is accepted; the reader must report):

  - a split that places rows of one generalisation unit on both sides
  - rows with status other than converged
  - non-finite values in a field or scalar, with the row and name
  - a key value outside its declared bounds
  - more than one support (index-aligned operations unavailable)
  - weights or normals present but not marked as recomputed
  - a group key with no category table entry for some value
  - the observed range of a key differs from its declared bounds by
    more than a stated tolerance (possibly stale bounds)
  - a categorical key stored as floating point
  - a units string the validator cannot parse


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

Still open:

  a. Whether a file with callable slots may also carry the training
     keys as rows (useful for cards and extrapolation warnings; costs
     privacy of the design). Producer's choice under the current
     text; decide whether to say so explicitly.


17. Dictionary codec
--------------------

`to_dict` yields a nested dictionary whose leaves are numeric arrays,
numbers, booleans, or strings. It maps to an HDF5 group as follows,
so that every language round-trips it identically:

  nested dictionary   a subgroup with the key as its name
  numeric array       a dataset, C order, with named dimensions
                      `d0`, `d1`, ... unless the callable names them
  number or boolean   an attribute on the enclosing group
  string              an attribute on the enclosing group,
                      fixed-length UTF-8
  list of numbers     a one-dimensional dataset
  list of strings     a one-dimensional fixed-length string dataset
  null                an attribute with the reserved string "\0null"
  anything else       not representable; the writer must refuse

Key names must be valid HDF5 link names and must not begin with
`mestra_`, which is reserved for the container. Attribute order is not
significant. A reader reconstructs the dictionary and hands it to
`from_dict` for the group's `type`.
