The conformance corpus
======================

This directory is the conformance corpus of SPEC.md section 15: a set
of small golden files and, for each one, the outcome every
implementation must find. Every reader and every writer, in every
language, runs it in its own test suite.

No implementation is the reference. The specification and this corpus
define conformance between them. When a file here and an
implementation disagree, the specification decides; when the
specification is silent, that is a defect in the specification and it
is fixed there, in the same change that regenerates the corpus.

Nothing here depends on any tool beyond Python, h5py and numpy, and
nothing here is a mestra package. `generate.py` is sections 13 to 30
read literally and written out with h5py, so that an implementer can
compare a file byte for byte against the rules rather than against
somebody's code.


What is in it
-------------

68 cases, one directory each, holding exactly the two files section
30 requires:

    cases/<case>/case.mes        the golden file
    cases/<case>/expected.json   what every implementation must find

and `manifest.json` listing every case with a one-line description,
sorted by name. The cases fall into five groups:

  - the two files listed object by object in docs/example.md,
    `mesh_two_rows` and `affine_zero_rows`, regenerated here. They are
    byte identical to the committed copies under docs/examples, which
    is what makes this generator checkable against a document written
    before it;
  - the five datasets mapped onto the model in docs/mappings.md, at
    toy size: `family_static`, `cascade_varying_geometry`,
    `scalars_only`, `transient_fixed_mesh`, `axis_signature`;
  - the rest of the model: rows together with callable slots, one
    callable filling two slots, two supports, draws with their
    summaries, labels with and without a category table, a family with
    time, a derived array, and a support of kind none;
  - one file per error identifier of section 14, named `err_<id>`,
    each violating that rule and, where the rule cannot be reached
    alone, saying so in its description;
  - one file per warning identifier, named `warn_<id>`, the same way.

Every file is a few tens of kilobytes. That is almost all HDF5 object
headers and dimension scales; the data in each file is a few hundred
bytes.


Regenerating and checking
-------------------------

    python generate.py            # rewrite every case in place
    python check.py               # compare the committed corpus with
                                  # a fresh run, one line per case

`check.py` regenerates everything into a temporary directory and
compares. It compares bytes first. When the bytes differ it falls back
to the structural equality rule of section 30, which is the normative
comparison, because the HDF5 library decides the superblock and the
object header layout and byte identity across HDF5 versions must not
be tested. It then opens every case that must validate cleanly with
two netCDF-4 readers that share no code and checks that each
variable's dimension names are the link names of the scales attached
to it. It exits non-zero on any difference or failure.

The golden files are byte reproducible on one machine: object time
tracking is off everywhere, `created` and `writer` are fixed strings,
and the order in which the generator creates links, attributes and
scale attachments is fixed in its source. That order is part of the
golden bytes; reordering the statements in a builder changes them.


The schema of expected.json
---------------------------

Canonical JSON as section 30 defines it: UTF-8 with no byte order
mark, object keys sorted by their code points, no whitespace except
one closing newline, the separators "," and ":", non-ASCII written
literally. Every float is a string in the C format "%.17e", and the
three non-finite values are "nan", "inf" and "-inf"; a comparison
parses the string to float64 and requires bit equality.

  description   one or two sentences; the same string appears in
                manifest.json
  validator     {"errors": [ids], "warnings": [ids]}, each sorted and
                without duplicates. Two empty lists means the file
                must validate cleanly
  support_ids   support group name to the 64-character lower-case
                digest of section 24. It is the digest an
                implementation must compute from the stored arrays,
                which for `err_e08` is not the digest the file stores
  probes        a list of stored values, each naming its axes
  codec         callable id to the round trip of that callable's
                dictionary, in the tagged form of section 30
  evaluation    a list of worked evaluations, one per callable

A probe names one value by axis and never by axis position, so that it
means the same thing to a row-major and a column-major reader:

  slot        the HDF5 path of the dataset
  row         the row index, when the slot has a row dimension
  instance    the index along a `group:<k>` leading dimension
  draw        the draw index, when the slot has a draw dimension
  node        the node index, or the cell index for a cell array
  component   the component index
  index       the index along the flat connectivity axis
  value       the value as a decimal string: the "%.17e" form for a
              float64 slot and the plain decimal form for an integer
              slot

Several probes are chosen so that a transposed read is caught: the
row, the node and the component are all different and the values
differ along every axis, so a reader that took the axes by position
returns a number that is in the file but in the wrong place.

An evaluation entry states what a callable must produce:

  callable    the callable id
  keys        the keys table it is evaluated on, key name to a list of
              "%.17e" strings, one entry per table row
  probes      the expected outputs, in the probe form above, against
              the slot each output fills. The row index is the index
              into the keys table here and not into any row the file
              stores, which matters for `affine_with_rows`, where the
              table happens to be the design the file also carries


Three places the specification leaves a choice
----------------------------------------------

The corpus had to decide these to exist at all. Each is a proposed
correction to the specification, not a private convention, and the
phase report carries the proposed wording.

  - section 30 names five fields for expected.json and says "exactly
    these fields". This corpus writes a sixth, `evaluation`, present
    on every case and empty where there is nothing to evaluate,
    because the affine callable of section 27 has to be conformance
    tested and there is nowhere else to state its result.
  - the probe fields of section 30 name a row, a node and a component.
    They do not name the leading dimension of a `group:<k>` array or
    the flat connectivity axis, both of which the corpus has to probe.
    `instance` and `index` above are the two added names.
  - W08 fires when the observed range of a key differs from its
    declared bounds "by more than a stated tolerance", and no
    tolerance is stated anywhere. The corpus avoids depending on the
    choice: `warn_w08` declares bounds two thousand units wide around
    data that spans four tenths of one, so any tolerance fires, and
    every other case keeps the declared range within twice the
    observed one, which docs/example.md already treats as clean.


Rules a file cannot break on its own
------------------------------------

Six identifiers cannot be reached by a file that breaks nothing else.
Their cases say so in their own description, and the extra identifier
is in the expected list because an implementation will and should
report it:

  E06, E07, E37, W15   need more than one support, so W05 comes with
                       them; E07 additionally implies E28 and E37,
                       because section 22 makes `aligned` decidable
                       from the file
  W07                  is the same fact as E10 for a group key
  W09                  is already an error by the dtype table of
                       section 19, so E20 comes with it

E18 is not mechanically decidable at all: it asks a reader to notice
that public information is only under `/private`, and section 29 tells
the same reader not to interpret `/private`. The case `err_e18` is the
clearest instance that could be built, a file that declares a group
key and names its unit of generalisation only under `/private`.
