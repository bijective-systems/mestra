API conventions across the four implementations
================================================

Decided 2026-09-20 from the Phase 3 ergonomics review. These are
conventions for the reader, writer, builder, and helper APIs; they do
not change the file format. Every implementation follows them, so a
user moving between languages meets the same names, the same order,
the same defaults, and the same messages. Where a language's idiom
forces a difference (keyword arguments, name-value pairs, a struct),
the difference is in syntax only.


1. Building
-----------

Keys: `add_key(name, values, role, units)` in that order. The role and
the units are required for design, condition, and time keys. A
categorical, group, split, id, or status key takes `category` naming
its table instead of units. Bounds: when the caller gives none, the
builder records the observed finite minimum and maximum as `lower`
and `upper`, so that every writer produces the same file from the same
arrays and W04 and W08 are decidable on every file. A caller who wants
a wider domain of validity passes `lower` and `upper` explicitly.

Category tables: one way per language, `add_category_table(name,
entries)` before the key or label that uses it; the key or label then
names it with `category`. No inline alternative.

The unit of generalisation: a dataset property, set by
`set_generalisation_group(name)` (spelled to the language's idiom),
naming a key of role group. A language may keep a key-level shortcut
as sugar, but the dataset-level setter exists everywhere and is the
one the documents show.

Scalars: `add_scalar(name, values, units)`.

Arrays: `add_node_array(support, name, values, units, dims)` and
`add_cell_array(...)` with the same order. `dims` names the axes of
the array the caller passes, in the caller's own axis order; the
builder derives `varies` from `dims` (a `row` axis means row, a
`group:<k>` axis means that group, neither means none) and derives
`components` from the component axis or adds a component axis of
length one. A caller who passes `varies` as well as `dims` gets an
error at build time if they disagree. Every builder refuses at build
time, with the rule id, anything the validator would refuse; the model
message is Python's for E04.

Callables: `add_callable(id, callable)` then `add_callable_slot(...)`
with the same argument order as the array builders plus `callable`
and `output`.


2. Writing and reading
----------------------

`write(dataset, path)` validates first and refuses on any error, with
the findings, unless the caller passes `check=false`. A file written
by any implementation validates clean in every implementation.

`read(path)` is strict by default and refuses a file that breaks a
structural rule (E01, E16, E19, E25, E26, E29, E30, E40, E41); a
non-strict read returns the dataset with the refused parts listed. A
semantic fault (a missing unit, a bad split) never stops a read, so
that `info` works on the files a user most needs to inspect.


3. Weights and integration
--------------------------

The spec says a weight array is computed from connectivity and never
imported. Every implementation therefore provides
`compute_weights(support, location)`: cell measure (length, area,
volume by cell type) for cells, and the lumped share of adjacent cell
measure for nodes, stored as an array with role `weight`, units of
the coordinates raised to the support's dimension, and the
`recomputed` flag set. The array is named `weight` at both locations
unless the caller names it. `integrate(dataset, slot)` uses the weight
array at the slot's location on its support by default, and computes
one on the fly, saying so, when the file has none; `weight=` overrides
by name.


4. Post-processing
------------------

Where a language has the helpers, they take a slot by name and a label
by name: `field_statistics(dataset, slot, by=<label name>)`, with the
output keyed by the label's name (never a fixed word), and no grouping
column at all when `by` is not given. `time_series(dataset, slot,
node, trajectory)`. `grouped_split(dataset, fractions, seed)` assigns
whole units of generalisation to parts, never returns an empty part
when there are at least as many units as parts, takes a seed with a
documented default, and refuses without a declared unit of
generalisation. A language without the helpers says so in its README
under a heading of its own.


5. Validator output
-------------------

One finding per rule per object. A finding that could repeat per row
(W02, W03, W04) reports once with the count and the first three row
indices in its message. Each finding is printed as
`<id> <path>: <message>` and the run ends with
`<n> error(s), <m> warning(s)`; the command-line tools of every
language print exactly that. `info` prints, for every key: name, role,
units, bounds, category, trajectory group, parent; for every support:
kind, counts, id; for every slot: shape with named axes, units,
source, and for callable slots the callable id and output.


6. Messages
-----------

An error names the rule id first, then the object path, then what to
do. A builder error says which argument to change. The models are the
Python E04 and W01 messages.


7. Two decisions from the verification round
--------------------------------------------

What an evaluated file carries. Evaluating a file turns every callable
slot into a stored slot, so the result has no callable to keep: the
`/callables` group is absent from an evaluated file, not present and
empty. This is the same rule as section 13's container groups, and it
keeps the four writers' output identical.

What a metadata open may read. Opening a file reads attributes,
dataspaces, link types, and dimension-scale structure, and may read a
category table in full, because tables are small by construction and
the open needs them to name E10, E26, and E41 on the same files the
read names them on. An open never reads a slot's data and never reads
a dataset inside a callable's dictionary; those wait for the read.
The nine structural rules of section 2 are decided from exactly this
much, so the open and the read name the same rule for the same file.
