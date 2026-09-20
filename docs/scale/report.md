The scale study
===============

Date: 2026-09-20. Branch `phase3/scale-study`. Nothing outside
`docs/scale/` was changed.

This answers the questions Phase 3 left open about size: findings 4,
8, 11, 15, 16, 17 and 18 of `docs/verification/phase-3.md`. It is a
measurement report. Every number below came out of a script in
`docs/scale/scripts/`, every script is committed beside this file,
and the command that produced each table is given with it.

    ceiling.py     the 4085 ceiling, and the properties that lift it
    mkfiles.py     conforming files with N row-dimensioned datasets,
                   in a chosen HDF5 layout
    readable.py    who can read a file, and what they call its axes
    nccheck.py     what netCDF-C does to a file, and what it writes
    probe4.py      all four implementations over one file
    bigfile.py     one file the size a real dataset will be
    time_open.cpp  the C++ timing driver, against the library
    time_cpp.py    the same through `mestra-cli`
    time_py.py     the Python timing driver
    time_jl.jl     the Julia timing driver
    timeMestra.m   the MATLAB timing driver
    time_ml.py     the wrapper that starts it
    time_write.py  each writer, writing the same file
    fit.py         the timing logs as tables, with the exponents
    profile_py.py  where the Python reader spends its time
    profile_jl.jl  where the Julia reader spends its time
    profileMestra.m  and where the MATLAB one does

Conventions. `$REPO` is the repository, `$SCRATCH` a scratch
directory, `$PY` the Python interpreter, `$CLI` the built
`mestra-cli`, `$MATLAB` the MATLAB launcher and `julia` the Julia
one. The four implementations were read from `main` and none was
modified. HDF5 is 1.12.2, h5py 3.11, netCDF-C 4.9.3 with its `ncdump`
and `nccopy`, h5netcdf 1.8.1, netCDF4 1.7.4; the C++ tool was built
against the same 1.12.2. Main moved four times while this ran, which
section 2.0 is about: unless a table says "before", it was measured
against main as it stood at the end of the study, after the four
Phase 3 fix branches had landed.

A warning about the times, and only the times. The machine was shared
with unrelated work throughout, and for part of the session heavily:
three or four other processes held CPU on eight cores. Every timed
call below is the smallest of three attempts, and each language's
whole sweep ran in one pass so that the sweep sees one load, but the
absolute seconds are indicative rather than reproducible. What the
tables are for is the shape of each curve and the ratio between two
layouts of the same file, and those survive a busy machine. Nothing
in sections 1, 3 and 4 is a timing: those are what the library and
the readers did, and they would be the same on an idle machine.


1. The 4085 ceiling, and what lifts it
---------------------------------------

### 1.1 What fails

Section 21 requires exactly one dimension scale on every axis of
every dataset, and `row` is the axis of every key, every scalar,
every row-varying array and `/row_support`. HDF5 records each
attachment twice: forwards in the attached dataset's DIMENSION_LIST,
and backwards in the scale's REFERENCE_LIST. REFERENCE_LIST is one
attribute on one object and it grows with every attachment.

Measured, with `ceiling.py sizes`, on the scale's own attribute:

    attachments   element size   attribute bytes on disk
              1             16                        16
              2             16                        32
           1000             16                    16 000
           4000             16                    64 000
           4084             16                    65 344
           4085             16                    65 360

The element is the compound H5DSattach_scale writes: an eight-byte
object reference and a four-byte dimension index, sixteen bytes on
disk after padding. No HDF5 object header can hold a message larger
than 64 KiB, and a compact attribute is one message: its data plus
its name, datatype and dataspace, which come to about 160 bytes here.
A version 2 object header has somewhere else to put an attribute --
the file's fractal heap, where the message limit does not apply -- and
a version 1 object header has not. So under the default library
version bounds, which write version 1 headers, 4085 attachments fit
in 65 360 + 160 bytes and 4086 do not.

The failing call, with the HDF5 error stack left visible by
`ceiling.py stack`, is not H5DSattach_scale itself but the attribute
creation inside it:

    #000: H5A.c line 298 in H5Acreate2(): unable to create attribute
    #004: H5Aint.c line 268 in H5A__create(): unable to create
          attribute in object header
    #005: H5Oattribute.c line 317 in H5O__attr_create(): unable to
          create new attribute in header
    #007: H5Omessage.c line 1847 in H5O__msg_alloc(): unable to
          allocate space for message
    #008: H5Oalloc.c line 1291 in H5O__alloc(): object header message
          is too large

and what Python sees is
`RuntimeError: Unspecified error in H5DSattach_scale (return value <0)`.

This is a ceiling on the container in its present layout and not on
any implementation. It reproduces in a plain HDF5 file and in a
conforming mestra file alike:

    $PY docs/scale/scripts/ceiling.py reproduce $SCRATCH/files
    $PY docs/scale/scripts/mkfiles.py \
        vectors/cases/mesh_two_rows/case.mes $SCRATCH/n \
        4085 4086 --layouts default

    N        default layout
    1000     written
    4000     written
    4085     written
    4086     refused, at the 4086th attachment
    8000     refused, at the 4086th attachment

