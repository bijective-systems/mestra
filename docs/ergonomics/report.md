Ergonomics review: the five mapped datasets in four languages
=============================================================

What was done. Each of the five datasets of `docs/mappings.md` was
built at toy size from plain arrays in Python, MATLAB, Julia and C++,
written, validated, read back in a different language, permuted by
name and checked at one value. A callable file with an affine model
was built in Python and evaluated in the other three. The
post-processing helpers were used where they exist, and both
command-line tools were judged as a first-time reader would.

The only documents used were `README.md`, `SPEC.md`, `docs/example.md`,
`docs/mappings.md` and each language's README. Where a document did
not say how to do something, that is recorded as a finding, and only
then was the source consulted, to say what the document should have
said. Every script is under `docs/ergonomics/scripts/`.

Findings are ranked blocking, annoying, cosmetic. Blocking means a
user following the documents cannot get the result, or gets a wrong
one without being told. Annoying means it costs an attempt or a guess.
Cosmetic means it reads badly but misleads nobody.

Attempts per dataset, counting a run that ended in an error or an
invalid file as an attempt:

    dataset              Python  MATLAB  Julia  C++
    1 family                  3       4      1    2
    2 cascade                 1       1      1    1
    3 scalars only            1       1      1    1
    4 transient               1       2      1    1
    5 axis support            1       1      1    1

The two languages that needed the most attempts are the two whose
`write` does not check what it is about to write.


Python
------

### Blocking

**P1. `post.integrate` cannot be reached from the documents.**

    post.integrate(ds, "pressure", weight="area")
    MestraError: E05: area: no array called 'area' on the nodes of
    support s0

The README's headline example for integration names a weight array
called `area`. No document says how a weight array gets into a file,
and none of the five mappings has one. The specification says a weight
is "computed from connectivity, never imported", so a user is not
supposed to supply one, and no implementation computes one. There is
also no way to integrate without a weight: `weight` is a required
keyword-only argument, and omitting it gives

    TypeError: integrate() missing 1 required keyword-only argument:
    'weight'

Proposal, an API change and a document change. Give `integrate` a
`weight=None` default meaning unit weights, so the call in the README
works on any file; and add a `compute_weights(support)` call that
makes the measure from the connectivity, since the specification says
that is the only legitimate source. Then say in the README which one
the example is using.

### Annoying

**P2. `field_statistics` calls its grouping column `region` whatever
the label is called.**

    post.field_statistics(ds, "pressure", label="cad_face_id").as_table()
    [{'row': 0, 'region': '11', 'count': 2, ...}, ...]

and with no label at all the rows still carry `'region': None`. The
name of the README's example label has become part of the generic
output. A user grouping by `topo_group` gets a column called `region`.
Proposal, an API change: name the column after the label, and leave it
out when there is no label.

**P3. `dims=` is accepted and silently ignored.**

    support.add_node_array("pressure", values, units="Pa",
                           dims=("row", "node"))
    MestraError: E04: pressure: a node array of shape (6, 6) on a
    support of 6 nodes is either (node, component) or (row, node); say
    which with varies

`dims` is the documented way to name your array's axes in both MATLAB
and Julia. Python accepts the keyword, does nothing with it, and then
refuses the array for an ambiguity that `dims` would have settled. A
neighbouring typo, `untis=`, is properly refused, so this is not a
general laxness: it is this one keyword. Proposal, an API change: make
`dims=` mean in Python what it means in the other two languages, and
document it. Failing that, refuse it.

**P4. Rule identifiers are used for caller mistakes.**

    post.field_statistics(ds3, "CL")
    MestraError: E05: CL: no array called 'CL' on any support

E05 of section 14 is "an array whose node or cell count disagrees with
its support". The file here is perfectly valid; the caller named
something that is not there. Using a file rule for a lookup miss makes
the identifiers mean two different things, and a caller who catches
E05 to detect a malformed file will catch this too. Proposal, an
error-message change: raise a `MestraError` with no rule id for a name
that is not in the file, and keep the identifiers for findings about a
file.

