Implementation plan
===================

Order matters more than parallelism at the start. Three languages
implementing an underspecified layout in parallel produce three
formats. So: pin the bytes, build the corpus, then fan out.


Phase 0: pin the byte-level details (one agent, a spec addendum)
-----------------------------------------------------------------

Everything below is currently implied or unstated, and every one of
them would be resolved differently by independent implementers:

  - attribute encodings: booleans (int8 0/1), integers (int64),
    floats (float64), strings (fixed-length UTF-8, null-padded)
  - dimension scale names and how `group:<key>` dimensions are named
    on disk
  - the index rule for `varies = group:<key>`: instance i is the
    category with id i, in category-table order
  - `row_support` dtype (int32) and the rule when omitted
  - `support_id`: SHA-256 over, in order, n_nodes as int64 LE,
    cell_types as uint8, cell_offsets as int64 LE, cell_connectivity
    as int64 LE, and for axis supports the axis coordinates as
    float64 LE; hex-encoded, lower case
  - chunking (along row; a stated default chunk size) and
    compression (allowed filters: none, gzip)
  - the codec's edge cases: zero-dimensional arrays, empty arrays,
    integer versus float scalars, unicode in strings, nested lists,
    dictionary key ordering
  - the keys-table convention per language: Python, a mapping from
    key name to one-dimensional array; MATLAB, a table; C++, a struct
    of vectors; all with the same column names and row order
  - one reference callable type in the open package, `affine`
    (y = A x + b per slot), so that the protocol and the codec can be
    conformance-tested in every language without any proprietary
    model
  - `format` versioning: what a reader of "mestra/0" does with
    "mestra/1" (refuse), and what additive changes are allowed within
    a version (new optional attributes only)
  - what a reader must offer for lazy access: at minimum, read a
    slot for a row range without reading the rest


Phase 1: the conformance corpus (one agent, Python, h5py only)
--------------------------------------------------------------

A generator that writes golden files directly with h5py, with no
mestra package involved, and for each file an `expected.json`:
validator outcomes (errors and warnings by rule id), values at named
coordinates (row r, node n, component c) in both row-major and
column-major axis conventions, every support_id, and the codec's
round-trip dictionary for each callable. Files to include:

  - the five worked mappings from docs/mappings.md, at small size
  - zero rows with callable slots (the affine type)
  - two supports, unaligned
  - an axis support
  - a draw dimension with derived mean and std
  - labels with and without category tables
  - a status column with a failed row
  - a split that leaks the generalisation unit (must warn)
  - every error in section 14, one file each
  - group-varying coordinates (a family with time)


Phase 2: language interfaces, in parallel (one agent each)
----------------------------------------------------------

Each agent works from SPEC.md and the corpus alone, does not read the
other implementations, and ships its own tests that run the corpus.

  python/   reader, writer, validator, the dataset protocol, the
            affine callable, `evaluate`, and the generic
            post-processing that only needs the format (per-field
            statistics, integration over labels with weights, a time
            series at a node, grouped splitting)
  matlab/   reader, writer, validator, the affine callable, evaluate
  cpp/      reader, writer, validator (for TopoLink's export path);
            HDF5 through a header-only wrapper unless netCDF-C is
            needed for the netCDF-4 layout

First wave is these three; Julia and R follow once the corpus is
stable.


Phase 3: verification and ergonomics (independent agents)
---------------------------------------------------------

  - a verifier that runs every implementation against the corpus,
    then cross-writes: every file written by each language read by
    every other, values compared at named coordinates, support_ids
    compared, codec round trips compared; named-dimension permutation
    checked explicitly between MATLAB and Python
  - an ergonomics reviewer who builds each of the five mapped datasets
    in each language the way a user would, from the public docs only,
    and reports every friction point; the fixes go back to the
    implementations, and to the spec if the friction is structural


Phase 4: adoption
-----------------

TopoLink's export set writes `.mes`; the modelling tools gain a view
that produces their own dataset objects from a `.mes` file; the
dataset builders write `.mes`. Each adoption is its own change in its
own repository.


Phase 5: polish, after everything above has landed
--------------------------------------------------

The repository is finished only when a stranger can use it. This
phase produces the front door and the deeper layers, and it is
governed by one rule: economy of words and of examples. Too much on
the first screen scares people off; too little hurts technical
adoption later. The answer is layers, each complete at its own depth,
each pointing down to the next, and nothing repeated between them.

  Layer 1  README.md: one screen. What the format is in two
           sentences, what it holds, install in each language, one
           example of ten lines that writes a file and reads it back
           in another language, and links down. Nothing else.
  Layer 2  docs/guide.md: five to eight pages. The concepts of SPEC
           section 2 in plain words, one worked example per concept
           (rows and roles, a support and a field, a group and a
           split, a callable and evaluation, uncertainty as draws),
           each example under thirty lines and runnable in every
           language from docs/examples/. How to validate. How to read
           a file someone else made. The public/private line.
  Layer 3  SPEC.md: the reference, unchanged in role. The guide links
           into it by section; the README never does.
  Layer 4  docs/mappings.md and docs/design-notes.md: for people who
           want to know why. Linked from the guide's last page.

Per-language README files shrink to the same skeleton: install, the
ten-line example in that language, the axis-order statement, the link
to the guide. Everything else they currently carry moves into the
guide (if it is about the format) or into docstrings and help text (if
it is about that API).

Examples: exactly one directory per guide concept under docs/examples,
each with the same small dataset in all four languages, kept under
thirty lines each and run by every language's test suite so they
cannot rot. The five mapped datasets of docs/mappings.md are the
source material; the examples use their toy sizes.

A logo: a simple wordmark that works at 32 pixels and in both light
and dark, committed as SVG. A placeholder is acceptable until the
owner replaces it.

Inputs: the ergonomics report is the primary input (fix the friction
before documenting around it); the verification report is the second
(anything graded NOTE that a user would hit belongs in the guide).

What this phase must not do: add features, restate the spec in the
guide, or write a tutorial longer than the guide. When in doubt, cut.


Rules
-----

  - No implementation is the reference; the spec and the corpus are.
  - The spec changes only through a change to SPEC.md that
    regenerates the corpus in the same change.
  - The four-method callable protocol is frozen.
  - Nothing in this repository depends on any proprietary tool.