### 1.2 What the failure leaves behind

H5DSattach_scale deletes the old REFERENCE_LIST before it writes the
longer one, so the failure is destructive. The file left on disk has
a `row` scale carrying CLASS and NAME and no REFERENCE_LIST at all,
while all 4086 datasets keep their DIMENSION_LIST.

Nothing downstream notices. On that file the C++ validator reports
`0 error(s), 0 warning(s)`; `ncdump -h` still prints `double cl(row)`
and `row = UNLIMITED ; // (2 currently)`; the netCDF4 package still
reports `cl` as having dimension `row`. No rule in section 14 is
about REFERENCE_LIST, and every reader resolves an axis from the
forward reference.

All four writers do raise on the failed attachment -- the C++ writer
checks the return, and the other three are raised for them by h5py,
HDF5.jl and the MATLAB H5DS wrapper -- so no writer ships such a file
while it is working correctly. What it means is that a partly written
file must be deleted rather than kept: it passes every check the
format has and it has lost the back references netCDF-C would need to
rebuild the dimension.

### 1.3 The property calls that lift it

Five property choices were tried against the library defaults, each
on the same content (`ceiling.py reproduce` for a plain HDF5 file,
and `mkfiles.py --layouts ...` for the conforming one). Only the
second column matters: whether the 4086th attachment succeeds.

    property call                                  8000 attachments
    ------------------------------------------------------------
    (the library defaults)                         refused at 4085
    H5Pset_attr_phase_change(dcpl, 0, 0)           refused at 4085
        on the scale alone
    H5Pset_attr_creation_order(dcpl, TRACKED)      written
        on the scale alone
    H5Pset_attr_creation_order(dcpl,               written
        TRACKED | INDEXED) on the scale alone
    H5Pset_libver_bounds(fapl, V18, LATEST)        written
    H5Pset_libver_bounds(fapl, LATEST, LATEST)     written

The one that looks like the answer is the one that does not work.
Asking for dense attribute storage directly, with
H5Pset_attr_phase_change, is silently ignored while the file's low
library version bound is the default: dense storage needs a version 2
object header, the default bound will not write one, and the property
has nowhere to be recorded. The file that comes out has no version 2
object header and no fractal heap in it, and it stops at 4085 like
any other.

What works is anything that promotes the scale's object header to
version 2, because then its attributes can live in the file's
fractal heap, where there is no 64 KiB message limit. Tracking
attribute creation order does that for one object at a time; the
library version bounds do it for every object in the file. With a
version 2 header the same scale carries 8000 attachments in a
128 000-byte REFERENCE_LIST without complaint.

The recommended pair, because it is exactly what netCDF-C sets and
because it changes one object and not the file, is

    H5Pset_attr_creation_order(dcpl,
        H5P_CRT_ORDER_TRACKED | H5P_CRT_ORDER_INDEXED);
    H5Pset_obj_track_times(dcpl, 0);

on the dataset creation property list of every dimension scale. The
second call is not optional: a version 2 object header records four
timestamps unless it is told not to, and a file that records when it
was written is not byte reproducible.

### 1.4 What each choice costs

From `mkfiles.py`, on the same content. "Version 2 headers" counts
the objects whose header carries the OHDR signature; the file at 250
slots has 275 objects. "Two runs" is the same file written twice a
second apart and compared byte for byte.

    layout            250 slots    8000 slots   v2 headers   two runs
    ---------------------------------------------------------------
    default             676 760             -            0  identical
    scale-phase         676 760             -            0  identical
    scale-order         676 183    21 086 806           10  identical
    scale-nc            676 239             -           10  identical
    v18                 630 136             -          275  (not run)
    latest              198 906     5 857 632          275  differ
    latest-notimes      198 772             -          275  identical

Three things to take from it. The scale-only lift is free: ten
objects change and the file is 577 bytes smaller at 250 slots,
because a version 2 header is more compact than a version 1 one. The
whole-file latest layout is three and a half times smaller, and the
saving is the chunk index: the 250-slot file carries 261 version 1
B-tree nodes in the default layout, 250 of them under the V18 bounds,
and none at all under the latest bounds, where a dataset of one chunk
gets an index that fits in its header. That is a real saving, and
section 2 shows what it used to cost to read. And the determinism
cost of the latest layout, which `julia/README.md` and
Phase 3 finding 8 both describe, is not inherent: the four timestamps
appear at offsets 0x36, 0x3a, 0x3e and 0x42 of every version 2 object
header whose creating property list tracks times, and turning tracking
off in the three places it can be set -- the file creation property
list, for the root group; every group creation property list; every
dataset creation property list -- makes the latest layout byte
reproducible too. netCDF-C sets it on everything it creates and its
own output is byte identical across runs.

### 1.5 Who can still read the file