**P5. No statistics over scalars.** Dataset 3 has nothing but scalars,
and `field_statistics` only looks at support arrays, so the one
post-processing verb that suits the dataset does not apply to it. The
mappings document presents dataset 3 as a first-class case; the
helpers do not treat it as one. Proposal, an API change: let
`field_statistics` accept a scalar and report over rows.

**P6. W02 is reported once per row.** Six rows gave six findings, one
of which was about a row whose status was fine:

    W02  /keys/status: row 0 has status 'ok'
    W02  /keys/status: row 1 has status 'ok'
    ... six lines for six rows

The HiLift mapping has 1,800 rows. W03 in the same report coalesces,
naming only the first non-finite value per array, so the two rules
behave differently for no stated reason. Proposal, an API change:
coalesce W02 like W03, giving a count and the first row.

**P7. Nothing says the status word the validator wants is
`converged`.** `categories=["ok", "failed"]` is the natural choice and
produces a warning on every row, including the good ones, whose
message never mentions the expected word. Only one line of `SPEC.md`
carries the vocabulary; neither the README nor `docs/mappings.md`
repeats it, although two of the five mappings use a status column.
Proposal, a document change and an error-message change: put
`converged, failed, partial` in the README beside `role="status"` and
in the mappings; and make the message say what it expected.

**P8. `kind="axis"`, `trajectory_group=` and the whole of writing a
callable file are undocumented.** The Python README shows
`add_support` only with a mesh and a `cells=` tuple, so dataset 5 was
built by guessing `kind="axis"` from the specification's vocabulary.
`trajectory_group` is listed as an attribute of `Key` but never shown
being set, so dataset 4 was built by guessing the keyword. For the
callable file the README shows how to read and evaluate one and never
how to write one: `callable_id` and `output` appear in no document at
all, and were found with `inspect.signature`. `add_scalar` names them;
`add_node_array` hides them in `**rest`. Every guess turned out right,
which is a compliment to the naming and not a substitute for the
document. Proposal, a document change, plus naming `callable_id` and
`output` in `add_node_array`'s signature.

**P9. `ds.supports["s0"].node_arrays["coordinates"]` is a bare
`KeyError`.** Coordinates are their own attribute of `Support`, which
only the API list at the end of the README says. Every other slot is
in `node_arrays`, so the natural first guess is wrong and the answer
is a plain dictionary error with no advice. Proposal, a document
change, and a `KeyError` that says coordinates are on the support.

### Cosmetic

**P10. `as_table()` returns dictionaries, not lines.** The README says
`for line in stats.as_table(): print(line)`, which suggests formatted
lines; what comes out is a raw dictionary per row, one long line each.
Either format them or stop calling them lines.

**P11. `print(slot.values)` hides the value.** A one-element scalar
prints `NamedArray(1, dims=row)`. The MATLAB README's equivalent line
prints `1.45`. `NamedArray.__repr__` should show the contents of a
small array, as numpy does.

**P12. Findings name category ids where the file has a table.** "the
rows of geometry 0 are on both sides", "the trajectory 0". The file
knows these are `g0` and `r0`.

**P13. `mestra info` says "aligned" for a file with no supports at
all.** Dataset 3 declares no support, and the summary line still reads
"12 row(s), aligned". Aligned with what is a fair question.

**P14. `mestra.post` has no `__all__`.** `dir(post)` offers `np`,
`Mapping`, `dataclass` and `annotations` alongside the five helpers.


MATLAB
------

### Blocking

**M1. `mestra.write` writes a file that `mestra.validate` rejects.**

    d.addNodeArray('s0', 'cad_edge_t', linspace(0, 1, 6), 'field', ...
                   'Units', '1', 'Dims', {'component', 'node'});
    mestra.write(d, out);                      % succeeds, says nothing
    mestra.validate(out)
    E16 /supports/s0/node_arrays/cad_edge_t the leading extent is 1
        where 6 rows are on this support