`readable.py` over every layout at 250 slots, and over the lifted
layouts at 4086 and 8000 slots. Every reader was asked for the same
two things: does the file parse, and what does it call the axis of
`/scalars/cl`.

    reader      default  scale-  scale-  scale-  v18  latest
                         order      nc   phase
    ------------------------------------------------------
    netCDF-C         ok      ok      ok      ok   ok      ok
    h5netcdf         ok      ok      ok      ok   ok      ok
    netCDF4          ok      ok      ok      ok   ok      ok
    C++              ok      ok      ok      ok   ok      ok
    Python           ok      ok      ok      ok   ok      ok
    MATLAB           ok      ok      ok      ok   ok      ok
    Julia            ok      ok      ok      ok   ok      ok

The latest-notimes layout was checked too and is the same seven
"ok"s; it is left out of the table to keep it to one page.

"ok" means, for the three netCDF readers, that the file parsed and
that `cl` came back with the single dimension `row`, and for the four
implementations, that the validator reported no error and no warning
and that the metadata open reported two rows. At 8000 slots the
netCDF readers see 8007 variables and ten dimensions in both lifted
layouts and still name `cl(row)`; C++, MATLAB and Julia read the
4086-slot lifted file clean. No layout changed what any reader
returned. Nothing here is close to a boundary: the lift is invisible
to every consumer tested.

### 1.6 What netCDF-C chooses, and whether its own big file exists

It exists. `nccheck.py` writes 8000 variables on one unlimited
dimension through netCDF-C in 5.2 s and 3 847 144 bytes, with a
REFERENCE_LIST of 8000 entries and 128 000 bytes on the dimension's
scale. netCDF-C has no ceiling here and never had one.

What it sets, read back from the property lists of the file it wrote:

    superblock version                           2
    root group link creation order               tracked and indexed
    root group attribute creation order          tracked and indexed
    every dataset, attribute creation order      tracked and indexed
    every dataset, attribute phase change        the default, (8, 6)
    every dataset, object time tracking          off
    version 2 object headers in the file         8002 of 8002

So netCDF-C does not set the library version bounds -- the superblock
is version 2 and not the version 3 that the latest bounds produce --
and it does not touch the attribute phase change. It tracks creation
order, on everything, and that is what promotes every object header to
version 2 and puts the long REFERENCE_LIST in the heap. The
recommended lift in 1.3 is the same call on the one object that needs
it.

Finding 18 is right that netCDF-C cannot write a conforming file, and
the reasons are more than the one it names. Measured on a file
netCDF-C wrote and on a golden case it copied:

  - every text attribute is ASCII with NUL termination where section
    18 requires fixed-length UTF-8 with NUL padding (E19);
  - every scalar attribute becomes a one-element array, so `aligned`,
    `lower`, `upper`, `n_nodes`, `n_cells` and `components` all change
    shape;
  - the scale of an unlimited dimension is left at length 0, where
    section 21 requires the scale's own length to equal the row count;
  - dimension scales are written contiguous, where section 21
    requires them chunked;
  - a variable on the unlimited dimension is chunked at 512 rows,
    where section 23's default is derived from the row size;
  - it adds `_NCProperties` to the root, `_Netcdf4Dimid` to every
    scale and `_Netcdf4Coordinates` to every variable.

The format is readable by netCDF tooling and not writable by it.


2. Object header layout: four readers against the count
--------------------------------------------------------

### 2.0 The implementations moved while this ran

This study began against the tree Phase 3 reported on. While it ran,
four pull requests landed on main, three of which fix findings this
section was written to measure: Python's quadratic open (finding 4),
the C++ half of finding 8, and Julia's quadratic validator (finding
17). Every table below is against main at the end of the study unless
it says "before", and a "before" row is the same measurement against
the tree Phase 3 saw. Nothing in the format changed; only the four
readers did.

One writer changed too, and it matters here. Julia's writer used to
produce the whole-file version 2 layout, which is what finding 8 is
about; it now writes the same layout as the other three. Measured:
two runs a second apart give byte-identical files of 35 808 bytes
with no version 2 object header in them. So no writer of the four
produces the `latest` layout any more, and the second column of every
table below is a layout that only another tool would hand you.

The files are a corpus case with extra scalar columns, built by
`mkfiles.py`, in two layouts: `default`, which is what all four
writers produce, and `latest`, which is the whole-file version 2
object header layout. Each reader was asked for the metadata open of
section 29, the validator, and one lazy read of `/scalars/cl` for a
row range, which section 29 says must touch no other slot. `p` is the
exponent between that size and the one above it: 1 is linear, 2 is
the square.

    $PY docs/scale/scripts/mkfiles.py \
        vectors/cases/mesh_two_rows/case.mes $SCRATCH/n \
        125 250 500 1000 2000 4000 --layouts default,latest
    $PY docs/scale/scripts/fit.py $SCRATCH/out/time_*.log

### 2.1 C++

Timed in one process against the library, not through `mestra-cli`,
because the tool's `info` command validates the file before it prints
anything: on the file of section 5 `info` costs 7.5 s and the
library's `read_header` costs 0.018 s. `time_open.cpp` is the
program.

    N        open  validate  one row range   |   open  validate  range
             ---------- default ----------   |  ---------- latest ----
     125    0.100     0.060      0.002       |  0.097     0.063  0.002
     250    0.183     0.118      0.003       |  0.185     0.112  0.003
     500    0.368     0.227      0.007       |  0.350     0.224  0.005
    1000    0.745     0.508      0.015       |  0.699     0.451  0.013
    2000    1.633     1.075      0.031       |  1.502     0.932  0.025
    4000    2.977     1.744      0.049       |  3.095     1.939  0.051
    8000        -         -          -       |  6.149     3.586  0.123

    exponent over the last doubling:  open p0.87, validate p0.70,
    range p0.68 (default); open p0.99, validate p0.89, range p1.27
    (latest). Linear in both.

Before, on the same files through the same tool: the latest layout
cost 6.9 s to validate at a thousand datasets and 24.1 s at two
thousand, against 0.76 s and 1.61 s in the default layout. That is
the quadratic finding 8 describes, and it is gone: the two layouts
now cost the same. The 8000-dataset file in the default layout does
not exist, because of section 1.

### 2.2 Python

    N        open  validate  one row range   |   open  validate  range
             ---------- default ----------   |  ---------- latest ----
     125    0.134     0.105     0.0003       |  0.151     0.122 0.0003
     250    0.249     0.185     0.0002       |  0.290     0.233 0.0004
     500    0.514     0.389     0.0002       |  0.556     0.429 0.0003
    1000    1.009     0.847     0.0003       |  1.044     0.755 0.0003
    2000    1.984     1.690     0.0003       |  1.776     1.394 0.0002
    4000    4.397     3.452     0.0004       |  3.423     3.402 0.0003
    8000        -         -          -       |  7.837     6.235 0.0003

    exponent over the last doubling:  open p1.15, validate p1.03
    (default); open p1.20, validate p0.87 (latest). Linear in both.

Before, the same open of the 250-dataset file cost 32.1 s in the
default layout and 37.2 s in the latest one, against 0.25 s and 0.29
s now: a hundred and thirty times. The lazy row range is the one
measurement that is the same in every column, because it reads one
chunk and nothing else.

### 2.3 Julia

    N        open  validate  one row range   |   open  validate  range
             ---------- default ----------   |  ---------- latest ----
     125    0.062     0.045      0.002       |  0.378     0.214  0.128
     250    0.132     0.109      0.004       |  0.471     0.250  0.145
     500    0.285     0.237      0.011       |  0.530     0.346  0.135
    1000    0.648     0.445      0.018       |  0.723     0.455  0.127
    2000    1.208     0.960      0.039       |  1.101     0.816  0.148
    4000    2.222     1.715      0.086       |  2.217     1.717  0.199
    8000        -         -          -       |  5.065     3.439  0.239

    exponent over the last doubling:  open p0.88, validate p0.84
    (default); open p1.19, validate p1.00 (latest). Linear in both.

Before, in the default layout: 2.40 s to open the 250-dataset file,
30.6 s at a thousand and 516 s at four thousand, with p 2.04 over the
last doubling. That is finding 17, and it turns out to have been the
open as well as the validator, which is a correction to the finding:
the reader was not "not affected". It is now linear and two hundred
and thirty times faster at four thousand.

The lazy row range is worth a sentence in every language. It is not
flat, because a reader has to find the slot before it can read it, so
the range carries whatever the open costs: in Julia it goes from
0.002 s at 125 datasets to 0.086 s at four thousand in the default
layout, and sits between 0.13 s and 0.24 s across the whole range in
the latest one, which is a fixed cost of that layout rather than a
scaling fault. What it never does in any of the four is grow with the
size of the slot: that is the point of section 29, and section 5
shows it on a file where one field is 144 MiB.

### 2.4 MATLAB

    N        open  validate  one row range   |   open  validate  range
             ---------- default ----------   |  ---------- latest ----
     125    0.408     0.435      0.031       |  0.608     0.675  0.073
     250    0.622     0.695      0.050       |  1.116     1.194  0.200
     500    1.266     1.292      0.099       |  2.980     3.067  0.647
    1000    2.700     3.662      0.336       |  8.070     9.844  2.788
    2000    9.457     5.447      0.706       | 36.844    26.534 11.239
    4000   22.502    20.125      1.480       |      -         -      -

    exponent over the last doubling:  open p1.25, validate p1.89,
    range p1.07 (default); open p2.19, validate p1.43, range p2.01
    (latest). Worse than linear in the default layout and quadratic
    in the latest one.

MATLAB is the one reader of the four that is still super-linear, and
the only one for which the two layouts still differ: at a thousand
datasets the latest layout costs three times the default one and at
two thousand it costs four, which is the quadratic showing. The
dashes are not missing measurements but the shape of the problem. A
first sweep, which included the 8000-dataset files, was stopped after
forty-five minutes on `n08000_latest.mes`; the sweep above reached
two thousand in that layout and no further inside the time this study
had. Every other reader opens the 8000-dataset file in under seven
seconds.