Three arrays came out broken this way. `Dims` named no `row` axis, and
`Varies` still defaulted to `'row'`. Julia infers `varies` from the
leading name in `dims` and got this right with no extra argument;
MATLAB does not, and nothing in the MATLAB README says `Varies` has a
default or that it must be stated. Writing the file took a fourth
attempt with `'Varies', 'none'` added to all three calls.

Two proposals, both API changes. Infer `Varies` from the leading name
of `Dims`, as Julia does. And make `write` refuse to emit a file that
its own validator would reject: a writer that produces invalid files
silently is the one failure mode an open format cannot afford, because
the file outlives the session that made it.

**M2. There is no post-processing.** Per-field statistics, integration
over a label, a time series at a node and a grouped split do not exist
in MATLAB. They are the four operations that only need the format, and
they are the reason to have a format. A MATLAB user who reads the
Python README will look for them and find nothing; the MATLAB README
does not say they are absent, it simply does not mention them.
Proposal, an API change, or failing that a document change saying
plainly that these live in Python and Julia only.

### Annoying

**M3. Every vector trips the `Dims` check.**

    d.addNodeArray('s0', 'cad_edge_t', linspace(0, 1, 6), 'field', ...
                   'Units', '1', 'Dims', {'node'});
    mestra:dims: the array has 2 axes and 1 names; name every axis

MATLAB has no one-dimensional array, so a plain row vector is 1-by-N
and `{'node'}` can never be right. The README's rule that "a name the
slot needs and your array does not have becomes an axis of length one"
handles a missing name but not this, which is the opposite case and
the common one. The message is accurate and unhelpful: it does not
mention that MATLAB vectors are two-dimensional, and it does not say
what to write instead. Proposal, an error-message change: say that a
row vector is 1-by-N here and that the leading singleton is usually
`component`; and a document change adding a vector to the README's
example.

**M4. `write` chooses a chunk its own validator warns about.**

    W12 /supports/s0/node_arrays/cad_edge_t the chunk is [1 6 1] where
        the default of section 23 is [6 6 1]

The user did nothing to cause this; the writer picked the chunk.
Proposal, an API change: pick the default of section 23.

**M5. Key bounds are not filled in from the data.** Python and Julia
default `lower` and `upper` to the observed range. MATLAB leaves them
out, so the same arrays written by MATLAB give a file that says less
about itself, and W04 and W08 can never fire on it. The README's list
of what is filled in for you mentions the support id, the component
counts, the dimension names, the chunking and the row dimension, and
not the bounds. Proposal, an API change to match Python and Julia.

**M6. Findings do not say which row or which value.**

    W02 /keys/status a row has a status other than converged
    W03 /scalars/power a non-finite value

Which row, and which value, is exactly what a user needs in order to
act. Python names them. Proposal, an error-message change.

**M7. The README documents one support builder and one array
builder.** `addCellArray`, `addAxisSupport` and `'TrajectoryGroup'`
were all guessed; all three exist and all three worked. The
"What is in the package" section lists `mestra.Dataset` as "the data
model and the builder" and never lists its methods, so there is no
place in the document where a user can see what can be built.
Proposal, a document change.

### Cosmetic

**M8. A report has three shapes.** `r.valid` is a logical, `r.errors`
and `r.warnings` are cell arrays of identifiers, and `r.findings` is a
struct array with `id`, `path` and `message`. Iterating findings with
`for f = r.findings` works; the same loop over `r.errors` gives you
strings. One shape would be easier to remember.


Julia
-----

### Blocking

**J1. `grouped_split` silently returns an empty test set.**

    Mestra.grouped_split(ds; fractions = ["train" => 0.8,
                                          "test" => 0.2])
    Dict("test" => [], "train" => [1, 2, ..., 12])

Dataset 3 has three units of generalisation. Python on the same file,
written by any of the four languages, returns eight training rows and
four test rows, which is two geometries against one. Julia gives every
row to training and nothing to test, on files written by all four
languages, and says nothing about it. The whole purpose of the call is
an honest generalisation test; a user would train a model and then
score it on an empty set. With eight units the same call behaves.
Proposal, an API change: give every named part at least one unit, or
refuse the fractions and say the units cannot be divided that way.

**J2. `grouped_split` has no seed.** Python documents `seed=0`. The
Julia README shows no seed and makes no statement about
reproducibility, so a user cannot write down which split they used.
Proposal, an API change and a document change.

### Annoying

**J3. A lazily-read key's `.values` is `nothing`, and touching it
gives a raw Julia error.**

    ds.keys["mach"].values[2]
    ERROR: MethodError: no method matching getindex(::Nothing, ::Int64)

Nothing in the message mentions mestra. The README's own getting-
started block reads `ds.keys["mach"].role` and `ds.keys["mach"].lower`
off a key, so `.values` is the obvious next thing to reach for, and
the README never says the field exists and is empty until you call
`Mestra.values(ds, key)` or `materialise!`. The same expression works
in Python, which materialises on access. Proposal, an API change:
either make the field raise an error naming `Mestra.values`, or do not
expose it at all; plus a document change showing how to get a key's
values.

**J4. `field_statistics` calls its grouping column `region`.** Exactly
as in Python: `region = "all"` with no label, `region = "11"` when
grouped by `cad_face_id`. Two implementations made the same choice
independently, which suggests it came from the design rather than from
chance, and it is wrong in both. Proposal, an API change: name the
column after the label.

**J5. A scalar handed to `field_statistics` leaks an internal
message.**

    Mestra.field_statistics(ds, ds["CL"])
    MestraError: permute needs one name per axis: got 3 for 1 axes

The caller asked a reasonable question about dataset 3 and got a
sentence about the internals of the axis machinery. Proposal, an
error-message change, and the same API change as P5.

**J6. `integrate`'s documented weight cannot be satisfied, and the
weightless call raises a raw Julia error.** The README names
`weight = "measure"`; the Python README names `weight = "area"` for
the same missing thing. The refusal itself is good and says exactly
what is missing. Omitting the keyword gives `UndefKeywordError`, which
is Julia's, not mestra's. Proposal, as P1.

**J7. Naming the unit of generalisation is undocumented.**
`ds.generalisation_group = "member"` was a guess. It is not in the
README's building section, not in its API list, and not in the
defaults list, yet `grouped_split` refuses to work without it and
`split_leaks` depends on it. Proposal, a document change.

**J8. `trajectory_group` on `add_key!` is undocumented.** Guessed, and
right. Dataset 4 cannot be built correctly without it.

### Cosmetic

**J9. `Symbol("group:member")` is unavoidable in the builder.** The
README offers `:instance` as an accepted alias when reading, but the
building section never shows a group-varying array, so a user writing
one has to work out the spelling. Showing `dims = (:instance, :node,
:component)` once in the builder example would remove it.

**J10. `split_leaks` returns an empty dictionary both when there are
no leaks and when there is no split key.** Two different answers, one
value.


C++
---

### Blocking

**C1. `mestra::write` writes a file that `mestra::validate` rejects.**

    mestra::ArraySlot& et = mestra::add_field(
        s, mestra::Location::Node, "cad_edge_t", "1", edge_t);
    et.varies = "none";                   // silently ignored
    mestra::write(d, path);               // succeeds, says nothing

    E04 /supports/s0/node_arrays/cad_edge_t: `varies` is none and the
        leading dimension is "row"
    E16 ... the leading dimension does not match the number of rows
    E27 ... a row-dimensioned dataset that is not chunked

The README's `add_field` takes five arguments and none of them is
`varies`, so setting the field on the returned slot is the only move
the document leaves. It does not work: the shape and the dimension
names were fixed inside `add_field`, and the public, mutable `varies`
member no longer changes them. The real signature has two further
defaulted parameters, `components` and `varies`, and neither appears
in the README.