The profiler says where it goes, on the file of a thousand datasets
in the latest layout:

    $MATLAB -batch "profileMestra('open', \
        '$SCRATCH/n/n01000_latest.mes')"

    function                                 seconds      calls
    Reader.load                               20.282          1
    Reader.readScalar                         12.901        997
    H5.scalarAttr                              6.113       6047
    Reader.str                                 5.776       5033
    H5.attrNames                               5.599       9085
    id.delete                                  5.555      55831

The call counts are all in proportion to the dataset count and not to
its square, so part of this is simply a large constant: six attribute
reads, nine attribute listings and fifty-six HDF5 identifier closes
per dataset. The rest is the layout, and
`matlab/+mestra/+internal/H5.m` still lists a group's links with
`H5L.get_name_by_idx`, one index at a time, which is the call the C++
fix replaced with a single pass for exactly this reason.

The layout section 6.1 recommends was measured too, at the size that
only it and the latest layout can reach. Reading the 8000-dataset
file written with the scale-only lift, against the same file in the
whole-file latest layout:

    reader     open  validate  range   |   open  validate  range
              ------ scale-order ----  |  -------- latest -------
    C++       5.692     3.521  0.101   |  6.149     3.586  0.123
    Python    8.689     6.167  0.000   |  7.837     6.235  0.000
    Julia     5.654     3.753  0.327   |  5.065     3.439  0.239
    MATLAB        -         -      -   |      -         -      -

The lift costs nothing to read. It is the same file in the same
layout everywhere except ten objects, and the ten objects are scales
nobody reads a value from.

### 2.5 Where the time went, by name

The three fixes that landed during this study, and the profiles that
name them, are worth recording because the same two mistakes were
made independently in three languages.

Python, before: `python/mestra/h5safe.py`, `scale_index`. It caches
the index of scales on the file handle it is given, and `axis_names`
gave it `dataset.file`, which h5py builds fresh on every read. The
cache therefore never hit and the whole file was walked once per
dataset. The profile of the 250-dataset open: 1027 calls to
`scale_index`, 282 233 calls to `_member`, 276 048 h5py `File`
objects built, 32.2 s of 32.8 s. After the fix the same profile is
flat: h5py attribute reads, in proportion to the dataset count.

C++, before: `cpp/src/h5.cpp`, `File::members`, which listed a
group's links with `H5Lget_name_by_idx` and `H5Lget_info_by_idx2`,
three indexed lookups per link. On a group whose links are in the
heap -- which is what the latest layout does -- each indexed lookup
rebuilds the whole link table, so one walk of a group of N links
costs N squared. A sample of the 2000-dataset open put 8520 of 8898
samples in `H5G__dense_build_table` below that call.

Julia, before: `julia/src/h5low.jl`, `attached_scale`, which asked
`H5DSis_attached` of every candidate scale for every axis of every
dataset. That call reads the scale's REFERENCE_LIST, which is as long
as the number of attachments, so it costs the count on every call. A
sample of the 1000-dataset validate put 1639 of 1688 samples in
`h5ds_is_attached`.

MATLAB, now: `matlab/+mestra/+internal/H5.m`, `H5.attrNames` and
`H5.scalarAttr` under `Reader.readScalar`, and the same indexed link
listing the C++ fix replaced.


3. Section 21's claim about netCDF-C
-------------------------------------

What section 21 claims, in the paragraph on making `row` unlimited:

    "Making it unlimited in every file has three effects: [...] and
    the layout matches what netCDF-C itself writes, so a round trip
    through netCDF-C changes nothing."

What is true is the first half and not the second. The layout of the
`row` scale is the layout netCDF-C reads as an unlimited dimension,
and every netCDF reader tested agrees about it. A round trip through
netCDF-C changes a great deal. `nccheck.py` runs `nccopy -k nc4` over
a golden case and lists what survives; the C++ validator then reports
38 errors and 4 warnings on the copy. The changes are the six in 1.6
above, applied to every object of the file, plus the `row` scale
going from length 2 to length 0.

The corrected sentence, to replace the clause after the second
semicolon:

    "and the layout is the one netCDF-C reads as an unlimited
    dimension. That is a claim about reading and not about round
    trips: a file that netCDF-C has written or copied is not a
    conforming file, and section 13 says why."


4. A second unlimited dimension
--------------------------------

The spec neither allows nor forbids it, and the four implementations
do not disagree until the dimension is used. Measured with
`mkfiles.py --unlimited` and `probe4.py`, on the corpus case
`draws_and_summaries`, whose `draw_3` dimension has length three.

A file whose `draw` dimension is unlimited and still three long: all
four validators report no error and no warning, all four readers open
it, and all five of the case's probes come back identical and correct
in all four languages. `ncdump -h` shows two unlimited dimensions,
`row` and `draw_3`, which netCDF-4 allows.