Three proposals. Document the full signature. Make `write` validate
before it writes, as in M1. And either recompute the shape from
`varies` at write time or stop exposing `varies` as a mutable member
once the slot is built, because a writable field that is read only at
construction time is a trap.

**C2. There is no post-processing.** As M2.

### Annoying

**C3. The library README documents about half the builder.**
`add_label` is not mentioned anywhere, so dataset 1's three label
arrays were written by guessing it from `add_field`'s shape.
`add_axis_support` is not mentioned, so dataset 5 was guessed the same
way. `Dataset::key`, which is how dataset 4's `trajectory_group` gets
set, is not mentioned. `add_none_support`, `add_callable_field` and
`add_callable_scalar` are not mentioned. Every guess compiled and
worked first time, which says the names are good; it does not say the
document is finished. Proposal, a document change: list the builders,
as the header already does in comments that are better than the
README.

**C4. Key bounds are not filled in from the data.** As M5. The
README's example sets `mach.lower` and `mach.upper` by hand, which is
the only hint that they are not defaulted.

**C5. `mestra-cli validate` is unusable as a human reader.**

    $ mestra-cli validate d2_cascade.mes
    W W02
    W W03

No path, no message, no file name, no count. To learn what W02 means a
first-time reader has to open the specification. The same file through
the other tool:

    $ mestra validate d2_cascade.mes
      W02  /keys/status: row 6 has status 'partial'
      W02  /keys/status: row 7 has status 'partial'
      W03  /scalars/angle_out: a non-finite value at (6,), which is
           how this format spells missing floating-point data
      W03  /scalars/power: a non-finite value at (6,), ...
      d2_cascade.mes: valid, 4 warning(s): W02 W03

The terse form is deliberate and right for a script. There is no human
form. Proposal, an API change: print paths and sentences by default
and keep the bare identifiers behind a flag such as `--ids`, or the
reverse, but offer both.

**C6. `mestra-cli info` prints no shapes.**

    node_array overpressure role=field varies=row components=1
                                                       source=data

against `mestra info`'s

    overpressure     (row, node, component) 6x8x1  field  units Pa

A first-time reader of a file they did not write wants to know how big
it is. The C++ tool reads the dataspaces already, since it reports
`n_nodes`. Proposal, an API change: print the dimension names and the
extents.

**C7. `mestra-cli info` does not report `trajectory_group`.** The
attribute is in the file, `mestra info` prints it, and `mestra-cli
roundtrip` preserves it, so this is a reporting gap and not data loss.
For dataset 4 it is the attribute that makes the file a set of
trajectories rather than a pile of rows. Proposal, an API change.

**C8. `mestra-cli evaluate` prints nothing on success.** Every other
subcommand says something. Proposal, an API change: say what was
written and how many rows.

### Cosmetic

**C9. `add_scalar` puts units before values.**

    d.add_scalar("cl", "1", {0.25, 0.55});

Python, MATLAB and Julia all put the values before the units. Within
C++ itself, `add_key(name, role, values, units)` puts them after. One
order inside one language would be a start.

**C10. The README warns against a reference it then holds.** "fetch by
name rather than holding a reference across a later `add_`" is good
advice, and the example directly above it holds `mestra::Key& mach`
and `mestra::Support& s`. Both uses happen to be safe; a reader cannot
tell that from the page.


Across the four languages
-------------------------

These are the things that would trip a user moving between the
implementations. They are ranked by how badly a user is misled.

**X1. Key bounds default differently, and the difference is silent.**
Python and Julia fill `lower` and `upper` from the observed range;
MATLAB and C++ leave them out. The same five datasets written in four
languages produced two different files. A downstream tool asking a
file for its domain of validity gets an answer from two of them and
silence from the other two, and W04 and W08 can only ever fire on half
the files in the world. This is the one inconsistency that changes
what a file means rather than how it is written. Either default
everywhere or nowhere, and say which in the specification.

**X2. Two of the four writers emit invalid files.** Given the same
mistake, a node array that does not vary along rows, Python refuses at
build time with the clearest message in the system, Julia gets it
right from `dims`, and MATLAB and C++ both write a file that their own
validators immediately reject. `write` should validate in all four.

**X3. The keyword that names your array's axes exists in three
languages, is spelled three ways, and is a trap in the fourth.**
MATLAB `'Dims'`, Julia `dims`, C++ has no such thing and uses `varies`
plus argument order, and Python accepts `dims=` and ignores it. A
MATLAB or Julia user's first Python line is the one that fails.

**X4. Argument order is different in all four.**

    Python   ds.add_key("mach", values, role="condition", units="1")
    Julia    add_key!(ds, "mach", values; role = :condition,
                      units = "1")
    MATLAB   d.addKey('mach', 'condition', values, 'Units', '1')
    C++      d.add_key("mach", "condition", values, "1")

Role is second in MATLAB and C++ and a keyword in Python and Julia;
units is a positional fourth in C++ and a keyword elsewhere. Scalars
are worse: C++ is `add_scalar(name, units, values)` and everyone else
is `(name, values, units)`.

**X5. Category tables are attached four different ways.** Python
passes `categories=[...]` to `add_key` itself. Julia and MATLAB
require a separate `add_category_table!` or `addCategory` first and
then a `category=` reference. C++ requires `add_categories` first and
then a different function entirely, `add_category_key` instead of
`add_key`. Three of the five datasets have category tables, so this is
hit constantly.

**X6. The unit of generalisation is named four ways, one of which is a
different mechanism.** Python `add_key(..., generalisation=True)` on
the key; Julia `ds.generalisation_group = "member"`, undocumented;
MATLAB `d.generalisationGroup = 'member'`; C++
`d.generalisation_group = "member"`. Python's is a property of the
key, the other three are a property of the dataset.

**X7. Array builders take the support four different ways.** Python is
a method on the support object, Julia takes the support object as an
argument, MATLAB takes the support's name as a string, and C++ takes a
reference to it as a free function.

**X8. The post-processing helpers disagree on names, arguments and
results.**

    Python  post.field_statistics(ds, "pressure", label="region")
    Julia   Mestra.field_statistics(ds, ds["pressure"], by = "region")

Python takes the slot by name, Julia takes the slot object. The
grouping keyword is `label` in one and `by` in the other. The weight
in the integration example is `"area"` in one README and `"measure"`
in the other, and neither can be satisfied. `grouped_split` takes a
dictionary and a seed in Python, and a vector of pairs and no seed in
Julia, and gives different splits.

**X9. Post-processing exists in two languages of four.** MATLAB and
C++ have none, and neither README says so.

**X10. Validator findings have opposite granularity per rule.** On one
file: Python reports W02 once per row and names the rows, while
MATLAB, Julia and C++ report it once and name no row. W03 is the other
way round, with Python naming the index and the others not. A user
comparing two languages' reports on the same file cannot tell a
difference in the file from a difference in the reporter.

**X11. `mestra validate` and `mestra-cli validate` are two registers
for one verb.** Paths and sentences and a summary line against
two-letter identifiers. `info` is the same split: an aligned human
table against a flat key-value dump with no shapes. The names being
identical promises something the outputs do not deliver.

**X12. What `.values` gives back differs.** In Python a key's
`.values` materialises and can be indexed; in Julia the same field is
`nothing` until `Mestra.values` is called. In Python a scalar slot's
`.values` is a `NamedArray` whose printed form hides the number, while
MATLAB's `e.scalar('cl').values` is the number.


What works well and should not be changed
-----------------------------------------