The same file after one more draw is appended, so that the array has
four draws and the scale is four long:

    reader    validator      what a read does
    ------------------------------------------------------
    Python    E25 and W12    refuses, naming E25
    MATLAB    E25 and W12    returns the dataset
    C++       W12 only       returns 999.0 at draw 3
    Julia     W12 only       returns 999.0 at draw 3

Python's message says it exactly: "axis 1 carries the dimension
draw_3, which is not the name section 21 requires". MATLAB's
validator says the same and its reader returns anyway, which is
Phase 3 finding 13 and not this one. Every dimension except `row` has
its length in its name -- `draw_<n>` and `component_<n>` directly,
`group_<k>` and `category_<t>` through the table they name -- so a
dimension that grows makes its own name false. Two validators catch
that and two do not; one reader of the four refuses the file, and two
hand back the value at the new draw. W12 appears everywhere because
growing the array also makes its chunk shape no longer the default of
section 23.

The recommendation is forbid, and the reason is the naming rule
rather than any reader's behaviour: the only dimension whose name
does not record its length is `row`, so `row` is the only dimension
that can grow. Allowing it would mean renaming a scale on append,
which means rewriting the DIMENSION_LIST of every dataset that uses
it; ignoring it leaves a file that two implementations read and two
refuse.

One exception has to survive the rule. Five corpus cases already
contain an unlimited dimension that is not `row`: the scales of the
zero-length dictionary datasets inside a callable, such as
`callables/m1/outputs/cl/mestra_shape_d0`, which section 25 requires
to be unlimited because HDF5 has no other legal way to write a
zero-length axis. The wording in section 6 below keeps them.


5. One file the size a real dataset will be
--------------------------------------------

`bigfile.py` builds it through the Python builder: 500 rows on one
mesh support of 36 000 nodes and 35 621 quadrilateral cells, six node
fields, two scalars and three keys, one of them a group key with a
category table. The fields are a smooth function of position and of
the row's parameters plus a small random perturbation, so that they
compress about as well as real field data. Every row-dimensioned
dataset is chunked by the default of section 23, which works out at
(3, 36000, 1), and gzipped at level 4, which section 23 allows.

    field values before compression      824 MiB
    the file                             743 997 554 bytes (710 MiB)
    built from arrays and written        125.7 s, peak resident 939 MiB
    the C++ validator on it              0 error(s), 0 warning(s)

The compression ratio is 1.16, which is what noisy float64 gives.

### 5.1 Reading it

Each reader was asked for four things: the metadata open of section
29, the validator, one lazy read of ten rows of one field (2.7 MiB of
the 144 MiB that field holds), and the whole of that field. Seconds,
and the peak resident size of the process.

    reader      open   validate   ten rows   whole field   peak
    ------------------------------------------------------------
    C++        0.018      6.84       0.025        1.06     168 MiB
    Python     0.030     18.79       0.063        2.76     248 MiB
    Julia      0.012      6.76       0.025        1.11     749 MiB
    MATLAB     0.188     50.82       0.044        0.78           -

MATLAB reports no peak resident size, which is why its cell is a
dash; the other three are from `getrusage` and `Sys.maxrss`.

Three things worth saying about that table. The metadata open is
free: tenths of a second at worst on a 710 MB file, and tens of
milliseconds in three of the four, which is section 29 working as
intended. The lazy row range is also free, and it is the number a
product will care about most: a twentieth of a second to pull ten
rows of one field out of a 710 MB file without touching anything
else, in every language. And the validator is not free and cannot be:
W03 asks it to report NaN and W04 to report values outside a key's
bounds, so a validation reads and decompresses all 824 MiB. Seven
seconds for that is the floor; Python's nineteen seconds and MATLAB's
fifty-one are the same work in a slower loop. A product that
validates on every open will feel that, and a product that validates
on write and then trusts its own files will not.

One thing that is not in the table: `mestra-cli info` on this file
costs 7.5 s, because the tool validates before it prints. The
library's own metadata open, which is what section 29 is about, costs
0.018 s. A product that shells out to the tool for metadata is paying
for a validation it did not ask for.

### 5.2 Writing it

Each writer was asked to read the file and write it again, through
the driver Phase 3 already has for it, so the work is the same in
every language. The time includes the eager read; the `start` column
is the same call on a two-row file and is what to subtract for the
interpreter.

    writer     start   read and write again   bytes written  gzip
    ---------------------------------------------------------------
    Python      0.2 s                109.9 s     743 997 554  kept
    C++         0.2 s                 11.7 s     867 894 141  lost
    Julia      24.2 s                 91.6 s     743 997 208  kept
    MATLAB     13.8 s                 71.6 s     867 895 837  lost

All four write a file the C++ validator accepts, and two of them
write a different file from the one they read: C++ and MATLAB drop
the gzip filter. The chunk shape survives both round trips and the
compression does not, so 710 MiB in becomes 828 MiB out, and a
producer that round-trips a real dataset through either of those two
grows it by a sixth every time. The two fast times in the table are
the same fact seen from the other side: neither of those writers is
doing any compression work.

On the C++ side this is a gap in the model rather than a slip in one
function: `cpp/include/mestra/dataset.hpp` carries
`chunk_overrides`, so a chunk shape that is not the default survives
a round trip, and there is nowhere in it to put a filter.

    $CLI roundtrip $SCRATCH/big/big.mes $SCRATCH/big/rt.mes
    $PY -c "import h5py
    for p in ('$SCRATCH/big/big.mes', '$SCRATCH/big/rt.mes'):
        d = h5py.File(p)['/supports/s0/node_arrays/pressure']
        print(p, d.chunks, d.compression, d.compression_opts)"

prints chunks (3, 36000, 1) and `gzip 4` for the source, and the same
chunks and `None None` for what C++ wrote. The same two lines through
`mestra.read` and `mestra.write` in MATLAB give the same answer.

Nothing in the corpus could have caught this: not one of the seventy
cases carries a filter at all, so the cross-write matrix of Phase 3
never asked any writer to preserve one. `python/README.md` states the
rule the other two are breaking -- "everything a file said about its
own layout survives being read and written again: a chunk shape that
is not the default, a compression filter" -- and it is the only one of
the four READMEs that states it. The specification does not require
it either: section 23 makes compression optional, so all four files
conform. What a producer will expect is another matter.

6. What the specification should say
-------------------------------------

Six changes to the specification, one line for the conventions, and
what it would cost the corpus. Only the first changes any byte of any
existing file.

### 6.1 Section 21: how a dimension scale is created (finding 11)

After the paragraph that ends "A writer that calls those two
functions produces the layout netCDF-C expects", add:

    A dimension scale is created with attribute creation order
    tracked and indexed, and with object time tracking off:

        H5Pset_attr_creation_order(dcpl,
            H5P_CRT_ORDER_TRACKED | H5P_CRT_ORDER_INDEXED);
        H5Pset_obj_track_times(dcpl, 0);

    which is what netCDF-C sets on every object it creates. The first
    call gives the scale a version 2 object header, so that its
    REFERENCE_LIST is kept in the file's heap rather than as an
    object header message, where an attribute may not exceed 64 KiB.
    Without it no scale can carry more than 4085 attachments:
    REFERENCE_LIST grows by sixteen bytes each time, and the 4086th
    H5DSattach_scale fails with "object header message is too large"
    after it has already deleted the attribute it was extending. The
    second call keeps the file byte reproducible, because a version 2
    object header records four timestamps unless it is told not to.
    No other object's property list is changed by this rule.

This is the whole of the lift. It is one call on one kind of object;
it leaves every other object's header at version 1; it was read by
netCDF-C, h5netcdf, the netCDF4 package and all four implementations
at 250, 4086 and 8000 row-dimensioned datasets; and the file it
produces is byte identical between two runs a second apart.

Two alternatives were measured and are worse. Setting the library
version bounds to V18 or LATEST lifts the ceiling too and makes the
file three and a half times smaller, but it changes the format of
every object in the file, it needs the same time-tracking call in
three places rather than one to stay reproducible, and section 2
shows that it is still the expensive layout for one of the four
readers. Asking for dense
attribute storage directly, with H5Pset_attr_phase_change, does not
work at all under the default library version bounds.

### 6.2 Section 19 and E27: one unlimited dimension (finding 15)

In section 19, in the "Zero rows" paragraph, after "A zero-length
extent is legal only for the `row` dimension and for a zero-length
axis of a dictionary dataset (section 25); every other dimension has
length one or more", add:

    `row` is also the only dimension that may be unlimited. Every
    other dimension scale, and every axis attached to one, is created
    with a maximum extent equal to its length (E27). The exception is
    a zero-length axis of a dictionary dataset, which section 25
    requires to be unlimited because HDF5 has no other legal way to
    write it.

and extend E27's line in section 14 from

    E27  `row` not an unlimited dimension, or a row-dimensioned
         dataset that is not chunked

to

    E27  `row` not an unlimited dimension; any other dimension
         unlimited, except a zero-length dictionary axis; or a
         row-dimensioned dataset that is not chunked

The reason to forbid rather than allow is the naming rule two
paragraphs above it in section 21: `draw_<n>` and `component_<n>`
carry their length in their name, and `group_<k>` and `category_<t>`
carry it through the table they name. `row` is the only dimension
whose name stays true when the dimension grows. Section 4 shows what
a grown one costs today: two implementations refuse the file with
E25 and two read it and hand back the value.

### 6.3 Section 21: the sentence about netCDF-C (finding 16)

Replace, in the "`row` in a zero-row file" paragraph,

    "and the layout matches what netCDF-C itself writes, so a round
    trip through netCDF-C changes nothing."

with

    "and the layout is the one netCDF-C reads as an unlimited
    dimension. That is a claim about reading and not about round
    trips: a file that netCDF-C has written or copied is not a
    conforming file, and section 13 says why."

### 6.4 Section 13: what netCDF tooling cannot do (finding 18)