**The named-axis contract.** Sixteen writer-and-reader pairs were
tried, and every one answered 3.0 for the coordinate at instance 1,
node 2, component 0, and 0.6 for `cad_edge_t` at node 3. The
axis-order statements in the Python, MATLAB and Julia READMEs were
enough on first reading, in all three: no axis was ever counted, and
the reversal between row-major and column-major languages never once
had to be thought about. `mestra.permute`, `Mestra.permute`,
`at(**names)` and `Mestra.at` are the same idea in four idioms and all
four are obvious. Naming the axis after the group key,
`group:member`, with `instance` accepted as an alias, reads correctly
in every language.

**The worked example.** `docs/example.md`'s "Values to check a reader
against" and its worked affine evaluation are the most useful pages in
the repository. A callable file built in Python from the numbers on
that page evaluated in MATLAB, Julia and the C++ tool to 1.45 and
0.5, 1.1, 3.7, 4.3, 6.9, 7.5, with no adjustment anywhere, and the C++
probe printed them to seventeen digits. The "Checking an
implementation against these two" list is exactly the right document
to hand somebody.

**The support id.** Four languages writing the same connectivity all
produced `96df395d80ef5484...`, and the model file and the family file
matched on one attribute with no array read. The claim in the
documents is true and it is cheap.

**Python's message for an ambiguous shape.**

    E04: pressure: a node array of shape (6, 6) on a support of 6
    nodes is either (node, component) or (row, node); say which with
    varies

It states both readings, says which parameter settles it, and arrives
before anything is written. This is the model every other message in
the system should follow. It is worth noting that a square toy shape
is not an exotic case: it happens whenever a reviewer shrinks a
dataset.

**W01's message.**

    W01 /keys/split: the rows of geometry 0 are on both sides of the
    split, so this is not a generalisation test

It names the leaked unit and then says why it matters, which is what
turns a warning into something a user acts on.

**The promised validator behaviours are real.** Every behaviour
`docs/mappings.md` claims for these datasets was checked and holds: a
split that leaks a geometry warns W01, a time key that goes backwards
inside a run errors E09, a key outside its declared bounds warns W04,
and an invented unit string warns W10. The format's selling points are
not aspirational.

**Portability.** A grouped split computed in Python gave identical row
indices on the same dataset written by all four languages, and the
four-by-four read matrix agreed everywhere. Whatever the builders
disagree about, the files themselves are genuinely one format.

**Exit codes.** Both command-line tools exit 1 on an error and 0 on
warnings alone, and both say so in their documents. That is the part
of a command-line tool that has to be right, and it is.

**Rule identifiers on errors.** Every refusal in every language
carried the identifier of the rule it broke, and the identifiers meant
the same thing in all four. Catching `mestra:E32` in MATLAB and `E32`
in Python is the same act. Keep this, and keep it out of the
caller-error path that P4 describes.


One thing about the top-level README
------------------------------------

`README.md` still says "Status: **specification draft, version 0.**
Nothing is implemented," and describes `python/`, `matlab/`, `cpp/`
and `vectors/` as a "planned layout once implementation starts". All
four interfaces exist, pass the corpus and are documented. A first-time
reader starts at that file and is told the thing they are about to use
does not exist. It is the cheapest fix in this report.


The scripts
-----------

Under `docs/ergonomics/scripts/`, one directory per language. The
comments in them record the attempts: a line marked "attempt 2" or
"attempt 3" is where something had to be changed after a failure, and
a line marked "header only" or "a guess" is where a document did not
say.

    python/   d1_family.py .. d5_axis.py, one per dataset
              model_build.py        the callable file
              post_checks.py        the four helpers
              cross_read.py         read another language's file
              promised_warnings.py  the mappings' validator claims
    matlab/   d1_family.m .. d5_axis.m, cross_read.m, model_eval.m
    julia/    build_all.jl, post_checks.jl, cross_read.jl,
              model_eval.jl
    cpp/      build_all.cpp, build.sh

The Python and Julia scripts take an output directory; the MATLAB ones
take an output path; the C++ one is compiled with `build.sh` against a
configured build tree and takes an output directory.