In section 13, after "The layout is constrained so that a valid file
is also a valid netCDF-4 file", add:

    The converse does not hold. netCDF-C reads every file this format
    defines, and cannot write one: its text attributes are ASCII with
    NUL termination where section 18 requires fixed-length UTF-8 with
    NUL padding, it writes a scalar attribute as a one-element array,
    it leaves the scale of an unlimited dimension at length 0 where
    section 21 requires the row count, it writes dimension scales
    contiguous where section 21 requires them chunked, and it adds
    `_NCProperties`, `_Netcdf4Dimid` and `_Netcdf4Coordinates`. A
    file that has been through netCDF-C, including through `nccopy`,
    must be written again by a conforming writer before it is a
    conforming file.

### 6.5 Section 21: how an attachment is resolved

Section 21 already tells a reader to build a map from each scale's
address to its link name and to resolve attachments through it. Add
one sentence, because a reader that does it another way is wrong and
not merely slow:

    A reader resolves an axis through the dataset's own
    DIMENSION_LIST and that map, and not by asking the library
    whether a scale is attached: H5DSis_attached consults the scale's
    REFERENCE_LIST as well, so it costs the length of that list on
    every call and it answers no for a file whose REFERENCE_LIST has
    been lost, where the dimension is still named by DIMENSION_LIST.

Measured on a file whose `row` scale has no REFERENCE_LIST, which is
what a failed attachment leaves behind (1.2): C++, Python, MATLAB,
`ncdump` and the netCDF4 package all still call the axis `row`, and
Julia's `info` calls it `unknown`. No validator reports anything on
that file.

### 6.6 A note in section 29 on what an open costs

Section 29 says what an open may read. It says nothing about what it
may cost, and it should not, because a speed limit in a data format
is a rule nobody can check. A non-normative note would still be worth
the space, because three of the four implementations have shipped the
same two mistakes:

    Note. Both of the natural ways to resolve axis names are
    quadratic in the number of row-dimensioned datasets. Building the
    index of scales once per dataset rather than once per open costs
    the square, and so does asking the library whether each candidate
    scale is attached, because that reads the scale's REFERENCE_LIST
    each time. Listing a group's links by index, rather than in one
    pass, costs the square again on a file written under the newer
    object header layout, where links are held in a heap and each
    indexed lookup rebuilds the table.

### 6.7 What would change in the golden files

Only 6.1 touches bytes, and it touches all of them: every file in
`vectors/` has at least a `row` scale, and a scale's object header
changes version. Measured on one corpus case rebuilt both ways by
`mkfiles.py`: 35 880 bytes against 35 468, and 6 578 differing bytes
in the common prefix, because every offset after the first scale
moves. The two files are structurally equal under section 30's rule,
and `docs/verification/structural.py` says so, so the change is
invisible to the normative comparison and visible to `check.py`,
which compares bytes first.

So 6.1 has to land in the same change as a regeneration of
`vectors/`, as `vectors/README.md` already requires for any change
that moves the bytes. Nothing in 6.2 to 6.6 changes a byte: no corpus
case has an unlimited dimension other than `row` and the five
dictionary axes the exception keeps, and the rest is prose.


### 6.8 One line for the conventions, not the specification

Section 5.2 shows two writers of the four dropping the gzip filter on
a round trip. That is not a conformance fault -- section 23 makes
compression optional and all four files validate -- so it does not
belong in the specification. It belongs in
`docs/api-conventions.md`, section 2, beside the sentence about what
`write` does, as the rule three of the four already follow in spirit:

    A writer that was given a dataset a reader produced writes the
    filters that dataset came with, as it already writes the chunk
    shape it came with. A reader therefore has somewhere to keep
    them.

and in the corpus as a case with a compressed array, which is what
would have caught it.

7. Before any product adopts the format
----------------------------------------

Three things, in this order. Land the dimension-scale property rule
of 6.1 and regenerate the corpus in the same change: the 4085 ceiling
is the only finding in this report that a product cannot work around,
because it is the container and not a reader; the fix is one call on
one kind of object; every reader tested here reads the result at four
thousand and at eight thousand; the file stays byte reproducible; and
a product that ships files before the rule lands will have to rewrite
every one of them that outgrows four thousand columns. Settle the
second unlimited dimension in the same round, because a file that has
appended a draw is read by one implementation today, refused by
another and accepted with an error by the other two, and that is the
worst kind of disagreement to discover after the files exist. Then
give the corpus the two cases it does not have: one with a few
thousand row-dimensioned datasets, which costs about ten megabytes
and would have caught every cost finding in this report and the
ceiling itself, and one with a compressed array, which costs about a
kilobyte and would have caught two of the four writers dropping gzip
from a 710 MB file. The format itself came out of this well, and that
is worth saying plainly: a real dataset at 500 rows on a 36 000-node
support opens in tenths of a second or less, gives ten rows of one
field in a twentieth, holds 824 MiB of field values in a 710 MB file,
and validates in seven seconds in the two fastest of the four
languages. What is not ready is the evidence around it. The corpus
tests six nodes and three rows, and every single thing that broke in
this study broke above that size.
